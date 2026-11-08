"""gen_ms_vectors.py -- vectors for sim/tb/ad_rop_ms_tb.v (ad_rop_ms alone).

sim/vec/ms_in.hex : one 896-bit record per line
  [895:892] kind (0 beat, 1 STATE write)  [891:888] section
  [887:879] st_idx  [878:847] st_wdata
  [846:815] xy  [814:811] mask  [810:299] color  [298:171] depth  [170] dbg
  [169:16] aux  [15:0] 0
sim/vec/ms_exp.hex : one 1088-bit record per output beat
  [1087:1084] section [1083:1052] xy [1051:1036] smask [1035:524] color
  [523:12] sdepth [11] dbg [10] front [9:6] beat [5:0] 0
Sections: 0 depth, 1 a2c, 2 beats, 3 bypass1x.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from admodel import f2b, rand_f32, QNAN   # noqa: E402
from ms_model import MsModel              # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
rng = np.random.default_rng(20261108)
recs_in, recs_exp = [], []
model = MsModel()

SPECIAL_A = [0, 0x80000000, QNAN, 0xFFC00000, 0x7F800000, 0xFF800000, 0xBF800000,
             0x3E000000, 0x3DFFFFFF, 0x3E000001, 0x3E7FFFFF, 0x3E800000, 0x3EC00000,
             0x3EBFFFFF, 0x3F000000, 0x3EFFFFFF, 0x3F200000, 0x3F1FFFFF, 0x3F600000,
             0x3F5FFFFF, 0x3F800000, 0x00000001, 0x807FFFFF]


def r_alpha():
    r = rng.random()
    if r < 0.3:
        return int(rng.choice(SPECIAL_A))
    if r < 0.5:   # [0.125, 0.25): the MUT_A2C_STEP band
        return f2b(float(np.float32(0.125 + rng.random() * 0.125)))
    if r < 0.9:
        return f2b(float(np.float32(rng.random())))
    return rand_f32(rng)


def r_depth():
    r = rng.random()
    if r < 0.6:
        return f2b(float(np.float32(rng.random() * 1.1 - 0.05)))
    if r < 0.7:
        return int(rng.choice([0, 0x80000000, 0x3F800000, 0x3F7FFFFF, QNAN, 0x7F800000,
                               0xFF800000, 0x00000001, 0x80000001]))
    return rand_f32(rng)


def r_off():
    r = rng.random()
    if r < 0.8:
        return f2b(float(np.float32((rng.random() - 0.5) * 0.02)))
    if r < 0.9:
        return int(rng.choice([0, 0x80000000, QNAN, 0x3F800000, 0xBF800000]))
    return rand_f32(rng)


def r_color(alpha=None):
    c = 0
    for l in range(4):
        for ch in range(4):
            v = f2b(float(np.float32(rng.random())))
            if ch == 3:
                v = r_alpha() if alpha is None else alpha
            c |= v << (32 * (4 * l + ch))
    return c


def pack(fields):
    v, pos = 0, 0
    for val, w in reversed(fields):
        v |= (val & ((1 << w) - 1)) << pos
        pos += w
    return v


def st(sec, idx, val):
    recs_in.append(pack([(1, 4), (sec, 4), (idx, 9), (val, 32), (0, 847)]))
    model.state(idx, val)


def mk_aux(rt=0, qlast=1, qfirst=1, nocol=0, front=1, ds=0, zexp=0, smask=0xFFFF):
    return pack([(rt, 2), (qlast, 1), (qfirst, 1), (nocol, 1), (front, 1), (ds, 128),
                 (zexp, 4), (smask, 16)])


def beat(sec, xy, mask, color, depth, dbg, aux):
    recs_in.append(pack([(0, 4), (sec, 4), (0, 9), (0, 32), (xy, 32), (mask, 4),
                         (color, 512), (depth, 128), (dbg, 1), (aux, 154), (0, 16)]))
    e = model.beat(xy, mask, color, depth, dbg, aux)
    if e is not None:
        recs_exp.append(pack([(sec, 4), (e['xy'], 32), (e['smask'], 16), (e['color'], 512),
                              (e['sdepth'], 512), (e['dbg'], 1), (e['front'], 1),
                              (e['beat'], 4), (0, 6)]))


def r_quad(sec, ds_fixed=None, smask=None, mask=None, alpha=None, dbg=None, zexp=None,
           first=1, rt=0, nocol=0, qlast=1):
    xy = int(rng.integers(0, 1 << 32))
    m = int(rng.integers(0, 16)) if mask is None else mask
    if mask is None and rng.random() < 0.7:
        m = 0xF
    sm = smask if smask is not None else (0xFFFF if rng.random() < 0.5 else int(rng.integers(0, 1 << 16)))
    ds = ds_fixed if ds_fixed is not None else sum(r_off() << (32 * s) for s in range(4))
    ze = int(rng.integers(0, 16)) if zexp is None else zexp
    d = sum(r_depth() << (32 * l) for l in range(4))
    db = (1 if rng.random() < 0.1 else 0) if dbg is None else dbg
    beat(sec, xy, m, r_color(alpha), d, db,
         mk_aux(rt=rt, qlast=qlast, qfirst=first, nocol=nocol, front=int(rng.integers(0, 2)),
                ds=ds, zexp=ze, smask=sm))


def r_viewport(sec):
    r = rng.random()
    if r < 0.4:
        n, s = 0, 0x3F800000
    elif r < 0.7:
        n = f2b(float(np.float32(rng.random() * 0.5)))
        s = f2b(float(np.float32(rng.random() * 0.5)))
    elif r < 0.9:   # reversed depth: f < n
        n = f2b(float(np.float32(0.5 + rng.random() * 0.5)))
        s = f2b(float(np.float32(-rng.random() * 0.5)))
    else:
        n, s = rand_f32(rng), rand_f32(rng)
    st(sec, 0x054, s)
    st(sec, 0x055, n)


# ---------------- depth: four samples ----------------
SEC = 0
st(SEC, 0x05E, 2)
for dc in [0, 1, 2, 3, 0, 1, 3, 2]:
    st(SEC, 0x059, dc)
    for _ in range(4):
        r_viewport(SEC)
        for _ in range(12):
            r_quad(SEC)
st(SEC, 0x059, 0)

# ---------------- a2c (four samples, with and without alpha to one) ----------------
SEC = 1
for ctrl in [0x102, 0x302, 0x202, 0x102]:
    st(SEC, 0x05E, ctrl)
    st(SEC, 0x059, int(rng.integers(0, 4)))
    r_viewport(SEC)
    for _ in range(80):
        r_quad(SEC, smask=0xFFFF if rng.random() < 0.7 else None)
    for a in SPECIAL_A:   # every lane at the special alpha
        r_quad(SEC, smask=0xFFFF, mask=0xF, alpha=a, dbg=0)

# ---------------- beats ----------------
SEC = 2
for ctrl in [0x002, 0x302, 0x100, 0x200]:
    st(SEC, 0x05E, ctrl)
    st(SEC, 0x059, int(rng.integers(0, 4)))
    r_viewport(SEC)
    r_quad(SEC, first=0)                     # stray later beat after a drop/none: dropped
    for _ in range(40):
        nb = int(rng.integers(1, 5))
        dropq = rng.random() < 0.3
        for b in range(nb):
            r_quad(SEC, first=1 if b == 0 else 0, rt=b, nocol=int(rng.random() < 0.2),
                   qlast=int(b == nb - 1),
                   smask=(0 if dropq else None) if b == 0 else int(rng.integers(0, 1 << 16)),
                   mask=None if b == 0 else int(rng.integers(0, 16)))

# ---------------- bypass1x: one sample ----------------
SEC = 3
for ctrl in [0x100, 0x000, 0x300, 0x000, 0x101]:
    st(SEC, 0x05E, ctrl)
    for dc in [0, 1, 2, 3]:
        st(SEC, 0x059, dc)
        r_viewport(SEC)
        for _ in range(20):
            r_quad(SEC, smask=0xFFFF if rng.random() < 0.6 else None)

os.makedirs(os.path.join(ROOT, "sim/vec"), exist_ok=True)
with open(os.path.join(ROOT, "sim/vec/ms_in.hex"), "w") as fh:
    for v in recs_in:
        fh.write("%0224x\n" % v)
with open(os.path.join(ROOT, "sim/vec/ms_exp.hex"), "w") as fh:
    for v in recs_exp:
        fh.write("%0272x\n" % v)
print("ms vectors: %d inputs, %d outputs" % (len(recs_in), len(recs_exp)))
