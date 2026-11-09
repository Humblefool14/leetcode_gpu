#!/usr/bin/env python3
"""gen_asm_vectors -- draws and expected results for sim/tb/ad_vf_asm_tb.v (tools/asm_model.py).

Writes sim/vec/asm_vec.hex: one flat array of 32-bit words.
  word 0: number of tests T; words 1..T: offset of each test record.
  test record: section, topology, provoking, indexed, vertex_offset,
               n_items, n_warps, n_vb, n_prims, then
               items  (3 words each: index, inst, {last, restart}),
               warps  (2 words each: vl_mask, number of vb),
               vb     (2 words each: index, inst; lane / last follow from the warp list),
               prims  (2 words each: {warp[15:0], lane2, lane1, lane0} as warp<<16 | l2<<10 | l1<<5 | l0,
                       {last, kind[1:0], free[2:0]}, then the reference vertices of slots 0..2
                       from asm_model.reference() as (index, inst) pairs: 8 words each).
Sections: 0 list, 1 strip, 2 restart, 3 free, 4 kind (the TB prints them in that order).
Every draw is also checked against asm_model.reference() (Vulkan's order without warps).
"""
import os
import random
import sys

sys.path.insert(0, 'tools')
from asm_model import assemble, check, reference  # noqa: E402

M32 = (1 << 32) - 1
rnd = random.Random(20261109)


def items_plain(n, inst=0, rand_idx=True):
    return [((rnd.getrandbits(32) if rand_idx else 1000 + k), inst, False, k == n - 1) for k in range(n)]


def items_rand(n, p_rst=0.08, p_inst=0.03, inst0=0):
    its, inst = [], inst0
    for k in range(n):
        if rnd.random() < p_inst:
            inst = (inst + 1) & M32
        rs = rnd.random() < p_rst
        its.append(((0xFFFFFFFF if rs else rnd.getrandbits(32)), inst, rs, k == n - 1))
    return its


def with_restarts(n, positions, inst=0):
    """n items where the item numbers in positions are restart markers."""
    return [((0xFFFF if k in positions else rnd.getrandbits(16)), inst, k in positions, k == n - 1)
            for k in range(n)]


tests = []


def add(sec, topo, prov, its, indexed=None, voff=None):
    if indexed is None:
        indexed = rnd.random() < 0.6
    if voff is None:
        voff = rnd.choice([0, 1, 0x7FFFFFFF, 0xFFFFFFF0, rnd.getrandbits(32)])
    check(topo, prov, its, voff, indexed)
    tests.append((sec, topo, prov, its, indexed, voff))


# 0 list: point, line, triangle lists over several warps (both provoking modes)
for topo in (0, 1, 3, 6):
    for prov in (0, 1):
        for n in (1, 2, 3, 4, 31, 32, 33, 47, 64, 65, 97, 100):
            add(0, topo, prov, items_plain(n, inst=rnd.choice([0, 5])))
# 1 strip: strips, fans and line strips across warp boundaries
for topo in (2, 4, 5):
    for prov in (0, 1):
        for n in (1, 2, 3, 4, 30, 31, 32, 33, 34, 35, 62, 63, 64, 90, 121):
            add(1, topo, prov, items_plain(n))
# 2 restart: restart markers in strips, fans and lists; instances; draws with no primitive
for topo in range(8):
    for prov in (0, 1):
        for pos in ([0], [1], [2], [3], [29], [30], [31], [32], [33], [30, 31], [31, 32], [32, 33],
                    [5, 6, 7], [61, 62], [63]):
            n = max(pos) + rnd.randint(1, 40)
            add(2, topo, prov, with_restarts(n, set(pos)))
        add(2, topo, prov, with_restarts(40, {39}))                 # ends with a restart
        add(2, topo, prov, with_restarts(33, {32}))                 # draw ends between warps
        add(2, topo, prov, with_restarts(65, {32, 64}))
        add(2, topo, prov, with_restarts(4, {0, 1, 2, 3}))          # only restarts: nothing
        add(2, topo, prov, with_restarts(5, {0, 2, 4}))             # isolated vertices
        # instances: the walk repeated, iv_inst changes (ends strips / fans / list primitives)
        for cnt in (1, 2, 3, 4, 5, 31, 32, 33):
            its = []
            for i in range(3):
                its += [(1000 + k, 7 + i, False, False) for k in range(cnt)]
            its[-1] = its[-1][:3] + (True,)
            add(2, topo, prov, its)
        for _ in range(6):
            add(2, topo, prov, items_rand(rnd.randint(20, 140), 0.1, 0.05))
# 3 free: mixed topologies, random restarts and instances (PT model with two 32-entry blocks)
for _ in range(120):
    add(3, rnd.randrange(8), rnd.randrange(2), items_rand(rnd.randint(1, 160), rnd.choice([0, 0.03, 0.1, 0.3]),
                                                          rnd.choice([0, 0.02, 0.1])))
# 4 kind: every topology, both provoking modes
for topo in range(8):
    for prov in (0, 1):
        add(4, topo, prov, items_rand(rnd.randint(40, 90), 0.05, 0.02))

words = [len(tests)] + [0] * len(tests)
for t, (sec, topo, prov, its, indexed, voff) in enumerate(tests):
    r = assemble(topo, prov, its, voff, indexed)
    words[1 + t] = len(words)
    nvb = sum(len(w['verts']) for w in r['warps'])
    words += [sec, topo, prov, int(indexed), voff, len(its), len(r['warps']), nvb, len(r['prims'])]
    for idx, inst, rs, last in its:
        words += [idx & M32, inst & M32, (int(last) << 1) | int(rs)]
    for w in r['warps']:
        words += [w['mask'], len(w['verts'])]
    for w in r['warps']:
        for v in w['verts']:
            words += [v['index'], v['inst']]
    ref = reference(topo, prov, its, voff, indexed)
    assert len(ref) == len(r['prims'])
    for p, (rv, rk) in zip(r['prims'], ref):
        l0, l1, l2 = p['lanes']
        words += [(p['warp'] << 16) | (l2 << 10) | (l1 << 5) | l0,
                  (int(p['last']) << 5) | (rk << 3) | p['free']]
        for vi, vn in rv:
            words += [vi, vn]

os.makedirs('sim/vec', exist_ok=True)
with open('sim/vec/asm_vec.hex', 'w') as f:
    for w in words:
        f.write('%08x\n' % (w & M32))
print('gen_asm_vectors: %d tests, %d words' % (len(tests), len(words)))
