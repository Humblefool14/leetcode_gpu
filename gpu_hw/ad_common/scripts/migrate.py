#!/usr/bin/env python3
"""migrate.py REPO: move a repository's private copies of common primitives to ../ad_common.

Rewrites the RTL instances (module name and, where they differ, port names), deletes the private
copies and their formal directories, and points every sim .f list and formal .sby at
../ad_common/rtl/common/.  Prints what it changed.
"""
import os
import re
import shutil
import sys

C = 'rtl/common/'
ARB = [C + 'arb/rec_arbiter.sv']
MAP = {  # old module: (new module, common files, port renames {old: new})
    'ad_su_fifo':       ('ad_fifo', [C + 'fifo/ad_fifo.v'], {}),
    'ad_gfx_fifo':      ('ad_fifo', [C + 'fifo/ad_fifo.v'], {'d': 'din', 'q': 'dout'}),
    'ad_ctl_spipe':     ('ad_delay', [C + 'pipe/ad_delay.v'], {}),
    'ad_gfx_skid':      ('ad_skid', [C + 'pipe/ad_skid.v'], {}),
    'ad_su_ram1r1w':    ('ad_ram_1r1w', [C + 'mem/ad_ram_1r1w.v'], {}),
    'ad_mem_tdpram':    ('ad_ram_tdp', [C + 'mem/ad_ram_tdp.v'], {}),
    'ad_cache_ram':     ('ad_ram_sp_be', [C + 'mem/ad_ram_sp_be.v'], {}),
    'ad_hazard_prienc': ('rec_arbiter', ARB, {'any': 'grant_valid', 'idx': 'grant_index'}),
    'ad_vf_vc_penc':    ('rec_arbiter', ARB, {'any': 'grant_valid', 'idx': 'grant_index'}),
    'ad_su_rr_pick':    ('rr_pick', ARB + [C + 'arb/rr_pick.sv'],
                         {'gnt': 'grant_onehot', 'idx': 'grant_index', 'any': 'grant_valid'}),
    'ad_gfx_popc32':    ('ad_popcount', [C + 'math/ad_popcount.v'], {'m': 'in', 'n': 'count'}),
    'ad_amb_mux':       ('ad_amb_mux', [C + 'bus/ad_amb_mux.v'] + ARB + [C + 'arb/rr_pick.sv'], {}),
    'rec_arbiter':      ('rec_arbiter', ARB, {}),                       # ad_vf's local copy
    'rr_pick':          ('rr_pick', ARB + [C + 'arb/rr_pick.sv'], {}),  # ad_vf's local copy
}
# parameters that change name (old module: {old param: new param or None to drop})
PMAP = {'ad_hazard_prienc': {'IDX_W': None}, 'ad_vf_vc_penc': {'IDX_W': None},
        'ad_su_rr_pick': {'PW': None}, 'ad_gfx_popc32': {}}
EXTRA_PARAMS = {'ad_gfx_popc32': '#(.W(32)) '}
# formal-only defines that change name
DEFS = {'AD_FV_CACHE': ['AD_FV_RAM']}


def walk(root, exts):
    for d, _, fs in os.walk(root):
        for f in fs:
            if f.endswith(exts):
                yield os.path.join(d, f)


def remap_instance(text, old, new, ports, params, extra):
    # module name at an instantiation: "old #(" or "old name ("
    pat = re.compile(r'\b' + old + r'(\s*)(#\s*\(|[A-Za-z_]\w*\s*\()')
    out, pos, n = [], 0, 0
    for m in pat.finditer(text):
        # find the end of the instance (the matching ');')
        start = m.start()
        depth, i, seen = 0, m.end() - 1, False
        while i < len(text):
            if text[i] == '(':
                depth += 1; seen = True
            elif text[i] == ')':
                depth -= 1
                if seen and depth == 0 and text[i + 1:].lstrip().startswith(';'):
                    break
            i += 1
        body = text[start:i + 1]
        body = body.replace(old, new, 1)
        if extra and '#(' not in body.split('(')[0] + '(':
            body = body.replace(new + ' ', new + ' ' + extra, 1)
        for po, pn in ports.items():
            body = re.sub(r'\.' + po + r'(\s*)\(', '.' + pn + r'\1(', body)
        for po, pn in params.items():
            body = re.sub(r',?\s*\.' + po + r'\s*\([^()]*(\([^()]*\))?[^()]*\)', '', body) if pn is None else \
                re.sub(r'\.' + po + r'(\s*)\(', '.' + pn + r'\1(', body)
        out.append(text[pos:start]); out.append(body); pos = i + 1; n += 1
    out.append(text[pos:])
    return ''.join(out), n


