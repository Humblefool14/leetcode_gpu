#!/usr/bin/env python3
# gen_fpu_vectors.py: vectors for sim/tb/ad_su_fpu_tb.v and
# sim/tb/ad_su_fp_leaf_tb.v, every expected value from tools/gsi1fp.py.
#
#   python3 -I tools/gen_fpu_vectors.py [--seed N] [--groups N] [--leaf N] [--out sim/vec]
#
# sim/vec/fpu_grp.hex     one lane per line, 8 consecutive lines are one lane
#                         group (same op, rm, sat): "%02x%x%x%08x%08x%08x%08x"
#                         op rm sat a b c y (as gsi1fp.py --fpu-vec)
# sim/vec/fpu_ffma.hex    rm noc a b c y         ("%x%x%08x%08x%08x%08x")
# sim/vec/fpu_rint.hex    rm x neg big mag       ("%x%08x%x%x%08x"; mag 0 when big)
# sim/vec/fpu_i2f.hex     uns rm a y             ("%x%x%08x%08x")
# sim/vec/fpu_f2i.hex     uns rm x y             ("%x%x%08x%08x"; through ad_su_rint)
# sim/vec/fpu_fadd.hex    a b y                  ("%08x%08x%08x"; y = fpu(FADD, a, b, 0, RNE))
#
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
import gsi1fp as G  # noqa: E402

M32 = G.M32
S = 0x80000000
NL = 8          # lanes per group in the file (NPHYS 8; NPHYS 4 uses the low 4)

# Directed corners per op: (a, b, c) tuples.
MAXF, MINN, ONE, INF, QN = 0x7F7FFFFF, 0x00800000, 0x3F800000, 0x7F800000, 0x7FC00000
SNAN, DEN = 0x7F800001, 0x00000001
ADD_C = [(MAXF, MAXF, 0), (MAXF | S, MAXF | S, 0), (ONE, ONE | S, 0), (S, S, 0), (0, S, 0),
         (S, 0, 0), (INF, INF | S, 0), (INF, INF, 0), (QN, ONE, 0), (ONE, SNAN, 0),
         (ONE, 0xBF800001, 0), (0x00800001, 0x80800000, 0), (0x00C00000, 0x80800000, 0),
         (DEN, 0x00800000, 0), (0x00800000, 0x807FFFFF, 0), (0x00800000, DEN | S, 0),
         (0x4B800000, 0x3F800000, 0), (0x4B800000, 0x3F800001, 0), (0x4B800000, 0xBF800001, 0),
         (0x4B7FFFFF, 0x3F000000, 0), (0x7F7FFFFF, 0x73000000, 0), (0x7F7FFFFF, 0x72FFFFFF, 0),
         (0x7F7FFFFF, 0x737FFFFF, 0), (0x00FFFFFF, 0x80FFFFFE, 0), (0x01000000, 0x80FFFFFF, 0),
         (0x3F800000, 0xB3800000, 0), (0x3F800000, 0xB3000000, 0), (0x3F800000, 0x33800000, 0),
         (0x3F800000, 0x33000001, 0), (0x00800000, 0x00800000, 0), (0x80800000, 0x80000001, 0),
         (0x3F800001, 0xBF800000, 0)]
MUL_C = [(MAXF, 0x40000000, 0), (MAXF | S, 0x40000000, 0), (MAXF, MAXF | S, 0),
         (0x20000000, 0x1F800000, 0), (0xA0000000, 0x1F800000, 0), (0x1FFFFFFF, 0x20000001, 0),
         (0x1FFFFFFF, 0x9F800001, 0), (0x1F800000, 0x1FFFFFFF, 0), (0x20000000, 0x20000000, 0),
         (0, INF, 0), (S, INF, 0), (INF | S, S, 0), (S, ONE, 0), (S, S, 0), (0, ONE | S, 0),
         (DEN, ONE, 0), (QN, 0, 0), (0x3FFFFFFF, 0x3FFFFFFF, 0), (0x3F800001, 0x3F7FFFFF, 0),
         (0x5F800000, 0x5F800000, 0), (0x5F7FFFFF, 0x5F7FFFFF, 0), (0x00800000, 0x3F000000, 0),
         (0x00800000, 0x3F7FFFFF, 0), (0x00FFFFFF, 0x3F000000, 0), (0x00FFFFFF, 0x3F000001, 0)]
