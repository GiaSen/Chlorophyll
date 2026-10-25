#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# What a newer iOS's Metal/QuartzCore expects of Chlorophyll's classes, against an older iOS: base classes we subclass (super,
# ivars, methods), required protocol methods added since, and the selectors QuartzCore newly sends that are Metal protocol
# methods, each marked answered by us (src/bgmtl.m), by Apple's base class, or only by the zero-forwarder (bg_fwd_inv).
#   tools/dsc-objc-gap.py OLD_DIR NEW_DIR [src/bgmtl.m] [-v]
# Each DIR holds, from that iOS's SystemOS cryptex shared cache (DSC), for LIB in Metal QuartzCore IOGPU:
#   ipsw class-dump --no-color DSC /System/Library/.../LIB > DIR/LIB.cd.txt
#   ipsw class-dump --no-color --refs DSC /System/Library/Frameworks/QuartzCore.framework/QuartzCore > DIR/QuartzCore.refs.txt
# (IOS26.md: how the 18.7.8 and 26.6.2 caches were read without keeping the IPSW.)
import collections
import os
import re
import sys

SEL = re.compile(r'(\w+)\s*:\s*\([^)]*\)\s*\w+')
def selof(line):
    body = re.sub(r'^[-+]\s*\([^)]*\)\s*', '', line.strip()).rstrip(';').strip()
    if ':' not in body: return body.split()[0]
    return ''.join(p + ':' for p in SEL.findall(body))
MR = re.compile(r'^\s*([-+])\[\S+ ([^\]]+)\];')
PR = re.compile(r'^\s*@property \(([^)]*)\) (?:.*?)(\w+);\s*$')
def meths(s):
    m = MR.match(s)
    if m: return [(m.group(1), m.group(2))]
    m = PR.match(s)
    if not m: return []
    attrs, name = m.group(1).split(','), m.group(2)
    g = next((a[1:] for a in attrs if a.startswith('G')), name)
    out = [('-', g)]
    if 'R' not in attrs:
        st = next((a[1:] for a in attrs if a.startswith('S')), 'set' + name[0].upper() + name[1:] + ':')
        out.append(('-', st))
    return out
def parse(path):
    classes, protos = {}, {}
    cur = None; kind = None; sect = 'req'; inivars = False
    for line in open(path, errors='replace'):
        s = line.rstrip('\n')
        m = re.match(r'@interface (\w+) : (\w+)(?: <([^>]*)>)?', s)
        if m:
            cur = m.group(1); kind = 'c'; inivars = s.endswith('{')
            classes[cur] = [m.group(2), [p.strip() for p in (m.group(3) or '').split(',') if p.strip()], 0, set(), set()]
            continue
        m = re.match(r'@protocol (\w+)(?: <([^>]*)>)?\s*$', s)
        if m:
            cur = m.group(1); kind = 'p'; sect = 'req'
            protos[cur] = [[p.strip() for p in (m.group(2) or '').split(',') if p.strip()], set(), set()]
            continue
        if s.startswith('@end'): cur = None; continue
        if cur is None: continue
        if kind == 'c':
            if inivars:
                if s.strip() == '}': inivars = False
                elif s.startswith('    ') and not s.strip().startswith('/*'): classes[cur][2] += 1
                continue
            for kindc, sel in meths(s): classes[cur][3 if kindc == '-' else 4].add(sel)
        else:
            if s.startswith('@optional'): sect = 'opt'
            elif s.startswith('@required'): sect = 'req'
            else:
                for kindc, sel in meths(s):
                    if kindc == '-': protos[cur][1 if sect == 'req' else 2].add(sel)
    return classes, protos
def all_proto(protos, name, which=1, seen=None):
    seen = seen if seen is not None else set()
    if name in seen or name not in protos: return set()
    seen.add(name); r = set(protos[name][which])
    for p in protos[name][0]: r |= all_proto(protos, p, which, seen)
    return r


def bg_selectors(path):
    """per-class instance selectors implemented in bgmtl.m"""
    out, cls = collections.defaultdict(set), None
    for line in open(path):
        m = re.match(r'@implementation\s+(\w+)', line)
        if m: cls = m.group(1); continue
        if line.startswith('@end'): cls = None; continue
        if cls and re.match(r'^-\s*\(', line):
            sig = re.sub(r'^-\s*\([^)]*\)\s*', '', line.strip()).split('{')[0]
            out[cls].add(sig.strip().rstrip(';') if ':' not in sig else
                         ''.join(p + ':' for p in re.findall(r'(\w+)\s*:\s*(?:\([^)]*\)\s*)?\w+', sig)))
    return out


ARGS = [a for a in sys.argv[1:] if a != "-v"]
D18, D26 = ARGS[0], ARGS[1]
BGM = ARGS[2] if len(ARGS) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "bgmtl.m")
m18, p18 = parse(D18 + '/Metal.cd.txt'); m26, p26 = parse(D26 + '/Metal.cd.txt')
for extra in ('QuartzCore', 'IOGPU'):
    for d, pr in ((D18, p18), (D26, p26)):
        _, x = parse(f'{d}/{extra}.cd.txt')
        for k, v in x.items(): pr.setdefault(k, v)
def selrefs(path):
    t = open(path).read()
    return set(re.findall(r'=> 0x[0-9a-f]+: (\S+)', t.split('@selectors refs', 1)[1])) if '@selectors refs' in t else set()
