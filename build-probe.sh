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
xcrun strip -x "$OUT/libbgair.dylib"      # 9.4 MB instead of 10 MB: large scp transfers over the USB link have dropped
cp -f "$WORK/mesa-air/drm-ios/libdrm.2.arm64e.dylib" "$OUT/libdrm.2.dylib"
$CC -O1 -g -fno-objc-arc -Wall -Wno-deprecated-declarations -I"$HERE/air" -c "$HERE/src/bgmtl.m" -o "$OUT/bgmtl.o"
$CC -O1 -g -fno-objc-arc -Wall -Wno-deprecated-declarations -c "$HERE/test/bgmtl_probe.m" -o "$OUT/bgmtl_probe.o"
$CC -o "$OUT/bgmtl_probe" "$OUT/bgmtl.o" "$OUT/bgmtl_probe.o" "$OUT/libbgair.dylib" "$OUT/libdrm.2.dylib" -framework Foundation -framework Metal -framework IOSurface \
    -Wl,-rpath,@executable_path
# the test kernels: AIR compiled on the Mac
xcrun -sdk iphoneos metal -mios-version-min=18.0 -c "$HERE/test/bg_kernels.metal" -o "$OUT/bg_kernels.air"
xcrun -sdk iphoneos metallib "$OUT/bg_kernels.air" -o "$OUT/bg_kernels.metallib"
xcrun -sdk iphoneos metal -mios-version-min=18.0 -c "$HERE/test/bg_render.metal" -o "$OUT/bg_render.air"
xcrun -sdk iphoneos metallib "$OUT/bg_render.air" -o "$OUT/bg_render.metallib"
$CC -O1 -g -fno-objc-arc -Wall -Wno-deprecated-declarations -c "$HERE/test/bgmtl_render_probe.m" -o "$OUT/bgmtl_render_probe.o"
$CC -O1 -g -fno-objc-arc -Wall -Wno-deprecated-declarations -I"$HERE/air" -c "$HERE/test/bgmtl_ca_probe.m" -o "$OUT/bgmtl_ca_probe.o"
$CC -o "$OUT/bgmtl_ca_probe" "$OUT/bgmtl.o" "$OUT/bgmtl_ca_probe.o" "$OUT/libbgair.dylib" "$OUT/libdrm.2.dylib" -framework Foundation -framework Metal -framework IOSurface -Wl,-rpath,@executable_path
$CC -O1 -g -fno-objc-arc -Wall -Wno-deprecated-declarations -c "$HERE/test/bgmtl_layer_probe.m" -o "$OUT/bgmtl_layer_probe.o"
$CC -o "$OUT/bgmtl_layer_probe" "$OUT/bgmtl.o" "$OUT/bgmtl_layer_probe.o" "$OUT/libbgair.dylib" "$OUT/libdrm.2.dylib" -framework Foundation -framework Metal -framework IOSurface -framework QuartzCore -Wl,-rpath,@executable_path
# phase (j)(b): CoreAnimation's Metal renderer offscreen over BGMTLDevice, against its CPU renderer
$CC -O1 -g -fno-objc-arc -Wall -Wno-deprecated-declarations -c "$HERE/test/bgmtl_carenderer_probe.m" -o "$OUT/bgmtl_carenderer_probe.o"
$CC -o "$OUT/bgmtl_carenderer_probe" "$OUT/bgmtl.o" "$OUT/bgmtl_carenderer_probe.o" "$OUT/libbgair.dylib" "$OUT/libdrm.2.dylib" -framework Foundation \
    -framework Metal -framework IOSurface -framework QuartzCore -framework CoreGraphics -Wl,-rpath,@executable_path
$CC -O1 -g -fno-objc-arc -Wall -Wno-deprecated-declarations -c "$HERE/test/bgmtl_adddev.m" -o "$OUT/bgmtl_adddev.o"
$CC -o "$OUT/bgmtl_adddev" "$OUT/bgmtl.o" "$OUT/bgmtl_adddev.o" "$OUT/libbgair.dylib" "$OUT/libdrm.2.dylib" -framework Foundation -framework Metal -framework IOSurface -Wl,-rpath,@executable_path
$CC -O1 -g -Wall -I"$HERE/air" "$HERE/test/bgair_vertex_test.c" -o "$OUT/bgair_vertex_test" "$OUT/libbgair.dylib" "$OUT/libdrm.2.dylib" -Wl,-rpath,@executable_path
$CC -O1 -g -fno-objc-arc -Wall -Wno-deprecated-declarations -I"$HERE/air" -c "$HERE/test/bgmtl_mercury_probe.m" -o "$OUT/bgmtl_mercury_probe.o"
$CC -o "$OUT/bgmtl_mercury_probe" "$OUT/bgmtl.o" "$OUT/bgmtl_mercury_probe.o" "$OUT/libbgair.dylib" "$OUT/libdrm.2.dylib" -framework Foundation -framework Metal -framework IOSurface -Wl,-rpath,@executable_path
$CC -o "$OUT/bgmtl_render_probe" "$OUT/bgmtl.o" "$OUT/bgmtl_render_probe.o" "$OUT/libbgair.dylib" "$OUT/libdrm.2.dylib" -framework Foundation -framework Metal -framework IOSurface -Wl,-rpath,@executable_path
$CC -O1 -g -fno-objc-arc -o "$OUT/mtl_introspect" "$HERE/test/mtl_introspect.m" -framework Foundation
$CC -O1 -g -Wall -I"$HERE/air" "$HERE/test/bgair_test.c" -o "$OUT/bgair_test" "$OUT/libbgair.dylib" -Wl,-rpath,@executable_path
$CC -O1 -g -fno-objc-arc -Wall -Wno-deprecated-declarations -c "$HERE/test/mtl_gap.m" -o "$OUT/mtl_gap.o"
$CC -o "$OUT/mtl_gap" "$OUT/bgmtl.o" "$OUT/mtl_gap.o" "$OUT/libbgair.dylib" "$OUT/libdrm.2.dylib" -framework Foundation -framework Metal -framework IOSurface -Wl,-rpath,@executable_path
$CC -O1 -g -o "$OUT/bootinfo" "$HERE/test/bootinfo.c" -framework IOKit -framework CoreFoundation
# the injection dylib (Mercury only, inert unless armed; see inject/bgmtl_inject.m)
$CC -O1 -g -fno-objc-arc -Wall -Wno-deprecated-declarations -c "$HERE/inject/bgmtl_inject.m" -o "$OUT/bgmtl_inject.o"
$CC -dynamiclib -o "$OUT/bgmtl-inject.dylib" "$OUT/bgmtl.o" "$OUT/bgmtl_inject.o" "$OUT/libbgair.dylib" "$OUT/libdrm.2.dylib" \
    -framework Foundation -framework Metal -framework IOSurface -install_name /usr/local/lib/bgmtl/bgmtl-inject.dylib -Wl,-rpath,@loader_path
ls -l "$OUT"
