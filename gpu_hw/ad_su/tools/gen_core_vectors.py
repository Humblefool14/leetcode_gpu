#!/usr/bin/env python3
# gen_core_vectors.py: vectors of the SU core blocks (ad_su_alu, ad_su_pipe,
# ad_su_opd forwarding) from tools/gsi1model.py (the ISA model).
#
#   python3 -I tools/gen_core_vectors.py [--seed N] [--n N]
#
# sim/vec/core_alu.hex: one ALU case a line, {op[7:0], a, b, c, imm, result}
#   (8 + 5 x 32 bits, '_' separated), result = gsi1model.alu(op & 0x1F, a,
#   imm if op & AD_ALU_IMMB else b, c, imm) & 0xFFFFFFFF.  Every op 0-18 with
#   and without the IMMB bit, edge values and random words.
# sim/vec/core_fpu.hex: tools/gsi1fp.py fpu_vec() (6000 cases, {op, rm, sat, a, b,
#   c, result}) for ad_su_pipe_tb's FPU half.
# sim/vec/core_fmod.hex: {unit[3:0], neg, abs, v, result} cases of the float
#   modifiers (gsi1model.fmod) for ad_su_opd_tb's modifier check.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
import gsi1model as M  # noqa: E402
import gsi1fp as FP  # noqa: E402

M32 = 0xFFFFFFFF
EDGE = [0, 1, 2, 31, 32, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFF, 0xFFFFFFFE,
        0x0000FFFF, 0xFFFF0000, 0x55555555, 0xAAAAAAAA]


def word(r):
    k = r.random()
    if k < 0.25:
        return r.choice(EDGE)
    if k < 0.35:
        return r.randrange(64)
    return r.getrandbits(32)


def alu_vecs(r, n):
    out = []
    for i in range(n):
        op = i % 19
        if r.random() < 0.4 and op != 18:
            op |= 0x80
        a, b, c, imm = word(r), word(r), word(r), word(r)
        if r.random() < 0.3:
            b = a                       # equal operands for the compares
        res = M.alu(op & 0x1F, a, imm if op & 0x80 else b, c, imm) & M32
        out.append("%02x_%08x_%08x_%08x_%08x_%08x" % (op, a, b, c, imm, res))
    return out


def fmod_vecs(r, n):
    out = []
    units = list(range(16))
    for _ in range(n):
        u, ng, ab, v = r.choice(units), r.getrandbits(1), r.getrandbits(1), word(r)
        out.append("%x_%x_%x_%08x_%08x" % (u, ng, ab, v, M.fmod(v, ng, ab, u)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--n", type=int, default=4000)
    ap.add_argument("--out", default="sim/vec")
    a = ap.parse_args()
    r = random.Random(a.seed)
    os.makedirs(a.out, exist_ok=True)
    for name, lines in (("core_alu.hex", alu_vecs(r, a.n)), ("core_fmod.hex", fmod_vecs(r, 512))):
        with open(os.path.join(a.out, name), "w") as f:
            f.write("\n".join(lines) + "\n")
        print("gen_core_vectors: %s %d lines" % (name, len(lines)))
    n = FP.fpu_vec(os.path.join(a.out, "core_fpu.hex"), a.seed + 100)
    print("gen_core_vectors: core_fpu.hex %d lines" % n)


if __name__ == "__main__":
    main()
