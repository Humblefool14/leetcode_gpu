#!/usr/bin/env python3
# gen_div_vectors.py: vectors for sim/tb/ad_su_div_tb.v (ad_su_div), from
# tools/gsi1fp.py div() (RISC-V div/divu/rem/remu).
#   python3 -I tools/gen_div_vectors.py [--seed N] [--out sim/vec/div_ops.hex]
# One line per lane: op(1 hex) a(8) b(8) result(8); the op is the same for
# each block of 32 lines (one instruction of a warp).  Corners: /0,
# INT_MIN/-1, +-1, 0, INT_MAX, small and power-of-two operands.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
import gsi1fp as FP  # noqa: E402

M32 = 0xFFFFFFFF
CORNERS = [0, 1, 2, 3, 7, M32, M32 - 1, 0x80000000, 0x80000001, 0x7FFFFFFF, 0x7FFFFFFE,
           0x10000, 0xFFFF0000, 0x55555555, 0xAAAAAAAA]


def operand(r):
    k = r.random()
    if k < 0.25:
        return r.choice(CORNERS)
    if k < 0.4:
        return r.randrange(0, 64) if r.random() < 0.5 else (-r.randrange(1, 64)) & M32
    if k < 0.5:
        return (1 << r.randrange(32)) ^ (M32 if r.random() < 0.3 else 0)
    if k < 0.65:
        return r.getrandbits(r.randrange(1, 33))
    return r.getrandbits(32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", default="sim/vec/div_ops.hex")
    ap.add_argument("--insts", type=int, default=160)
    a = ap.parse_args()
    r = random.Random(a.seed)
    vec = []
    for i in range(a.insts):
        op = i % 4 if i < 8 else r.randrange(4)
        for ln in range(32):
            x, y = operand(r), operand(r)
            k = r.random()
            if k < 0.08:
                y = 0
            elif k < 0.14:
                x, y = 0x80000000, M32
            vec.append((op, x, y, FP.div(op, x, y)))
    # every op on every corner pair (at the end, ops kept per block of 32)
    pairs = [(x, y) for x in CORNERS for y in CORNERS]
    for op in range(4):
        blk = [(op, x, y, FP.div(op, x, y)) for x, y in pairs]
        while len(blk) % 32:
            blk.append(blk[len(blk) % len(pairs)])
        vec += blk
    with open(a.out, "w") as f:
        for op, x, y, z in vec:
            f.write("%x_%08x_%08x_%08x\n" % (op, x, y, z))
    print("gen_div_vectors: %d vectors in %s" % (len(vec), a.out))


if __name__ == "__main__":
    main()
