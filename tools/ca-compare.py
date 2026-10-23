#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Compare two bgmtl_ca_probe outputs (softpipe vs Adreno), and lph vs lpf variants on one device.
usage: ca-compare.py SOFT.tsv GPU.tsv [--tol N]"""
import sys, collections
def load(p):
    d = {}
    for l in open(p):
        f = l.rstrip('\n').split('\t')
        if len(f) >= 3: d[f[0]] = (f[1], f[2])
    return d
def px(h): return bytes.fromhex(h)
def diff(a, b):
    a, b = px(a), px(b)
    mx = max(abs(x - y) for x, y in zip(a, b)); n = sum(1 for i in range(0, len(a), 4) if any(abs(a[i+k]-b[i+k]) > 0 for k in range(4)))
    return mx, n
tol = 3
if '--tol' in sys.argv: tol = int(sys.argv[sys.argv.index('--tol') + 1])
soft, gpu = load(sys.argv[1]), load(sys.argv[2])
both = [n for n in sorted(gpu) if gpu[n][0] == 'drawn' and soft.get(n, ('',))[0] == 'drawn']
exact = close = far = 0; rows = []
for n in both:
    mx, cnt = diff(soft[n][1], gpu[n][1])
    if mx == 0: exact += 1
    elif mx <= tol: close += 1
    else: far += 1; rows.append((n, mx, cnt))
print('softpipe vs Adreno 630, %d functions drawn by both: identical %d, within +-%d/255 %d, further apart %d' % (len(both), exact, tol, close, far))
for n, mx, cnt in rows: print('  differs: %-44s max channel diff %3d, %4d of 1024 pixels' % (n, mx, cnt))
# lph vs lpf on the Adreno
pairs = [(n[:-4] + '_lpf', n) for n in sorted(gpu) if n.endswith('_lph') and gpu.get(n[:-4] + '_lpf', ('',))[0] == 'drawn' and gpu[n][0] == 'drawn']
e = c = f = 0; rows = []
for a, b in pairs:
    mx, cnt = diff(gpu[a][1], gpu[b][1])
    if mx == 0: e += 1
    elif mx <= 4: c += 1
    else: f += 1; rows.append((b, mx, cnt))
print('Adreno 630, half vs float variants (%d pairs): identical %d, within +-4/255 %d, further apart %d' % (len(pairs), e, c, f))
for n, mx, cnt in rows: print('  differs: %-44s max channel diff %3d, %4d of 1024 pixels' % (n, mx, cnt))
st = collections.Counter(v[0] for v in gpu.values()); print('Adreno run:', dict(st), ' softpipe run:', dict(collections.Counter(v[0] for v in soft.values())))
clear = bytes([191, 127, 63, 255])   # BGRA of the clear colour 0.75,0.5,0.25? informational only
untouched = [n for n in sorted(gpu) if gpu[n][0] == 'drawn' and set(px(gpu[n][1])[i:i+4] for i in range(0, 4096, 4)) == {bytes([191, 128, 64, 255])}]
print('Adreno drawn but every pixel still the clear colour (nothing written):', len(untouched))

# ---- the comparable subset: a float-precision (_lpf or unsuffixed) shader that writes colour 0, does not read the framebuffer, and softpipe
# can run. Half variants (_lph) are NOT comparable on softpipe (it has no 16-bit values; its result for them is not a reference).
import os
cls = os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), 'class.tsv')
if '--classes' in sys.argv: cls = sys.argv[sys.argv.index('--classes') + 1]
if os.path.exists(cls):
    c = {l.split()[0]: l.split()[1:] for l in open(cls)}
    sel = [n for n in sorted(gpu) if gpu[n][0] == 'drawn' and soft.get(n, ('',))[0] == 'drawn' and n in c and c[n][0] == '0' and int(c[n][1]) > 0
           and not n.endswith('_lph')]
    bands = collections.Counter(); far = []
    for n in sel:
        mx, cnt = diff(soft[n][1], gpu[n][1])
        b = 'identical' if mx == 0 else '<=3/255' if mx <= 3 else '<=10/255' if mx <= 10 else 'further'
        bands[b] += 1
        if b == 'further': far.append((n, mx))
    print('REFERENCE SUBSET (float precision, colour 0, no framebuffer fetch): %d shaders:' % len(sel), dict(bands))
    for n, mx in far: print('  needs a look: %-40s max channel diff %d' % (n, mx))
