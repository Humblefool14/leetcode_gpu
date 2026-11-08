"""admodel.py -- bit-exact Python reference models for the ad_rop arithmetic IPs.

Every function takes and returns integers (bit patterns for fp32) so that test
vectors can be written as hex and compared word for word with the RTL.
"""
import struct
from fractions import Fraction

import numpy as np

QNAN = 0x7FC00000
MIN_NORMAL = 2.0 ** -126


def f2b(x: float) -> int:
    return struct.unpack("<I", struct.pack("<f", x))[0]


def b2f(u: int) -> float:
    return struct.unpack("<f", struct.pack("<I", u & 0xFFFFFFFF))[0]


def is_nan(u):
    return (u >> 23) & 0xFF == 0xFF and (u & 0x7FFFFF) != 0


def is_denorm(u):
    return (u >> 23) & 0xFF == 0 and (u & 0x7FFFFF) != 0


def ftz_in(u):
    """Flush a denormal input to a signed zero."""
    return u & 0x80000000 if is_denorm(u) else u


# ---------------------------------------------------------------- unorm8 path
def div255(x: int) -> int:
    """round(x / 255) for 0 <= x <= 65025 (ties never occur: 255 is odd)."""
    return (x + 127) // 255


def rne_frac(fr: Fraction) -> int:
    """Round a non-negative Fraction to the nearest integer, ties to even."""
    n = fr.numerator // fr.denominator
    rem = fr - n
    if rem > Fraction(1, 2) or (rem == Fraction(1, 2) and n & 1):
        n += 1
    return n


def f2unorm(u: int, n: int) -> int:
    """RNE(clamp01(f) * (2^n - 1)); NaN, negatives, denormals -> 0."""
    maxv = (1 << n) - 1
    if is_nan(u) or (u >> 31) or (u >> 23) & 0xFF == 0:
        return 0
    if (u >> 23) & 0xFF >= 127:      # >= 1.0 and +inf
        return maxv
    f = Fraction(b2f(u))
    if f >= 1:
        return maxv
    return rne_frac(f * maxv)


def f2u8(u: int) -> int:
    # identical to f2unorm(u, 8) (values below 2^-10 round to 0 anyway)
    return f2unorm(u, 8)


def unorm2f(x: int, n: int) -> int:
    """RNE(x / (2^n - 1)) as fp32 bits."""
    maxv = (1 << n) - 1
    if x == 0:
        return 0
    if x == maxv:
        return 0x3F800000
    return frac_to_f32(Fraction(x, maxv))


def frac_to_f32(fr: Fraction) -> int:
    """Exact Fraction (positive, normal range) to fp32 bits, RNE."""
    assert fr > 0
    e = fr.numerator.bit_length() - fr.denominator.bit_length()
    while Fraction(2) ** e > fr:
        e -= 1
    while Fraction(2) ** (e + 1) <= fr:
        e += 1
    m = rne_frac(fr / Fraction(2) ** (e - 23))
    if m == 1 << 24:
        m >>= 1
        e += 1
    return ((e + 127) << 23) | (m & 0x7FFFFF)


# ---------------------------------------------------------------- fp32 (FTZ)
def _flush_out(r: np.float32) -> int:
    u = int(np.float32(r).view(np.uint32))
    if is_nan(u):
        return QNAN
    if is_denorm(u):
        return u & 0x80000000
    return u


def fp_add(a: int, b: int, sub: int = 0) -> int:
    if sub:
        b ^= 0x80000000
    a, b = ftz_in(a), ftz_in(b)
    if is_nan(a) or is_nan(b):
        return QNAN
    with np.errstate(all="ignore"):
        r = np.float32(np.uint32(a).view(np.float32)) + np.float32(np.uint32(b).view(np.float32))
    return _flush_out(r)


def fp_mul(a: int, b: int) -> int:
    a, b = ftz_in(a), ftz_in(b)
    if is_nan(a) or is_nan(b):
        return QNAN
    fa = float(np.uint32(a).view(np.float32))
    fb = float(np.uint32(b).view(np.float32))
    with np.errstate(all="ignore"):
        exact = np.float64(fa) * np.float64(fb)          # exact: 24x24 bits fit 53
        if np.isnan(exact):
            return QNAN
        s = (a ^ b) & 0x80000000
        if exact != 0 and abs(exact) < MIN_NORMAL:      # flush before rounding
            return s
        r = np.float32(exact)
    u = int(r.view(np.uint32))
    if r == 0:
        return s
    return u


def fp_cmp(a: int, b: int):
    """(lt, eq, un) of a against b; -0 == +0."""
    if is_nan(a) or is_nan(b):
        return 0, 0, 1
    fa, fb = b2f(a), b2f(b)
    return int(fa < fb), int(fa == fb), 0


def cmp_op(op: int, lt: int, eq: int, un: int) -> int:
    gt = int(not lt and not eq and not un)
    return [0, lt, eq, lt | eq, gt, int(not eq), gt | eq, 1][op]


# ---------------------------------------------------------------- random fp32
def rand_f32(rng, special_rate=0.05):
    """Random fp32 pattern biased toward interesting values."""
    r = rng.random()
    if r < special_rate:
        return int(rng.choice([0, 0x80000000, 0x7F800000, 0xFF800000, QNAN,
                               0x7F800001, 0x3F800000, 0xBF800000, 0x00000001,
                               0x807FFFFF, 0x00800000, 0x7F7FFFFF]))
    if r < 0.35:   # values in [0, 1.25] - the ROP's working range
        return f2b(float(np.float32(rng.random() * 1.25)))
    if r < 0.55:   # close exponents (cancellation)
        e = int(rng.integers(100, 140))
        return (int(rng.integers(0, 2)) << 31) | (e << 23) | int(rng.integers(0, 1 << 23))
    return int(rng.integers(0, 1 << 32))