FMA_C = [(0x3FC00000, 0x40000000, 0xC0400000), (0x3FC00000, 0xC0000000, 0x40400000),
         (0, ONE, S), (S, ONE, S), (S, ONE, 0), (0, ONE, 0), (ONE, S, S), (0, 0, 0),
         (INF, ONE, INF | S), (INF, ONE, INF), (ONE, ONE, INF | S), (0, INF, ONE),
         (ONE, ONE, QN), (QN, 0, INF), (0x3F800001, 0x3F800001, 0xBF800002),
         (0x3F800001, 0x3F800001, 0xBF800003), (0x3F800001, 0x3F7FFFFF, 0xBF800000),
         (0x20000000, 0x1F800000, S), (0x20000000, 0x1F800000, 0x00800000),
         (0x20000000, 0x9F800000, 0x00800000), (0x1FFFFFFF, 0x20000001, 0x80000000),
         (MAXF, 0x40000000, MAXF | S), (MAXF, 0x40000000, MAXF), (MAXF, ONE, MAXF),
         (0x4B800000, 0x4B800000, 0xD7800000), (0x4B800000, 0x4B800001, 0xD7800000),
         (0x3F800000, 0x00800000, 0x80800000), (0x3F800000, 0x00800001, 0x80800000),
         (0x5F800000, 0x5F800000, 0xFF7FFFFF), (0x34000000, 0x34000000, 0x3F800000),
         (0x34000000, 0x34000000, 0xBF800000), (0x33800000, 0x33800000, 0xBF800000),
         (ONE, DEN, ONE), (DEN, DEN, S), (ONE, ONE, DEN | S), (0x3F800000, 0x7F000000, 0xFF000000)]
CVTF_C = [(x, 0, 0) for x in
          [0x3F000000, 0x3FC00000, 0x40200000, 0xBF000000, 0xBFC00000, 0x4AFFFFFF, 0x4B000000,
           0x4F000000, 0xCF000000, 0x4F800000, 0xCF000001, 0x4F7FFFFF, 0x4EFFFFFF, QN, SNAN,
           INF, INF | S, S, 0, DEN, 0x807FFFFF, 0x3EFFFFFF, 0x3F000001, 0xBEFFFFFF, 0xBF000001,
           0x3F7FFFFF, 0xBF7FFFFF, 0x3FFFFFFF, 0xC0400000, 0x40400000, 0x4B7FFFFF, 0xCB7FFFFF,
           0x00800000, 0x80800000, 0x3F800000, 0xBF800000, 0x5F000000, 0xDF000000, 0x40100000,
           0xC0100000, 0x40300000, 0xC0300000]]
CVTI_C = [(x, 0, 0) for x in
          [0, 1, M32, 0x7FFFFFFF, S, 0x80000001, 0x01000001, 0x00FFFFFF, 0x01000003, 0xFEFFFFFF,
           0xFF000001, 0x7FFFFFC0, 0x7FFFFFBF, 0x7FFFFF80, 0xFFFFFF80, 0x00000003, 0x12345678,
           0xFFFFFFFE, 0x80000080, 0x80000040, 0x0100000F]]
CMP_C = [(0, S, 0), (S, 0, 0), (QN, QN, 0), (QN, ONE, 0), (ONE, QN, 0), (SNAN, SNAN, 0),
         (DEN, 0, 0), (DEN, S, 0), (DEN, 0x00000002, 0), (INF, INF, 0), (INF | S, INF, 0),
         (ONE, ONE, 0), (ONE, 0x3F800001, 0), (0xBF800000, ONE, 0), (MAXF, INF, 0),
         (0x80800000, 0x807FFFFF, 0), (0x807FFFFF, S, 0), (0x00800000, 0x807FFFFF, 0),
         (0xFFC00000, 0x7FC00000, 0), (0xBF800000, 0xBF800001, 0)]
MUL_I = [(S, S, 0), (M32, M32, 0), (S, M32, 0), (M32, S, 0), (0x7FFFFFFF, 0x7FFFFFFF, 0),
         (S, 0x7FFFFFFF, 0), (0, M32, 0), (1, M32, 0), (M32, 1, 0), (0x12345678, 0x9ABCDEF0, 0)]