bg = bg_selectors(BGM)
NSO = all_proto(p26, 'NSObject', 1)
def chain(cl, n):
    r = set()
    while n in cl: r |= cl[n][3]; n = cl[n][0]
    return r
print('== base classes Chlorophyll subclasses (old -> new)')
for n in ['_MTLDevice', '_MTLObjectWithLabel', '_MTLAllocation', '_MTLResource', '_MTLCommandQueue', '_MTLCommandBuffer', '_MTLCommandEncoder',
          '_MTLComputePipelineState', '_MTLRenderPipelineState', '_MTLSamplerState', '_MTLDepthStencilState']:
    a, b = m18.get(n), m26.get(n)
    if not a or not b: print(n, 'missing in', '18' if not a else '26'); continue
    add, rem = sorted(b[3] - a[3]), sorted(a[3] - b[3])
    print(f'{n:26} super {a[0]}->{b[0]}  ivars {a[2]}->{b[2]}  methods {len(a[3])}->{len(b[3])} (+{len(add)} -{len(rem)})')
    if '-v' in sys.argv:
        if rem: print('     removed:', ' '.join(rem))
BGMAP = {'BGMTLDevice': ('_MTLDevice', ['MTLDevice', 'MTLDeviceSPI']), 'BGMTLBuffer': ('_MTLResource', ['MTLBuffer', 'MTLBufferSPI', 'MTLResource', 'MTLResourceSPI']),
         'BGMTLTexture': ('_MTLResource', ['MTLTexture', 'MTLTextureSPI', 'MTLTextureImplementation', 'MTLResource', 'MTLResourceSPI']),
         'BGMTLCommandQueue': ('_MTLCommandQueue', ['MTLCommandQueue', 'MTLCommandQueueSPI']), 'BGMTLCommandBuffer': ('_MTLCommandBuffer', ['MTLCommandBuffer', 'MTLCommandBufferSPI']),
         'BGMTLComputeEncoder': ('_MTLCommandEncoder', ['MTLCommandEncoder', 'MTLComputeCommandEncoder', 'MTLComputeCommandEncoderSPI']),
         'BGMTLBlitEncoder': ('_MTLCommandEncoder', ['MTLCommandEncoder', 'MTLBlitCommandEncoder', 'MTLBlitCommandEncoderSPI']),
         'BGMTLRenderEncoder': ('_MTLCommandEncoder', ['MTLCommandEncoder', 'MTLRenderCommandEncoder', 'MTLRenderCommandEncoderSPI']),
         'BGMTLComputePipeline': ('_MTLComputePipelineState', ['MTLComputePipelineState', 'MTLComputePipelineStateSPI']),
         'BGMTLRenderPipeline': ('_MTLRenderPipelineState', ['MTLRenderPipelineState', 'MTLRenderPipelineStateSPI']),
         'BGMTLSampler': ('_MTLSamplerState', ['MTLSamplerState', 'MTLSamplerStateSPI']), 'BGMTLDepthStencil': ('_MTLDepthStencilState', ['MTLDepthStencilState', 'MTLDepthStencilStateSPI'])}
q18, q26 = selrefs(D18 + '/QuartzCore.refs.txt'), selrefs(D26 + '/QuartzCore.refs.txt')
qnew = q26 - q18
print(f'\n== QuartzCore selector refs: {len(q18)} -> {len(q26)} (+{len(qnew)} new)')
print('\n== required protocol methods NEW in the newer iOS, per Chlorophyll class: answered by us / by the 26 base class / only by the zero-forwarder')
allnew_unans = {}
for k, (sup, protos) in BGMAP.items():
    ans_us = bg[k]; ans_base = chain(m26, sup)
    for p in protos:
        if p not in p26: continue
        r26 = all_proto(p26, p, 1) - NSO; r18 = all_proto(p18, p, 1) - NSO if p in p18 else set()
        new = r26 - r18
        if p not in p18: tag = '(protocol absent from 18 metadata: all listed)'
        else: tag = ''
        un = sorted(new - ans_us - ans_base)
        print(f'{k:20} {p:30} req {len(r18):3}->{len(r26):3} new={len(new):3} base-answers={len((new & ans_base) - ans_us):3} UNANSWERED={len(un):3} {tag}')
        for s in un: allnew_unans.setdefault(s, set()).add(k)
        if '-v' in sys.argv:
            for s in un: print('      ', s, '[QC-new]' if s in qnew else ('[QC]' if s in q26 else ''))
# QuartzCore's new selectors that are Metal protocol methods and nothing of ours answers
mtlsels = {}
for p, v in p26.items():
    if p.startswith('MTL') or p.startswith('_MTL'):
        for s in v[1] | v[2]: mtlsels.setdefault(s, set()).add(p)
print('\n== selectors QuartzCore (new) newly references that are Metal protocol methods, and whether a Chlorophyll class chain answers them')
for s in sorted(qnew & set(mtlsels)):
    who = [k for k, (sup, _) in BGMAP.items() if s in bg[k] or s in chain(m26, sup)]
    print(f'  {s:70} {",".join(sorted(mtlsels[s]))[:60]:60} answered-by: {",".join(who) or "NONE (zero-forwarder)"}')
