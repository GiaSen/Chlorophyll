# Chlorophyll on Turnip (branch `turnip`, 2026-10-26)

Goal (user, 2026-10-26): run Chlorophyll on Mesa's Turnip (Vulkan) instead of Gallium freedreno, and **drop Gallium completely**.
The reason is CPU cost per draw. On Gallium, backboardd spends 20-55 ms encoding a frame of 170-270 draws (0.1-0.2 ms per draw),
so home-screen swipes run at 14-35 fps, while the A630 at 710 MHz is at most 60 % busy.

Status: Turnip is built for iOS and **runs on the phone**. It creates an instance and a device on the A630, clears an image, draws a
triangle and reads it back with every pixel correct. It encodes a 200-draw frame with per-draw state changes in about 0.8 ms.
The Metal runtime (`air_metal.c`, `bgmtl.m`) is not ported yet. The plan for that is below.

## 1. What other XNU-on-Snapdragon projects give us (read 2026-10-26)

Both repositories were read as shallow clones. Their GPU kernel drivers, Metal plug-ins and AIR compilers are submodules that the clone
did not include (UniXNU: `drivers/Adreno740`, `drivers/AdrenoMetal`, `kits/AirNir`; Snapintosh: `gpu/adreno-kext/*`, `gpu/air2ir3`).
So anything said about those parts comes from their documentation only.