CORNERS = {
    G.FADD: ADD_C, G.FSUB: [(a, b ^ S, c) for a, b, c in ADD_C], G.FMUL: MUL_C,
    G.FMADD: FMA_C, G.FMSUB: [(a, b, c ^ S) for a, b, c in FMA_C],
    G.FNMSUB: [(a ^ S, b, c) for a, b, c in FMA_C], G.FNMADD: [(a ^ S, b, c ^ S) for a, b, c in FMA_C],
    G.FSGNJ: CMP_C, G.FMIN: CMP_C, G.FMAX: CMP_C,
    G.FCVTWS: CVTF_C, G.FCVTWUS: CVTF_C, G.FCVTSW: CVTI_C, G.FCVTSWU: CVTI_C,
    G.FEQ: CMP_C, G.FLT: CMP_C, G.FLE: CMP_C, G.FNE: CMP_C,
    G.FROUND: CVTF_C, G.FRACT: CVTF_C,
    G.MUL: MUL_I, G.MULH: MUL_I, G.MULHSU: MUL_I, G.MULHU: MUL_I,
}


def lane_inputs(r, op):
    """One lane's random (a, b, c), gsi1fp.fpu_vec style."""
    a, b, c = G.rnd32(r), G.rnd32(r), G.rnd32(r)
    if op in (G.FADD, G.FSUB, G.FMADD, G.FMSUB, G.FNMSUB, G.FNMADD) and r.random() < 0.3:
        b = (a ^ S) + r.randrange(-3, 4) & M32 if op != G.FSUB else (a + r.randrange(-3, 4)) & M32
        if op >= G.FMADD:
            c = (G.fpu(G.FMUL, a, b, 0, G.RNE) ^ S) & M32
            if r.random() < 0.5:
                c = (c + r.randrange(-2, 3)) & M32
    if op in (G.FCVTSW, G.FCVTSWU, G.MUL, G.MULH, G.MULHSU, G.MULHU) and r.random() < 0.5:
        a, b = r.getrandbits(32), r.getrandbits(32)
    if op in (G.FCVTWS, G.FCVTWUS, G.FROUND, G.FRACT) and r.random() < 0.5:
        e = r.randrange(120, 162)
        a = r.getrandbits(1) << 31 | e << 23 | r.getrandbits(23)
        if r.random() < 0.3:      # exact halves
            a &= ~((1 << max(0, 149 - e)) - 1) & M32
    return a, b, c


def gen_groups(path, seed, ngroups):
    r = random.Random(seed)
    lines = []

    def group(op, rm, st, lanes):
        for a, b, c in lanes:
            y = G.fpu(op, a, b, c, rm, st)
            lines.append("%02x%x%x%08x%08x%08x%08x" % (op, rm, st, a, b, c, y))

    # Directed corners: every op, every rm 0-7, sat 0 and 1.
    for op in range(24):
        cl = CORNERS[op]
        for i in range(0, len(cl), NL):
            ch = cl[i:i + NL]
            ch = ch + [cl[(i + j) % len(cl)] for j in range(NL - len(ch))]
            for rm in range(8):
                for st in (0, 1):
                    group(op, rm, st, ch)
    ncorner = len(lines) // NL
    for _ in range(ngroups):
        op = r.randrange(24)
        rm = r.randrange(8)
        st = 1 if r.random() < 0.15 else 0
        group(op, rm, st, [lane_inputs(r, op) for _ in range(NL)])
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return len(lines), ncorner


