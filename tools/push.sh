#!/bin/bash
# SPDX-License-Identifier: MIT
# push.sh STAGEDIR FILE... : arm64e Mach-O files (dylib/exe) are copied to STAGEDIR, stripped of PAC and ad-hoc signed with
# `renegade strip --sign`, every remote file is deleted first, pushed with scp -O, and verified by sha256. Remote dir: /var/root/metal-test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ST="$1"; shift
REM=/var/root/metal-test
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=60 -o UserKnownHostsFile=/Users/zesmoi/.ssh/known_hosts_ios18 root@192.168.7.2)
SCP=(scp -O -o BatchMode=yes -o ConnectTimeout=60 -o UserKnownHostsFile=/Users/zesmoi/.ssh/known_hosts_ios18)
mkdir -p "$ST"
names=()
for f in "$@"; do
  b="$(basename "$f")"; cp "$f" "$ST/$b"
  case "$(file -b "$f")" in *Mach-O*) python3 "$ROOT/tools/renegade/pacstrip.py" --sign "$ST/$b" >/dev/null ;; esac
  names+=("$b")
done
"${SSH[@]}" "export PATH=/usr/bin:/bin:/usr/local/bin; mkdir -p $REM; cd $REM && rm -f ${names[*]}"
for b in "${names[@]}"; do "${SCP[@]}" "$ST/$b" root@192.168.7.2:$REM/; done
(cd "$ST" && shasum -a 256 "${names[@]}" | awk '{print $1}') > "$ST/.sha.local"
"${SSH[@]}" "export PATH=/usr/bin:/bin:/usr/local/bin; cd $REM && sha256sum ${names[*]} | cut -c1-64" > "$ST/.sha.phone"
cmp "$ST/.sha.local" "$ST/.sha.phone" && echo "SHA-OK ${names[*]}" || { echo SHA-MISMATCH; exit 1; }
