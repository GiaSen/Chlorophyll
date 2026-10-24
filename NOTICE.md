# gpu/metal third-party notices

`air/` (the AIR -> NIR frontend: `air_bitcode.*`, `air_layout.c`, `air_metallib.c`, `air_module.*`, `air_print.c`, `air_private.h`, `air_to_nir.c`,
`air_intrinsics.c`, `nir_air.h`, `air2nir.c`, `meson.build`, and the Metal-driver library `air_metal.c` / `air_metal.h` (their libhackiosair,
the interface their `userland/src/hkmetal.m` uses)) and `patches/` (`air-frontend`, `air-ir3` (reduced: no `air_run`), `ir3-round-default`,
`ir3-shift-split`, `ir3-ssbo-subdword`) come from the `metal` branch of the hackios userland repository (hackios-xnu-userland @ 29eef72,
`tools/mesa/`), MIT, `Copyright (c) 2026 OOSEX GANG`, files marked `Copyright 2026 Darwin on redwood contributors, SPDX-License-Identifier: MIT`.
The licence text is `LICENSE.hackios-userland`. The per-file notices are kept unchanged. Our changes are marked "Bergamota" or "Chlorophyll" in the source (in `air_metal.c`: the IOSurface/KMS import path, the SBO
cache, render passes, refused-draw handling and the other Chlorophyll-marked blocks)
(iOS 18 two-word inline sampler state, `AIR_FC_FILL` stress switch) and are under the same licence.
Nothing of the third-party repository was built from its own scripts or run; the files were read, copied and built with our own build script.

Credit: the AIR front end and the AIR-to-ir3 path that Chlorophyll is built on are the work of the hackios / Darwin on redwood
contributors (OOSEX GANG, https://github.com/oosexgang/hackios-xnu-userland). Chlorophyll's Metal device (`src/bgmtl.m`), the
system plugin (`plugin/`), the backboardd injection (`inject/`) and the libdrm stand-in (`libdrm` / Bergamota's `sweet_drm.c`)
are separate work and not copied from that repository.
