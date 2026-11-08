"""blend_model.py -- bit-exact reference model of ad_rop_blend (spec/gpu/rop/ad_rop_blend.md).

BlendModel keeps the STATE words the block snoops; beat() returns the 128-bit b_pix of a beat
using the state as it is *before* any STATE write of the same cycle (the RTL captures the beat's
state at b_valid with the registers' old values).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from admodel import div255, f2u8  # noqa: E402

S_RT_FORMAT, S_BLEND, S_BLEND_CONST, S_WRITE_MASK, S_RT_FORMATS = 0x072, 0x07A, 0x07B, 0x07C, 0x07D
S_BLEND1, S_BLEND2, S_BLEND3 = 0x084, 0x085, 0x086
S_BCONST_F = (0x087, 0x088, 0x089, 0x08A)
S_ROP_CTRL, S_LOGIC_OP = 0x08D, 0x08E

VK_R5G6B5, VK_A1R5G5B5, VK_R8, VK_R8G8, VK_RGBA8, VK_BGRA8, VK_ABGR8 = 4, 8, 9, 16, 37, 44, 51
FORMATS = (VK_RGBA8, VK_ABGR8, VK_BGRA8, VK_R8, VK_R8G8, VK_R5G6B5, VK_A1R5G5B5)

_f2u8_cache = {}


def cf2u8(u):
    v = _f2u8_cache.get(u)
    if v is None:
        v = f2u8(u)
        if len(_f2u8_cache) < 1 << 20:
            _f2u8_cache[u] = v
    return v


def unpack(lane, fmt):
    """-> (r, g, b, a) or None for a format outside the list."""
    b0, b1, b2, b3 = lane & 0xFF, (lane >> 8) & 0xFF, (lane >> 16) & 0xFF, (lane >> 24) & 0xFF
    if fmt in (VK_RGBA8, VK_ABGR8):
        return b0, b1, b2, b3
    if fmt == VK_BGRA8:
        return b2, b1, b0, b3
    if fmt == VK_R8:
        return b0, 0, 0, 255
    if fmt == VK_R8G8:
        return b0, b1, 0, 255
    r5, b5 = (lane >> 11) & 31, lane & 31
    if fmt == VK_R5G6B5:
        g6 = (lane >> 5) & 63
        return (r5 << 3) | (r5 >> 2), (g6 << 2) | (g6 >> 4), (b5 << 3) | (b5 >> 2), 255
    if fmt == VK_A1R5G5B5:
        a1, r5, g5 = (lane >> 15) & 1, (lane >> 10) & 31, (lane >> 5) & 31
        return (r5 << 3) | (r5 >> 2), (g5 << 3) | (g5 >> 2), (b5 << 3) | (b5 >> 2), 255 * a1
    return None


def pack(rgba, fmt, wm):
    """-> (bits, keep) with keep = per-bit 'keep destination' mask; wm = {A,B,G,R}."""
    r, g, b, a = rgba
    m = [0xFF if (wm >> i) & 1 else 0 for i in range(4)]
    if fmt in (VK_RGBA8, VK_ABGR8):
        bits, wr = r | g << 8 | b << 16 | a << 24, m[0] | m[1] << 8 | m[2] << 16 | m[3] << 24
    elif fmt == VK_BGRA8:
        bits, wr = b | g << 8 | r << 16 | a << 24, m[2] | m[1] << 8 | m[0] << 16 | m[3] << 24
    elif fmt == VK_R8:
        bits, wr = r, m[0]
    elif fmt == VK_R8G8:
        bits, wr = r | g << 8, m[0] | m[1] << 8
    elif fmt == VK_R5G6B5:
        bits = div255(r * 31) << 11 | div255(g * 63) << 5 | div255(b * 31)
        wr = (m[0] & 0x1F) << 11 | (m[1] & 0x3F) << 5 | (m[2] & 0x1F)
    elif fmt == VK_A1R5G5B5:
        bits = int(a >= 128) << 15 | div255(r * 31) << 10 | div255(g * 31) << 5 | div255(b * 31)
        wr = (m[3] & 1) << 15 | (m[0] & 0x1F) << 10 | (m[1] & 0x1F) << 5 | (m[2] & 0x1F)
    else:
        bits, wr = 0, 0
    return bits, (~wr) & 0xFFFFFFFF


def logicop(op, s, d):
    M = 0xFFFFFFFF
    return [0, s & d, s & ~d, s, ~s & d, d, s ^ d, s | d, ~(s | d), ~(s ^ d), ~d, s | ~d, ~s,
            ~s | d, ~(s & d), M][op] & M


def factor(sel, dual, is_alpha, c, s, d, k, s1):
    """8-bit factor for channel c (3 = alpha). s, d, k, s1 are RGBA8 tuples."""
    sc, sa, dc, da, kc, ka, s1c, s1a = s[c], s[3], d[c], d[3], k[c], k[3], s1[c], s1[3]
    if sel == 0:
        return 0
    if sel == 1:
        return 255
    if sel == 2:
        return sc
    if sel == 3:
        return 255 - sc
    if sel == 4:
        return dc
    if sel == 5:
        return 255 - dc
    if sel == 6:
        return sa
    if sel == 7:
        return 255 - sa
    if sel == 8:
        return da
    if sel == 9:
        return 255 - da
    if sel == 10:
        return kc
    if sel == 11:
        return 255 - kc
    if sel == 12:
        return ka
    if sel == 13:
        return 255 - ka
    if sel == 14:
        return 255 if is_alpha else min(sa, 255 - da)
    if dual and 15 <= sel <= 18:
        return [s1c, 255 - s1c, s1a, 255 - s1a][sel - 15]
    return 0


def blend_op(op, s, d, fs, fd):
    ts, td = div255(s * fs), div255(d * fd)
    if op == 1:
        return max(0, ts - td)
    if op == 2:
        return max(0, td - ts)
    if op == 3:
        return min(s, d)
    if op == 4:
        return max(s, d)
    return min(255, ts + td)


class BlendModel:
    def __init__(self):
        self.reset()

    def reset(self):
        self.st = {}
        self.kf = [0, 0, 0, 0]

    def w(self, idx):
        return self.st.get(idx, 0)

    def write(self, idx, data):
        data &= 0xFFFFFFFF
        self.st[idx] = data
        if idx in S_BCONST_F:
            self.kf[S_BCONST_F.index(idx)] = cf2u8(data)

    def sel(self, rt):
        """Selected state of attachment rt -> dict."""
        bw = self.w([S_BLEND, S_BLEND1, S_BLEND2, S_BLEND3][rt])
        fb = (self.w(S_RT_FORMATS) >> (8 * rt)) & 0xFF
        if rt == 0 and fb == 0:
            fb = {0: VK_BGRA8, 1: VK_RGBA8, 2: VK_R5G6B5, 3: VK_R5G6B5}.get(self.w(S_RT_FORMAT), 0)
        ropc = self.w(S_ROP_CTRL)
        lb = (self.w(S_LOGIC_OP) >> (8 * rt)) & 0xFF
        if (ropc >> 1) & 1:
            k = tuple(self.kf)
        else:
            bc = self.w(S_BLEND_CONST)
            k = tuple((bc >> (8 * i)) & 0xFF for i in range(4))
        return dict(blend=bw, fmt=fb, wm=(self.w(S_WRITE_MASK) >> (4 * rt)) & 0xF,
                    lop_en=((ropc >> 2) & 1) | (lb & 1), lop=(lb >> 1) & 0xF, k=k,
                    dual=(ropc >> 7) & 1)

    def beat(self, src, src1, has_src1, dst, mask, rt):
        """src/src1: 16 fp32 words [4*l + c]; dst: 4 lane words. -> list of 4 b_pix lanes."""
        S = self.sel(rt)
        bw, fmt, dual = S['blend'], S['fmt'], S['dual']

        def fsel(lo, msb):
            v = (bw >> lo) & 0xF
            return v | (16 if dual and (bw >> msb) & 1 else 0)

        f_sc, f_dc, f_sa, f_da = fsel(1, 23), fsel(5, 24), fsel(12, 25), fsel(16, 26)
        cop, aop, ben = (bw >> 9) & 7, (bw >> 20) & 7, bw & 1
        out = []
        for l in range(4):
            d_lane = dst[l] & 0xFFFFFFFF
            dv = unpack(d_lane, fmt)
            if not (mask >> l) & 1 or dv is None:
                out.append(d_lane)
                continue
            s = tuple(cf2u8(src[4 * l + c]) for c in range(4))
            s1 = tuple(cf2u8(src1[4 * l + c]) if has_src1 else 0 for c in range(4))
            if S['lop_en'] or not ben:
                v = s
            else:
                v = []
                for c in range(4):
                    isa = c == 3
                    fs = factor(f_sa if isa else f_sc, dual, isa, c, s, dv, S['k'], s1)
                    fd = factor(f_da if isa else f_dc, dual, isa, c, s, dv, S['k'], s1)
                    v.append(blend_op(aop if isa else cop, s[c], dv[c], fs, fd))
            bits, keep = pack(v, fmt, S['wm'])
            if S['lop_en']:
                bits = logicop(S['lop'], bits, d_lane)
            out.append((keep & d_lane) | (~keep & bits & 0xFFFFFFFF))
        return out
