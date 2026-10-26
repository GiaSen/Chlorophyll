#!/bin/bash
# SPDX-License-Identifier: MIT
# Build turnip/test/chl_test (Chlorophyll's Turnip runtime, air/chl.h) for the phone into OUT (default $GPU_METAL_WORK/out-chl):
# arm64e, PAC-stripped, signed with turnip/entitlements.plist, next to libchlorophyll.dylib, the libdrm stand-in and the test metallibs.
# Run turnip/build-turnip.sh first. On the phone: ./chl_test bg_kernels.metallib bg_render.metallib  (CHL_BENCH=1 adds the 200-draw bench)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BG_GPU="${BERGAMOTA_GPU:-$HERE/../..}"
WORK="${GPU_METAL_WORK:?set GPU_METAL_WORK}"
D="${TURNIP_TREE:-$WORK/mesa-turnip26}"
OUT="${1:-$WORK/out-chl}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min=18.0 -isysroot $SDK"
mkdir -p "$OUT"
cp -f "$D/build-ios/src/freedreno/vulkan/libchlorophyll.dylib" "$OUT/"
xcrun strip -x "$OUT/libchlorophyll.dylib"
cp -f "$D/drm-ios/libdrm.2.arm64e.dylib" "$OUT/libdrm.2.dylib"
for m in bg_kernels bg_render; do
  xcrun -sdk iphoneos metal -mios-version-min=18.0 -c "$HERE/../test/$m.metal" -o "$OUT/$m.air"
  xcrun -sdk iphoneos metallib "$OUT/$m.air" -o "$OUT/$m.metallib"
done
$CC -O2 -g -Wall -I"$HERE/../air" "$HERE/test/chl_test.c" -o "$OUT/chl_test" "$OUT/libchlorophyll.dylib" "$OUT/libdrm.2.dylib" \
    -Wl,-rpath,@executable_path
codesign -f -s - --entitlements "$HERE/entitlements.plist" "$OUT/chl_test" 2>/dev/null
for f in chl_test libchlorophyll.dylib libdrm.2.dylib; do python3 "$BG_GPU/../tools/renegade/pacstrip.py" --sign "$OUT/$f" >/dev/null; done
ls -l "$OUT"
