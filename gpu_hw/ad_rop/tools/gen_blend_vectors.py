"""gen_blend_vectors.py -- vectors for ad_rop_blend's TBs (ad_rop_blend_tb, ad_rop_logicop_tb,
ad_rop_dualsrc_tb) from tools/blend_model.py.  Writes sim/vec/blend_<section>.hex.

One record (one clock cycle) per line, 1344 bits = 336 hex digits, MSB first:
  [1343:1328] ctl: [0] b_valid [1] b_has_src1 [3:2] b_rt [7:4] b_mask [8] st_we [15] end marker
  [1327:1312] st_idx   [1311:1280] st_wdata
  [1279:1152] b_dst    [1151:640] b_src    [639:128] b_src1   [127:0] expected b_pix
The expected b_pix is checked LAT=3 cycles later.  A STATE write in the same record as a beat
takes effect for the following beats only (the beat uses the old state); most writes are put
in the record of the preceding beat so that beats stay back to back.
Each file starts from reset state (the TB resets the DUT before each section).
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import blend_model as bm  # noqa: E402
from admodel import f2b, rand_f32, QNAN  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'sim', 'vec')
M32 = 0xFFFFFFFF


class Gen:
    def __init__(self, seed):
        self.rng = np.random.default_rng(seed)
        self.m = bm.BlendModel()
        self.rec = []
        self.pend = None       # STATE write to attach to the next record
        self.beats = 0

    # ---------------- random data ----------------
    def ri(self, n):
        return int(self.rng.integers(0, n))

    def rsrc(self):
        r = self.rng.random()
        if r < 0.45:   # exact k/255 (rounded to fp32)
            return f2b(float(np.float32(self.ri(256) / 255.0)))
        if r < 0.75:
            return f2b(float(np.float32(self.rng.random())))
        if r < 0.80:   # near a rounding half-way point
            return f2b(float(np.float32((self.ri(255) + 0.5) / 255.0))) + self.ri(3) - 1
        return rand_f32(self.rng, 0.15)

    def rdst(self):
        return self.ri(1 << 32)

    def rblend(self, en=None, msb=False):
        w = self.ri(1 << 23)
        if msb:
            w |= self.ri(16) << 23
        if en is not None:
            w = (w & ~1) | int(en)
        return w

    # ---------------- records ----------------
    def write(self, idx, data):
        """STATE write seen by every following beat: put in the previous record (same cycle as
        that record's beat, which still uses the old state) when it has no write, else in an
        idle record."""
        data &= M32
        if self.pend is not None:
            self.idle()
        if self.rec and not (self.rec[-1] >> 1336) & 1:
            self.rec[-1] |= 1 << 1336 | idx << 1312 | data << 1280
            self.m.write(idx, data)
        else:
            self.pend = (idx, data)
            self.idle()

    def _emit(self, ctl, dst=(0,) * 4, src=(0,) * 16, src1=(0,) * 16, exp=(0,) * 4):
        sw = self.pend
        self.pend = None
        if sw is not None:
            ctl |= 1 << 8
        v = ctl << 1328
        if sw is not None:
            v |= sw[0] << 1312 | sw[1] << 1280
        for l in range(4):
            v |= (dst[l] & M32) << (1152 + 32 * l)
            v |= (exp[l] & M32) << (32 * l)
        for i in range(16):
            v |= (src[i] & M32) << (640 + 32 * i)
            v |= (src1[i] & M32) << (128 + 32 * i)
        self.rec.append(v)
        if sw is not None:
            self.m.write(*sw)

    def idle(self, n=1):
        for _ in range(n):
            self._emit(0)

    def beat(self, rt=None, mask=None, src=None, src1=None, has1=None, dst=None):
        rt = self.ri(4) if rt is None else rt
        mask = (0xF if self.rng.random() < 0.7 else self.ri(16)) if mask is None else mask
        src = [self.rsrc() for _ in range(16)] if src is None else src
        has1 = self.ri(2) if has1 is None else has1
        src1 = [self.rsrc() for _ in range(16)] if src1 is None else src1
        dst = [self.rdst() for _ in range(4)] if dst is None else dst
        exp = self.m.beat(src, src1, has1, dst, mask, rt)   # state before this cycle's write
        self._emit(1 | has1 << 1 | rt << 2 | mask << 4, dst, src, src1, exp)
        self.beats += 1

    def save(self, name):
        if self.pend is not None:
            self.idle()
        self._emit(1 << 15)
        p = os.path.join(OUT, 'blend_%s.hex' % name)
        with open(p, 'w') as f:
            for v in self.rec:
                f.write('%0336x\n' % v)
        print('%-24s %5d records %5d beats' % (os.path.basename(p), len(self.rec), self.beats))
        return self.beats


ALLFMT = bm.FORMATS
BADFMT = (0, 43, 50, 57, 64, 97, 1, 255)
FP_SPECIAL = (0, 0x80000000, 0x3F800000, 0xBF800000, 0x40000000, 0x7F800000, 0xFF800000, QNAN,
              0x7F800001, 0xFFC00000, 0x00000001, 0x807FFFFF, 0x3F000000, 0x3A800000, 0x3A7FFFFF,
              0x7F7FFFFF, 0xC2C80000, 0x3F7FFFFF)


def fmts_word(g, pool):
    return sum(int(g.rng.choice(pool)) << (8 * k) for k in range(4))


# =============================================================== ad_rop_blend_tb
def sec_formats():
    g = Gen(101)
    g.write(bm.S_ROP_CTRL, 0)
    for seg in range(60):
        pool = ALLFMT + BADFMT[:2] if seg % 3 else ALLFMT
        fw = fmts_word(g, pool)
        if seg % 5 == 0:
            fw &= ~0xFF                      # RT0 from the legacy RT_FORMAT code
            g.write(bm.S_RT_FORMAT, int(g.rng.choice([0, 1, 2, 3, 3, 5])))
        g.write(bm.S_RT_FORMATS, fw)
        g.write(bm.S_WRITE_MASK, 0xFFFF if seg % 2 else g.ri(1 << 16))
        for k, idx in enumerate((bm.S_BLEND, bm.S_BLEND1, bm.S_BLEND2, bm.S_BLEND3)):
            g.write(idx, g.rblend(en=(seg % 4 != 0) and g.ri(4) != 0, msb=True))
        g.write(bm.S_BLEND_CONST, g.ri(1 << 32))
        for _ in range(25):
            g.beat()
            if g.rng.random() < 0.08:        # STATE write in the same cycle as a beat
                g.pend = (int(g.rng.choice([bm.S_WRITE_MASK, bm.S_BLEND, bm.S_BLEND2])), g.ri(1 << 27))
    return g.save('formats')


def sec_factors():
    g = Gen(102)
    g.write(bm.S_RT_FORMATS, bm.VK_RGBA8 | bm.VK_BGRA8 << 8 | bm.VK_ABGR8 << 16 | bm.VK_RGBA8 << 24)
    g.write(bm.S_WRITE_MASK, 0xFFFF)
    g.write(bm.S_BLEND_CONST, g.ri(1 << 32))
    col = [(sf, df, op) for sf in range(15) for df in range(15) for op in range(8)]
    alp = list(col)
    g.rng.shuffle(alp)
    idxs = (bm.S_BLEND, bm.S_BLEND1, bm.S_BLEND2, bm.S_BLEND3)
    cfg = []
    for (sf, df, op), (sa, da, aop) in zip(col, alp):
        cfg.append(1 | sf << 1 | df << 5 | op << 9 | sa << 12 | da << 16 | aop << 20 | g.ri(16) << 23)
    # cycle i: beat with cfg[i] on rt i%4, and (same cycle) BLEND of rt (i+1)%4 := cfg[i+1]
    g.write(idxs[0], cfg[0])
    for i, w in enumerate(cfg):
        if i + 1 < len(cfg):
            g.pend = (idxs[(i + 1) % 4], cfg[i + 1])
        if i % 97 == 50:
            g.beat(rt=i % 4, mask=0xF)
            g.write(bm.S_BLEND_CONST, g.ri(1 << 32))
            g.pend = None if i + 1 >= len(cfg) else (idxs[(i + 1) % 4], cfg[i + 1])
            continue
        g.beat(rt=i % 4, mask=0xF)
    return g.save('factors')


def sec_r8rg8():
    g = Gen(103)
    g.write(bm.S_WRITE_MASK, 0xFFFF)
    for fmt in (bm.VK_R8, bm.VK_R8G8, bm.VK_A1R5G5B5):
        g.write(bm.S_RT_FORMATS, fmt * 0x01010101)
        for sf in range(15):
            g.write(bm.S_BLEND_CONST, g.ri(1 << 32))
            for df in range(15):
                rt = g.ri(4)
                w = 1 | sf << 1 | df << 5 | g.ri(8) << 9 | g.ri(15) << 12 | g.ri(15) << 16 | g.ri(8) << 20
                g.write((bm.S_BLEND, bm.S_BLEND1, bm.S_BLEND2, bm.S_BLEND3)[rt], w)
                g.beat(rt=rt)
                # alpha factor sweep too (A1R5G5B5 has an alpha)
                w2 = 1 | g.ri(15) << 1 | g.ri(15) << 5 | g.ri(8) << 9 | sf << 12 | df << 16 | g.ri(8) << 20
                g.write((bm.S_BLEND, bm.S_BLEND1, bm.S_BLEND2, bm.S_BLEND3)[rt], w2)
                g.beat(rt=rt)
        # random write masks with these formats
        for _ in range(40):
            g.write(bm.S_WRITE_MASK, g.ri(1 << 16))
            g.write(bm.S_BLEND1, g.rblend())
            g.beat(rt=1)
        g.write(bm.S_WRITE_MASK, 0xFFFF)
    return g.save('r8rg8')


def fp_const(g):
    r = g.rng.random()
    if r < 0.35:
        return int(g.rng.choice(FP_SPECIAL))
    if r < 0.6:
        return f2b(float(np.float32(g.ri(256) / 255.0)))
    if r < 0.75:
        return f2b(float(np.float32((g.ri(255) + 0.5) / 255.0))) + g.ri(3) - 1
    if r < 0.85:
        return f2b(float(np.float32(-g.rng.random() * 2)))
    if r < 0.92:
        return f2b(float(np.float32(1 + g.rng.random() * 100)))
    return rand_f32(g.rng, 0.2)


def sec_const():
    g = Gen(104)
    g.write(bm.S_RT_FORMATS, bm.VK_RGBA8 | bm.VK_BGRA8 << 8 | bm.VK_A1R5G5B5 << 16 | bm.VK_R5G6B5 << 24)
    g.write(bm.S_WRITE_MASK, 0xFFFF)
    cfac = (10, 11, 12, 13)
    for seg in range(80):
        order = g.ri(3)
        if order == 0:
            g.write(bm.S_ROP_CTRL, (seg & 1) << 1)
        for i in range(4):
            if g.rng.random() < 0.8:
                g.write(bm.S_BCONST_F[i], fp_const(g))
        if order == 1:
            g.write(bm.S_ROP_CTRL, (seg & 1) << 1)
        g.write(bm.S_BLEND_CONST, g.ri(1 << 32))
        if order == 2:
            g.write(bm.S_ROP_CTRL, ((seg >> 1) & 1) << 1)
        for k, idx in enumerate((bm.S_BLEND, bm.S_BLEND1, bm.S_BLEND2, bm.S_BLEND3)):
            w = (1 | int(g.rng.choice(cfac)) << 1 | int(g.rng.choice(cfac + (0, 1, 2))) << 5 | g.ri(3) << 9
                 | int(g.rng.choice(cfac)) << 12 | int(g.rng.choice(cfac + (0, 1))) << 16 | g.ri(3) << 20)
            g.write(idx, w)
        for _ in range(8):
            g.beat()
            if g.rng.random() < 0.15:   # fp constant changes in the same cycle as a beat
                g.pend = (bm.S_BCONST_F[g.ri(4)], fp_const(g))
    return g.save('const')


# =============================================================== ad_rop_logicop_tb
def lop_word(g, ops=None, en=None):
    w = 0
    for k in range(4):
        e = g.ri(2) if en is None else en[k]
        o = g.ri(16) if ops is None else ops[k]
        w |= (e | o << 1 | g.ri(8) << 5) << (8 * k)   # bits [7:5] of each byte: junk, ignored
    return w


def sec_lop_all16():
    g = Gen(201)
    g.write(bm.S_RT_FORMATS, bm.VK_RGBA8 * 0x01010101)
    g.write(bm.S_WRITE_MASK, 0xFFFF)
    for op in range(16):
        for half in range(2):
            if half == 0:     # per-RT enable
                g.write(bm.S_ROP_CTRL, 0)
                g.write(bm.S_LOGIC_OP, lop_word(g, ops=[op] * 4, en=[1] * 4))
            else:             # global ROP_CTRL[2], per-RT enable bits 0
                g.write(bm.S_ROP_CTRL, 4)
                g.write(bm.S_LOGIC_OP, lop_word(g, ops=[op] * 4, en=[0] * 4))
            for idx in (bm.S_BLEND, bm.S_BLEND1, bm.S_BLEND2, bm.S_BLEND3):
                g.write(idx, g.rblend(en=g.ri(2)))   # blend must be ignored
            for _ in range(20):
                d = [g.rdst() for _ in range(4)]
                if g.rng.random() < 0.3:   # truth-table corners: s/d all 0 or all 1
                    d = [int(g.rng.choice([0, M32])) for _ in range(4)]
                    s = [int(g.rng.choice([0, 0x3F800000])) for _ in range(16)]
                    g.beat(mask=0xF, src=s, dst=d)
                else:
                    g.beat(mask=0xF, dst=d)
    return g.save('lop_all16')


def sec_lop_masks():
    g = Gen(202)
    g.write(bm.S_ROP_CTRL, 0)
    for seg in range(40):
        g.write(bm.S_RT_FORMATS, fmts_word(g, ALLFMT))
        g.write(bm.S_LOGIC_OP, lop_word(g, en=[1, 1, 1, g.ri(2)]))
        g.write(bm.S_WRITE_MASK, g.ri(1 << 16))
        for _ in range(20):
            g.beat(mask=g.ri(16))
            if g.rng.random() < 0.15:
                g.pend = (bm.S_WRITE_MASK, g.ri(1 << 16))
    return g.save('lop_masks')


def sec_lop_indep():
    g = Gen(203)
    for seg in range(25):
        g.write(bm.S_ROP_CTRL, 0)
        g.write(bm.S_RT_FORMATS, fmts_word(g, ALLFMT))
        g.write(bm.S_WRITE_MASK, 0xFFFF if seg % 2 else g.ri(1 << 16))
        en = [g.ri(2) for _ in range(4)]
        if sum(en) in (0, 4):
            en[g.ri(4)] ^= 1                  # mix of blending and logic-op RTs
        g.write(bm.S_LOGIC_OP, lop_word(g, en=en))
        for idx in (bm.S_BLEND, bm.S_BLEND1, bm.S_BLEND2, bm.S_BLEND3):
            g.write(idx, g.rblend(en=g.ri(4) != 0))
        g.write(bm.S_BLEND_CONST, g.ri(1 << 32))
        for _ in range(40):
            g.beat()                          # random rt each cycle, back to back
            if g.rng.random() < 0.05:
                g.pend = (bm.S_LOGIC_OP, lop_word(g, en=en))
    return g.save('lop_indep')


def sec_lop_formats():
    g = Gen(204)
    g.write(bm.S_WRITE_MASK, 0xFFFF)
    for fmt in (bm.VK_BGRA8, bm.VK_RGBA8, bm.VK_R8, bm.VK_R8G8, bm.VK_R5G6B5, bm.VK_A1R5G5B5,
                bm.VK_ABGR8, 43):
        g.write(bm.S_RT_FORMATS, fmt * 0x01010101)
        for op in range(16):
            g.write(bm.S_LOGIC_OP, lop_word(g, ops=[op] * 4, en=[1] * 4))
            for _ in range(5):
                g.beat()
        g.write(bm.S_RT_FORMATS, 0)            # RT0 by the legacy code
        for code in (0, 1, 2, 3):
            g.write(bm.S_RT_FORMAT, code)
            for _ in range(8):
                g.write(bm.S_LOGIC_OP, lop_word(g, en=[1] * 4))
                g.beat(rt=0)
    return g.save('lop_formats')


# =============================================================== ad_rop_dualsrc_tb
def ds_word(g, sf, df, sa, da, cop=None, aop=None):
    return (1 | (sf & 15) << 1 | (df & 15) << 5 | (g.ri(8) if cop is None else cop) << 9
            | (sa & 15) << 12 | (da & 15) << 16 | (g.ri(8) if aop is None else aop) << 20
            | (sf >> 4) << 23 | (df >> 4) << 24 | (sa >> 4) << 25 | (da >> 4) << 26)


def sec_ds_factors():
    g = Gen(301)
    g.write(bm.S_RT_FORMATS, bm.VK_RGBA8 | bm.VK_BGRA8 << 8 | bm.VK_ABGR8 << 16 | bm.VK_RGBA8 << 24)
    g.write(bm.S_WRITE_MASK, 0xFFFF)
    g.write(bm.S_BLEND_CONST, g.ri(1 << 32))
    idxs = (bm.S_BLEND, bm.S_BLEND1, bm.S_BLEND2, bm.S_BLEND3)
    # ROP_CTRL[7] = 1: every pair of 0..18 (colour) with random alpha factors 0..18 / 19..31
    g.write(bm.S_ROP_CTRL, 0x80)
    for sf in range(19):
        for df in range(19):
            rt = g.ri(4)
            sa = g.ri(19) if g.rng.random() < 0.9 else 19 + g.ri(13)
            da = g.ri(19) if g.rng.random() < 0.9 else 19 + g.ri(13)
            g.write(idxs[rt], ds_word(g, sf, df, sa, da))
            g.beat(rt=rt, mask=0xF)
            g.write(idxs[rt], ds_word(g, g.ri(32), g.ri(32), sf, df))   # alpha sweep, colour incl. 19..31
            g.beat(rt=rt, mask=0xF)
    # ROP_CTRL[7] = 0: factors 15..18 read ZERO (the MSBs are ignored; 15 itself is ZERO)
    g.write(bm.S_ROP_CTRL, 0x00)
    for i in range(300):
        rt = g.ri(4)
        f = [15 + g.ri(4) for _ in range(4)]
        if i % 3 == 0:
            f = [15, 16, 17, 18]
        g.write(idxs[rt], ds_word(g, f[0], f[1], f[2], f[3]))
        g.beat(rt=rt, mask=0xF, has1=1)
    # toggle ROP_CTRL[7] while beats are in flight
    for i in range(200):
        rt = g.ri(4)
        g.write(idxs[rt], ds_word(g, 15 + g.ri(4), 15 + g.ri(4), 15 + g.ri(4), 15 + g.ri(4)))
        g.beat(rt=rt, mask=0xF)
        g.pend = (bm.S_ROP_CTRL, (g.ri(2) << 7) | (g.ri(2) << 1))
    return g.save('ds_factors')


def sec_ds_font():
    g = Gen(302)
    g.write(bm.S_ROP_CTRL, 0x80)
    g.write(bm.S_RT_FORMATS, bm.VK_BGRA8 | bm.VK_RGBA8 << 8 | bm.VK_R5G6B5 << 16 | bm.VK_ABGR8 << 24)
    g.write(bm.S_WRITE_MASK, 0xFFFF)
    for k, idx in enumerate((bm.S_BLEND, bm.S_BLEND1, bm.S_BLEND2, bm.S_BLEND3)):
        # C = C_text * M + C_dst * (1 - M); alpha: SRC1_ALPHA / ONE_MINUS_SRC1_ALPHA or ONE / ZERO
        sa, da = ((17, 18), (1, 0), (1, 9), (17, 18))[k]
        g.write(idx, ds_word(g, 15, 16, sa, da, cop=0, aop=0))
    for i in range(500):
        text = [f2b(float(np.float32(g.ri(256) / 255.0))) for _ in range(4)]
        src = text * 4 if i % 2 else [g.rsrc() for _ in range(16)]   # one text colour per quad
        cov = [g.rsrc() for _ in range(16)]                          # subpixel coverage
        g.beat(src=src, src1=cov, has1=1 if i % 10 else 0)
    return g.save('ds_font')


def sec_ds_masks():
    g = Gen(303)
    g.write(bm.S_ROP_CTRL, 0x80)
    for seg in range(30):
        g.write(bm.S_RT_FORMATS, fmts_word(g, ALLFMT))
        g.write(bm.S_WRITE_MASK, g.ri(1 << 16))
        for idx in (bm.S_BLEND, bm.S_BLEND1, bm.S_BLEND2, bm.S_BLEND3):
            g.write(idx, ds_word(g, 15 + g.ri(4), 15 + g.ri(4), 15 + g.ri(4), g.ri(19)))
        for _ in range(20):
            g.beat(mask=g.ri(16))
    return g.save('ds_masks')


def sec_ds_formats():
    g = Gen(304)
    g.write(bm.S_ROP_CTRL, 0x80)
    g.write(bm.S_WRITE_MASK, 0xFFFF)
    for fmt in (bm.VK_RGBA8, bm.VK_BGRA8, bm.VK_ABGR8, bm.VK_R8, bm.VK_R8G8, bm.VK_R5G6B5,
                bm.VK_A1R5G5B5, 97):
        g.write(bm.S_RT_FORMATS, fmt * 0x01010101)
        for _ in range(12):
            for idx in (bm.S_BLEND, bm.S_BLEND1, bm.S_BLEND2, bm.S_BLEND3):
                g.write(idx, ds_word(g, g.ri(19), g.ri(19), g.ri(19), g.ri(19)))
            for _ in range(6):
                g.beat()
    return g.save('ds_formats')


if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    total = 0
    for fn in (sec_formats, sec_factors, sec_r8rg8, sec_const, sec_lop_all16, sec_lop_masks,
               sec_lop_indep, sec_lop_formats, sec_ds_factors, sec_ds_font, sec_ds_masks,
               sec_ds_formats):
        total += fn()
    print('total beats', total)
