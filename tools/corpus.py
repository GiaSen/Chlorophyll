#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Corpus run for the AIR -> NIR -> ir3 (a630) path, Mac host only.

For every function of every .metallib given:
  stage 1  container   the MTLB slice is found (fat wrappers are unwrapped)
  stage 2  reader      the bitcode reader accepts the module
  stage 3  translate   air_to_nir produces a nir_shader that passes nir_validate
  stage 4  ir3         ir3 compiles it for chip 0x06030001 (Adreno 630)
Each function is counted under the first stage it fails; the failure text is normalised into a
"class" so that the report says what kinds of thing fail, not only how many.

Nothing here says a translated shader is *correct*: that needs the GPU (spike 2).

usage: corpus.py --air2nir BIN --ir3 BIN [--chip 0x06030001] [--json OUT] [--md OUT] [-j N] LIB...
"""
import argparse, collections, json, os, re, struct, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor


def mtlb_slices(path):
    """Yield (index, cputype, bytes) for each MTLB slice of a metallib (fat or plain)."""
    d = open(path, 'rb').read()
    if d[:4] == b'MTLB':
        yield 0, None, d
    elif d[:4] == b'\xca\xfe\xba\xbe':
        n = struct.unpack('>I', d[4:8])[0]
        for i in range(n):
            cpu, sub, off, sz, al = struct.unpack('>IIIII', d[8 + 20 * i:28 + 20 * i])
            if d[off:off + 4] == b'MTLB':
                yield i, cpu, d[off:off + sz]


def norm(msg):
    """Collapse a failure message into a class: drop numbers, hex, quoted names, ids."""
    m = msg.strip()
    m = re.sub(r'0x[0-9a-fA-F]+', 'N', m)
    m = re.sub(r'%[0-9a-zA-Z_.]+', '%v', m)
    m = re.sub(r'"[^"]*"', '"..."', m)
    m = re.sub(r"'[^']*'", "'...'", m)
    m = re.sub(r'\b[a-z]+\.[a-z0-9_.]+\b', lambda x: x.group(0) if x.group(0).startswith('air.') else 'ID', m)
    m = re.sub(r'\d+', 'N', m)
    return m[:160]


def parse_report_line(line):
    f = {}
    for kv in line.rstrip('\n').split('\t'):
        if '=' in kv:
            k, v = kv.split('=', 1)
            f[k] = v
    return f


def run_ir3(ir3, chip, mtlb_path, fn):
    try:
        p = subprocess.run([ir3, '--chip-id', chip, mtlb_path, fn], capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return 'timeout', 'ir3 timeout (120 s)', None
    out = p.stdout + p.stderr
    if p.returncode != 0:
        lines = [l for l in out.splitlines() if l.strip()]
        sig = ''
        if p.returncode < 0:
            sig = 'signal %d: ' % -p.returncode
        # the last "Assertion"/"error"/failing line is the most informative
        pick = [l for l in lines if re.search(r'ssert|rror|fail|unsupported|not supported|NIR_PASS|abort', l)]
        return 'fail', sig + (pick[-1] if pick else (lines[-1] if lines else 'exit %d' % p.returncode)), None
    m = re.search(r'(\d+) instr', out)
    return 'ok', '', out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--air2nir', required=True)
    ap.add_argument('--ir3', required=True)
    ap.add_argument('--chip', default='0x06030001')
    ap.add_argument('--json')
    ap.add_argument('--md')
    ap.add_argument('--work', default=None)
    ap.add_argument('-j', type=int, default=2)
    ap.add_argument('libs', nargs='+')
    a = ap.parse_args()
    work = a.work or tempfile.mkdtemp(prefix='corpus-')
    os.makedirs(work, exist_ok=True)

    results = []   # one dict per function
    tasks = []
    for lib in a.libs:
        base = os.path.basename(lib)
        for idx, cpu, data in mtlb_slices(lib):
            sp = os.path.join(work, '%s.%d.metallib' % (base, idx))
            open(sp, 'wb').write(data)
            rep = subprocess.run([a.air2nir, '--report', sp], capture_output=True, text=True)
            seen = 0
            for line in rep.stdout.splitlines():
                f = parse_report_line(line)
                if 'module' not in f:
                    continue
                seen += 1
                r = {'lib': base, 'slice': idx, 'fn': f['module'], 'kind': f.get('container', '-'), 'stage_name': f.get('stage', '-'),
                     'fc': int(f.get('fc', 0)), 'mtlb': sp}
                if 'crash' in f:
                    r.update(stage='translate', status='crash', why=f['crash'])
                elif f.get('reader') == 'fail':
                    r.update(stage='reader', status='fail', why=f.get('error', ''))
                elif f.get('translate') == 'fail':
                    r.update(stage='translate', status='fail', why=f.get('error', ''))
                elif f.get('translate') == 'ok':
                    r.update(stage='translate', status='ok', why='', nir_instrs=int(f.get('nir_instrs', 0)), notes=f.get('notes', ''))
                    tasks.append(r)
                else:
                    r.update(stage='container', status='fail', why=line)
                results.append(r)
            if seen == 0:
                results.append({'lib': base, 'slice': idx, 'fn': '(container)', 'stage': 'container', 'status': 'fail',
                                'why': (rep.stderr.strip().splitlines() or ['no module'])[-1], 'kind': '-'})

    def job(r):
        st, why, out = run_ir3(a.ir3, a.chip, r['mtlb'], r['fn'])
        r['ir3'] = st
        r['ir3_why'] = why
        if out:
            m = re.search(r'; (\d+) instr', out) or re.search(r'(\d+) instr', out)
            if m:
                r['ir3_instrs'] = int(m.group(1))
    with ThreadPoolExecutor(a.j) as ex:
        list(ex.map(job, tasks))

    for r in results:
        r.pop('mtlb', None)

    total = len(results)
    n_read = sum(1 for r in results if r['stage'] != 'reader' and r['stage'] != 'container')
    n_tr = sum(1 for r in results if r['status'] == 'ok')
    n_ir3 = sum(1 for r in results if r.get('ir3') == 'ok')
    classes = collections.Counter()
    examples = {}
    for r in results:
        if r['status'] != 'ok':
            key = ('%s: %s' % (r['stage'], norm(r['why'])))
        elif r.get('ir3') != 'ok':
            key = 'ir3: ' + norm(r.get('ir3_why', ''))
        else:
            continue
        classes[key] += 1
        examples.setdefault(key, []).append('%s/%s' % (r['lib'], r['fn']))
    summary = {'total': total, 'reader_ok': n_read, 'translate_ok': n_tr, 'ir3_ok': n_ir3, 'chip': a.chip,
               'classes': [{'class': k, 'count': c, 'examples': examples[k][:4]} for k, c in classes.most_common()]}
    by_kind = collections.defaultdict(lambda: [0, 0, 0])
    for r in results:
        k = by_kind[(r['lib'], r.get('kind', '-'))]
        k[0] += 1
        k[1] += r['status'] == 'ok'
        k[2] += r.get('ir3') == 'ok'
    summary['by_lib_kind'] = [{'lib': l, 'kind': k, 'total': v[0], 'translate_ok': v[1], 'ir3_ok': v[2]} for (l, k), v in sorted(by_kind.items())]
    if a.json:
        json.dump({'summary': summary, 'results': results}, open(a.json, 'w'), indent=1)
    lines = ['functions=%d reader_ok=%d translate_ok=%d ir3_ok=%d (chip %s)' % (total, n_read, n_tr, n_ir3, a.chip)]
    for e in summary['by_lib_kind']:
        lines.append('  %-44s %-10s total=%-4d translate=%-4d ir3=%d' % (e['lib'], e['kind'], e['total'], e['translate_ok'], e['ir3_ok']))
    for c in summary['classes']:
        lines.append('  [%d] %s   e.g. %s' % (c['count'], c['class'], ', '.join(c['examples'][:2])))
    txt = '\n'.join(lines)
    print(txt)
    if a.md:
        open(a.md, 'w').write(txt + '\n')


if __name__ == '__main__':
    main()
