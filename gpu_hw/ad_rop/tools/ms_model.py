"""ms_model.py -- bit-exact reference model of ad_rop_ms (spec/gpu/rop/ad_rop_ms.md).

Values are integers (fp32 bit patterns).  d_s layout (ASSUMPTION, spec §10):
sample offset s at d_s[32 s +: 32], shared by the four lanes.
"""
from admodel import fp_add, fp_cmp, is_nan

ONE = 0x3F800000
T_A2C = [0x3E000000, 0x3EC00000, 0x3F200000, 0x3F600000]   # .125 .375 .625 .875
T_HALF = 0x3F000000
A2C_TABLE = [0b0000, 0b0001, 0b1001, 0b1011, 0b1111]
MUT_T0 = 0x3E800000


def ge(a, t):
    lt, _, un = fp_cmp(a, t)
    return int(not un and not lt)


def a2c(alpha, mut=False):
    """(4-bit sample mask, alpha >= 0.5)."""
    th = list(T_A2C)
    if mut:
        th[0] = MUT_T0
    n = sum(ge(alpha, t) for t in th)
    return A2C_TABLE[n], ge(alpha, T_HALF)


def clamp01(x):
    if is_nan(x) or (x >> 31):
        return 0
    lt, _, _ = fp_cmp(ONE, x)
    return ONE if lt else x


def lohi(n, f):
    lt, _, _ = fp_cmp(f, n)
    return (f, n) if lt else (n, f)


def clampmm(x, lo, hi):
    if is_nan(x) or fp_cmp(x, lo)[0]:
        return lo
    if fp_cmp(hi, x)[0]:
        return hi
    return x


def lane(v, l, w=32):
    return (v >> (w * l)) & ((1 << w) - 1)


class MsModel:
    """Holds STATE and the first beat's result; beat() returns None (dropped)
    or the output dict."""

    def __init__(self, mut=False):
        self.ms_ctrl = 0
        self.dclamp = 0
        self.zscale = 0
        self.zoff = 0
        self.drop = True
        self.smask = 0
        self.sdepth = 0
        self.mut = mut

    def state(self, idx, val):
        if idx == 0x05E:
            self.ms_ctrl = val
        elif idx == 0x059:
            self.dclamp = val
        elif idx == 0x054:
            self.zscale = val
        elif idx == 0x055:
            self.zoff = val

    def beat(self, xy, mask, color, depth, dbg, aux):
        four = (self.ms_ctrl & 0xF) == 2
        use_a2c = (self.ms_ctrl >> 8) & 1 and not dbg
        a21 = (self.ms_ctrl >> 9) & 1 and not dbg
        dmm = self.dclamp & 1
        drx = (self.dclamp >> 1) & 1
        n = self.zoff
        f = fp_add(self.zoff, self.zscale)
        lo, hi = lohi(n, f)
        qfirst = (aux >> 150) & 1
        sin = aux & 0xFFFF
        zexp = (aux >> 16) & 0xF
        ds = (aux >> 20) & ((1 << 128) - 1)
        col = color
        if a21:
            for l in range(4):
                col &= ~(0xFFFFFFFF << (128 * l + 96))
                col |= ONE << (128 * l + 96)
        if qfirst:
            sm = 0
            for l in range(4):
                m4, h = a2c(lane(color, 4 * l + 3), self.mut)
                lb = (mask >> l) & 1
                if four:
                    v = ((sin >> (4 * l)) & 0xF) & (0xF if lb else 0) & (m4 if use_a2c else 0xF)
                    sm |= v << (4 * l)
                else:
                    b = ((sin >> (4 * l)) & 1) & lb & (h if use_a2c else 1)
                    sm |= b << (4 * l)
            if sm == 0:
                self.drop = True
                return None
            self.drop = False
            sd = 0
            for l in range(4):
                z = lane(depth, l)
                for s in range(4):
                    if four:
                        if (zexp >> l) & 1:
                            x = z
                        else:
                            x = fp_add(z, lane(ds, s))
                            if not drx:
                                x = clamp01(x)
                    elif s == 0:
                        x = z
                    else:
                        continue
                    if dmm:
                        x = clampmm(x, lo, hi)
                    sd |= x << (32 * (4 * l + s))
            self.smask, self.sdepth = sm, sd
        elif self.drop:
            return None
        beat = (((aux >> 152) & 3) << 2) | (((aux >> 149) & 1) << 1) | qfirst
        return dict(xy=xy, smask=self.smask, color=col, sdepth=self.sdepth,
                    dbg=dbg, front=(aux >> 148) & 1, beat=beat)
