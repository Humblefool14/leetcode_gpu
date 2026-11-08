"""fblend_model.py -- bit-exact Python model of ad_rop_fblend (fp32 blend path).

Built on tools/admodel.py (fp_add, fp_mul, fp_cmp, f2unorm, unorm2f) plus the
fp16 conversions and sRGB tables defined here.  All values are integer bit
patterns.  See spec/gpu/rop/ad_rop_fblend.md §10 for the choices made here.

sRGB tables: the EOTF ((x + 0.055) / 1.055) ** 2.4 is evaluated with the
decimal module at 60 significant digits (ln/exp), converted to an exact
Fraction and rounded to fp32 RNE with admodel.frac_to_f32.  The linear segment
(x / 12.92) is evaluated exactly with Fractions.  The generator asserts that
no value lies within 1e-30 (relative) of an fp32 rounding midpoint, so the
60-digit evaluation gives the correctly rounded result.
"""
import os
import sys
from decimal import Decimal, getcontext
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from admodel import (QNAN, b2f, f2b, fp_add, fp_mul, fp_cmp, f2unorm,  # noqa: E402
                     unorm2f, frac_to_f32, rne_frac, is_nan)

ONE = 0x3F800000
ZERO = 0x00000000

F_RGBA8_SRGB = 43
F_BGRA8_SRGB = 50
F_ABGR8_SRGB = 57
F_A2BGR10 = 64
F_R16F = 76
F_RG16F = 83
F_RGBA16F = 97
FORMATS = [F_RGBA8_SRGB, F_BGRA8_SRGB, F_ABGR8_SRGB, F_A2BGR10, F_R16F, F_RG16F, F_RGBA16F]
SRGB_FMTS = (F_RGBA8_SRGB, F_BGRA8_SRGB, F_ABGR8_SRGB)
FIXED_FMTS = SRGB_FMTS + (F_A2BGR10,)
ALL1_64 = (1 << 64) - 1


# ------------------------------------------------------------------ sRGB tables
getcontext().prec = 60
_C1 = Fraction(4045, 100000)          # 0.04045
_A = Fraction(55, 1000)               # 0.055