def main(repo):
    os.chdir(repo)
    log = []
    # 1. private copies
    copies = {}
    for f in walk('rtl', ('.v', '.sv')):
        m = re.search(r'^\s*module\s+(\w+)', open(f).read(), re.M)
        if m and m.group(1) in MAP:
            copies[m.group(1)] = f
    # 2. instances in RTL and formal harnesses
    for f in list(walk('rtl', ('.v', '.sv'))) + list(walk('formal', ('.sv',))) + list(walk('sim/tb', ('.v',))):
        if f in copies.values():
            continue
        t = open(f).read(); t0 = t
        for old in copies:
            new, _, ports = MAP[old]
            t, n = remap_instance(t, old, new, ports, PMAP.get(old, {}), EXTRA_PARAMS.get(old, ''))
            if n:
                log.append('%s: %d x %s -> %s' % (f, n, old, new))
            t = re.sub(r'\b' + old + r'\b(?=[ ,.)])', new, t) if old != new and n == 0 and \
                re.search(r'//.*\b' + old + r'\b', t) else t
        for d, nd in DEFS.items():
            pass
        if t != t0:
            open(f, 'w').write(t)
    # 3. file lists
    commonf = lambda p: '../ad_common/' + p
    for f in walk('sim/tb', ('.f',)):
        L = open(f).read().split('\n'); out = []; add = []
        for l in L:
            hit = [o for o, p in copies.items() if l.strip() == p]
            if hit:
                add += MAP[hit[0]][1]
            else:
                out.append(l)
        if add:
            for p in dict.fromkeys(add):
                if commonf(p) not in out:
                    out.insert(0, commonf(p))
            open(f, 'w').write('\n'.join(out)); log.append('%s: -> common %s' % (f, sorted(set(add))))
    for f in walk('formal', ('.sby',)):
        t = open(f).read(); t0 = t; add = []
        for o, p in copies.items():
            base = os.path.basename(p)
            if re.search(r'(^|\s|/)' + re.escape(base) + r'(\s|$)', t):
                add += MAP[o][1]
                t = re.sub(r'^.*/' + re.escape(base) + r'\s*$\n?', '', t, flags=re.M)     # [files]
                t = re.sub(r'(?<=[ \t])(?:\S*/)?' + re.escape(base) + r'(?=[ \t\n])', '', t)  # read lines
        if add:
            add = list(dict.fromkeys(add))
            bases = ' '.join(os.path.basename(p) for p in add)
            # prefixed read lines are per task: each gets the files; of the unprefixed ones (all run
            # in sequence) only the first, or the modules would be read twice
            first = [True]
            has_plain = re.search(r'^read -formal', t, flags=re.M) is not None
            def addto(m):
                if m.group(2):
                    return m.group(1) + ('' if has_plain else ' ' + bases)
                if first[0]:
                    first[0] = False
                    return m.group(1) + ' ' + bases
                return m.group(1)
            t = re.sub(r'^((\w+: )?read -formal(?: -D\w+(?:=\S+)?)*(?: -I\S+)*)', addto, t, flags=re.M)
            t = t.replace('[files]\n', '[files]\n' + ''.join('../../../ad_common/%s\n' % p for p in add))
            t = re.sub(r'  +', ' ', t)
        for d, nds in DEFS.items():
            t = re.sub(r'-D' + d + r'\b', '-D' + d + ''.join(' -D' + x for x in nds), t) if ('-D' + nds[0]) not in t else t
        if t != t0:
            open(f, 'w').write(t); log.append('%s: updated' % f)
    # 4. delete private copies and their formal dirs
    for o, p in copies.items():
        os.remove(p); log.append('removed %s' % p)
        for d in os.listdir('formal'):
            sby = os.path.join('formal', d, d + '.sby')
            if os.path.exists(sby) and re.search(r'prep -top fv_' + d, open(sby).read()) and \
                    (d == o or d == o.replace('ad_su_', 'ad_core_')):
                shutil.rmtree(os.path.join('formal', d)); log.append('removed formal/%s' % d)
    for d in ('rtl/common/arb', 'rtl/common'):
        if os.path.isdir(d) and not os.listdir(d):
            os.rmdir(d); log.append('removed empty %s' % d)
    for l in log:
        print(l)


if __name__ == '__main__':
    main(sys.argv[1])
