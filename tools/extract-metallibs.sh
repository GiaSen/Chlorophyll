#!/bin/bash
# SPDX-License-Identifier: MIT
# Read-only extraction of iOS 18.7.8 (22H352) system metallibs from the root image (never mounted, never written).
#   tools/extract-metallibs.sh OUTDIR
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
IMG="${IOS18_ROOT_SIMG:-/Users/zesmoi/git/iAndroid/ios-beryllium-ios18/research/ios18/ios18-root-full.simg}"
OUT="${1:?OUTDIR}"; mkdir -p "$OUT"
for p in /System/Library/Frameworks/QuartzCore.framework/default.metallib \
         /System/Library/PrivateFrameworks/CoreUI.framework/default.metallib \
         /System/Library/PrivateFrameworks/RenderBox.framework/default.metallib \
         /System/Library/PrivateFrameworks/MediaCoreUI.framework/default.metallib \
         /System/Library/PrivateFrameworks/SiriUICore.framework/default.metallib \
         /System/Library/Frameworks/SpriteKit.framework/default.metallib \
         /System/Library/Frameworks/PencilKit.framework/default.metallib \
         /System/Library/Frameworks/MetalFX.framework/default.metallib \
         /System/Library/Extensions/AppleMetalGLRenderer.bundle/default.metallib; do
  n="$(echo "$p" | awk -F/ '{print $(NF-1)}' | sed 's/\.\(framework\|bundle\)$//').default.metallib"
  python3 "$ROOT/tools/renegade/hfsx.py" "$IMG" get "$p" "$OUT/$n"
done
# QuartzCore's file is a fat wrapper: slice 0 (cputype 0x01000017) is the AIR container ("MTLB", 178 functions),
# slice 1 (cputype 0x01000013) is a Mach-O with Apple's precompiled GPU binaries (A12 ISA, useless here). tools/corpus.py unwraps it.
ls -l "$OUT"
