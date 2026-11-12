#!/usr/bin/env python3
"""scan_instances.py: every configuration of a common primitive that ROP, SU and VF instantiate.

Elaborates each design top (with the parameter sets its regression runs) with Yosys, reads the
derived modules' parameter values and writes formal/instances.json:
  {primitive: [{param: value, ...}, ...]}  (unique; primitives' own recursion included)
gen_fpv.py merges these into the FPV tasks, so a new instance size gets its own proof the next
time the generator runs.
"""
import glob
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WS = os.path.dirname(ROOT)
PRIMS = ['ad_fifo', 'ad_delay', 'ad_skid', 'ad_ram_1r1w', 'ad_ram_tdp', 'ad_ram_sp_be', 'ad_popcount',
         'rec_arbiter', 'rr_pick', 'rr_arbiter', 'qos_arbiter', 'ad_amb_mux']
# repo, top, extra file filter, parameter sets (as in each regression)
TOPS = [
    ('ad_rop', 'ad_rop', [{}]),
    ('ad_rop', 'ad_rop_cache', [{}]),                 # standalone block (not in the ROP top)
    ('ad_su', 'ad_su', [{'NPHYS': n} for n in (4, 8, 16, 32)] + [{'NPHYS': 8, 'PACKED': 1, 'SUBGROUP': 1}]),
    ('ad_su', 'ad_su_pipe', [{}]),
    ('ad_vf', 'ad_vf', [{'LINE_BYTES': 32, 'LINE_SHIFT': 5}, {'LINE_BYTES': 64, 'LINE_SHIFT': 6}]),
    ('ad_vf', 'ad_vf_vc', [{}]),
]


def files(repo):
    r = os.path.join(WS, repo)
    fs = sorted(glob.glob(r + '/rtl/**/*.v', recursive=True) + glob.glob(r + '/rtl/**/*.sv', recursive=True))
    fs += sorted(glob.glob(ROOT + '/rtl/common/**/*.v', recursive=True) +
                 glob.glob(ROOT + '/rtl/common/**/*.sv', recursive=True))
    return fs


def scan(repo, top, params):
    r = os.path.join(WS, repo)
    inc = ' '.join('-I' + os.path.relpath(d, WS) for d in glob.glob(r + '/rtl/include'))
    fl = ' '.join(os.path.relpath(f, WS) for f in files(repo))
    ch = ''.join(' -chparam %s %d' % kv for kv in params.items())
    cmd = 'read -sv %s %s; hierarchy -top %s%s; proc; write_json scan_tmp.json' % (inc, fl, top, ch)
    p = subprocess.run(['yowasp-yosys', '-q', '-p', cmd], cwd=WS, capture_output=True, text=True)
    if p.returncode:
        sys.exit('yosys failed for %s %s: %s' % (top, params, p.stderr[-800:]))
    j = json.load(open(os.path.join(WS, 'scan_tmp.json')))
    os.remove(os.path.join(WS, 'scan_tmp.json'))
    out = []
    for name, m in j['modules'].items():
        base = m.get('attributes', {}).get('hdlname') or name.split('\\')[-1]
        if base in PRIMS:
            pv = {k: int(v, 2) for k, v in m.get('parameter_default_values', {}).items() if set(v) <= set('01')}
            out.append((base, pv))
    return out


if __name__ == '__main__':
    found, where = {}, {}
    for repo, top, psets in TOPS:
        for ps in psets:
            for base, pv in scan(repo, top, ps):
                key = json.dumps(pv, sort_keys=True)
                found.setdefault(base, {})[key] = pv
                where.setdefault(base, {}).setdefault(key, set()).add('%s/%s' % (repo, top))
    res = {b: list(v.values()) for b, v in sorted(found.items())}
    json.dump(res, open(os.path.join(ROOT, 'formal', 'instances.json'), 'w'), indent=1, sort_keys=True)
    for b in sorted(found):
        for k, pv in found[b].items():
            print('%-12s %-60s %s' % (b, ','.join('%s=%d' % kv for kv in sorted(pv.items())),
                                      ' '.join(sorted(where[b][k]))))
