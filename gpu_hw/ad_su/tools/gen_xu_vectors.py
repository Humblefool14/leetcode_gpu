#!/usr/bin/env python3
# gen_xu_vectors.py: vectors for sim/tb/ad_su_xu_tb.v (ad_su_xu), the
# expected results from tools/gsi1fp.py xu() (bit for bit).
#   python3 -I tools/gen_xu_vectors.py [--seed N] [--out sim/vec/xu_funcs.hex]
# The first 3000 lines are gsi1fp.py's own xu_vec(seed) (one op per block of
# 8 lines), then targeted blocks: rcp/rsq/fsqrt on mantissa extremes and odd
# and even exponents, exp2 around integers and the range ends, log2 around
# 1 and powers of two, sin/cos around multiples of pi/4 and the 2^-12
# threshold, every special operand for every op.  Line: op(1) x(8) y(8).
# It also prints the error of the model against math (the TB checks the
# same bounds against $sin/$cos/$pow/$ln/$sqrt).
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import argparse
import math
import os
import random
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
import gsi1fp as FP  # noqa: E402

M32 = 0xFFFFFFFF


def f2r(x):
    s, e, m = x >> 31, x >> 23 & 255, x & 0x7FFFFF
    if e == 0:
        return -0.0 if s else 0.0
    v = (1 + m / 2.0 ** 23) * 2.0 ** (e - 127)
    return -v if s else v


def bits(v):
    return FP.bits_f(v)


def targeted(r):
    blocks = []

    def blk(op, xs):
        xs = list(xs)
        while len(xs) % 8:
            xs.append(r.choice(xs))
        for i in range(0, len(xs), 8):
            blocks.append([(op, x & M32) for x in xs[i:i + 8]])

    for op in range(7):
        sp = list(FP.SPECIALS32)
        blk(op, sp)
    # rcp, rsq, fsqrt: mantissa extremes, odd/even exponents
    for op in (FP.XU_RCP, FP.XU_RSQ, FP.XU_FSQRT):
        xs = []
        for e in [1, 2, 3, 126, 127, 128, 129, 200, 252, 253, 254] + [r.randrange(1, 255) for _ in range(5)]:
            for mf in (0, 1, 2, 0x7FFFFF, 0x7FFFFE, 0x400000, 0x3FFFFF, r.getrandbits(23)):
                s = r.getrandbits(1) if op == FP.XU_RCP else 0
                xs.append(s << 31 | e << 23 | mf)
        blk(op, xs)
    # perfect squares for fsqrt/rsq exactness
    blk(FP.XU_FSQRT, [bits(float(k * k)) for k in range(1, 65)])
    blk(FP.XU_RSQ, [bits(float(4 ** k)) for k in range(-20, 20)])
    # exp2
    xs = []
    for k in range(-150, 130, 7):
        for d in (0.0, 1e-6, -1e-6, 0.5, 0.999999):
            xs.append(bits(k + d))
    xs += [bits(v) for v in (-126.0, -127.0, -149.0, -150.0, 127.0, 127.99999, 128.0, 255.9, -255.9,
                             2.0 ** -30, 2.0 ** -31, -2.0 ** -30, 1e-9, -1e-9)]
    xs += [r.getrandbits(1) << 31 | r.randrange(100, 135) << 23 | r.getrandbits(23) for _ in range(40)]
    blk(FP.XU_EXP2, xs)
    # log2
    xs = [bits(1.0), 0x3F800001, 0x3F7FFFFF, 0x3F800002, 0x3F7FFFFE]
    xs += [bits(2.0 ** k) for k in range(-126, 128, 9)]
    xs += [bits(1 + r.uniform(-1e-5, 1e-5)) for _ in range(40)]
    xs += [r.randrange(1, 255) << 23 | r.getrandbits(23) for _ in range(40)]
    blk(FP.XU_LOG2, xs)
    # sin / cos
    for op in (FP.XU_SIN, FP.XU_COS):
        xs = []
        for k in range(-16, 17):
            c = k * math.pi / 4
            for d in (0.0, 1e-7, -1e-7, 1e-4):
                xs.append(bits(c + d))
        xs += [114 << 23 | 0x7FFFFF, 115 << 23, 115 << 23 | 1, 1 << 31 | 115 << 23,
               bits(1e5), bits(-1e5), bits(1e10), bits(3.0e38)]
        xs += [bits(r.uniform(-1000, 1000)) for _ in range(30)]
        blk(op, xs)
    return blocks


def err_stats(vec):
    worst = {}
    for op, x, y in vec:
        xv, yv = f2r(x), f2r(y)
        ey = y >> 23 & 255
        if ey in (0, 255) or (x >> 23 & 255) in (0, 255):
            continue
        ulp = 2.0 ** (ey - 150)
        try:
            if op == FP.XU_RCP:
                e = abs(yv - 1 / xv) / ulp
            elif op == FP.XU_RSQ:
                e = abs(yv - 1 / math.sqrt(xv)) / ulp
            elif op == FP.XU_FSQRT:
                e = abs(yv - math.sqrt(xv)) / ulp
            elif op == FP.XU_EXP2:
                ref = 2.0 ** xv
                if ref < 2.0 ** -125:
                    continue
                e = abs(yv - ref) / ulp
            elif op == FP.XU_LOG2:
                e = abs(yv - math.log2(xv)) * 2.0 ** 22
            else:
                if abs(xv) > 16:
                    continue
                ref = math.sin(xv) if op == FP.XU_SIN else math.cos(xv)
                e = abs(yv - ref) * 2.0 ** 22
        except (ValueError, ZeroDivisionError, OverflowError):
            continue
        worst[op] = max(worst.get(op, 0), e)
    return worst


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", default="sim/vec/xu_funcs.hex")
    a = ap.parse_args()
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "xu.hex")
        FP.xu_vec(p, a.seed)
        base = [(int(ln[0], 16), int(ln[1:9], 16), int(ln[9:17], 16))
                for ln in open(p).read().split()]
    r = random.Random(a.seed + 100)
    vec = list(base)
    for b in targeted(r):
        vec += [(op, x, FP.xu(op, x)) for op, x in b]
    while len(vec) % 32:
        vec.append(vec[len(vec) - 8])
    with open(a.out, "w") as f:
        for op, x, y in vec:
            f.write("%x%08x%08x\n" % (op, x, y))
    names = ["rcp", "rsq", "exp2", "log2", "sin", "cos", "fsqrt"]
    w = err_stats(vec)
    print("gen_xu_vectors: %d vectors in %s; worst error (ulp; log2/sin/cos in 2^-22 abs): %s" %
          (len(vec), a.out, ", ".join("%s %.3f" % (names[k], v) for k, v in sorted(w.items()))))


if __name__ == "__main__":
    main()
