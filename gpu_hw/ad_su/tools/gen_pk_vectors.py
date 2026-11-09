#!/usr/bin/env python3
# gen_pk_vectors.py: vectors for sim/tb/ad_su_pk_half_tb.v and sim/tb/ad_su_pk_tb.v,
# from the bit-exact reference tools/gsi1fp.py (pk, pk_half, f32_to_f16, f16_to_f32,
# fcmp, fminmax, sat).
#
#   python3 -I tools/gen_pk_vectors.py [--seed N] [--nfma N] [--npair N] [--ngrp N]
#
# Writes (repo root relative):
#   sim/vec/pk_h2f.hex   all 65536 fp16: h f32(h) sat(h)                  (4+8+4 hex)
#   sim/vec/pk_pair.hex  special pairs then random pairs: a b cmp min max
#                        cmp = {ne, le, lt, eq} of (a, b)                 (4+4+1+4+4 hex)
#   sim/vec/pk_half.hex  ad_su_pk_half: o r sat ha hb hc xw y             (1+1+1+4+4+4+8+4 hex)
#                        y is the ARITH 1 FP 1 result (the TB derives FP 0 / ARITH 0)
#   sim/vec/pk_lane.hex  ad_su_pk groups of 8 lanes sharing op rm hsel sub sat:
#                        op rm hsel sub sat a b c y                       (5+8*4 hex)
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
import gsi1fp as G  # noqa: E402

F16 = G.F16
# Memoise the exact value of every fp16 (same results, much faster).
_V16 = {}
_value16 = F16.value


def _cached_value(x):
    v = _V16.get(x)
    if v is None:
        v = _V16[x] = _value16(x)
    return v


F16.value = _cached_value

SPEC16 = [0x0000, 0x8000, 0x0001, 0x8001, 0x03FF, 0x83FF, 0x0200, 0x0400, 0x8400, 0x0401,
          0x3BFF, 0x3C00, 0xBC00, 0x3C01, 0x3800, 0x4000, 0x7BFF, 0xFBFF, 0x7C00, 0xFC00,
          0x7C01, 0x7E00, 0xFE00, 0x7FFF, 0xFFFF, 0x5555, 0xD555]
FLOAT_OPS = (G.PK_FADD2, G.PK_FSUB2, G.PK_FMUL2, G.PK_FFMA2, G.PK_FMIN2, G.PK_FMAX2)


def half_ref(o, ha, hb, hc, rm, st, xw):
    """One ad_su_pk_half output (ARITH 1, FP 1)."""
    if o == G.PK_PACKH:
        return G.f32_to_f16(xw)
    if o in (G.PK_UNPACKH, G.PK_SWAPH):
        return 0
    y = G.pk_half(o, ha, hb, hc, rm)
    if st and o in FLOAT_OPS:
        y = G.sat(F16, y)
    return y


def h16(r, ebias=None):
    k = r.random()
    if k < 0.12:
        return r.choice(SPEC16)
    if k < 0.65:
        return r.getrandbits(1) << 15 | r.randrange(8, 24) << 10 | r.getrandbits(10)
    if k < 0.75:
        # Sparse mantissa (exact products).
        m = 0
        for _ in range(r.randrange(0, 3)):
            m |= 1 << r.randrange(10)
        return r.getrandbits(1) << 15 | r.randrange(1, 31) << 10 | m
    return r.getrandbits(16)


def fma_vectors(r, n):
    out = []
    rms = [0, 1, 2, 3, 4, 5, 6, 7]
    # Every addend alignment: all (ea, eb, ec) of normal exponents.
    for ea in range(1, 31):
        for eb in range(1, 31):
            for ec in range(1, 31):
                a = r.getrandbits(1) << 15 | ea << 10 | r.getrandbits(10)
                b = r.getrandbits(1) << 15 | eb << 10 | r.getrandbits(10)
                c = r.getrandbits(1) << 15 | ec << 10 | r.getrandbits(10)
                out.append((G.PK_FFMA2, a, b, c, r.choice(rms), 0))
    while len(out) < n:
        k = r.random()
        o = r.choice((G.PK_FADD2, G.PK_FSUB2, G.PK_FMUL2, G.PK_FFMA2, G.PK_FFMA2))
        a, b, c = h16(r), h16(r), h16(r)
        if k < 0.25:
            # Cancellation: c near -(a*b), or b near a for fadd/fsub.
            if o == G.PK_FFMA2:
                p = G.fma(F16, a, b, 0, r.choice(rms), noc=True)
                c = (p ^ 0x8000) + r.randrange(-3, 4) & 0xFFFF
            elif o == G.PK_FADD2:
                b = (a ^ 0x8000) + r.randrange(-3, 4) & 0xFFFF
            else:
                b = a + r.randrange(-3, 4) & 0xFFFF
        elif k < 0.32:
            # Results near the overflow and underflow thresholds.
            e = r.choice((1, 2, 14, 15, 16, 29, 30))
            a = r.getrandbits(1) << 15 | e << 10 | r.getrandbits(10)
            b = r.getrandbits(1) << 15 | r.randrange(1, 31) << 10 | r.getrandbits(10)
        out.append((o, a, b, c, r.choice(rms), 1 if r.random() < 0.1 else 0))
    return out


