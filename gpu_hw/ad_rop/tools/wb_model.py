"""wb_model.py -- reference model of ad_rop_wb / ad_rop_wpix (spec/gpu/rop/ad_rop_wb.md,
ad_rop_wpix.md).

* fmt_info / resolve_fmt / pack2: the format table, the attachment's format, path-2 packing.
* wpix_eval: every combinational output of ad_rop_wpix for one set of inputs (the
  ad_rop_wpix testbench vectors).
* apply_beat: the final memory image of a beat (path 2 formats; path 0 with the testbench
  blend model: blend disabled = pack(f2u8(src)) with the write mask, blend enabled =
  per-channel saturating add of f2u8(src) and the old channel (BLEND = ONE/ONE/ADD);
  path 1 with the fblend stub: A2B10G10R10_UNORM, blend disabled).
Integers everywhere; fp32 values are bit patterns.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from admodel import f2u8, f2unorm  # noqa: E402

# ---- STATE indices (rtl/include/ad_rop_state.vh) ----
S_MS_CTRL = 0x05E
S_RT_BASE, S_RT_STRIDE, S_RT_FORMAT = 0x070, 0x071, 0x072
S_BLEND, S_BLEND_CONST, S_WRITE_MASK, S_RT_FORMATS = 0x07A, 0x07B, 0x07C, 0x07D
S_RTK_BASE = {0: 0x070, 1: 0x07E, 2: 0x080, 3: 0x082}
S_RTK_STRIDE = {0: 0x071, 1: 0x07F, 2: 0x081, 3: 0x083}
S_BLENDK = {0: 0x07A, 1: 0x084, 2: 0x085, 3: 0x086}
S_ROP_CTRL = 0x08D

# ---- format table: fmt -> (path, ps, chm) ----
FMT = {}
for f in (37, 44, 51):
    FMT[f] = (0, 4, 0xF)
FMT[4] = (0, 2, 0x7)
FMT[8] = (0, 2, 0xF)
FMT[9] = (0, 1, 0x1)
FMT[16] = (0, 2, 0x3)
for f in (43, 50, 57, 64):
    FMT[f] = (1, 4, 0xF)
FMT[76] = (1, 2, 0x1)
FMT[83] = (1, 4, 0x3)
FMT[97] = (1, 8, 0xF)
# path 2: fmt -> (channel width, channels); 68 special
P2 = {13: (8, 1), 14: (8, 1), 20: (8, 2), 21: (8, 2), 41: (8, 4), 42: (8, 4), 55: (8, 4), 56: (8, 4),
      74: (16, 1), 75: (16, 1), 81: (16, 2), 82: (16, 2), 95: (16, 4), 96: (16, 4),
      98: (32, 1), 99: (32, 1), 100: (32, 1), 101: (32, 2), 102: (32, 2), 103: (32, 2),
      107: (32, 4), 108: (32, 4), 109: (32, 4)}
for f, (w, n) in P2.items():
    FMT[f] = (2, w * n // 8, (1 << n) - 1)
FMT[68] = (2, 4, 0xF)
PATH2_FORMATS = sorted(list(P2) + [68])
PATH0_TB = [37, 44, 51, 9, 16]      # formats the testbench blend model writes
PATH1_TB = [64]                     # formats the fblend stub writes
M128 = (1 << 128) - 1


def fmt_info(f):
    """-> (sup, ps, path, chm); unsupported: (0, 0, 3, 0)."""
    if f in FMT:
        p, ps, chm = FMT[f]
        return 1, ps, p, chm
    return 0, 0, 3, 0


def lps_of(ps):
    return {1: 0, 2: 1, 4: 2, 8: 3, 16: 4}.get(ps, 0)


def resolve_fmt(st, rt):
    fb = (st.get(S_RT_FORMATS, 0) >> (8 * rt)) & 0xFF
    if rt == 0 and fb == 0:
        code = st.get(S_RT_FORMAT, 0)
        return {0: 44, 1: 37, 2: 4, 3: 4}.get(code, 0)
    return fb


def pack2(src, f, wm):
    """src: 4 x 32-bit words.  -> (raw, keep) 128-bit ints (path 2; else (0, all ones))."""
    raw, keep = 0, M128
    if f == 68:
        wr = [(wm >> c) & 1 for c in range(4)]
        raw = (src[0] & 0x3FF) | (src[1] & 0x3FF) << 10 | (src[2] & 0x3FF) << 20 | (src[3] & 3) << 30
        k = 0
        for c, (lo, w) in enumerate(((0, 10), (10, 10), (20, 10), (30, 2))):
            if not wr[c]:
                k |= ((1 << w) - 1) << lo
        keep = (M128 & ~0xFFFFFFFF) | k
    elif f in P2:
        w, n = P2[f]
        keep = M128
        for c in range(n):
            raw |= (src[c] & ((1 << w) - 1)) << (w * c)
            if (wm >> c) & 1:
                keep &= ~(((1 << w) - 1) << (w * c))
    return raw, keep


def words(color512, lane):
    v = (color512 >> (128 * lane)) & M128
    return [(v >> (32 * c)) & 0xFFFFFFFF for c in range(4)]


# ---------------------------------------------------------------- path 0 (TB model)
def _unpack8(f, old):
    """old pixel -> channels [R, G, B, A] (8-bit), None where the format lacks it."""
    b = [(old >> (8 * i)) & 0xFF for i in range(4)]
    if f in (37, 51):
        return [b[0], b[1], b[2], b[3]]
    if f == 44:
        return [b[2], b[1], b[0], b[3]]
    if f == 9:
        return [b[0], None, None, None]
    if f == 16:
        return [b[0], b[1], None, None]
    return None


def _pack8(f, ch):
    if f in (37, 51):
        return ch[0] | ch[1] << 8 | ch[2] << 16 | ch[3] << 24
    if f == 44:
        return ch[2] | ch[1] << 8 | ch[0] << 16 | ch[3] << 24
    if f == 9:
        return ch[0]
    if f == 16:
        return ch[0] | ch[1] << 8
    return 0


def path0_pix(f, src, old, wm, blend_en):
    """The testbench blend model (one lane): new 32-bit lane (unused formats: old)."""
    d = _unpack8(f, old)
    if d is None:
        return old
    out = []
    for c in range(4):
        if d[c] is None:
            out.append(0)
            continue
        s = f2u8(src[c])
        v = min(255, s + d[c]) if blend_en else s
        out.append(v if (wm >> c) & 1 else d[c])
    return _pack8(f, out)


# ---------------------------------------------------------------- path 1 (stub)
def path1_raw_keep(f, src, wm):
    """The fblend stub (one active lane): (raw, keep) 64-bit."""
    if f != 64:
        return 0, (1 << 64) - 1
    raw = f2unorm(src[0], 10) | f2unorm(src[1], 10) << 10 | f2unorm(src[2], 10) << 20 | f2unorm(src[3], 2) << 30
    k = 0
    for c, (lo, w) in enumerate(((0, 10), (10, 10), (20, 10), (30, 2))):
        if not (wm >> c) & 1:
            k |= ((1 << w) - 1) << lo
    return raw, (((1 << 64) - 1) & ~0xFFFFFFFF) | k


# ---------------------------------------------------------------- wpix outputs
def old_pixel(line, soff, ps):
    blk = (line >> (128 * (soff >> 4))) & M128
    if ps >= 16:
        return blk
    bo = (soff & 15) & ~(ps - 1)
    return (blk >> (8 * bo)) & ((1 << (8 * ps)) - 1)


def wpix_eval(st, rt, xy, smask, color, r, j, g, off0, off1, line0, line1, bpix, LB):
    """All combinational outputs of ad_rop_wpix (LINE_BYTES = LB)."""
    LS = LB.bit_length() - 1
    f = resolve_fmt(st, rt)
    sup, ps, path, chm = fmt_info(f)
    lps = lps_of(ps)
    wm = (st.get(S_WRITE_MASK, 0) >> (4 * rt)) & 0xF
    blend = st.get(S_BLENDK[rt], 0)
    s4 = (st.get(S_MS_CTRL, 0) & 0xF) == 2
    S = 4 if s4 else 1
    base = st.get(S_RTK_BASE[rt], 0)
    stride = st.get(S_RTK_STRIDE[rt], 0)
    x, y = xy & 0xFFFF, xy >> 16
    sm = smask if s4 else smask & 0x1111
    rowl = 1 + (2 if s4 else 0) + lps
    multi = rowl > LS
    nl = ((1 << (rowl - LS)) - 1) if multi else 0
    np_ = 3 if s4 else 0
    addr = (base + (y + r) * stride + (x << (lps + (2 if s4 else 0))) + ((j << LS) if multi else 0)) & 0xFFFFFFFF
    drop = int((not sup) or (chm & wm) == 0)
    read = int(((blend & 1) and path in (0, 1)) or (chm & ~wm & 0xF) != 0)
    rbits = (sm >> (8 * r)) & 0xFF
    mask, ent, soff, lane = [0] * 4, [0] * 4, [0] * 4, [0] * 4
    for k in range(4):
        if multi:
            le = LS - lps
            n = ((j << le) + k) & 0xF
            ent[k] = r
            lane[k] = (r << 1) | ((n >> 2) & 1)
            if k < (1 << le):
                mask[k] = (rbits >> (n & 7)) & 1
                soff[k] = (k << lps) & (LB - 1)
        else:
            ent[k] = k >> 1
            lane[k] = k
            mask[k] = (sm >> (4 * k + g)) & 1
            o = off1 if (k >> 1) else off0
            soff[k] = (o + (((4 * (k & 1)) if s4 else (k & 1)) + g << lps)) & (LB - 1)
    lw = int(any(mask)) if multi else int(rbits != 0)
    old = [old_pixel(line1 if ent[k] else line0, soff[k], ps if ps else 1) for k in range(4)]
    bdst = sum((old[k] & 0xFFFFFFFF) << (32 * k) for k in range(4))
    res = 0
    chk_res = 1
    for k in range(4):
        src = words(color, lane[k])
        if path == 0:
            v = (bpix >> (32 * k)) & 0xFFFFFFFF
        elif path == 2:
            raw, keep = pack2(src, f, wm)
            v = (raw & ~keep & M128) | (old[k] & keep)
        else:
            v = 0
            chk_res = 0
        res |= v << (128 * k)
    return dict(addr=addr, nl=nl, np=np_, multi=int(multi), drop=drop, read=read, path=path, lw=lw,
                mask=sum(mask[k] << k for k in range(4)), ent=sum(ent[k] << k for k in range(4)),
                soff=soff, ps=ps, bdst=bdst, res=res, chk_res=chk_res)


# ---------------------------------------------------------------- memory image
def apply_beat(mem, st, rt, xy, smask, color, nocol=False):
    """Apply one beat to mem (bytearray, address = index) as ad_rop_wb + the TB paths do."""
    if nocol:
        return
    f = resolve_fmt(st, rt)
    sup, ps, path, chm = fmt_info(f)
    wm = (st.get(S_WRITE_MASK, 0) >> (4 * rt)) & 0xF
    if not sup or (chm & wm) == 0:
        return
    blend_en = st.get(S_BLENDK[rt], 0) & 1
    s4 = (st.get(S_MS_CTRL, 0) & 0xF) == 2
    S = 4 if s4 else 1
    base = st.get(S_RTK_BASE[rt], 0)
    stride = st.get(S_RTK_STRIDE[rt], 0)
    x, y = xy & 0xFFFF, xy >> 16
    for lane in range(4):
        for s in range(S):
            if not (smask >> (4 * lane + s)) & 1:
                continue
            px = x + (lane & 1)
            py = y + (lane >> 1)
            a = (base + py * stride + (S * px + s) * ps) & 0xFFFFFFFF
            old = int.from_bytes(mem[a:a + ps], "little")
            src = words(color, lane)
            if path == 0:
                new = path0_pix(f, src, old, wm, blend_en) & ((1 << (8 * ps)) - 1)
            elif path == 1:
                raw, keep = path1_raw_keep(f, src, wm)
                new = ((raw & ~keep) | (old & keep)) & ((1 << (8 * ps)) - 1)
            else:
                raw, keep = pack2(src, f, wm)
                new = ((raw & ~keep) | (old & keep)) & ((1 << (8 * ps)) - 1)
            mem[a:a + ps] = new.to_bytes(ps, "little")


def init_byte(i, seed):
    """Initial memory pattern (the testbenches compute the same)."""
    return (i * 131 + seed * 17 + (i >> 7) * 29) & 0xFF
