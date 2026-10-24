#!/bin/bash
# SPDX-License-Identifier: MIT
# Spike 1: host-side (macOS) AIR -> NIR -> ir3(a630) translator, in a Mesa 25.0.7 tree of its own.
#   GPU_METAL_WORK=/scratch/dir gpu/metal/build-host.sh
# Needs Mesa 25.0.7 (the mesa submodule, or GPU_EAGL_MESA=<a checkout>): it is cloned with
# `git clone --shared`, so the gpu-eagl tree and its build directories are only READ, never modified. brew install meson bison.
# Produces $WORK/mesa-air/build/src/compiler/air/air2nir and .../src/gallium/drivers/freedreno/ir3_compiler (host binaries).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Bergamota's gpu/ (the libdrm stand-in freedreno-sweet/ and eagl/mesa/bergamota-mesa-25.0.7.patch): Chlorophyll is checked out
# as Bergamota's gpu/metal submodule, so it is the parent directory; for a standalone checkout set BERGAMOTA_GPU.
BG_GPU="${BERGAMOTA_GPU:-$HERE/..}"
[ -d "$BG_GPU/freedreno-sweet" ] || { echo "no $BG_GPU/freedreno-sweet: set BERGAMOTA_GPU to a Bergamota checkout's gpu/" >&2; exit 1; }
WORK="${GPU_METAL_WORK:?set GPU_METAL_WORK}"
EAGL_MESA="${GPU_EAGL_MESA:-$HERE/mesa}"                     # the mesa submodule (25.0.7) unless set
EAGL_LIBDRM="${GPU_EAGL_LIBDRM:-$HERE/libdrm}"               # the libdrm submodule (2.4.124 headers) unless set
VENV="${GPU_EAGL_VENV:?set GPU_EAGL_VENV to a venv with mako, pyyaml, meson}"
BISON="$(brew --prefix bison)/bin"
export PATH="$BISON:$VENV/bin:$PATH"
D="$WORK/mesa-air"
mkdir -p "$D" "$D/pc" "$D/drm-host"
cd "$D"
if [ ! -d mesa ]; then
  git clone -q --shared "$EAGL_MESA" mesa                       # HEAD = the pristine 25.0.7 commit; the gpu-eagl working-tree edits are not copied
  git -C mesa apply "$BG_GPU/eagl/mesa/bergamota-mesa-25.0.7.patch"
  # the freedreno msm backend over the libdrm stand-in is enabled for iOS only by that patch; here the host is macOS
  sed -i.bak "s/host_machine.system() == 'darwin' and host_machine.subsystem() == 'ios' and get_option/host_machine.system() == 'darwin' and get_option/" mesa/meson.build
  rm -f mesa/meson.build.bak
  for p in air-frontend air-ir3 ir3-round-default ir3-shift-split ir3-ssbo-subdword fd-bo-cache-keep fd-bo-cache-skip-busy fd-bo-new-purge-retry fd6-fb-barrier-reorder; do
    git -C mesa apply "$HERE/patches/$p.patch"
  done
  mkdir -p mesa/src/compiler/air
  for f in "$HERE"/air/*; do ln -sf "$f" "mesa/src/compiler/air/$(basename "$f")"; done     # edit in the repo, build here
fi
# host build of the libdrm stand-in: only so that ir3_compiler links; it is never run
clang -arch arm64 -O1 -dynamiclib -install_name "$D/drm-host/libdrm.2.dylib" -I"$EAGL_LIBDRM/include/drm" -I"$EAGL_LIBDRM" \
  "$BG_GPU/freedreno-sweet/sweet_drm.c" -o "$D/drm-host/libdrm.2.dylib" -framework IOKit -framework CoreFoundation
ln -sf libdrm.2.dylib "$D/drm-host/libdrm.dylib"
cat > "$D/pc/libdrm.pc" <<EOP
Name: libdrm
Description: host stand-in
Version: 2.4.124
Cflags: -I$EAGL_LIBDRM/include/drm -I$EAGL_LIBDRM
Libs: -L$D/drm-host -ldrm
EOP
[ -d build ] || PKG_CONFIG_PATH="$D/pc" meson setup build mesa --buildtype=release -Dplatforms= -Dgallium-drivers=freedreno \
  -Dfreedreno-kmds=msm -Dvulkan-drivers= -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dllvm=disabled -Dopengl=true -Dgles2=enabled \
  -Dshader-cache=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dglvnd=disabled -Dvideo-codecs= -Dtools= -Dlmsensors=disabled \
  -Dbuild-tests=false -Dzstd=disabled -Dxmlconfig=disabled -Dexpat=disabled -Dgallium-xa=disabled -Dosmesa=false > setup.log
ninja -j"${JOBS:-4}" -C build src/compiler/air/air2nir src/gallium/drivers/freedreno/ir3_compiler
echo "air2nir:      $D/build/src/compiler/air/air2nir"
echo "ir3_compiler: $D/build/src/gallium/drivers/freedreno/ir3_compiler"
echo "corpus run:   python3 $HERE/tools/corpus.py --air2nir ... --ir3 ... --chip 0x06030001 LIB.metallib..."
