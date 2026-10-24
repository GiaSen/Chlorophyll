#!/bin/bash
# SPDX-License-Identifier: MIT
# Build Chlorophyll.bundle, the Metal driver bundle Metal.framework loads from /System/Library/Extensions when the kernel's
# IOAcceleratorES names it (MetalPluginName = Chlorophyll, MetalPluginClassName = CHLDevice; xnu 0232, boot-arg chlorophyll=1).
#   GPU_METAL_WORK=/scratch gpu/metal/plugin/build.sh OUT [LIBDRM]
# OUT must hold libbgair.dylib and libdrm.2.dylib from build-probe.sh (LIBDRM overrides the libdrm copied in).
# Produces OUT/Chlorophyll.bundle: Info.plist, the Chlorophyll executable (an MH_BUNDLE), libbgair.dylib and libdrm.2.dylib
# next to it (@loader_path: sandboxed processes can read /System/Library/Extensions, not /usr/local/lib).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: plugin/build.sh OUT [LIBDRM]}"
DRM="${2:-$OUT/libdrm.2.dylib}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min=18.0 -isysroot $SDK"
B="$OUT/Chlorophyll.bundle"
rm -rf "$B"; mkdir -p "$B"
cp -f "$OUT/libbgair.dylib" "$B/libbgair.dylib"
cp -f "$DRM" "$B/libdrm.2.dylib"
# The bundle's copy of the Chlorophyll classes gets its own names: processes that also load the bgmtl inject (backboardd, the
# wallpaper poster) would otherwise hold two classes of each name, and a texture of one copy fails the other's class
# checks ("colour attachment 0 is not a texture": the poster's watchdog switched Metal off).
RENAME=""
for c in $(grep -oE '^@interface (BG[A-Za-z0-9_]+)' "$HERE/../src/bgmtl.m" | sed 's/@interface //' | sort -u); do RENAME="$RENAME -D$c=CHL_$c"; done
$CC -O1 -g -fno-objc-arc -Wall -Wno-deprecated-declarations $RENAME -I"$HERE/../air" -c "$HERE/chlorophyll_plugin.m" -o "$OUT/chlorophyll_plugin.o"
$CC -bundle -o "$B/Chlorophyll" "$OUT/chlorophyll_plugin.o" "$B/libbgair.dylib" "$B/libdrm.2.dylib" \
    -framework Foundation -framework Metal -framework IOSurface -framework IOKit -Wl,-rpath,@loader_path
cat > "$B/Info.plist" <<'EOP'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>Chlorophyll</string>
	<key>CFBundleIdentifier</key><string>com.bergamota.chlorophyll</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>Chlorophyll</string>
	<key>CFBundlePackageType</key><string>BNDL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>NSPrincipalClass</key><string>CHLDevice</string>
</dict>
</plist>
EOP
ls -l "$B"
