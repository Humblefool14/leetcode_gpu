"""gen_rop_sys_vectors.py -- system-level vectors for sim/tb/ad_rop_sys_tb.v.

Composes the per-block reference models (ms_model.MsModel, ds_model.DSModel,
blend_model.BlendModel) and a format-level write-back model into one model of
the whole ad_rop: quads in primitive order -> coverage/depth -> depth/stencil ->
colour attachments in memory.  Writes:
  sim/vec/sys_cmd.hex   one 900-bit command per line (see FIELDS)
  sim/vec/sys_init.hex  initial memory, one byte per line
  sim/vec/sys_exp.hex   expected final memory, one byte per line
  sim/vec/sys_occ.hex   expected occlusion count (40 bits)
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from admodel import f2b                               # noqa: E402
from ms_model import MsModel                          # noqa: E402
from ds_model import DSModel                          # noqa: E402
from blend_model import BlendModel                    # noqa: E402

MEM = 32 * 1024
OUT = os.path.join(os.path.dirname(__file__), "..", "sim", "vec")
rng = np.random.default_rng(int(os.environ.get("SEED", "7")))

# STATE indices (rtl/include/ad_rop_state.vh)
VP_ZS, VP_ZO, DCLAMP, MS_CTRL = 0x054, 0x055, 0x059, 0x05E
RT_BASE, RT_STRIDE, RT_FORMAT, DS_BASE, DS_STRIDE, DEBUG_COLOR = 0x070, 0x071, 0x072, 0x073, 0x074, 0x075
DEPTH, SFRONT, SOPS, SBACK, BLEND, BCONST, WMASK, RT_FORMATS = 0x076, 0x077, 0x078, 0x079, 0x07A, 0x07B, 0x07C, 0x07D
RTN_BASE = {1: 0x07E, 2: 0x080, 3: 0x082}
BLENDN = {1: 0x084, 2: 0x085, 3: 0x086}
DBMIN, DBMAX, ROP_CTRL, LOGIC_OP = 0x08B, 0x08C, 0x08D, 0x08E

PATH0 = {37: 4, 44: 4, 51: 4, 4: 2, 8: 2, 9: 1, 16: 2}          # unorm8 path, ps
PATH2 = {98: (4, 1, 32), 107: (16, 4, 32), 41: (4, 4, 8)}         # ps, channels, bits


class RopModel:
    def __init__(self, mem):
        self.mem = mem
        self.st = {}
        self.ms = MsModel()
        self.ds = DSModel(mem, stencil=1)
        self.bl = BlendModel()
        self.occ = 0

    def state(self, idx, val):
        val &= 0xFFFFFFFF
        self.st[idx] = val
        self.ms.state(idx, val)
        self.ds.write_state(idx, val)
        self.bl.write(idx, val)

    def g(self, i):
        return self.st.get(i, 0)

    def beat(self, xy, mask, color, depth, dbg, aux):
        o = self.ms.beat(xy, mask, color, depth, dbg, aux)
        if o is None:
            return
        d = self.ds.quad(o)
        if d is None:
            return
        if d["beat"] & 1 and (self.g(ROP_CTRL) & 1):
            self.occ += bin(d["smask"]).count("1")
        self.wb(d)

    # ---- write-back of one beat (formats used by the scenes) ----
    def wb(self, d):
        rt, nocol = (d["beat"] >> 2) & 3, (d["beat"] >> 1) & 1
        if nocol:
            return
        sel = self.bl.sel(rt)
        fmt, wm = sel["fmt"], sel["wm"]
        base = self.g(RT_BASE) if rt == 0 else self.g(RTN_BASE[rt])
        stride = self.g(RT_STRIDE) if rt == 0 else self.g(RTN_BASE[rt] + 1)
        S = 4 if (self.g(MS_CTRL) & 0xF) == 2 else 1
        x, y = d["xy"] & 0xFFFF, d["xy"] >> 16
        col = d["color"]
        words = [(col >> (32 * i)) & 0xFFFFFFFF for i in range(16)]

        def addr(l, s, ps):
            return base + (y + (l >> 1)) * stride + (S * (x + (l & 1)) + s) * ps

        if fmt in PATH0:
            ps = PATH0[fmt]
            for s in range(S):
                m = 0
                dst = [0, 0, 0, 0]
                for l in range(4):
                    if (d["smask"] >> (4 * l + s)) & 1:
                        m |= 1 << l
                        a = addr(l, s, ps)
                        dst[l] = int.from_bytes(self.mem[a:a + ps], "little")
                if m == 0:
                    continue
                pix = self.bl.beat(words, [0] * 16, 0, dst, m, rt)
                for l in range(4):
                    if (m >> l) & 1:
                        a = addr(l, s, ps)
                        self.mem[a:a + ps] = (pix[l] & ((1 << (8 * ps)) - 1)).to_bytes(ps, "little")
        elif fmt in PATH2:
            ps, nch, bits = PATH2[fmt]
            if not any((wm >> c) & 1 for c in range(nch)):
                return
            for l in range(4):
                for s in range(S):
                    if not (d["smask"] >> (4 * l + s)) & 1:
                        continue
                    a = addr(l, s, ps)
                    old = int.from_bytes(self.mem[a:a + ps], "little")
                    new = old
                    for c in range(nch):
                        if (wm >> c) & 1:
                            fm = ((1 << bits) - 1) << (bits * c)
                            v = (words[4 * l + c] & ((1 << bits) - 1)) << (bits * c)
                            new = (new & ~fm) | v
                    self.mem[a:a + ps] = new.to_bytes(ps, "little")
        # any other format: dropped (absent attachment)


# ------------------------------------------------------------------ commands
def rec(t, seq=0, xy=0, mask=0, last=0, aux=0, color=0, depth=0, idx=0, data=0):
    v = t
    v = (v << 16) | seq
    v = (v << 32) | xy
    v = (v << 4) | mask
    v = (v << 4) | last
    v = (v << 156) | aux
    v = (v << 512) | color
    v = (v << 128) | depth
    v = (v << 12) | idx
    v = (v << 32) | data
    return "%0225x" % v


cmds = []
mem = bytearray(int(x) for x in rng.integers(0, 256, MEM))
init = bytearray(mem)          # the TB's starting image (fill_depth writes both)
model = RopModel(mem)


def st(idx, val):
    model.state(idx, val)
    cmds.append(rec(1, idx=idx, data=val & 0xFFFFFFFF))


def idle():
    cmds.append(rec(5))


def fill_depth(base, stride, rows, row_bytes, lo=0.6, hi=1.0, d24=False):
    for r in range(rows):
        for b in range(0, row_bytes, 4):
            z = float(rng.uniform(lo, hi))
            w = int(round(z * 0xFFFFFF)) | (int(rng.integers(0, 256)) << 24) if d24 else f2b(np.float32(z))
            a = base + r * stride + b
            mem[a:a + 4] = w.to_bytes(4, "little")
            init[a:a + 4] = w.to_bytes(4, "little")


def rcolor(alpha_lo=0.0):
    c = 0
    for i in range(16):
        f = float(rng.uniform(alpha_lo if i % 4 == 3 else 0.0, 1.0))
        c |= f2b(np.float32(f)) << (32 * i)
    return c


def rint_color():
    return int.from_bytes(rng.integers(0, 256, 64, dtype=np.uint8).tobytes(), "little")


def aux_of(rt=0, qlast=1, qfirst=1, nocol=0, front=1, ds=0, zexp=0, smask=0x1111):
    return (rt << 152) | (qlast << 151) | (qfirst << 150) | (nocol << 149) | (front << 148) | \
           (ds << 20) | (zexp << 16) | smask


def depth4(lo=0.0, hi=1.0):
    return sum(f2b(np.float32(rng.uniform(lo, hi))) << (32 * l) for l in range(4))


seq = 0


def prim(quads, direct=False):
    """quads: list of beats (xy, mask, color, depth, aux, last flag set on the final beat)."""
    global seq
    cmds.append(rec(2, seq=seq))
    for i, (xy, mask, color, depth, aux) in enumerate(quads):
        last = int(i == len(quads) - 1)
        if direct:
            cmds.append(rec(4, seq=seq, xy=xy, mask=mask, last=last, depth=depth))
            if mask:
                model.beat(xy, mask, 0, depth, 1,
                           aux_of(smask=0x1111))
        else:
            cmds.append(rec(3, seq=seq, xy=xy, mask=mask, last=last, aux=aux, color=color, depth=depth))
            if mask:
                model.beat(xy, mask, color, depth, 0, aux)
    seq = (seq + 1) & 0xFFFF


def rxy(w=16, h=8):
    return (int(rng.integers(0, h // 2)) * 2 << 16) | (int(rng.integers(0, w // 2)) * 2)


cmds.append(rec(6))                       # occ_clear
st(ROP_CTRL, 1)                           # occlusion on

# ---------------- scene 1: one sample, D32F LESS, alpha blending into RGBA8 ----------
DSB, RTB = 0x0000, 0x1000
fill_depth(DSB, 64, 8, 64)
for i, v in [(DS_BASE, DSB), (DS_STRIDE, 64), (RT_BASE, RTB), (RT_STRIDE, 64), (RT_FORMATS, 37),
             (DEPTH, (1 << 0) | (1 << 1) | (1 << 2) | (1 << 6)),       # test, write, LESS, D32F
             (BLEND, 1 | (6 << 1) | (7 << 5) | (0 << 9) | (1 << 12) | (7 << 16) | (0 << 20)),
             (WMASK, 0xF), (MS_CTRL, 0)]:
    st(i, v)
for p in range(60):
    quads = []
    for q in range(int(rng.integers(1, 7))):
        quads.append((rxy(), int(rng.integers(0, 16)), rcolor(), depth4(0.0, 1.0),
                      aux_of(front=int(rng.integers(0, 2)))))
    prim(quads)
idle()

# ---------------- scene 2: four attachments as beats, nocol beats ----------------
RT1B, RT3B = 0x2000, 0x3000
for i, v in [(RT_FORMATS, 44 | (98 << 8) | (0 << 16) | (107 << 24)),
             (RTN_BASE[1], RT1B), (RTN_BASE[1] + 1, 64), (RTN_BASE[2], 0x6000), (RTN_BASE[2] + 1, 64),
             (RTN_BASE[3], RT3B), (RTN_BASE[3] + 1, 256),
             (BLEND, 1 | (2 << 1) | (7 << 5) | (1 << 12) | (1 << 16)),     # SRC_COLOR, ONE_MINUS_SRC_ALPHA; ONE + ONE
             (BLENDN[1], 0), (BLENDN[3], 0),
             (WMASK, 0x7 | (0xF << 4) | (0xF << 8) | (0xB << 12)),
             (DEPTH, (1 << 0) | (1 << 1) | (3 << 2) | (1 << 6))]:           # LESS_OR_EQUAL
    st(i, v)
for p in range(40):
    quads = []
    for q in range(int(rng.integers(1, 4))):
        xy, mask, dep = rxy(), int(rng.integers(1, 16)), depth4(0.0, 1.0)
        rts = [0, 1, 2, 3]
        nocol_extra = rng.random() < 0.3
        n = len(rts) + int(nocol_extra)
        for k in range(n):
            nocol = int(k == 4)
            rt = rts[k] if k < 4 else 0
            col = rcolor() if rt == 0 else rint_color()
            quads.append((xy, mask, col, dep,
                          aux_of(rt=rt, qfirst=int(k == 0), qlast=int(k == n - 1), nocol=nocol)))
    prim(quads)
idle()

# ---------------- scene 3: direct quads (DEBUG_COLOR) ----------------
for i, v in [(RT_FORMATS, 37), (BLEND, 0), (WMASK, 0xF), (DEBUG_COLOR, 0x80FF4020),
             (DEPTH, (1 << 0) | (1 << 1) | (1 << 2) | (1 << 6))]:
    st(i, v)
for p in range(20):
    quads = [(rxy(), int(rng.integers(0, 16)), 0, depth4(0.0, 0.7), 0) for _ in range(int(rng.integers(1, 4)))]
    prim(quads, direct=True)
    if rng.random() < 0.5:                 # interleave SU primitives
        prim([(rxy(), int(rng.integers(1, 16)), rcolor(), depth4(0.0, 0.7), aux_of())])
idle()

# ---------------- scene 4: four samples, A2C, D24S8 with stencil ----------------
DS4, RT4 = 0x4000, 0x5000
fill_depth(DS4, 256, 8, 256, d24=True)
ds_off = sum(f2b(np.float32(v)) << (32 * s) for s, v in enumerate([-0.01, 0.005, 0.01, -0.004]))
for i, v in [(MS_CTRL, 2 | (1 << 8)), (DS_BASE, DS4), (DS_STRIDE, 256), (RT_BASE, RT4), (RT_STRIDE, 256),
             (RT_FORMATS, 37), (BLEND, 1 | (6 << 1) | (7 << 5) | (1 << 12) | (7 << 16)),
             (SFRONT, 0x10 | (0xFF << 8) | (0xFF << 16) | (7 << 24)),           # ALWAYS
             (SBACK, 0x20 | (0x0F << 8) | (0xF0 << 16) | (4 << 24)),            # GREATER
             (SOPS, (0 << 0) | (6 << 3) | (3 << 6) | (1 << 16) | (2 << 19) | (7 << 22)),
             (DEPTH, (1 << 0) | (1 << 1) | (1 << 2) | (1 << 5) | (1 << 8))]:    # LESS, D24S8, stencil
    st(i, v)
for p in range(40):
    quads = []
    for q in range(int(rng.integers(1, 5))):
        quads.append((rxy(), int(rng.integers(0, 16)), rcolor(alpha_lo=0.0), depth4(0.0, 1.0),
                      aux_of(front=int(rng.integers(0, 2)), ds=ds_off,
                             zexp=int(rng.integers(0, 16)) if rng.random() < 0.2 else 0,
                             smask=int(rng.integers(0, 1 << 16)))))
    prim(quads)
idle()
cmds.append(rec(15))

os.makedirs(OUT, exist_ok=True)
open(os.path.join(OUT, "sys_init.hex"), "w").write("\n".join("%02x" % b for b in init) + "\n")
open(os.path.join(OUT, "sys_cmd.hex"), "w").write("\n".join(cmds) + "\n")
open(os.path.join(OUT, "sys_exp.hex"), "w").write("\n".join("%02x" % b for b in mem) + "\n")
open(os.path.join(OUT, "sys_occ.hex"), "w").write("%010x\n" % model.occ)
print("commands", len(cmds), "occ", model.occ)
