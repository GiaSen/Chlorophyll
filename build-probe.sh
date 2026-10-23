#!/bin/bash
# SPDX-License-Identifier: MIT
# Spike 2: build the BGMTLDevice probe for iOS arm64e (a standalone test tool; not an app, not a daemon, not a plug-in).
#   GPU_METAL_WORK=/scratch/dir gpu/metal/build-probe.sh [OUT]       needs $WORK/mesa-air/build-ios (libbgair.dylib, see build-ios.sh)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${GPU_METAL_WORK:?set GPU_METAL_WORK}"
OUT="${1:-$WORK/out}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min=18.0 -isysroot $SDK"
BG="$WORK/mesa-air/build-ios/src/gallium/drivers/freedreno/libbgair.dylib"
mkdir -p "$OUT"
cp -f "$BG" "$OUT/libbgair.dylib"
cp -f "$WORK/mesa-air/drm-ios/libdrm.2.arm64e.dylib" "$OUT/libdrm.2.dylib"
$CC -O1 -g -fno-objc-arc -Wall -Wno-deprecated-declarations -I"$HERE/air" -c "$HERE/src/bgmtl.m" -o "$OUT/bgmtl.o"
$CC -O1 -g -fno-objc-arc -Wall -Wno-deprecated-declarations -c "$HERE/test/bgmtl_probe.m" -o "$OUT/bgmtl_probe.o"
$CC -o "$OUT/bgmtl_probe" "$OUT/bgmtl.o" "$OUT/bgmtl_probe.o" "$OUT/libbgair.dylib" -framework Foundation -framework Metal \
    -Wl,-rpath,@executable_path
# the test kernels: AIR compiled on the Mac
xcrun -sdk iphoneos metal -mios-version-min=18.0 -c "$HERE/test/bg_kernels.metal" -o "$OUT/bg_kernels.air"
xcrun -sdk iphoneos metallib "$OUT/bg_kernels.air" -o "$OUT/bg_kernels.metallib"
$CC -O1 -g -fno-objc-arc -o "$OUT/mtl_introspect" "$HERE/test/mtl_introspect.m" -framework Foundation
ls -l "$OUT"