def _check_midpoint(fr: Fraction):
    """Assert fr is not within 1e-30 (relative) of an fp32 rounding midpoint."""
    e = fr.numerator.bit_length() - fr.denominator.bit_length()
    while Fraction(2) ** e > fr:
        e -= 1
    while Fraction(2) ** (e + 1) <= fr:
        e += 1
    m = fr / Fraction(2) ** (e - 23)
    frac = m - (m.numerator // m.denominator)
    assert abs(frac - Fraction(1, 2)) > Fraction(1, 10 ** 22), "too close to an fp32 midpoint"


def srgb_eotf_f32(x: Fraction) -> int:
    """fp32 RNE of the exact sRGB EOTF at x in [0, 1]."""
    if x == 0:
        return 0
    if x <= _C1:
        return frac_to_f32(x / Fraction(1292, 100))
    y = (x + _A) / Fraction(1055, 1000)
    yd = Decimal(y.numerator) / Decimal(y.denominator)
    v = (Decimal("2.4") * yd.ln()).exp()
    fr = Fraction(v)
    if fr >= 1:
        return ONE
    _check_midpoint(fr)
    return frac_to_f32(fr)


SRGB_LUT = [srgb_eotf_f32(Fraction(c, 255)) for c in range(256)]                   # code -> linear
SRGB_THR = [None] + [srgb_eotf_f32(Fraction(2 * k - 1, 510)) for k in range(1, 256)]  # T[k], k=1..255
assert SRGB_LUT[255] == ONE
assert all(SRGB_THR[k] < SRGB_THR[k + 1] for k in range(1, 255))
assert all(SRGB_THR[c] <= SRGB_LUT[c] < (SRGB_THR[c + 1] if c < 255 else 1 << 32) for c in range(1, 256))


def srgb_encode(u: int) -> int:
    """Linear fp32 -> sRGB code: number of k in 1..255 with u >= T[k]; NaN, negatives -> 0."""
    if is_nan(u) or (u >> 31):
        return 0
    return sum(1 for k in range(1, 256) if u >= SRGB_THR[k])   # unsigned order = value order for u >= 0


# ------------------------------------------------------------------ fp16
def h2f(h: int) -> int:
    """fp16 -> fp32 exactly; inf -> inf, NaN -> 0x7FC00000 (sign dropped)."""
    s = (h >> 15) & 1
    e = (h >> 10) & 0x1F
    m = h & 0x3FF
    if e == 31:
        return QNAN if m else (s << 31) | 0x7F800000
    if e == 0 and m == 0:
        return s << 31
    v = Fraction(m, 1 << 24) if e == 0 else Fraction(1024 + m, 1024) * Fraction(2) ** (e - 15)
    return (s << 31) | frac_to_f32(v)


def f2h(u: int) -> int:
    """fp32 -> fp16 RNE; subnormals produced, overflow -> inf, NaN -> 0x7E00, sign of zero kept.
    fp32 denormal inputs are taken by value (they always round to a signed zero)."""
    s = (u >> 31) & 1
    e = (u >> 23) & 0xFF
    m = u & 0x7FFFFF
    if e == 0xFF:
        return 0x7E00 if m else (s << 15) | 0x7C00
    if e == 0:
        return s << 15
    v = Fraction((1 << 23) | m, 1 << 23) * Fraction(2) ** (e - 127)
    E = e - 127
    if E < -14:
        q = rne_frac(v * (1 << 24))          # in subnormal units; 1024 = min normal encoding
        return (s << 15) | q
    q = rne_frac(v / Fraction(2) ** (E - 10))
    if q == 2048:
        q = 1024
        E += 1
    if E + 15 >= 31:
        return (s << 15) | 0x7C00
    return (s << 15) | ((E + 15) << 10) | (q - 1024)


# ------------------------------------------------------------------ blend pieces
def clamp01(u: int) -> int:
    """[0,1] clamp: NaN and negatives (incl. -0) -> +0, > 1 (incl. +inf) -> 1.0."""
    if is_nan(u) or (u >> 31):
        return ZERO
    if u > ONE:
        return ONE
    return u


def minmax(a: int, b: int, is_max: int) -> int:
    """One NaN -> the other operand; both NaN -> QNAN.  min = a<b ? a : b,
    max = a<b ? b : a (equal operands: min gives b, max gives a).  Operand bits returned unchanged."""
    na, nb = is_nan(a), is_nan(b)
    if na and nb:
        return QNAN
    if na:
        return b
    if nb:
        return a
    lt = fp_cmp(a, b)[0]
    if is_max:
        return b if lt else a
    return a if lt else b


def factor(sel: int, alpha: int, s, sa, d, da, c, ca) -> int:
    base = {2: s, 3: s, 4: d, 5: d, 6: sa, 7: sa, 8: da, 9: da,
            10: c, 11: c, 12: ca, 13: ca, 14: da}.get(sel, ZERO)
    om = fp_add(ONE, base, 1)
    if sel == 1:
        return ONE
    if sel in (2, 4, 6, 8, 10, 12):
        return base
    if sel in (3, 5, 7, 9, 11, 13):
        return om
    if sel == 14:
        return ONE if alpha else minmax(sa, om, 0)
    return ZERO                                   # 0 and 15


def combine(en: int, op: int, s, d, P, Q) -> int:
    if not en:
        return s
    if op == 1:
        return fp_add(P, Q, 1)
    if op == 2:
        return fp_add(Q, P, 1)
    if op == 3:
        return minmax(s, d, 0)
    if op == 4:
        return minmax(s, d, 1)
    return fp_add(P, Q, 0)


def unpack(raw: int, fmt: int):
    """64-bit stored lane -> 4 x fp32 linear (R, G, B, A)."""
    def b(lo, w):
        return (raw >> lo) & ((1 << w) - 1)
    if fmt in (F_RGBA8_SRGB, F_ABGR8_SRGB):
        return [SRGB_LUT[b(0, 8)], SRGB_LUT[b(8, 8)], SRGB_LUT[b(16, 8)], unorm2f(b(24, 8), 8)]
    if fmt == F_BGRA8_SRGB:
        return [SRGB_LUT[b(16, 8)], SRGB_LUT[b(8, 8)], SRGB_LUT[b(0, 8)], unorm2f(b(24, 8), 8)]
    if fmt == F_A2BGR10:
        return [unorm2f(b(0, 10), 10), unorm2f(b(10, 10), 10), unorm2f(b(20, 10), 10), unorm2f(b(30, 2), 2)]
    if fmt == F_R16F:
        return [h2f(b(0, 16)), ZERO, ZERO, ONE]
    if fmt == F_RG16F:
        return [h2f(b(0, 16)), h2f(b(16, 16)), ZERO, ONE]
    if fmt == F_RGBA16F:
        return [h2f(b(0, 16)), h2f(b(16, 16)), h2f(b(32, 16)), h2f(b(48, 16))]
    return [ZERO, ZERO, ZERO, ZERO]


def fields(fmt: int):
    """[(channel, lo, width, encoder)] of the format."""
    if fmt in (F_RGBA8_SRGB, F_ABGR8_SRGB):
        return [(0, 0, 8, srgb_encode), (1, 8, 8, srgb_encode), (2, 16, 8, srgb_encode),
                (3, 24, 8, lambda u: f2unorm(u, 8))]
    if fmt == F_BGRA8_SRGB:
        return [(2, 0, 8, srgb_encode), (1, 8, 8, srgb_encode), (0, 16, 8, srgb_encode),
                (3, 24, 8, lambda u: f2unorm(u, 8))]
    if fmt == F_A2BGR10:
        return [(0, 0, 10, lambda u: f2unorm(u, 10)), (1, 10, 10, lambda u: f2unorm(u, 10)),
                (2, 20, 10, lambda u: f2unorm(u, 10)), (3, 30, 2, lambda u: f2unorm(u, 2))]
    if fmt == F_R16F:
        return [(0, 0, 16, f2h)]
    if fmt == F_RG16F:
        return [(0, 0, 16, f2h), (1, 16, 16, f2h)]
    if fmt == F_RGBA16F:
        return [(0, 0, 16, f2h), (1, 16, 16, f2h), (2, 32, 16, f2h), (3, 48, 16, f2h)]
    return []


def pack(r, fmt: int, wm: int, active: int):
    """4 x fp32 -> (raw64, keep64); raw is 0 wherever keep is 1."""
    if not active:
        return 0, ALL1_64
    raw, keep = 0, ALL1_64
    for ch, lo, w, enc in fields(fmt):
        if (wm >> ch) & 1:
            mask = ((1 << w) - 1) << lo
            keep &= ~mask
            raw |= (enc(r[ch]) << lo) & mask
    return raw, keep


def lane(src4, dst64, fmt, blend, const4, wm, active):
    if not active or fmt not in FORMATS:
        return 0, ALL1_64
    d = unpack(dst64, fmt)
    fixed = fmt in FIXED_FMTS
    s = [clamp01(x) for x in src4] if fixed else list(src4)
    c = [clamp01(x) for x in const4] if fixed else list(const4)
    en = blend & 1
    r = []
    for ch in range(4):
        al = int(ch == 3)
        fs_sel = (blend >> 12) & 15 if al else (blend >> 1) & 15
        fd_sel = (blend >> 16) & 15 if al else (blend >> 5) & 15
        op = (blend >> 20) & 7 if al else (blend >> 9) & 7
        Fs = factor(fs_sel, al, s[ch], s[3], d[ch], d[3], c[ch], c[3])
        Fd = factor(fd_sel, al, s[ch], s[3], d[ch], d[3], c[ch], c[3])
        P = fp_mul(s[ch], Fs)
        Q = fp_mul(d[ch], Fd)
        r.append(combine(en, op, s[ch], d[ch], P, Q))
    return pack(r, fmt, wm, 1)


def beat(lanes, src, dst, fmt, blend, const, wm):
    """Full beat: src = 16 fp32 (lane-major, RGBA), dst = 4 x 64, const = 4 fp32.
    Returns (o_raw 256-bit int, o_keep 256-bit int)."""
    oraw, okeep = 0, 0
    for k in range(4):
        rw, kp = lane(src[4 * k:4 * k + 4], dst[k], fmt, blend, const, wm, (lanes >> k) & 1)
        oraw |= rw << (64 * k)
        okeep |= kp << (64 * k)
    return oraw, okeep
