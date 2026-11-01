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
| `/private/var/tmp/bgmtl.env.<bundle id>` | `KEY=VALUE` lines set for that process alone before its device exists (`bgmtl-bb.env` is backboardd's), e.g. `FD_RD_DUMP=enable,combine` |
| `/private/var/tmp/bgmtl.fidraw` | one `bgmtl.log` line per draw of RenderBox's `primitive_custom_vertex` pipelines |
| `/private/var/tmp/chl.inflight.clients` | command buffers a process other than backboardd may have on the ring (default 3, 0 is no limit); read at process start. `chl.inflight` is backboardd's (default 2) |
| `/private/var/tmp/chl.passdump` | a directory, world-writable, there at process start: every colour attachment of every render pass, memoryless ones too, as it stood when the pass ended, raw in `/private/var/tmp/chlpd-<pid>-<command buffer>-<pass>-c<n>-<w>x<h>-<Metal format>.raw`; with `bgmtl.tracing` a trace line names each |
| `/private/var/tmp/bgmtl.compilelog` | one `bgmtl.log` line per call that reaches Apple's MTLCompilerService (specialised functions, libraries from source), with who asked and how long it took |

Restart backboardd after changing one (`kill -9` it; launchd restarts it). If `bgmtl-bb.state` says `alive=0`, delete it too.

---

## Fixes

### SpringBoard's SMMU faults: the texture pipe following an unwritten sampler (2026-10-30)

- **Symptom.** With SpringBoard and iconservicesagent on the GPU, an SMMU fault within minutes, often seconds:
  `TP|VFD` at an address far from any buffer (`FAR 0xe00b2880`, `0x17af27a00`, ...), always SpringBoard's work. The kernel's
  recovery then failed every client's command buffers, so all the dead-men fired and the phone fell back to the CPU renderer.
  It looked like a race: logging per draw, tracing, `TU_DEBUG=noubwc` and the kernel's UBWC registers each made it rarer.
- **Why.** Metal's constexpr samplers are immutable samplers in the set layout, and `flush_bindings` skipped them because a
  set's immutable samplers need no write. Turnip reads them from the descriptors, though, and for a push set it copies the
  layout's sampler in only when the binding is written. The set itself lives in a host buffer from `vk_realloc`, never
  cleared, which is copied whole into the command stream at each push. So the slot held whatever the heap held: zeros
  (nearest filtering, repeat) or stale pointers. A sampler's `BCOLOR` is the byte offset of its border colour, so the texture
  pipe read `TPL1_GFX_BORDER_COLOR_BASE + BCOLOR * 0x80`. In the faulting command stream of one capture the slot held
  `0afdde78 00000002 23160002 00000001`: `BCOLOR` 0x462c00, base 0x8003f200, sum 0xa319f200, exactly that fault's FAR. Every
  FAR seen was a multiple of 0x80. Each "cure" only changed what the heap held. RenderBox's `fi*` pipelines were the ones
  that hit it.
- **Fix.** `flush_bindings` writes immutable samplers too (the handle in the write is ignored, Turnip copies the layout's).
- **Check.** On the kernel and test that faulted within 2 rounds (`uitest`): 20 minutes with 59 app launches, 32673
  submissions, 0 faults, 0 recoveries, all six clients on the GPU.

### A RenderBox custom effect refused: "a store of a pointer into memory" (2026-10-30)

- **Symptom.** SpringBoard logged the refusal in pairs, dozens of times per boot, for `custom_effect_vertex +
  ffgea5cmba5gemhba3`. Whatever that effect draws was skipped.
- **Why.** Its linked `custom_fn` copies its texture argument into a local `RB::Layer` and never reads that member back (the
  sample call uses the argument). The frontend refused any pointer stored into memory.
- **Fix.** A pointer stored into a local is dropped. Reading one back is still refused, by `air_load_ptr`.

### backboardd aborted with asynchronous commits: "Collection was mutated while being enumerated" (2026-10-30)

- **Symptom.** A soft reboot, once in about 12 minutes of UI use with `bgmtl-bb.sync` removed: `NSGenericException` from
  `commit`, under CoreAnimation's `MetalContext::flush` and `commitAndWaitUntilSubmitted`.
- **Why.** After submitting, `commit` walked and emptied `_scheduled`, while the completion thread, which can run as soon as
  the GPU is done, walked and emptied the same array in `bgCompleteFrom`. A handler could also run twice, or after the
  completed handlers, and `commit` wrote a field of a context the completion side may already have freed. Every process but
  backboardd, which ran synchronous commits, had the same race.
- **Fix.** The scheduled handlers leave `_scheduled` before the submit and run from that copy, the command buffer stays
  retained until they finish, and `bgCompleteFrom` waits for them. A scheduled handler must not wait for its own command
  buffer to complete.

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

### Every app a black screen (iOS 26, 2026-10-30)

- **What it looks like.** Tapping an icon dims the home screen, then the panel is black: no status bar, no frames, touches
  land on SpringBoard's home screen window while the app runs behind them. The same with backboardd and SpringBoard stock, so
  not a rendering bug.
- **Why.** The poster's snapshots (`RuntimeSnapshot-*.atx`) load as CGImages `(IP) <ATX >`. SpringBoard puts one in the fake
  wallpaper of `SBMainSwitcherWindow`, the window that hosts the app. The render server cannot decode it (backboardd:
  `CompressedImage port is MACH_PORT_NULL!`) and drops the whole commit (`serialization error from context`), so that context
  never shows. That image alone in a new context reproduces it; a bitmap copy of it does not. Why the port is empty in the
  sender was not found.
- **Fix.** `inject/bgmtl_inject.m`, `atx_contents_install`: in SpringBoard, before the GPU gates so it holds on stock too,
  `-[CALayer setContents:]` gets a bitmap copy of such an image (2-20 ms). `bgmtl.noatxfix` turns it off.
- **How to check.** `sweetlog 60 serialization` stays empty after opening an app; `ATX image` lines in `bgmtl.log`.

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

## Texture memory stays around for a few seconds (2026-10-31, Mi 8)

A glass animation makes hundreds of offscreen textures a second, many of a shape never seen before, so the shape-keyed pool in
bgmtl.m misses (400-800 misses per scene). A miss cost a kernel allocation, and later a kernel free, on the render thread.
`memc_take` / `memc_give` (air/chl_vk.c) keep released texture memory for 3 s, rounded up to a quarter of its power of two, up to
96 MB, and only in backboardd (with BGMTL_TEXPOOL_MB). A VkImage over existing memory costs almost nothing. `/private/var/tmp/chl.nomemcache`
turns it off; `memcache:` lines in bgmtl.log count it (bgmtl.perf). Reused memory holds old pixels, as Metal allows; screenshots and a
5 minute soak showed no damage.

`TU_DEBUG=sysmem` is NOT usable here: GPU time drops by 15-25% but the picture breaks, black wedges and staircases in Control Center
and on icons. It forces passes with framebuffer fetch off GMEM. Turnip's autotuner keeps those on GMEM by itself, and
`/private/var/tmp/chl.autotune` = `prefer_sysmem` (TU_AUTOTUNE_ALGO) is clean, but gains nothing because the glass passes are the ones that
stay on GMEM. Left at the default. Look at screenshots before believing a frame-rate gain.

## The first gestures after a boot, and what held encoding back (2026-10-31, Mi 8)

**Translations on disk.** `air_metal.c`'s translation cache was never ported to Chlorophyll: `translate` (air/chl_vk.c) parsed and translated
AIR at every pipeline build, in every process, after every boot, on whichever thread wanted the pipeline. `translate_cached` keeps the NIR and
the air_shader_info in a Mesa disk cache of their own ("chlorophyll-air", beside Turnip's), under this library's LC_UUID. A rebuilt library starts
cold, so its first boot costs about a minute of compiling. `/private/var/tmp/chl.noaircache` turns it off. backboardd, same gestures on three boots each:
224 pipelines in 6.2-7.2 s before, 240 in 2.6-2.9 s after.

**At most two frames on the ring.** Kernel patch 3021 removed two waits that made the render thread wait for the GPU (see NOTES.md). They were also
the only thing holding the compositor back: without them it queued frames faster than the GPU drew them, the display, which shows the newest finished
frame, dropped most, and shown fps fell (Control Center open 38-43 to 33-35) while rendered fps rose. `chl_cmdbuf_commit` now holds the render server
at two command buffers in flight, 100 ms at most per commit. `/private/var/tmp/chl.inflight` overrides the 2; 0 is no limit.

**Where a slow frame's GPU time goes.** `/private/var/tmp/chl.passprof`, read at process start in backboardd only: GPU timestamps around each render pass.
The file holds the GPU time in ms above which a command buffer's passes are listed (default 80); `pass` lines in bgmtl.log give the gap before the pass,
its time, size, draws and the first four fragment functions. `slowcb:` (over 50 ms from flush to done, any process) and `slowcommit:` (over 30 ms) have
timestamps, as do `hitch:` and `slow:` lines.

Tried and rejected, each measured: bigger VSC (binning) buffers, no overflow was ever logged, also at upstream's sizes; `prefer_gmem`, first-unlock GPU time unchanged.

## The first unlock: CoreAnimation's generic shader (2026-10-31, Mi 8)

What CoreAnimation has no specialised shader for yet, it draws with a generic one, `A2Xghfc` in QuartzCore's default.metallib (the binary also has `uber_fragment`). On this GPU that is ruinous: Turnip's statistics give its fragment stage 53905 instructions (15219 of them nops), 168 loops, 549 texture fetches, 844 memory instructions, 439 spills and 638 reloads, 48 registers, 4 waves per core; `A2Xhf` has 9 instructions and `TimgA2Xhf_Isrc` 11. One full-screen draw costs 40-58 ms and scales with area, about 35 ns a pixel. One pass of 830x1794 with 63 draws took 1214 ms at the first unlock and 17 ms a minute later, without `A2Xghfc`.

QuartzCore reads `CA_DISABLE_GENERIC_SHADERS`, and the inject now sets it for backboardd (`/private/var/tmp/bgmtl-bb.generic` keeps Apple's behaviour): it builds the specialised shader at first use instead, which costs a few ms from the disk caches. I did not read QuartzCore's code to see the policy, only the effect: `A2Xghfc` no longer appears in the log, in any pipeline or pass. The first boot after a driver rebuild compiles more on the render thread.

`/private/var/tmp/chl.shaderdump` (see `shader_dump`, air/chl_render.c.inc) writes statistics, NIR and ir3's disassembly of named fragment functions to /private/var/tmp/chl-shaders.

## Glass icons: what RenderBox drew into a surface never reached it (2026-10-31, Mi 8)

With iconservicesagent on the GPU, home screen icons lost layers, always the same ones: Photos' petals, Notes' yellow band, Safari's compass, the glyphs of Phone and Music. So the agent had been kept off the GPU, and without a GPU it cannot draw an SF Symbol, which left Settings' rows empty.

**Cause.** A surface the GPU cannot import is "copied": the texture gets its own memory, filled from the surface at each use. The comment said "good for sampling, which is all CA does with those". RenderBox also draws into them. It renders each layer of an icon into its own RGBA16F IOSurface, then wraps that surface in a second MTLTexture to sample it. What the GPU drew stayed in the first texture's memory, so the second read an empty surface. The first one was no better off: the seed bump at completion made its next use refresh it from the empty surface. `chl.passdump` showed it directly: Notes' band is correct in surface 1205 (608x153), and every later pass that samples that surface gets nothing.

Which layers are lost depends only on the layer's size, which is why the same icons were hit each time, and why flushes, tiling and timing changed nothing. A surface is refused when:
- its pitch is not 128-byte aligned (`fd6_layout.c`, RGBA16F: 3392 for 424 wide, 960 for 120 wide, while IOSurface aligns to 64);
- its pitch is fine but it holds fewer bytes than the image Turnip lays over it, whose height is aligned to 4 rows (608x153: 753664 bytes, Turnip asks 758784; `real_size < size` in `tu_knl_drm_msm.cc`).

The blank 40x40 a root tool got from `prepareImageForDescriptor:` was this too.

**Fix.** `bgCopyWriteBack`: at completion, what the GPU wrote goes back into the surface, and the writer takes the new seed. A reader of a surface drawn into by a command buffer in flight waits for that write-back, at most 500 ms (`bg_surfwb_wait`). backboardd is left out, as for the other surface syncs here.

**The tiled-mode fault, avoided and not understood.** With layers now present, an icon larger than about 220 px, so more than one tile, soon gives an SMMU fault: `TP|VFD`, always in iconservicesagent, at a low address: FAR 0x2504c00, 0x2504000, 0x24d7080, 0x247cd80. Home screen sizes never did, in any run. `TU_DEBUG=sysmem` has none. But direct rendering alone reads stale cache lines in framebuffer fetches: black squares on Mail, blocks on Photos and Music, with or without UBWC, gone with `flushall`. So the inject sets `TU_DEBUG=sysmem,flushall` for this process (`bgmtl.env.com.apple.iconservicesagent` overrides it). It draws little, so the cost does not show.

Observed in a capture of the fault (`FD_RD_DUMP=enable,combine`; **`FD_RD_DUMP_PATH` must exist: otherwise `fd_rd_output_write_section` spins forever on a failed gzwrite**): the only low addresses a fetch can start from are the tile-memory descriptors of the input attachments (0x100000 to 0x200000), and all four FARs are multiples of 0x80. A guess that fits all four: FAR = 0x160000 + 16 * (y * 4608 + x * 8), y about 500, x under 530, as if an RGBA16F attachment were read with coordinates still in sixteenths of a pixel. Not confirmed: the 1/16 constant is right in every fetching shader of the capture. Beware cffdump in binning phases: it shows the previous fragment shader's register state, so a set can look as if it held a texture descriptor made of scissor words. It does not; that was a false lead here. SpringBoard's RenderBox stays tiled and may meet this if it ever draws that large with fetches; not seen in any soak.

**Checks.** Ten icons at 528x528 against the CPU renderer: mean difference 0.90 to 2.92 of 255, about 0.06 % of pixels (0.14 % for Maps) off by more than 48. Empty cache, reboot: 276 files in under 2 minutes, 35 s of the agent's CPU where the CPU path took about 2 minutes, home screen and every row of Settings correct, 0 faults, no kill switch tripped.

## A healthy GPU reset by its own backlog: Mercury's wallpaper (2026-11-01, Mi 8)

On the first boot of a fresh root the kernel reported `GPU HANG (no completion)` twice, with no SMMU fault, and each reset failed every client's work, so the dead-men sent backboardd, SpringBoard and the icon agent to the CPU. Both reports were at the same place in a command stream (`rem 946`).

**Cause.** Nothing had hung. Until the first-boot job sets the wallpaper, PosterBoard uses the poster it picks by itself, Mercury's `space.dynamic`. Each of its frames takes about 110 ms of GPU time and it submits at 60 fps, and only backboardd was held back from queueing. The queue grew without limit. With the same conditions recreated: 26.6 s behind by Mercury's own `max wait`, 105 s flush to done at worst. A process that then waits for its own GPU work, behind all of that, runs into the kernel's `WAIT_PATIENCE_MS` of 5 s, and the kernel resets the GPU. The arithmetic fits the first report: 46 submissions behind at 110 ms each is 5.06 s. (Not every backlog trips it: it takes a wait of a second or more, as in `chl_texture_get`. The recreated run reached 26 s with no reset. It only went wrong when someone waited at the wrong moment.)

**Fix.** `chl_cmdbuf_commit` holds any process at 3 command buffers on the ring, for at most 1 s per commit (backboardd stays at 2 and 100 ms), and never on the completion thread, which is what makes room. The limit is per process, so several busy clients still add up, but to about a second rather than without bound.

**Checks.** First-boot conditions recreated by hand (poster store and icon cache emptied, first-boot markers removed, phone left locked): worst wait in a poster or icon process 0.57 s, down from 105 s. The one larger value, 3.4 s, is a single backboardd frame about 11 s after boot, before any of this load. 0 resets, 0 dead-men. Warm gestures unchanged: Control Center open 48-51 fps, scroll 54-56, back 51-55, Spotlight about 41. Soak 300 s, 18 app launches, 0 faults.
