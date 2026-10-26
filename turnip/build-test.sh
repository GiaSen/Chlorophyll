#!/bin/bash
# SPDX-License-Identifier: MIT
# Build the Turnip smoke test for the phone: tu_smoke (arm64e, PAC-stripped, ad-hoc signed with turnip/entitlements.plist) next to
# libvulkan_freedreno.dylib and the libdrm stand-in, in OUT (default $GPU_METAL_WORK/out-turnip). Run turnip/build-turnip.sh first.
#   GPU_METAL_WORK=/Users/zesmoi/git/iAndroid/work-chlorophyll gpu/metal/turnip/build-test.sh [OUT]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BG_GPU="${BERGAMOTA_GPU:-$HERE/../..}"
WORK="${GPU_METAL_WORK:?set GPU_METAL_WORK}"
D="${TURNIP_TREE:-$WORK/mesa-turnip26}"
OUT="${1:-$WORK/out-turnip}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min=18.0 -isysroot $SDK"
mkdir -p "$OUT"
for s in tri.vert color.frag tex.frag; do
  glslangValidator -V --target-env vulkan1.1 --vn "spv_${s/./_}" -o "$OUT/${s/./_}.h" "$HERE/test/$s" >/dev/null
done
cp -f "$D/build-ios/src/freedreno/vulkan/libvulkan_freedreno.dylib" "$OUT/"
xcrun strip -x "$OUT/libvulkan_freedreno.dylib"
cp -f "$D/drm-ios/libdrm.2.arm64e.dylib" "$OUT/libdrm.2.dylib"
$CC -O2 -g -Wall -I"$D/mesa/include" -I"$OUT" "$HERE/test/tu_smoke.c" -o "$OUT/tu_smoke" "$OUT/libvulkan_freedreno.dylib" "$OUT/libdrm.2.dylib" \
    -Wl,-rpath,@executable_path
for f in tu_smoke libvulkan_freedreno.dylib libdrm.2.dylib; do
  if [ "$f" = tu_smoke ]; then codesign -f -s - --entitlements "$HERE/entitlements.plist" "$OUT/$f" 2>/dev/null; fi
  python3 "$BG_GPU/../tools/renegade/pacstrip.py" --sign "$OUT/$f" >/dev/null
done
# the same benchmark on Gallium (the installed libbgair, from build-ios.sh), while Gallium is still around
BGAIR="$WORK/mesa-air/build-ios/src/gallium/drivers/freedreno/libbgair.dylib"
if [ -f "$BGAIR" ]; then
  cp -f "$BGAIR" "$OUT/libbgair.dylib"; xcrun strip -x "$OUT/libbgair.dylib"
  xcrun -sdk iphoneos metal -mios-version-min=18.0 -c "$HERE/../test/bg_render.metal" -o "$OUT/bg_render.air"
  xcrun -sdk iphoneos metallib "$OUT/bg_render.air" -o "$OUT/bg_render.metallib"
  $CC -O2 -g -Wall -I"$HERE/../air" "$HERE/test/bgair_drawbench.c" -o "$OUT/bgair_drawbench" "$OUT/libbgair.dylib" "$OUT/libdrm.2.dylib" \
      -Wl,-rpath,@executable_path
  codesign -f -s - --entitlements "$HERE/entitlements.plist" "$OUT/bgair_drawbench" 2>/dev/null
  for f in bgair_drawbench libbgair.dylib; do python3 "$BG_GPU/../tools/renegade/pacstrip.py" --sign "$OUT/$f" >/dev/null; done
fi
ls -l "$OUT"
