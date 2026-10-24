#!/bin/bash
# SPDX-License-Identifier: MIT
# Spike 2: cross-build libbgair.dylib (AIR -> NIR -> ir3 -> freedreno compute, air_metal.c) for iOS arm64e in the SAME separate Mesa tree as
# build-host.sh ($WORK/mesa-air), in its own build dir build-ios. The gpu-eagl tree and its build dirs are never touched.
#   GPU_METAL_WORK=/scratch gpu/metal/build-ios.sh        (run build-host.sh first: it creates and patches the source tree)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Bergamota's gpu/ (the libdrm stand-in freedreno-sweet/ and eagl/mesa/bergamota-mesa-25.0.7.patch): Chlorophyll is checked out
# as Bergamota's gpu/metal submodule, so it is the parent directory; for a standalone checkout set BERGAMOTA_GPU.
BG_GPU="${BERGAMOTA_GPU:-$HERE/..}"
[ -d "$BG_GPU/freedreno-sweet" ] || { echo "no $BG_GPU/freedreno-sweet: set BERGAMOTA_GPU to a Bergamota checkout's gpu/" >&2; exit 1; }
WORK="${GPU_METAL_WORK:?set GPU_METAL_WORK}"
EAGL_LIBDRM="${GPU_EAGL_LIBDRM:-$HERE/libdrm}"               # the libdrm submodule (2.4.124 headers) unless set
VENV="${GPU_EAGL_VENV:?set GPU_EAGL_VENV}"
EAGL_CROSS="${GPU_EAGL_CROSS:?set GPU_EAGL_CROSS to gpu-eagl's ios-hw.cross}"
export PATH="$(brew --prefix bison)/bin:$VENV/bin:$PATH"
D="$WORK/mesa-air"; cd "$D"
"$BG_GPU/freedreno-sweet/build.sh" "$D/drm-ios" >/dev/null           # the libdrm stand-in, arm64e, PAC-stripped and signed copy in libdrm.2.dylib
mkdir -p pc-ios drm-ios-link
cp drm-ios/libdrm.2.arm64e.dylib drm-ios-link/libdrm.2.dylib; ln -sf libdrm.2.dylib drm-ios-link/libdrm.dylib
cat > pc-ios/libdrm.pc <<EOP
Name: libdrm
Description: Bergamota libdrm stand-in (gpu/freedreno-sweet)
Version: 2.4.124
Cflags: -I$EAGL_LIBDRM/include/drm -I$EAGL_LIBDRM
Libs: -L$D/drm-ios-link -ldrm
EOP
sed "s#pkg_config_path = .*#pkg_config_path = ['$D/pc-ios']#" "$EAGL_CROSS" > ios.cross
[ -d build-ios ] || meson setup build-ios mesa --cross-file ios.cross --buildtype=release -Dgallium-drivers=softpipe,freedreno -Dfreedreno-kmds=msm \
  -Dgallium-xa=disabled -Dtools= -Dvulkan-drivers= -Dllvm=disabled -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dplatforms= -Dosmesa=false \
  -Dopengl=true -Dgles1=disabled -Dgles2=enabled -Dshared-glapi=enabled -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=disabled -Dxmlconfig=disabled \
  -Dbuild-tests=false -Dglvnd=disabled -Dlmsensors=disabled -Dgallium-opencl=disabled -Dgallium-rusticl=false -Dshader-cache=disabled -Dprefix=/ > setup-ios.log
ninja -j"${JOBS:-4}" -C build-ios src/gallium/drivers/freedreno/libbgair.dylib
ls -l build-ios/src/gallium/drivers/freedreno/libbgair.dylib
