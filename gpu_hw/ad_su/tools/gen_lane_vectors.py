#!/usr/bin/env python3
# gen_lane_vectors.py: vectors for sim/tb/ad_su_lane_tb.v (ad_su_lane), the
# expected results from tools/gsi1model.py Machine.lane() (qd, shfl, vote,
# ballot; the fp32 subtract of qdx/qdy from tools/gsi1fp.py).
#   python3 -I tools/gen_lane_vectors.py [--seed N]
# Writes sim/vec/lane_qd.hex (qd only, every lane defined) and
# sim/vec/lane_sub.hex (shfl/vote/ballot with qswap/qbcast between them,
# rs1/rs2 X on the lanes outside EXEC).  33 lines per instruction:
#   header  op(2) sub(2) rd(2) wrd(1) exec(8)
#   lane i  rs1(8) rs2(8) result(8) written(1)     ('x' digits: undefined)
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
import gsi1fp as FP  # noqa: E402
import gsi1model as GM  # noqa: E402

M32 = 0xFFFFFFFF
RS1, RS2, RD = 10, 11, 12


def exec_mask(r):
    k = r.randrange(6)
    if k == 0:
        return 0
    if k == 1:
        return 1 << r.randrange(32)
    if k == 2:
        return M32 ^ (1 << r.randrange(32))
    if k == 3:
        return M32
    return r.getrandbits(32)


def fval(r, prev):
    """fp32 operands for qdx/qdy: neighbours close to each other often."""
    k = r.random()
    if prev is not None and k < 0.35:
        return (prev + r.randrange(-4, 5)) & M32
    if prev is not None and k < 0.45:
        return prev ^ (1 << r.randrange(23))
    return FP.rnd32(r)


def run(op, sub, ex, rs1, rs2, wrd=1):
    f = {"OP": op, "SUB": sub, "RD": RD, "RS1": RS1, "RS2": RS2, "WRD": wrd}
    r = {RS1: list(rs1), RS2: list(rs2), RD: [None] * 32}

    def src(n, use, i, ln):
        v = r[n][ln]
        if v is None:
            raise SystemExit("gen_lane_vectors: read of an undefined lane %d" % ln)
        return v
    GM.Machine.lane(None, f, ex, r, src)
    return r[RD]


def emit(out, op, sub, rd, wrd, ex, rs1, rs2, res):
    out.append("%02x%02x%02x%x%08x" % (op, sub, rd, wrd, ex))
    for ln in range(32):
        a = "xxxxxxxx" if rs1[ln] is None else "%08x" % rs1[ln]
        b = "xxxxxxxx" if rs2[ln] is None else "%08x" % rs2[ln]
        if res[ln] is None:
            out.append("%s%s000000000" % (a, b))
        else:
            out.append("%s%s%08x1" % (a, b, res[ln]))


def qd_inst(r, out, ex=None):
    sub = r.randrange(6)
    ex = exec_mask(r) if ex is None else ex
    rs1, p = [], None
    for ln in range(32):
        p = fval(r, p)
        rs1.append(p)
    rs2 = [r.getrandbits(32) for _ in range(32)]
    wrd = 1 if r.random() < 0.9 else 0
    res = run(0, sub, ex, rs1, rs2, wrd)
    emit(out, 0, sub, r.randrange(64), wrd, ex, rs1, rs2, res)


def shfl_rs2(r, ln, sub):
    k = r.random()
    if k < 0.6:
        if sub == 0:
            return r.randrange(32)
        if sub == 1:
            return r.randrange(32)
        return r.randrange(0, 32)
    if k < 0.75:
        return r.choice([32, 33, 63, 64, 0x80000000, 0xFFFFFFFF, 0xFFFFFFE0, 0x100000001 & M32,
                         0x20, 0x1F, 0x21])
    if k < 0.85:
        return (ln + r.randrange(-3, 4)) & M32
    return r.getrandbits(r.choice([6, 8, 16, 32]))


def sub_inst(r, out):
    k = r.random()
    ex = exec_mask(r)
    wrd = 1 if r.random() < 0.92 else 0
    if k < 0.3:
        qd_inst(r, out, ex)
        return
    if k < 0.65:
        op, sub = 1, r.randrange(5)
    elif k < 0.85:
        op, sub = 2, r.randrange(2)
    else:
        op, sub = 3, 0
    rs1, rs2 = [], []
    for ln in range(32):
        if ex >> ln & 1:
            v = 0 if r.random() < (0.5 if op != 1 else 0.1) else r.getrandbits(32)
            if op != 1 and r.random() < 0.05:
                v = 1 << r.randrange(32)
            rs1.append(v)
            rs2.append(shfl_rs2(r, ln, sub) if op == 1 else r.getrandbits(32))
        else:
            rs1.append(None)
            rs2.append(None)
    # vote.all with every EXEC lane nonzero now and then
    if op == 2 and r.random() < 0.3:
        rs1 = [None if v is None else (v or 1) for v in rs1]
    res = run(op, sub, ex, rs1, rs2, wrd)
    emit(out, op, sub, r.randrange(64), wrd, ex, rs1, rs2, res)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--qd", type=int, default=1200)
    ap.add_argument("--sub", type=int, default=1500)
    a = ap.parse_args()
    r = random.Random(a.seed)
    out = []
    for i in range(a.qd):
        qd_inst(r, out)
    with open("sim/vec/lane_qd.hex", "w") as f:
        f.write("\n".join(out) + "\n")
    print("gen_lane_vectors: %d qd instructions in sim/vec/lane_qd.hex" % a.qd)
    out = []
    for i in range(a.sub):
        sub_inst(r, out)
    with open("sim/vec/lane_sub.hex", "w") as f:
        f.write("\n".join(out) + "\n")
    print("gen_lane_vectors: %d instructions in sim/vec/lane_sub.hex" % a.sub)


if __name__ == "__main__":
    main()