def other_vectors(r, n):
    out = []
    ops = [G.PK_FMIN2, G.PK_FMAX2, G.PK_IADD2, G.PK_ISUB2, G.PK_IMUL2, G.PK_FCMPLT2,
           G.PK_FCMPGE2, G.PK_FCMPEQ2, G.PK_FCMPNE2, G.PK_PACKH, G.PK_UNPACKH, G.PK_SWAPH]
    for _ in range(n):
        o = r.choice(ops)
        a, b, c = h16(r), h16(r), h16(r)
        if r.random() < 0.3:
            b = a if r.random() < 0.5 else a ^ 0x8000
        xw = G.rnd32(r)
        if r.random() < 0.5:
            # Around the fp16 range (rounding, overflow, underflow).
            xw = r.getrandbits(1) << 31 | r.randrange(98, 146) << 23 | r.getrandbits(23)
        if r.random() < 0.1:
            xw = (xw & ~0x1FFF) | r.choice((0x1000, 0x0FFF, 0x1001, 0x0000, 0x1FFF))
        out.append((o, a, b, c, r.choice(range(8)), 1 if r.random() < 0.2 else 0, xw))
    return out


def lane_groups(r, ngrp):
    groups = []
    for g in range(ngrp):
        op = r.randrange(16)
        rm = r.randrange(8)
        hsel = r.randrange(4)
        sub = r.randrange(2) if op == G.PK_UNPACKH else r.choice((0, 0, 0, 1))
        st = 1 if r.random() < 0.15 else 0
        lanes = []
        for _ in range(8):
            a = h16(r) << 16 | h16(r)
            b = h16(r) << 16 | h16(r)
            c = h16(r) << 16 | h16(r)
            if op in (G.PK_FADD2, G.PK_FSUB2, G.PK_FFMA2) and r.random() < 0.2:
                b = a ^ 0x80008000 if op != G.PK_FSUB2 else a
            if op in (G.PK_PACKH, G.PK_UNPACKH) and r.random() < 0.7:
                a, b = G.rnd32(r), G.rnd32(r)
                if r.random() < 0.5:
                    a = r.getrandbits(1) << 31 | r.randrange(98, 146) << 23 | r.getrandbits(23)
                    b = r.getrandbits(1) << 31 | r.randrange(98, 146) << 23 | r.getrandbits(23)
            y = G.pk(op, a, b, c, rm, hsel, sub, st)
            lanes.append((a, b, c, y))
        groups.append((op, rm, hsel, sub, st, lanes))
    return groups


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--nfma", type=int, default=220000)
    ap.add_argument("--nother", type=int, default=60000)
    ap.add_argument("--npair", type=int, default=1000000)
    ap.add_argument("--ngrp", type=int, default=7000)
    ap.add_argument("--out", default="sim/vec")
    a = ap.parse_args()
    r = random.Random(a.seed)
    os.makedirs(a.out, exist_ok=True)

    with open(os.path.join(a.out, "pk_h2f.hex"), "w") as f:
        for h in range(65536):
            f.write("%04x%08x%04x\n" % (h, G.f16_to_f32(h), G.sat(F16, h)))

    def pair_line(x, y):
        cmp = 0
        for i in range(4):
            cmp |= int(G.fcmp(F16, x, y, i)) << i
        return "%04x%04x%x%04x%04x\n" % (x, y, cmp, G.fminmax(F16, x, y, False),
                                          G.fminmax(F16, x, y, True))
    npair = 0
    with open(os.path.join(a.out, "pk_pair.hex"), "w") as f:
        for x in SPEC16:
            for y in SPEC16:
                f.write(pair_line(x, y))
                npair += 1
        while npair < a.npair + len(SPEC16) ** 2:
            k = r.random()
            x = r.getrandbits(16)
            if k < 0.2:
                y = x
            elif k < 0.3:
                y = x ^ 0x8000
            elif k < 0.5:
                y = (x + r.randrange(-4, 5)) & 0xFFFF
            else:
                y = r.getrandbits(16)
            if r.random() < 0.5:
                x, y = y, x
            f.write(pair_line(x, y))
            npair += 1

    nhalf = 0
    with open(os.path.join(a.out, "pk_half.hex"), "w") as f:
        for o, x, y, z, rm, st in fma_vectors(r, a.nfma):
            f.write("%x%x%x%04x%04x%04x%08x%04x\n" % (o, rm, st, x, y, z, 0,
                                                      half_ref(o, x, y, z, rm, st, 0)))
            nhalf += 1
        for o, x, y, z, rm, st, xw in other_vectors(r, a.nother):
            f.write("%x%x%x%04x%04x%04x%08x%04x\n" % (o, rm, st, x, y, z, xw,
                                                      half_ref(o, x, y, z, rm, st, xw)))
            nhalf += 1

    with open(os.path.join(a.out, "pk_lane.hex"), "w") as f:
        for op, rm, hsel, sub, st, lanes in lane_groups(r, a.ngrp):
            for x, y, z, res in lanes:
                f.write("%x%x%x%x%x%08x%08x%08x%08x\n" % (op, rm, hsel, sub, st, x, y, z, res))
    print("gen_pk_vectors: 65536 h2f, %d pairs, %d half, %d lane vectors (%d groups)"
          % (npair, nhalf, 8 * a.ngrp, a.ngrp))


if __name__ == "__main__":
    main()
