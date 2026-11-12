#!/usr/bin/env python3
"""gen_fpv.py: one parameterized FPV harness per common primitive, many configurations.

For each primitive in PRIMS this writes formal/<prim>/<prim>.sby with one `prove` (and one `bmc`)
task per configuration.  The configurations are the union of
  * the corner sizes listed in PRIMS (smallest legal sizes, non-powers of two, wide data), and
  * every configuration the designs instantiate (formal/instances.json, written by
    scripts/scan_instances.py from the elaborated ROP / SU / VF tops).
Data independence: the storage primitives (fifo, delay, skid, RAMs) treat every data bit (every
byte, for ad_ram_sp_be) alike and never combine bits, so a proof at a narrow data width covers every
width.  Their `prove` tasks therefore cap the data-width parameter (DCAP) and keep every other
parameter (depth, stages, address width) at the instance's value; the `bmc` task of the same
configuration runs at the real width.  A capped task is named ..._di.
Full-width BMC is skipped when the primitive holds more than BMC_MAX_BITS bits of state (the
128 x 512-bit ROP cache RAM): the width-capped proof covers that configuration, and the parent
block's own formal (formal/ad_rop_cache) runs with the real RAM.
Run:  python3 scripts/gen_fpv.py            (rewrites every .sby)
      python3 scripts/gen_fpv.py --list     (prints primitive: configurations)
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# prim: (rtl files, harness params in task-name order, corner configs, bmc depth(cfg), prove engine,
#        extra script lines)
ARB = ['rtl/common/arb/rec_arbiter.sv', 'rtl/common/arb/rr_pick.sv', 'rtl/common/arb/rr_arbiter.sv',
       'rtl/common/arb/qos_arbiter.sv']
PRIMS = {
    'ad_fifo': dict(rtl=['rtl/common/fifo/ad_fifo.v'], params=['W', 'DEPTH'], dcap={'W': 4},
                    defines=['AD_FV_FIFO'], prove_engine='smtbmc z3', prove_depth=3,
                    corners=[(1, 2), (8, 4), (8, 8), (33, 16)], bmc=lambda c: min(2 * c[1] + 6, 24 if c[0] <= 64 else 12)),
    'ad_delay': dict(rtl=['rtl/common/pipe/ad_delay.v'], params=['N', 'W'], dcap={'W': 4},
                     corners=[(1, 1), (2, 8), (6, 8), (9, 33)], bmc=lambda c: c[0] + 6),
    'ad_skid': dict(rtl=['rtl/common/pipe/ad_skid.v'], params=['W'], dcap={'W': 4},
                    corners=[(1,), (8,), (64,)], bmc=lambda c: 12),
    'ad_ram_1r1w': dict(rtl=['rtl/common/mem/ad_ram_1r1w.v'], params=['DW', 'AW', 'DEPTH'], dcap={'DW': 4},
                        corners=[(1, 1, 2), (8, 3, 8), (8, 3, 6), (32, 5, 32)], bmc=lambda c: 8),
    'ad_ram_tdp': dict(rtl=['rtl/common/mem/ad_ram_tdp.v'], params=['DEPTH', 'AW', 'DW'], dcap={'DW': 4},
                       corners=[(2, 1, 1), (10, 4, 8), (16, 4, 32)], bmc=lambda c: 8),
    'ad_ram_sp_be': dict(rtl=['rtl/common/mem/ad_ram_sp_be.v'], params=['DEPTH', 'AW', 'NBYTES'],
                         dcap={'NBYTES': 2},
                         corners=[(2, 1, 1), (8, 3, 4), (6, 3, 3)], bmc=lambda c: 8),
    'ad_popcount': dict(rtl=['rtl/common/math/ad_popcount.v'], params=['W'],
                        corners=[(1,), (2,), (7,), (16,), (32,)], bmc=None),
    'rec_arbiter': dict(rtl=ARB, params=['N'], corners=[(n,) for n in (1, 2, 3, 4, 5, 7, 8, 13, 16, 32, 64)],
                        bmc=None),
    'rr_pick': dict(rtl=ARB, params=['N'], corners=[(n,) for n in (1, 2, 3, 5, 6, 8, 13, 16)], bmc=None),
    'rr_arbiter': dict(rtl=ARB, params=['N'], corners=[(3,), (5,), (8,)], bmc=lambda c: 24),
    'qos_arbiter': dict(rtl=ARB, params=['N', 'HI_BURST'], corners=[(3, 1), (4, 2), (5, 3)],
                        bmc=lambda c: 24),
}
# ad_amb_mux keeps its hand-written harness and tasks (formal/ad_amb_mux/ad_amb_mux.sby): the payload
# is only multiplexed, so it is proven at a reduced width, N = 2 (every instance) and TBL_LOG2 2 and 4.


BMC_MAX_BITS = 32768
STATE_BITS = {'ad_fifo': lambda c: c[0] * c[1], 'ad_delay': lambda c: c[0] * c[1],
              'ad_ram_1r1w': lambda c: c[0] * c[2], 'ad_ram_tdp': lambda c: c[0] * c[2],
              'ad_ram_sp_be': lambda c: c[0] * c[2] * 8}


def configs(prim):
    spec = PRIMS[prim]
    cfgs = [tuple(c) for c in spec['corners']]
    inst = os.path.join(ROOT, 'formal', 'instances.json')
    if os.path.exists(inst):
        for c in json.load(open(inst)).get(prim, []):
            t = tuple(c[p] for p in spec['params'])
            if t not in cfgs:
                cfgs.append(t)
    return cfgs


def tname(spec, c):
    return '_'.join('%s%d' % (p.lower(), v) for p, v in zip(spec['params'], c))


def write(prim):
    spec = PRIMS[prim]
    cf = configs(prim)
    tasks, seen = [], set()
    cap = spec.get('dcap', {})
    for c in cf:
        pc = tuple(min(v, cap[p]) if p in cap else v for p, v in zip(spec['params'], c))
        if pc not in seen:
            seen.add(pc)
            tasks.append(('prove_' + tname(spec, pc) + ('_di' if pc != c else ''), 'prove', pc))
        if spec['bmc'] and STATE_BITS.get(prim, lambda c: 0)(c) <= BMC_MAX_BITS:
            tasks.append(('bmc_' + tname(spec, c), 'bmc', c))
    L = ['# generated by scripts/gen_fpv.py: one harness (fv_%s.sv), one task per configuration' % prim,
         '[tasks]'] + [t[0] for t in tasks] + ['', '[options]']
    for n, m, c in tasks:
        L.append('%s: mode %s' % (n, m))
        if m == 'bmc':
            L.append('%s: depth %d' % (n, spec['bmc'](c)))
        elif spec.get('prove_depth'):
            L.append('%s: depth %d' % (n, spec['prove_depth']))
    L += ['', '[engines]']
    for n, m, c in tasks:
        L.append('%s: %s' % (n, spec.get('prove_engine', 'abc pdr') if m == 'prove'
                              else spec.get('bmc_engine', 'abc bmc3')))
    files = [os.path.basename(f) for f in spec['rtl']] + ['fv_%s.sv' % prim]
    defs = ''.join(' -D' + d for d in spec.get('defines', []))
    L += ['', '[script]', 'read -formal%s %s' % (defs, ' '.join(files))]
    for n, m, c in tasks:
        for p, v in zip(spec['params'], c):
            L.append('%s: chparam -set %s %d fv_%s' % (n, p, v, prim))
    L += ['prep -top fv_%s' % prim, 'techmap t:$shiftx', 'setundef -zero', '', '[files]']
    L += ['../../' + f for f in spec['rtl']] + ['fv_%s.sv' % prim]
    os.makedirs(os.path.join(ROOT, 'formal', prim), exist_ok=True)
    open(os.path.join(ROOT, 'formal', prim, prim + '.sby'), 'w').write('\n'.join(L) + '\n')
    return cf


if __name__ == '__main__':
    for prim in PRIMS:
        cf = write(prim) if '--list' not in sys.argv else configs(prim)
        print('%-13s %s' % (prim, ', '.join('(' + ','.join(map(str, c)) + ')' for c in cf)))
