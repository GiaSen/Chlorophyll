# Chlorophyll fixes

Rendering bugs found running iOS 18's CoreAnimation on Chlorophyll (Metal on the Adreno 630 of the Poco F1):
what went wrong, why, and what fixed it. Each entry has the symptom, the cause, the fix (commit in this repository, or a
Mesa patch in `patches/`) and how to check it. Kernel and phone-side fixes are in Bergamota's
`docs/FIXES_KERNEL_SYSTEM.md`.

Debugging switches referred to below (files on the phone, read when the process starts):

| File | Effect |
|---|---|
| `/private/var/tmp/bgmtl.trace` | every Chlorophyll process traces into `/private/var/tmp/bgmtl-trace-<pid>.txt` |
| `/private/var/tmp/bgmtl.dumpatt` | with the trace: attachments and blur-chain targets dumped as raw BGRA into `/private/var/tmp/att/` |
| `/private/var/tmp/bgmtl.perf` | per-second commit timing in `bgmtl.log` (encode, GPU wait, gap between commits) |
| `/private/var/tmp/bgmtl-bb.inorder` | backboardd: freedreno without batch reordering (`FD_MESA_DEBUG=inorder`) |
| `/private/var/tmp/bgmtl-bb.fddebug` | backboardd: any `FD_MESA_DEBUG` flags (`flush`, `ddraw`, `sysmem`, ...) |
| `/private/var/tmp/bgmtl-bb.sync` / `.full` / `.off` | synchronous commits / dirty regions off / Metal off in backboardd |

Restart backboardd after changing one (`kill -9` it; launchd restarts it). If `bgmtl-bb.state` says `alive=0`, delete it too.

---

## Fixes

### Frame time: what helped and what did not (2026-10-24)

- **Framebuffer kept bound per pass (31e727e).** Every draw used to make new `pipe_surface`s, set the framebuffer, and
  reset it to empty: two framebuffer changes per draw, each switching freedreno's batch and re-dirtying all state. Each
  texture now keeps one surface, and a pass's draws bind an equal state. Correct, but frame time did not move.
  A profile showed why: about 2/3 of backboardd's CPU is CoreAnimation's own work, and in libbgair the main cost is
  uploads.
- **Linear sampled textures: reverted (5eb3387).** freedreno uploads into a tiled texture through a staging buffer and
  a GPU blit. Making sampled-only textures linear blanked the home screen (only the widget placeholders drew), with
  nothing refused in the log, so it was reverted. The cause is not yet found.
- **ASTC LDR textures (fce9d47).** App snapshots and wallpapers are ASTC 4x4. The Adreno samples ASTC natively; uploads
  count rows of blocks.
- **What did move frame time:** the kernel's GPU scan-out copy (0240) and async commits (no `bgmtl-bb.sync`): 20.8 to
  28.4 fps in the same swipe test. See Bergamota's `docs/FIXES_KERNEL_SYSTEM.md`.

### Control Center blur: half of every blurred area missing along a diagonal

- **Symptom.** Control Center's backdrop showed only its lower-left triangle; the upper-right was black or stale, with a
  stair-stepped edge. The same happened in the platter tiles (Wi-Fi, AirDrop, VPN) and in the low-battery alert, and
  which half went wrong depended on timing.