def gen_leaf(out, seed, n):
    r = random.Random(seed + 1000)
    # ffma
    with open(os.path.join(out, "fpu_ffma.hex"), "w") as f:
        for i in range(n):
            a, b, c = G.rnd32(r), G.rnd32(r), G.rnd32(r)
            k = r.random()
            if k < 0.25:
                c = (G.fpu(G.FMUL, a, b, 0, G.RNE) ^ S) + r.randrange(-3, 4) & M32
            elif k < 0.35:
                b = G.ONE
                c = (a ^ S) + r.randrange(-3, 4) & M32
            elif k < 0.45:      # product near the bottom of the normal range
                ea = r.randrange(1, 127)
                eb = r.randrange(max(1, 125 - ea), min(255, 130 - ea + 1))
                a = r.getrandbits(1) << 31 | ea << 23 | r.getrandbits(23)
                b = r.getrandbits(1) << 31 | eb << 23 | r.getrandbits(23)
                if r.random() < 0.5:
                    c = r.getrandbits(1) << 31 | r.randrange(0, 3) << 23 | r.getrandbits(23)
            elif k < 0.5:       # product near overflow
                ea = r.randrange(128, 255)
                eb = r.randrange(max(1, 380 - ea), min(255, 384 - ea))
                a = r.getrandbits(1) << 31 | ea << 23 | r.getrandbits(23)
                b = r.getrandbits(1) << 31 | eb << 23 | r.getrandbits(23)
            rm = r.randrange(8)
            noc = 1 if r.random() < 0.2 else 0
            y = G.fma(G.F32, a, b, c, rm, noc=bool(noc))
            f.write("%x%x%08x%08x%08x%08x\n" % (rm, noc, a, b, c, y))
    # rint
    with open(os.path.join(out, "fpu_rint.hex"), "w") as f:
        for i in range(n):
            x = G.rnd32(r)
            if r.random() < 0.6:
                e = r.randrange(110, 165)
                x = r.getrandbits(1) << 31 | e << 23 | r.getrandbits(23)
                if r.random() < 0.3:
                    x &= ~((1 << max(0, min(23, 149 - e))) - 1) & M32
            rm = r.randrange(8)
            s, e, m = G.F32.fields(x)
            big = 1 if e >= 159 else 0
            mag = 0 if big or e == 0 else abs(G.rint(G.F32.value(x), rm))
            f.write("%x%08x%x%x%08x\n" % (rm, x, s, big, mag))
    # i2f
    with open(os.path.join(out, "fpu_i2f.hex"), "w") as f:
        for i in range(n):
            k = r.random()
            if k < 0.3:
                a = r.getrandbits(32)
            elif k < 0.6:
                a = r.getrandbits(r.randrange(1, 33))
            elif k < 0.8:
                a = (-r.getrandbits(r.randrange(1, 32))) & M32
            else:
                a = (r.getrandbits(r.randrange(20, 33)) | r.choice([0, 0x80, 0x7F, 0x40, 0xFF])) & M32
            uns = r.randrange(2)
            rm = r.randrange(8)
            f.write("%x%x%08x%08x\n" % (uns, rm, a, G.fcvt_sw(a, rm, uns)))
    # f2i (through ad_su_rint)
    with open(os.path.join(out, "fpu_f2i.hex"), "w") as f:
        for i in range(n):
            x = G.rnd32(r)
            if r.random() < 0.6:
                e = r.randrange(120, 162)
                x = r.getrandbits(1) << 31 | e << 23 | r.getrandbits(23)
            uns = r.randrange(2)
            rm = r.randrange(8)
            f.write("%x%x%08x%08x\n" % (uns, rm, x, G.fcvt_ws(x, rm, uns)))
    # fadd
    with open(os.path.join(out, "fpu_fadd.hex"), "w") as f:
        for i in range(n):
            a, b = G.rnd32(r), G.rnd32(r)
            k = r.random()
            if k < 0.3:
                b = (a ^ S) + r.randrange(-3, 4) & M32
            elif k < 0.4:
                e = r.randrange(1, 4)
                a = r.getrandbits(1) << 31 | e << 23 | r.getrandbits(23)
                b = r.getrandbits(1) << 31 | r.randrange(0, 4) << 23 | r.getrandbits(23)
            elif k < 0.5:
                a = r.getrandbits(1) << 31 | r.randrange(250, 255) << 23 | r.getrandbits(23)
                b = r.getrandbits(1) << 31 | r.randrange(220, 255) << 23 | r.getrandbits(23)
            f.write("%08x%08x%08x\n" % (a, b, G.fpu(G.FADD, a, b, 0, G.RNE)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--groups", type=int, default=7000)
    ap.add_argument("--leaf", type=int, default=200000)
    ap.add_argument("--out", default="sim/vec")
    ap.add_argument("--no-leaf", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    n, nc = gen_groups(os.path.join(a.out, "fpu_grp.hex"), a.seed, a.groups)
    print("gen_fpu_vectors: %d lanes (%d groups, %d directed) in fpu_grp.hex" % (n, n // NL, nc))
    if not a.no_leaf:
        gen_leaf(a.out, a.seed, a.leaf)
        print("gen_fpu_vectors: %d vectors per leaf in fpu_{ffma,rint,i2f,f2i,fadd}.hex" % a.leaf)


if __name__ == "__main__":
    main()
