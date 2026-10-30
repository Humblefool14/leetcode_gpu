"""Bit-exact reference model of the ad_rx arithmetic (exact rationals).

Rules: RNE; denormal inputs read as 0; results below 2^-126 after rounding
with an unbounded exponent flush to signed 0; canonical NaN 0x7FC00000;
overflow to +-inf; exact cancellation +0; (-0)+(-0) = -0.
"""
from fractions import Fraction as Fr
import random

QNAN = 0x7FC00000


def dec(b):
    s = b >> 31
    e = (b >> 23) & 0xFF
    m = b & 0x7FFFFF
    if e == 0xFF:
        return s, ("nan" if m else "inf")
    if e == 0:
        return s, Fr(0)
    v = Fr((1 << 23) | m, 1 << 23) * (Fr(2) ** (e - 127))
    return s, v


def rnd(sign, x):
    """x >= 0 exact rational -> fp32 bits with the RX rules."""
    if x == 0:
        return sign << 31
    e = 0
    while x >= 2:
        x /= 2
        e += 1
    while x < 1:
        x *= 2
        e -= 1
    m = x * (1 << 23)
    fl = m.numerator // m.denominator
    rem = m - fl
    if rem > Fr(1, 2) or (rem == Fr(1, 2) and fl & 1):
        fl += 1
    if fl == 1 << 24:
        fl >>= 1
        e += 1
    be = e + 127
    if be >= 255:
        return (sign << 31) | 0x7F800000
    if be <= 0:
        return sign << 31
    return (sign << 31) | (be << 23) | (fl & 0x7FFFFF)


def fadd(a, b, sub=0):
    if sub:
        b ^= 0x80000000
    sa, va = dec(a)
    sb, vb = dec(b)
    if va == "nan" or vb == "nan":
        return QNAN
    if va == "inf" and vb == "inf":
        return QNAN if sa != sb else a
    if va == "inf":
        return (sa << 31) | 0x7F800000
    if vb == "inf":
        return (sb << 31) | 0x7F800000
    if va == 0 and vb == 0:
        return (sa & sb) << 31
    x = (-va if sa else va) + (-vb if sb else vb)
    if x == 0:
        return 0
    return rnd(1 if x < 0 else 0, abs(x))


def fmul(a, b):
    sa, va = dec(a)
    sb, vb = dec(b)
    s = sa ^ sb
    if va == "nan" or vb == "nan":
        return QNAN
    if (va == "inf" and vb == 0) or (vb == "inf" and va == 0):
        return QNAN
    if va == "inf" or vb == "inf":
        return (s << 31) | 0x7F800000
    if va == 0 or vb == 0:
        return s << 31
    return rnd(s, va * vb)


def fdiv(a, b):
    sa, va = dec(a)
    sb, vb = dec(b)
    s = sa ^ sb
    if va == "nan" or vb == "nan":
        return QNAN
    if (va == 0 and vb == 0) or (va == "inf" and vb == "inf"):
        return QNAN
    if va == "inf" or vb == 0:
        return (s << 31) | 0x7F800000
    if va == 0 or vb == "inf":
        return s << 31
    return rnd(s, va / vb)


def i2f(v, W, F):
    if v >= 1 << (W - 1):
        v -= 1 << W
    if v == 0:
        return 0
    return rnd(1 if v < 0 else 0, Fr(abs(v), 1 << F))


def f2fix(f):
    SAT = (1 << 22) - 1
    s, v = dec(f)
    if v == "nan":
        return 0
    e = (f >> 23) & 0xFF
    if e < 94:
        return 0
    if v == "inf" or e >= 142:
        q = SAT
    else:
        x = v * 256
        fl = x.numerator // x.denominator
        rem = x - fl
        if rem > Fr(1, 2) or (rem == Fr(1, 2) and fl & 1):
            fl += 1
        q = min(fl, SAT) if fl <= SAT else SAT
    if s:
        q = -q
    return q & 0xFFFFFF


def rand_fp(r):
    """Operands biased toward the interesting corners."""
    k = r.random()
    if k < 0.03:
        return r.choice([0, 0x80000000, 0x7F800000, 0xFF800000, QNAN,
                         0x7F800001, 0x00000001, 0x807FFFFF, 0x3F800000,
                         0x00800000, 0x7F7FFFFF, 0xFF7FFFFF])
    if k < 0.10:   # near the denormal boundary
        return (r.getrandbits(1) << 31) | (r.randint(0, 3) << 23) | r.getrandbits(23)
    if k < 0.17:   # near overflow
        return (r.getrandbits(1) << 31) | (r.randint(250, 254) << 23) | r.getrandbits(23)
    if k < 0.45:   # moderate range, likely to cancel / tie
        e = r.randint(120, 134)
        return (r.getrandbits(1) << 31) | (e << 23) | (r.getrandbits(23) & ~r.choice([0, 0xFF, 0xFFFF]))
    return r.getrandbits(32)
