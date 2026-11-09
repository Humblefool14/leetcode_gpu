#!/usr/bin/env python3
# gen_ad_su_exec_vectors.py: random EXEC-unit instruction streams for
# sim/tb/ad_su_exec_tb.v with the expected EXEC, KILLED, warp control and
# exec.save results.  The semantics are those of tools/gsi1model.py (unit
# EXEC: the Boolean bt of rs1 over all lanes, branches 0-5 over EXEC, 8 set,
# 9 and, 10 or, 11 save, 12 kill = KILLED |= bt & EXEC, 13 end, 14 bar; the
# branch target (pc + imm) & 0xFFFF, else pc + 1).
#
#   gen_ad_su_exec_vectors.py OUT.hex [--seed S] [--n N] [--warps W] [--mode M]
#
# One record of 46 32-bit words per line group (one word per line):
#  0 kind (0 init, 1 instruction)  1 warp  2 op  3 use1  4 pc  5 imm
#  6 init mask  7..38 rs1 of lanes 0..31  39 EXEC after  40 KILLED after
#  41 wc expected  42 wc_op  43 wc_pc  44 writes rd (save)  45 EXEC before
# --mode branch|exec|endbar|mix picks the op mix.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import argparse
import random

M32 = 0xFFFFFFFF


def step(op, bt, ex, kd, pc, imm):
    """One instruction as tools/gsi1model.py (unit EXEC)."""
    npc = (pc + 1) & 0xFFFF
    wc, wop = 0, 0
    if op <= 5:
        tk = [bt & ex != 0, bt & ex == 0, ~bt & ex & M32 == 0, True, ex != 0, ex == 0][op]
        if tk:
            imm_s = imm - (1 << 32) if imm >> 31 else imm
            npc = (pc + imm_s) & 0xFFFF
        wc = 1
    elif op == 8:
        ex = bt
    elif op == 9:
        ex &= bt
    elif op == 10:
        ex |= bt
    elif op == 12:
        kd |= bt & ex
    elif op == 13:
        wc, wop = 1, 1
    elif op == 14:
        wc, wop = 1, 2
    return ex, kd, wc, wop, npc


def lanes_for(rnd, kind):
    """rs1 values: random patterns with zero / nonzero lanes."""
    if kind == 0:
        return [0] * 32
    if kind == 1:
        return [rnd.getrandbits(32) | 1 for _ in range(32)]
    p = rnd.random()
    return [rnd.getrandbits(32) if rnd.random() < p else 0 for _ in range(32)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--n", type=int, default=600)
    ap.add_argument("--warps", type=int, default=4)
    ap.add_argument("--mode", default="mix")
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    ops = {"branch": [0, 1, 2, 3, 4, 5], "exec": [8, 9, 10, 11, 12],
           "endbar": [13, 14, 0, 8], "mix": [0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 12, 13, 14]}[a.mode]
    ex = [0] * a.warps
    kd = [0] * a.warps
    recs = []
    for w in range(a.warps):
        m = rnd.choice([M32, 0, rnd.getrandbits(32), 0x0000FFFF, 0x80000001])
        ex[w], kd[w] = m, 0
        recs.append([0, w, 0, 0, 0, 0, m] + [0] * 32 + [m, 0, 0, 0, 0, 0, m])
    for _ in range(a.n):
        w = rnd.randrange(a.warps)
        if rnd.random() < 0.03:
            m = rnd.getrandbits(32) if rnd.random() < 0.7 else rnd.choice([0, M32])
            ex[w], kd[w] = m, 0
            recs.append([0, w, 0, 0, 0, 0, m] + [0] * 32 + [m, 0, 0, 0, 0, 0, m])
            continue
        op = rnd.choice(ops)
        use1 = 1 if op in (0, 1, 2, 8, 9, 10, 12) else 0
        lv = lanes_for(rnd, rnd.randrange(3))
        bt = 0
        for i in range(32):
            if lv[i]:
                bt |= 1 << i
        if not use1:
            bt = 0
        pc = rnd.getrandbits(16)
        imm = rnd.getrandbits(32) if rnd.random() < 0.3 else (rnd.randrange(-300, 300) & M32)
        before = ex[w]
        nex, nkd, wc, wop, npc = step(op, bt, ex[w], kd[w], pc, imm)
        ex[w], kd[w] = nex, nkd
        recs.append([1, w, op, use1, pc, imm, 0] + lv + [nex, nkd, wc, wop, npc,
                                                         1 if op == 11 else 0, before])
    with open(a.out, "w") as f:
        f.write("%08x\n" % len(recs))
        for r in recs:
            for v in r:
                f.write("%08x\n" % (v & M32))


if __name__ == "__main__":
    main()