**UniXNU** (<https://github.com/UniXNU/UniXNU>, BSD-2-Clause-Patent; new Mesa files are SPDX MIT)
- Boots iPadOS 17.7 through UEFI on a Xiaomi Pad 6S Pro (SM8550, Adreno 740). It uses a patched open-source XNU (xnu-10063, about 60
  patches), so it is an XNU port much like ours.
- GPU path: Apple's Metal front end, then metal2vulkan (AIR to SPIR-V, the external Rust project `steelbrain/metal2vulkan`), then
  Turnip, then a Darwin kernel backend, then their Adreno740 kext. **They run Turnip on XNU.** This is the same idea as ours with a
  different shader path.
- The code present is `patches/mesa/turnip-darwin-kmd.patch`, a new `tu_knl_darwin.cc` (1112 lines) modelled on the kgsl and msm
  backends:
  - IOKit service `IOAccelerator`; every call is tunnelled through one selector.
  - BOs have 64-bit handles, and the GPU addresses are chosen by the client.
  - Mappings come from `IOConnectMapMemory64` (write-combined).
  - One ring; fences are 32-bit integers waited on by the CPU, with no syncobjs. A 256-entry deferred BO retire queue.
  - Darwin fixes: no `pthread_condattr_setclock`; `CTR_EL0` traps at EL0; `vkGetInstanceProcAddr` exported for use without a loader.
- It targets Mesa main (about 26.x, pin `85fda3b3`), not 25.0.7. The kernel ABI header (`NativeAdrenoABI.h`) is not in the repository.
- Smaller MIT patches that also apply to A6xx: `turnip-empty-scissor`, `turnip-graphics-cache-feedback`, `ir3-portable-asm-roundtrip`
  (`fmemopen` instead of `open_memstream`), `ir3-darwin-build-id` (a 16-byte LC_UUID accepted as the build id), and
  `turnip-host-import-images` (images on `VK_EXT_external_memory_host` memory).

**Snapintosh** (<https://github.com/Snapintosh/Snapintosh>, MIT plus some GPL-2.0 files)
- An EL2 hypervisor that runs Apple's stock macOS 27 kernel on a Snapdragon X2 Elite (Adreno X2-90, an A8xx).
- Its GPU stack is an IOGPUFamily kext with its own Metal plug-in that encodes A8xx command streams, plus an AIR-to-ir3 compiler.
  There is no Turnip, freedreno or Vulkan in it.
- `compat/adreno-ib-tables.h` and its generator are GPL-2.0-only (from Linux msm): stay away from them.

**What we take:** the design confirmation (Turnip on XNU works, per-call cost decides smoothness), and the Darwin fixes we needed
anyway; we wrote ours independently against 25.0.7. `tu_knl_darwin.cc` is the template if we replace the msm emulation with a native
backend (phase T7 below). The small A6xx Turnip fixes are worth taking when we rebase.

**What we cannot take or do not need:**
- Their kexts and ABI (absent, and written for A740/A8xx).
- The XNU patches (APSL, and fitted to their kernel).
- metal2vulkan and AirNir (we already have AIR to NIR), and anything from Snapintosh's GPU tree.

## 2. Turnip for iOS: what was needed

Built by `turnip/build-turnip.sh` into `$GPU_METAL_WORK/mesa-turnip`, a separate tree and build directory. Gallium's
`mesa-air/build-ios`, which produces the `libbgair.dylib` installed on the phone, is not touched. The tree is pristine Mesa 25.0.7
plus Chlorophyll's compiler patches (`air-frontend`, `air-ir3`, the `ir3-*` fixes) and `patches/turnip-ios.patch`. No Gallium is
built: `-Dgallium-drivers= -Dvulkan-drivers=freedreno -Dfreedreno-kmds=msm`.

`patches/turnip-ios.patch` (61 lines):
- **meson:** `system_has_kms_drm` for darwin with the freedreno Vulkan driver; no `VK_KHR_display` / `wsi_common_display.c` (no KMS).
  The ICD links with undefined weak entry points allowed (`b_lundef=false`, as lavapipe does on macOS). Mach-O resolves the optional
  `vk_common_*` / `vk_cmd_enqueue_*` weak references at run time.
- **`tu_device.cc`:** no `pthread_condattr_setclock` on Darwin. Only the kgsl backend waits on that condition variable.
- **`tu_knl.cc`:** the L1 line size comes from `sysctlbyname("hw.cachelinesize")`. Reading `CTR_EL0` at EL0 raises **SIGILL** on our
  XNU, and that was the first failure on the phone.
- **`tu_knl.h`, `tu_knl.cc`, `tu_knl_drm.cc`, `tu_knl_drm_msm.cc`:** BO maps go through the stand-in's `sweet_drm_mmap` /
  `sweet_drm_munmap` (IOKit mappings, which cannot be placed). Turnip's msm backend accepts msm 1.4 on Apple: the stand-in reports 1.4
  for Gallium's sake and emulates syncobjs. `has_set_iova = false`: there is one GPU address space for every process
  (`PP_PGTABLE` 0), and Gallium's BOs live in it at kernel-chosen addresses, so Turnip takes the kernel's addresses too (`GET_IOVA`).

Build traps:
- Homebrew's host `SPIRV-Tools` leaked into the arm64e link through pkg-config's default search path. The cross file sets
  `pkg_config_libdir`.
- Turnip's BVH shaders need `glslangValidator` (`brew install glslang`).

**Bergamota side: the libdrm stand-in (`gpu/freedreno-sweet/sweet_drm.c`).** Additions only. What Gallium sees is unchanged:
`drmGetCap` still says no syncobj and `drmGetVersion` still says 1.4.
- **Syncobjs emulated on the kernel's fences.**
  - The kernel has one ring and one global fence sequence, so a syncobj is just a state here: unsignaled, signaled, or pending on
    fence F.
  - A submit's out-syncobjs become pending on its fence. Its in-syncobjs only need to have been submitted already, because the ring
    runs in order.
  - A CPU wait on a pending syncobj is `WAIT_FENCE`. `WAIT_FOR_SUBMIT` waits on a condition variable.
  - A submit with no command (Turnip signals semaphores that way) is not sent; it takes the last submitted fence.
  - Timelines are not emulated. Turnip emulates them on binary syncobjs, because no `DRM_CAP_SYNCOBJ_TIMELINE` is reported.
- **Device enumeration:** `drmGetDevices2` / `drmGetDevice2` return one platform device whose render node is `/dev/null`. Every
  `/dev/null` fd is the connection, as before.

## 3. On the phone (2026-10-26, boot 47 line, iOS 26.6.2, backboardd on Gallium at the same time)

`turnip/build-test.sh` builds `tu_smoke` (arm64e, PAC-stripped, signed with `turnip/entitlements.plist`: platform-application,
no-sandbox, `SweetAdrenoUserClient` in `com.apple.security.iokit-user-client-class`). It runs from `/var/root/turnip-test` next to
`libvulkan_freedreno.dylib` and the stand-in. Nothing was installed system-wide.

```
device: Turnip Adreno (TM) 630, Vulkan 1.3.305, driver turnip Mesa driver Mesa 25.0.7 (9.8 ms to here)
  memory type 0: flags 0x7 heap 0
  memory type 1: flags 0xb heap 0
device created (38.4 ms)
2 pipelines compiled in 14.6 ms
smoke submit+wait: done in 0.41 ms
smoke: centre ff0000ff corner ffff0000, 8192 red + 57344 blue of 65536 pixels (triangle area 8192 expected) -> PASS
```

The only kernel refusals in the trace were expected: `GET_PARAM` for an msm parameter the kernel lacks, and `SUBMITQUEUE_NEW` with
`ALLOW_PREEMPT`, which Turnip then does without. backboardd and SpringBoard kept running.

**CPU cost per draw, the same frame on both drivers.** The frame has N draws into a 256x256 RGBA8 target. Draws alternate a
flat-colour pipeline and a blended texture tap. Every draw binds per-draw vertex bytes and constants at offsets into one buffer,
which is what `setVertexBytes:` / `setFragmentBuffer:offset:` amount to. Encode is the CPU time to record the frame; the GPU wait is
measured separately.

| driver | test | draws/frame | encode per frame | per draw | GPU (submit to done) |
| --- | --- | --- | --- | --- | --- |
| Turnip | `turnip/test/tu_smoke.c` | 200 | 0.68-0.84 ms (min 0.28) | **3.4-4.2 us** | 0.85-0.91 ms |
| Turnip | | 1000 | 4.0 ms | 4.0 us | 4.5 ms |
| Gallium (`rwa_render_draw`) | `turnip/test/bgair_drawbench.c` | 200 | 1.8-3.3 ms (min 1.3) | **9-17 us** | 0.9-1.2 ms |
| Gallium | | 1000 | 9.2 ms | 9.2 us | 3.7 ms |
| Gallium in production (backboardd, bgmtl.m) | perf log | 170-270 | 20-55 ms | 100-200 us | |

What the table says:
- **The driver alone is 2.5-4x cheaper on Turnip.** The variance comes from CPU frequency and from backboardd competing for the CPU.
- **Most of production's 100-200 us per draw is above the driver**, in `bgmtl.m` and `air_metal.c`, not in freedreno:
  - an NSObject (`BGWork`) per draw that retains every slot, replayed at commit under the global `bg_lock`;
  - a GEM buffer and a mapping per `setVertexBytes:`;
  - per-draw validation, attachment views made anew each pass, and pipeline state re-bound unconditionally (`IOS26.md`,
    "Performance").
- **So swapping the driver underneath the same runtime would not give the 25-50x the raw numbers suggest.** The port has to record
  straight into Vulkan command buffers, as planned below. Vulkan's model makes that the natural design, which is the other reason
  for Turnip.

## 4. Port plan (Turnip only; Gallium is removed at the end)

The design follows the user's direction: one backend (Turnip), no Gallium fallback. Gallium stays only on the phone, as the
installed `libbgair.dylib`, until the Turnip runtime passes the tests. It is then deleted from the tree.

### Architecture

- **One dylib: `libbgair.dylib` = Turnip + libair + the new runtime `air/air_metal_vk.c`.** The runtime calls Vulkan entry points
  directly from inside the dylib, with no loader and no ICD indirection; dispatch is one function pointer.
- **Shaders as NIR, not SPIR-V.** `air_to_nir` produces NIR. The runtime wraps it with `vk_shader_module_handle_from_nir()` (Mesa's
  internal shader-module-from-NIR path, used for its meta shaders), so Turnip's pipeline code compiles it through ir3 without a
  SPIR-V round trip.
- **A binding bridge pass (`air_nir_vk.c`, new, about 300 lines).** `air_to_nir` emits Gallium-style flat indices: `load_ssbo` /
  `load_ubo` / `store_ssbo` with a buffer index, image intrinsics with an image index, tex with texture and sampler indices. The pass
  rewrites them onto one fixed Vulkan layout:
  - buffers become `vulkan_resource_index` and `load_vulkan_descriptor` on set 0;
  - textures, images and samplers become derefs of uniform variables with set and binding.

  Turnip's own descriptor lowering (`tu_shader.cc`) then takes over. ir3 on Turnip is bindless, so Mercury's dynamic image index and
  the texture phi lowering keep working as indexing into a descriptor array.
- **The fixed layout, one pipeline layout for every Metal pipeline:**
  - **set 0, a push-descriptor set** (`VK_KHR_push_descriptor`, which Turnip has): Metal buffer slots 0-30 as storage buffers, texture
    slots as sampled or storage images, sampler slots.
  - **Push constants:** the sub-64-byte buffer offset deltas that `add_ssbo_deltas` keeps in constant buffer 15 today, plus the
    sysvals `air_to_nir` reads from there. Turnip's `minStorageBufferOffsetAlignment` is 64, so the delta trick carries over.
  - **Later:** constant buffers of 64 KiB or less as UBOs, and buffer device addresses for argument buffers. A Metal argument buffer
    holds GPU addresses, and BDA is the natural match.
- **Encoders record straight into Vulkan; there is no BGWork replay.**

  | Metal | Vulkan |
  | --- | --- |
  | `MTLCommandBuffer` | one `VkCommandBuffer` from a per-thread pool |
  | `MTLRenderCommandEncoder` | `vkCmdBeginRendering` (dynamic rendering, core 1.3, which Turnip reports); load actions are `loadOp`; DontCare stores become `DONT_CARE` (perf item 11 for free) |
  | `setRenderPipelineState:` | `vkCmdBindPipeline` when the pipeline changed |
  | `set*Buffer` / `Bytes` / `Texture` / `Sampler` | dirty bits; at the draw, one push-descriptor update of the dirty slots and one push-constant update |
  | `drawPrimitives` / `drawIndexedPrimitives` | `vkCmdDraw` / `vkCmdDrawIndexed` |
  | `setVertexBytes:` / `setFragmentBytes:` | a per-command-buffer bump allocator over recycled persistently mapped slabs, retired at completion (perf item 1) |
  | `commit` | `vkQueueSubmit` under a queue mutex, signalling a fence; a waiter thread runs the completion handlers |

  Encoding takes no global lock. Encoders on different threads run in parallel (Vulkan's external-synchronisation rules).
- **Hazards:**
  - Every image lives in `VK_IMAGE_LAYOUT_GENERAL`; Turnip ignores layouts except for UBWC.
  - A conservative global memory barrier goes between encoders (render to compute, compute to render, blit), plus a
    framebuffer-local barrier for framebuffer fetch.
  - Metal tracks hazards automatically, so conservative is correct; refine later by tracking written resources per encoder.
- **Pipelines:**
  - A Metal render pipeline becomes a `VkPipeline`: the vertex descriptor becomes `VkPipelineVertexInputState`; blend and write masks
    map directly; colour and depth formats go through `VkPipelineRenderingCreateInfo`.
  - Viewport, scissor, stencil reference, blend constants, cull and depth bias are dynamic state. This also fixes the gap where
    `setViewport:` origin and size are ignored today.
  - A `VkPipelineCache` serialised to `/private/var/tmp/bgmtl/<process>.vkcache` covers cold starts (perf item 5).
  - The AIR-to-NIR translation is cached per (bitcode hash, entry, function constants), outside any lock (perf item 4).
- **Memory:**
  - `MTLBuffer` shared storage uses memory type 0 (host-visible, coherent).
  - Private storage and textures use device-local memory.
  - A suballocator for small buffers comes later. Today each `MTLBuffer` is one BO, as on Gallium.
- **IOSurfaces (drawables, CoreAnimation's surfaces):**
  - Import goes through the stand-in's `SURFACE_BO` (handle, iova, row bytes), wrapped as `VkDeviceMemory` by a small Turnip-side
    hook. That hook is a `tu_bo` made from an existing GEM handle, the same path as `msm_bo_init_dmabuf` without the fd.
  - The image is linear with the surface's row pitch, through `VK_EXT_image_drm_format_modifier`'s explicit layout (Turnip has it).
  - `rwa_texture_flush_surface` stays `BO_SYNC`.

### Phases, each with a check on the phone (test tools in `/var/root`, no system install without coordination)

- **T1, compute.**
  - Build `libbgair-vk.dylib`: Turnip, libair, `air_metal_vk.c` with the device, buffer, compute, dispatch, fence and texture
    read/write parts of `rwa_*`.
  - Check: `test/bgair_test.c` 14/14 on the A630 and the QuartzCore + HDR corpus compile count (369/375 today).
- **T2, render behind the current `rwa_render_*` API.**
  - Implement it as begin-rendering, draw, end, slow but correct.
  - Check: `bgair_vertex_test`, `_mrt_`, `_stencil_`, `_restart_`, `_pntc_`, `_cboffset_`, `_footprint_`, `_linked_` pass on Turnip.
- **T3, the encoder API.**
  - `rwa_cmdbuf_*` / `rwa_pass_*` / `rwa_draw_*`, mirroring `MTLCommandBuffer` / `MTLRenderCommandEncoder`.
  - `bgmtl.m` records into it directly. `BGWork` and `bg_lock` go away for render and compute; the bump allocator replaces the
    per-call GEM buffers of `setBytes`.
  - Check: `bgmtl_render_probe`, `bgmtl_ca_probe`, the CARenderer harness against its CPU renderer.
- **T4, IOSurfaces and drawables** (the hook described above).
  - Check: `bgmtl_layer_probe`, `bgmtl_texpool_test`, `bgmtl_xr2p_test`.
- **T5, on the device.**
  - With the user's OK for any system-wide install: backboardd, then SpringBoard, PosterBoard, Mercury and iconservicesagent on the
    Turnip libbgair.
  - Measure with `bgmtl.perf`: encode ms per frame and fps during swipes. Target: encode at or under 5 ms per frame, 60 fps when the
    GPU allows.
- **T6, delete Gallium.** Remove from the tree:
  - `air/air_metal.c`;
  - the Gallium patches (`fd-bo-cache-*`, `fd-bo-new-purge-retry`, `fd6-fb-barrier-reorder`, `fd-screen-trim`);
  - Bergamota's osmesa and freedreno_bo hunks;
  - `build-host.sh` / `build-ios.sh` in their Gallium form (replaced by the Turnip build);
  - `RWA_SOFTWARE` (softpipe).

  The Mac reference path for tests becomes **lavapipe** (Mesa's CPU Vulkan driver, which builds on macOS) running the same
  `air_metal_vk.c`.
- **T7, a native kernel backend (optional, after T5).**
  - Replace the msm emulation (fake `/dev/null` fds, mmap interposition, syncobj emulation, the 1.4 version dance) with a
    `tu_knl_sweet.cc` that calls `SweetAdrenoUserClient` directly. UniXNU's `tu_knl_darwin.cc` (MIT) is the template.
  - Then lift the kernel's limits for Turnip: `nr_cmds` at most 128 per submit; per-process address spaces with `SET_IOVA`, so Turnip
    could pick its own addresses.

### Risks and open points

- **GMEM vs sysmem:** Turnip decides per render pass, with autotune. Gallium needed sysmem for the whole process when framebuffer
  fetch was used (perf item 10, `fd_mesa_debug` bit 9). Turnip has its own framebuffer-fetch path (`VK_EXT_rasterization_order_attachment_access`
  and input attachments), so the corruption fixed on Gallium has to be re-checked there.
- **Submit size:** a CoreAnimation frame in one command buffer is far below the kernel's 128 cmds per submit, but long-lived
  multi-pass command buffers need watching. The stand-in could split them.
- **GPU faults:** the kernel recovers three times per boot and then marks the GPU lost until a reboot. A Turnip bug during
  development costs recoveries for the whole phone, backboardd included.
- **Address space:** all processes share one GPU address space and the kernel assigns every address. That is fine for Turnip with
  `has_set_iova = false`; sparse binding, capture/replay addresses and `VK_EXT_map_memory_placed` stay unavailable.

## Files

| what | where |
| --- | --- |
| Turnip build (separate tree `$WORK/mesa-turnip`) | `turnip/build-turnip.sh`, `patches/turnip-ios.patch` |
| smoke test + benchmark (Turnip) | `turnip/test/tu_smoke.c`, `turnip/test/*.vert,*.frag`, `turnip/build-test.sh`, `turnip/entitlements.plist` |
| the same benchmark on Gallium | `turnip/test/bgair_drawbench.c` (built by `turnip/build-test.sh` when `mesa-air/build-ios` exists) |
| libdrm stand-in additions | Bergamota `gpu/freedreno-sweet/sweet_drm.c` |
