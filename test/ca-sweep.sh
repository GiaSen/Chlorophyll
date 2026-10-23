#!/bin/sh
# SPDX-License-Identifier: MIT
# On the phone, in /var/root/metal-test: one process per fragment function (an abort in the compiler or driver is then one line).
#   ./ca-sweep.sh NAMES.txt OUT.tsv [SOFT]       SOFT=1: softpipe (RWA_SOFTWARE=1); otherwise the Adreno 630. Stops at once if the GPU state is not "on".
names="$1"; out="$2"; : > "$out"
while read n; do
  [ -z "$n" ] && continue
  if [ -z "$3" ]; then
    st=$(./bootinfo | grep -o 'state=[a-z]*' | head -1)
    case "$st" in state=lost) echo "GPU LOST: stopping before $n"; exit 3;; esac
  fi
  if [ -n "$3" ]; then RWA_SOFTWARE=1 ./bgmtl_ca_probe QuartzCore.mtlb "$out" --only "$n" >/dev/null 2>&1; else ./bgmtl_ca_probe QuartzCore.mtlb "$out" --only "$n" >/dev/null 2>&1; fi
  rc=$?
  [ $rc -ne 0 ] && printf '%s\tcrashed\texit %s\t0\n' "$n" "$rc" >> "$out"
done < "$names"
echo "done: $(wc -l < "$out") lines"
