# Chlorophyll on iOS 26 (branch `ios26`)

Bergamota's iOS 26 image is iOS 26.6.2 (23G90) for iPhone12,1 (Bergamota `docs/IOS26_PORT.md`). It was built without the Chlorophyll
payload, so its first boot uses the CPU renderer. This note covers what Chlorophyll needs on 26, read statically from the shared caches
(2026-10-24, nothing run on 26 yet).

## How it was read

The 23G90 (iPhone12,1) and 22H352 (iPhone11,8) SystemOS cryptexes were streamed from Apple's CDN and decrypted on the fly
(`remotezip` range reads piped into `aea decrypt -key-value`, the key from `ipsw fw aea -k` on the first MiB), mounted read-only,
class-dumped (`ipsw class-dump`, `--refs` for QuartzCore's selector references), then deleted. `tools/dsc-objc-gap.py OLD NEW -v`
compares the dumps with `src/bgmtl.m`. Its output is `results/ios26-23G90-vs-22H352-objc-gap.txt`.

## What changed between 18.7.8 and 26.6.2

* **Base classes** (what BGMTL* subclass): `_MTLDevice` 598 -> 672 methods, 50 -> 56 ivars; `_MTLCommandBuffer` +10 methods, +4 ivars;
  `_MTLCommandEncoder` +15; `_MTLResource` +5. `_MTLComputePipelineState` and `_MTLRenderPipelineState` now derive from `_MTLAllocation`
  instead of `NSObject` (our local `@interface` stubs still say NSObject; that only matters to the compiler, the runtime takes the
  real superclass). No method was removed from any of them. Ivars are non-fragile, so the subclasses' layout follows.
* **Required protocol methods added in 26** (`MTLDevice` 109 -> 129, `MTLDeviceSPI` 471 -> 528, pipeline states, depth-stencil,
  encoders): every one is answered by Apple's base class. The exception is `-[MTLTextureSPI writeAccessPattern]`, which the
  zero-forwarder answers with 0; that is the default access pattern.
* **QuartzCore** references 329 new selectors. The Metal ones are:
  * **Residency sets:** `newResidencySetWithDescriptor:error:` on the device, answered by `_MTLDevice`, which already had it on 18;
    `addAllocation:` and `removeAllocation:` go to the set it returns.
  * **Metal 4 queues:** `signalEvent:value:` and `waitForEvent:value:`.
  * **Shared events:** `newSharedEventWithMachPort:`.
  * **Lossy compression:** `supportsLossyCompression`, answered by `_MTLDevice`.
  * **Drawable:** `signalOnCommandQueue:` and `waitOnCommandQueue:` (the drawable is QuartzCore's own object).
* **Metal 4**: `_MTLDevice` gained `newMTL4CommandQueue[WithDescriptor:error:]`, `newCommandAllocator*`, `newCompilerWithDescriptor:error:`,
  `newArgumentTableWithDescriptor:error:`, `newCounterHeapWithDescriptor:error:`, `newTensorWithDescriptor:error:`,
  `newTextureViewPoolWithDescriptor:error:` and the `supportsMTL4*` / `supportsTensors` / `supportsMachineLearningCommandEncoders` /
  `supportsPlacementSparse` / `supportsTextureAccessPatterns` queries, plus `_MTL4CommandQueue` and IOGPU's `IOGPUMetal4*` classes.
  Their answers come from the feature tables an Apple GPU driver fills, which BGMTLDevice does not fill, and a base-class Metal 4 queue
  would not submit to our GPU. **Change on this branch:** BGMTLDevice says NO to each query (and to `supportsFamily:` MTLGPUFamilyMetal4,
  5002) and returns nil (NSError where there is one) from each factory. iOS 18 never sends these selectors, so the change is
  harmless there and can go to `main`.
* **Plugin lookup** (Chlorophyll.bundle): unchanged. Metal 26 still has `MetalPluginName`, `MetalPluginClassName`, `IOAcceleratorES`,
  `/System/Library/Extensions` and `.bundle`; `MTLIOAccelServiceGlobalContext` and `MTLIOAccelServiceDescriptor` have the same method
  sets as on 18, and `-[_MTLDevice initWithAcceleratorPort:]` is still the constructor. Kernel patch 0232's registry properties
  carry over as they are.
* **IOGPU**: 39 -> 46 classes (the seven new ones are Metal 4 and tensors). Chlorophyll does not use IOGPU.
* **IOSurface** (kernel side, also for the CPU renderer): QuartzCore 26 newly uses IOSurface shared events and transactions
  (`initWithSharedEvent:waitValue:isWrite:`, `eventPort`, `eventPortAtIndex:`, `transactionAtIndex:`; new classes
  `IOSurfaceTransaction`, `IOSurfaceTransactionListImpl`). Those reach Heartwood's IOSurface user client (0046 and later), not
  Chlorophyll: watch for failed IOSurface selectors on the first boot.

## Build

Nothing changes. Everything already builds with `-miphoneos-version-min=18.0` against the installed SDK (Xcode 27.1, iOS 27.1 SDK),
and an 18.0 deployment target loads on 26. arm64e is PAC-stripped by `freedreno-sweet/build.sh` like the rest of Renegade's root.
`src/bgmtl.m` compiles with the same 29 warnings as `main`.

## Still to check on the phone (needs a 26 boot)

1. **Residency sets.** QuartzCore 26 calls `newResidencySetWithDescriptor:error:`, which `_MTLDevice`'s default answers. Whether it
   returns a usable set or nil, and what QuartzCore does with nil, shows in `bgmtl.log` ("unimplemented") and in the render server's log.
2. **Metal 4 gating.** Whether QuartzCore takes the Metal 4 path only on `supportsMTL4CommandQueue` / Metal 4 family.
   Both now say NO, so `newMTL4CommandQueue` returning nil must leave it on the classic queue.
3. **Renegade's `bgmtl` feature** (Bergamota `tools/renegade/root_tweaks18.py`). Its paths exist in the 23G90 root, checked against
   the root image's mtree manifest in the IPSW:
   * `System/Library/ExtensionKit/Extensions/MercuryPosterExtension.appex/MercuryPosterExtension`
   * `Applications/PosterBoard.app/PosterBoard`
   * `usr/libexec/backboardd` and `System/Library/LaunchDaemons/com.apple.backboardd.plist`

   The default poster descriptor `com.apple.MercuryPoster:fluidity.two` was read back from PosterBoard on 18. Read it back again on
   26 (`sweetposterset --descriptors`) before the image makes it the default.

## On the phone, 2026-10-25 (boot 33b, backboardd and Mercury on Chlorophyll)

Five front-end and runtime gaps, each found from a refusal in `bgmtl-fail/refused.txt` or a dead-man trip, fixed and checked on the A630
with `test/bgair_test.c` (14/14) and the QuartzCore + HDR corpus (369/375, unchanged):

| commit | what was refused | fix |
|---|---|---|
| 6ac86f5 | backboardd's `compute_sum_luma` / `compute_average_luma` bind a `device` buffer at offsets 32, 96, 224; three refusals tripped the dead-man (`bgmtl-bb.off`) | `add_ssbo_deltas`: the buffer is bound in place at the offset rounded down to 64 and every load, store and atomic adds the rest, read from entries 16-31 of the delta table in constant buffer 15 (compute and draws). `RWA_SSBO_DELTA=0` turns it off |
| 8382d85 | Mercury's `VariableBlurrer::downsample`: an image store (and size query) at a mip level known only at run time | the image gets one slot per level 1..11 above the shader's images, the level picks the slot (ir3 takes a dynamic image index; resinfo ignores a lod), the runtime binds a view of each level there |
| 7425752, 6b32429 | Mercury's `space::rasterizeBackgroundFragment`: a phi between two textures, and in another variant a select among three merged with a fourth by a phi | the phi becomes a texture chosen at run time (a 1-bit register stored on each incoming edge); a texture operation on a chosen texture is made on every texture and the answers selected (derivatives stay valid). A write to a chosen texture is refused (the CFG is unstructured) |
| 462d0c2 | Mercury's `space::rasterizeMeshVertex` samples `air.get_null_texture` | a null texture reads zero, answers a query with zero, writes nowhere |

After these, Mercury's `space.dynamic` poster runs with no refused pipeline (pid 7070, first command buffer completed). Not yet seen on screen.

Found on the way, not fixed: an RGBA8Unorm image written by a compute kernel reads back zeros through `rwa_texture_read` (RGBA32Float is
fine, which is why `bg_tex_write` and `bg_mip_write` use it); `copyFromTexture:sourceSlice:sourceLevel:toTexture:destinationSlice:destinationLevel:sliceCount:levelCount:`
is unimplemented (Mercury calls it).

Lesson: a refused pipeline names the fragment (`(f)`) even when the vertex stage is the one refused; translate both dumps.

## Performance: what DXVK and Zink do that Chlorophyll does not (2026-10-25)

Read-only study of DXVK (cbd2206) and Mesa's Zink (837ab0e) against this tree. Nothing below is measured yet: turn on
`/private/var/tmp/bgmtl.perf` (encode time vs GPU wait per command buffer) before and after each change.

What Mesa already gives us, so we do not rebuild it: freedreno compiles initial ir3 variants on its own `compile_queue`
(ir3_gallium.c); Gallium/freedreno handle barriers and descriptors; ir3 picks variant keys per draw. Not worth copying:
pipeline libraries, our own compile thread pool for ir3, custom variant keys.

Ranked (impact over effort):

1. **setBytes / setVertexBytes / setFragmentBytes allocate a GEM buffer and a permanent map per call** (bgmtl.m
   `newBufferWithBytes` -> `rwa_buffer_create`). CoreAnimation calls these many times per frame. Replace with a
   per-command-buffer bump allocator over recycled 64-256 KB slabs (DXVK `DxvkStagingBuffer`, Gallium `u_upload_mgr`),
   slabs retired at completion. Small-medium effort, low risk.
2. **Compute dispatch waits for the GPU every time**: `rwa_dispatch_buffers` ends in a required finish (flush + fence wait).
   The luma kernels pay a full round trip each frame. Drop the wait as draws already did (keep an `RWA_DISPATCH_FINISH`
   switch); check the readback paths go through the commit fence. Small effort, low-medium risk.
3. **Per-draw state is re-bound unconditionally** in `rwa_render_draw`: blend, DSA, rasterizer, vs/fs, vertex elements,
   viewport, scissor, stencil ref, vertex buffers. freedreno does not dedup these: every vs/fs bind dirties PROG and costs
   an `ir3_cache_lookup` per draw. Shadow the last-bound objects on the device and skip equal ones (Zink `zink_state.c`,
   DXVK dirty flags; `cso_context` does the same). Small effort, low risk (invalidate on destroy).
4. **Pipeline creation has no cache, parses the bitcode three times, and runs under the global `bg_lock`**
   (`rwa_render_create`: fragment and vertex `air_to_nir`, then `rwa_module_textures` again in bgmtl.m). Cache translated
   NIR + info per (bitcode hash, entry, function constants, paired vertex entry) and the CSO pair per (vs, fs, shape);
   do the translation outside `bg_lock`. Medium effort, low risk.
5. **No shader cache survives a restart**: `ir3_disk_cache_init` is compiled out on `__APPLE__` and the build has
   shader-cache disabled. Re-enable it with a key from the Chlorophyll build, cache dir in `/private/var/tmp`; later add a
   `nir_serialize` cache for the AIR->NIR half. Helps backboardd/Mercury cold starts. Medium effort, low risk.
6. **Attachment views are new objects every pass** (`bg_attachment_view` makes a new BGMTLTexture, `texture_surface` a new
   pipe_surface; the pool skips views). The blur pyramid pays this every frame. Cache views on the parent by (format,
   type, levels, layers, swizzle), as Zink's surface cache does. Small-medium effort.
7. **Per-draw constant uploads**: the 33-word delta buffer goes up as a `user_buffer` per stage per draw, and unaligned
   constant bindings without delta support upload up to 4 KB. Skip the delta upload when unchanged; prefer the delta path.
8. **BGWork per draw retains every slot** (16 buffers + 16 textures + samplers per stage) and replay resolves each texture
   under `bg_lock`. Copy only changed state (DXVK's model), retain only up to the highest used slot.
9. **Per-draw validation** (formats, `index_range` scanning the whole index list, stream bounds, `check_bindings`) can be
   cached per pipeline + pass + binding signature, full checks behind an env switch.
10. **Framebuffer fetch forces sysmem for the whole process** (`fd_mesa_debug` bit 9, sticky) plus a framebuffer barrier
    before each fetching draw. Potentially the largest GPU win, but the highest risk: it fixed real corruption. Needs a
    per-batch flag in freedreno (`gmem_reason`) and barrier elision only when the attachment was written since.
11. **DontCare store actions are ignored**: use `pipe->invalidate_resource` so freedreno skips GMEM resolves of blur
    intermediates (stores only; CoreAnimation relies on zeroed DontCare loads).
12. Later, only after 1-4: `PIPE_CONTEXT_PREFER_THREADED` (freedreno supports `u_threaded_context`), deferred flushes,
    per-resource waits instead of `rwa_finish` on CPU-blit fallbacks.

Correctness gap found on the way: `setViewport:` keeps only znear/zfar; origin and size are ignored and every draw uses
the attachment size. The traced CoreAnimation passes all set a viewport equal to the attachment, so nothing visible yet.