- **Why.** CoreAnimation blurs the backdrop down to a tiny image (for example 73x155, drawn into a corner of the screen
  capture), then runs a framebuffer-fetch draw (`Tc33A2Xhf_Idst`, `[[color(0)]]` read) over the same quad. In sysmem,
  freedreno reads the attachment through the texture path, so it needs a barrier (CCU flush + cache invalidate) between
  the draw that wrote and the draw that fetches. Chlorophyll called `texture_barrier` before every fetch draw, but:
  1. `rwa_render_draw` makes new `pipe_surface`s for every draw, so `set_framebuffer_state` never sees an equal state;
  2. with batch reordering (freedreno's default) that drops `ctx->batch`;
  3. `fd6_texture_barrier` → `add_flushes()` found no current batch and threw the barrier away ("a batch switch is
     already a barrier");
  4. it is not one: the next draw goes back into the *cached* batch for that framebuffer, right behind the draw that
     wrote the pixels. The fetch read half-written memory, so one triangle of the quad came out stale.

  With `inorder` the same per-draw framebuffer change flushes the batch every draw, which hides the bug (and costs
  ~20-26 ms of encode per frame instead of ~12).
- **Fix.** Chlorophyll 0237bf4, `patches/fd6-fb-barrier-reorder.patch`: on a FRAMEBUFFER barrier with reordering and no
  current batch, bind the batch the next draw will use (`fd_context_batch`) so the flushes land in it.
- **How it was found.** First the per-draw dumps ruled out the source capture and CA's shaders. Then A/B tests with
  reordering on: `inorder` and `flush` fixed it; `ddraw` (all state re-emitted) and a wait-for-idle around subpass
  clears did not. So it was ordering, not state, and only when draws merge into a pending batch.
- **Check.** No `bgmtl-bb.inorder`, open Control Center: the backdrop and the platters are whole.
- **Follow-up (performance).** Caching the `pipe_surface`s per texture would make `set_framebuffer_state` early-return
  within a pass and avoid re-dirtying all state on every draw.

### Flat-shaded colours swapped between a quad's two triangles

- **Why.** Metal's provoking vertex is the first vertex of each triangle; Gallium's default is the last.
- **Fix.** `flatshade_first = 1` in the rasterizer state (130eca2). `test/bgmtl_quad_probe.m` checks this on the phone.

### `generateMipmapsForTexture` did nothing

- **Fix.** Mipmaps are made on the GPU with `util_gen_mipmap`, in order with the draws (`BG_WORK_MIPMAPS`, deac59c).

### Black corner wedges, dashed edges and specks on rounded layers (widgets, dock, folders)

- **Why.** CoreAnimation clips rounded layers in three steps. It copies the corner patches into a second attachment with
  `[[color(n)]]` fetch shaders, draws the layer, then blends the copy back outside the rounded shape. Through a6xx GMEM
  (tiling, chosen per batch at flush time, partly by the autotuner) those fetches returned zeros. Separately,
  `setScissorRect` was ignored, and CA draws its corner patches one pixel outside the scissor.
- **Fix.** Draws whose fragment shader fetches a colour attachment render in sysmem (`FD_DBG_SYSMEM`), and the scissor
  rect is honoured (004f9fa). Earlier, `DontCare` colour attachments of private textures start cleared to zero, because
  CA blends its masks into them (198d8c3).

### backboardd crashed every few minutes ("fence timeout" restarts)

- **Why.** The kernel allows 4096 GEM handles per client and silently refuses the next one. With the BO cache keeping
  buffers 15 s, backboardd ran out. `fd_bo_new` returned NULL and `upload_shader_variant` dereferenced it.
- **Fix.** On a refused GEM_NEW, empty the BO caches and retry (b927867, `patches/fd-bo-new-purge-retry.patch`). Fence
  waits retry twice and log the kernel's answer, and backboardd's exits and fatal signals are logged with a backtrace
  (8a65f63).

### Textures re-allocated although idle ones were cached

- **Why.** freedreno's BO cache stopped at the first busy entry in a bucket, so idle textures behind thousands of
  short-lived read-only buffers were missed (65 of 149 texture misses during swipes).
- **Fix.** Lookup matches flags first and skips busy entries (73aa9d4, `patches/fd-bo-cache-skip-busy.patch`). The cache
  keeps freed buffers 15 s instead of 1 (7e62ace): full-screen targets cost ~18 ms each to allocate.

### Black or grey wallpaper on the lock and home screens

- **Why.** One refused draw or clear failed the whole command buffer, so the rest of the frame was never drawn. A
  per-frame readback of the compositor's IOSurfaces only masked it.
- **Fix.** A refused draw or clear is skipped and logged, and the frame goes on (2cb58f9); the readback was removed. Also:
  clears and draws skip colour slots without a texture, which is legal in Metal (2a463ae, 0bbf76e).

### Metal switched off for good after a restart with the display off

- **Why.** The backboardd watchdog counted its 60 s to a first completed command buffer from launch; with the display off
  nothing commits.
- **Fix.** The watchdog starts counting at the first commit (e5f9f73).

### Crashes in apps through the Chlorophyll bundle

- **SpringBoard's Siri orb** crashed in Metal's library loader on a NULL `targetDeviceInfo`; it now returns
  `{0, 0, "Chlorophyll"}` (9728eb7).
- **SBRendererService** crashed in CoreImage's Metal kernel graph for CIKL source. Chlorophyll processes get
  `CI_USE_MTL_DAG_FOR_CIKL_SRC=0` (2a463ae).
- **SpringBoard crash loop.** QuartzCore's tiled compressed-image path read past the image file;
  `CA_USE_CGTEXTUREDATA=0` (0bbf76e).
- **Lock-screen Customize** aborted backboardd: `insertelement` at a run-time index did not translate; it is now
  `nir_vector_insert` (a95c328).
- **Multi-threaded commits** crashed in `fd6_draw_vbos`; one recursive lock now wraps every Gallium call (5657441).

### First backboardd runs

- **Deep-colour pipelines** (RGB10A8_2P_XR10, format 550) aborted the render server. `supportsExtendedXR10Formats`
  answers NO (2e65262), and XR formats stand in as same-size native formats (0925016).
- **Masks came out empty.** Gallium's default line width is 0, and CA's mask coverage is drawn as lines. Lines and points
  are now one pixel wide (175571a).
- **Colours from the wrong varying slot.** Varyings are linked by their AIR name (fb5d79f). 16-bit varyings cross the
  stage boundary as 32 bits (afb033a).
- **~120 ms per frame.** Fixed by uploading at most 4 KB for unsized constant pointers, caching IOSurface imports, and
  dropping the per-draw GPU waits (8eede6f). Asynchronous commit took it to ~20 ms (4762d9d).

## Texture pool and bounded constant uploads (2026-10-24)

- **Why.** In a home-screen swipe, backboardd spent ~9 % creating GPU resources: CoreAnimation makes a new MTLTexture
  for a backing store each time it is redrawn, and every one was a fresh freedreno resource (a kernel BO, madvise/close
  on the way out, a new sampler view). Another ~7.6 % went to copying constants bound at offsets the Adreno cannot
  fetch from: a pointer read at a computed offset still uploaded the 4 KB cap on every draw.
- **Fix.** Destroyed non-imported textures leave their resource and view in a small pool (24 entries, 48 MB, 2 s); a
  texture of the same template takes one back (`RWA_TEX_POOL=0` turns it off). Computed constant offsets are bounded
  with NIR's range analysis where possible, so those bindings copy up to the bound. With the current libdrm stand-in
  (madvise answered locally) installed too, the swipe test went from ~30 fps (300 frames / 10 s, backboardd at 93-98 %
  of a core) to ~41 fps (403-429 frames).

## Linear sampled textures: why they drew black, and the fix (2026-10-24)

- **Why.** c679731 (reverted by 5eb3387) added `PIPE_BIND_LINEAR` to the bind flags *before* the
  `is_format_supported` check. freedreno refuses `SAMPLER_VIEW | LINEAR` there, so every such texture failed to be
  created: CoreAnimation got a nil MTLTexture and drew nothing (icons and wallpaper black, text fine). It was never a
  layout, cache or sampling problem; `bgmtl_render_probe` with `RWA_LINEAR_SAMPLED=1` showed `t=0` at creation.
- **Fix.** Single-level 2D sampled-only textures of 4-byte texels (not imports) set LINEAR only on the allocation
  template, after the check, and fall back to tiled if the allocation refuses. `-replaceRegion:` then writes through
  the mapping for most uploads. Probe 18/18; texture uploads 6.4 % -> 4 % of backboardd, our share 37 % -> 30 %;
  `RWA_LINEAR_SAMPLED=0` turns it off.
