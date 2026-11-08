"""gen_ds_vectors.py -- vectors for sim/tb/ad_rop_dtest_tb.v and sim/tb/ad_rop_ds_tb.v.

  sim/vec/dtest_vec.hex : one 448-bit record per line, 14 fields of 32 bits, field 0 at the top:
                          sec, depth, sfront, sback, sops, bmin, bmax, {front,cov}, zf, stored,
                          pass, wword, wbe, 0.   sec: 0 stencil, 1 d16, 2 bounds, 3 order.
  sim/vec/ds_cmd.hex    : 1088-bit commands (see TYPE_* below), the ad_rop_ds stimulus.
  sim/vec/ds_exp.hex    : 568-bit expected outputs {color[511:0], beat[3:0], smask[15:0], xy[31:0]}.
  sim/vec/ds_mem.hex    : 32-bit little-endian words, MEMSZ/4 per image (run k: image 2k initial,
                          image 2k+1 expected final).
Run: python3 -I tools/gen_ds_vectors.py
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np  # noqa: E402
from admodel import f2b, unorm2f, f2unorm, QNAN, rand_f32  # noqa: E402
import ds_model as M  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
VEC = os.path.join(ROOT, "sim", "vec")
MEMSZ = 4096

TYPE_STATE, TYPE_QUAD, TYPE_LOAD, TYPE_CHECK, TYPE_SECEND = 1, 2, 3, 4, 5
SECTIONS = ["funcs", "stencil", "raw", "d16", "bounds", "beats"]


def h(v, bits):
    return format(v & ((1 << bits) - 1), "0%dx" % (bits // 4))


# ============================================================== dtest vectors
def rf01(rng):
    return f2b(float(np.float32(rng.random())))


def rand_stencil_word(rng, cop=None):
    cop = rng.randrange(8) if cop is None else cop
    ref = rng.choice([0, 255, rng.randrange(256)])
    cm = rng.choice([0xFF, 0xFF, rng.randrange(256), 0])
    wm = rng.choice([0xFF, 0xFF, rng.randrange(256), 0])
    return ref | (cm << 8) | (wm << 16) | (cop << 24)


def gen_dtest(rng):
    recs = []

    def add(sec, depth, sf, sb, so, bmin, bmax, cov, front, zf, stored):
        p, ww, be = M.dtest(depth, sf, sb, so, bmin, bmax, cov, front, zf, stored)
        recs.append([sec, depth, sf, sb, so, bmin, bmax, (front << 1) | cov, zf, stored, p, ww, be, 0])

    # ---- 0 stencil: 8 ops x 8 compare ops x front/back x random masks and references
    for op in range(8):
        for cop in range(8):
            for front in range(2):
                for k in range(12):
                    ops = [rng.randrange(8) for _ in range(6)]
                    slot = k % 3
                    ops[slot + (0 if front else 3)] = op
                    if k >= 6:                       # the op in every slot of the face
                        for j in range(3):
                            ops[j + (0 if front else 3)] = op
                    so = ops[0] | (ops[1] << 3) | (ops[2] << 6) | (ops[3] << 16) | (ops[4] << 19) | (ops[5] << 22)
                    so |= rng.randrange(128) << 9       # junk in the unused bits
                    st_a = rand_stencil_word(rng, cop)
                    st_b = rand_stencil_word(rng, cop if rng.random() < 0.5 else None)
                    sf, sb = (st_a, st_b) if front else (st_b, st_a)
                    dop = rng.randrange(8)
                    depth = M.D24 | (1 << 8) | (dop << 2) | rng.randrange(2) | (rng.randrange(2) << 1)
                    s_a = rng.choice([0, 1, 254, 255, rng.randrange(256), (st_a & 0xFF)])
                    d24 = rng.randrange(1 << 24)
                    zf = rng.choice([unorm2f(d24, 24), rf01(rng), 0, 0x3F800000])
                    add(0, depth, sf, sb, so, 0, 0x3F800000, int(rng.random() < 0.95), front, zf, (s_a << 24) | d24)
    # ---- 1 d16: compare, write, RNE, saturation
    specials = [0, 0x80000000, 0x3F800000, 0x3F800001, 0x40000000, 0x7F800000, 0xFF800000, QNAN,
                0xBF800000, 0x00000001, 0x807FFFFF, 0x3F7FFFFF]
    for k in range(3000):
        sv = rng.choice([0, 0xFFFF, rng.randrange(1 << 16)])
        r = rng.random()
        if r < 0.3:
            zf = unorm2f(sv, 16)
        elif r < 0.5:   # halfway points (RNE ties are not exact in fp32, but close)
            zf = f2b(float(np.float32((rng.randrange(65535) + 0.5) / 65535.0)))
        elif r < 0.65:
            zf = rng.choice(specials)
        else:
            zf = rf01(rng)
        depth = M.D16 | (rng.randrange(8) << 2) | 1 | (rng.randrange(2) << 1) | (rng.randrange(2) << 8)
        stored = (rng.randrange(1 << 16) << 16) | sv
        add(1, depth, rng.randrange(1 << 27), rng.randrange(1 << 27), rng.randrange(1 << 25),
            0, 0x3F800000, int(rng.random() < 0.95), rng.randrange(2), zf, stored)
    # ---- 2 bounds: inside, outside, at the bounds, NaN
    for k in range(3000):
        fmt = rng.choice([M.D24, M.D32F, M.D16])
        n = 16 if fmt == M.D16 else 24
        if fmt == M.D32F:
            stored = rng.choice([rf01(rng), rf01(rng), 0, 0x80000000, QNAN, 0xFFC00001, 0x3F800000,
                                 0x7F800000, 0xFF800000, 0x00000001])
            za = stored
        else:
            u = rng.choice([0, (1 << n) - 1, rng.randrange(1 << n)])
            stored = (rng.randrange(1 << (32 - n)) << n) | u
            za = unorm2f(u, n)
        lo, hi = sorted([rf01(rng), rf01(rng)], key=lambda v: np.uint32(v).view(np.float32))
        r = rng.random()
        if r < 0.15:
            lo = za
        elif r < 0.3:
            hi = za
        elif r < 0.4:
            lo = hi = za
        elif r < 0.5:
            lo = rng.choice([QNAN, 0x7F800001])
        elif r < 0.6:
            hi = rng.choice([QNAN, 0xFF800001])
        elif r < 0.65:
            lo, hi = hi, lo
        elif r < 0.7:
            lo, hi = 0x80000000, 0x00000000      # [-0, +0]
        depth = fmt | (1 << 9) | (rng.randrange(8) << 2) | rng.randrange(4) | (rng.randrange(2) << 8)
        zf = rng.choice([za, rf01(rng)])
        add(2, depth, rand_stencil_word(rng), rand_stencil_word(rng), rng.randrange(1 << 25),
            lo, hi, int(rng.random() < 0.95), rng.randrange(2), zf, stored)
    # ---- 3 order: bounds failure writes no stencil; then everything random
    for k in range(1500):
        # ZERO / REPLACE / INVERT in every slot (they would write the stencil)
        so = rng.randrange(1 << 25) if k % 4 == 3 else (rng.choice([1, 2, 5]) * 0x49) | ((rng.choice([1, 2, 5]) * 0x49) << 16)
        u = rng.randrange(1 << 24)
        stored = (rng.randrange(256) << 24) | u
        za = unorm2f(u, 24)
        # bounds that exclude z_a most of the time
        if rng.random() < 0.7:
            lo = hi = f2b(float(np.float32(min(1.0, np.uint32(za).view(np.float32) + 0.25))))
        else:
            lo, hi = 0, 0x3F800000
        depth = M.D24 | (1 << 9) | (1 << 8) | (rng.randrange(8) << 2) | rng.randrange(4)
        add(3, depth, rand_stencil_word(rng), rand_stencil_word(rng), so, lo, hi,
            int(rng.random() < 0.95), rng.randrange(2), rng.choice([za, rf01(rng)]), stored)
    nrng = np.random.default_rng(rng.randrange(1 << 30))
    for k in range(6000):
        depth = rng.randrange(1 << 10)
        add(3, depth, rng.randrange(1 << 27), rng.randrange(1 << 27), rng.randrange(1 << 25),
            rand_f32(nrng), rand_f32(nrng), rng.randrange(2), rng.randrange(2),
            rand_f32(nrng, 0.2), rng.randrange(1 << 32))
    with open(os.path.join(VEC, "dtest_vec.hex"), "w") as f:
        for r in recs:
            f.write("".join(h(v, 32) for v in r) + "\n")
    return len(recs)


# ============================================================== ds vectors
class DSGen:
    def __init__(self, rng):
        self.rng = rng
        self.cmd = []
        self.exp = []
        self.imgs = []
        self.model = None
        self.nexp = 0
        self.runs = 0

    def state(self, idx, val):
        self.model.write_state(idx, val)
        self.cmd.append(TYPE_STATE | (idx << 4) | ((val & 0xFFFFFFFF) << 13))

    def begin(self, mem):
        if self.model is None:
            self.model = M.DSModel(mem, stencil=1)
        self.model.mem = mem
        self.cmd.append(TYPE_LOAD | (len(self.imgs) << 4))
        self.imgs.append(bytes(mem))

    def end(self):
        self.cmd.append(TYPE_CHECK | (len(self.imgs) << 4) | (self.nexp << 36))
        self.imgs.append(bytes(self.model.mem))
        self.runs += 1

    def secend(self, sec):
        self.cmd.append(TYPE_SECEND | (sec << 4))

    def quad(self, xy, smask, beat=1, front=1, dbg=0, sdepth=0, color=None):
        rng = self.rng
        if color is None:
            color = rng.getrandbits(512)
        q = dict(xy=xy, smask=smask, beat=beat, front=front, dbg=dbg, sdepth=sdepth, color=color)
        self.cmd.append(TYPE_QUAD | (xy << 4) | (smask << 36) | (beat << 52) | (front << 56) |
                        (dbg << 57) | (sdepth << 58) | (color << 570))
        o = self.model.quad(q)
        if o is not None:
            self.exp.append(o["xy"] | (o["smask"] << 32) | (o["beat"] << 48) | (o["color"] << 52))
            self.nexp += 1

    def write(self):
        with open(os.path.join(VEC, "ds_cmd.hex"), "w") as f:
            for c in self.cmd:
                f.write(h(c, 1088) + "\n")
        with open(os.path.join(VEC, "ds_exp.hex"), "w") as f:
            for e in self.exp:
                f.write(h(e, 568) + "\n")
        with open(os.path.join(VEC, "ds_mem.hex"), "w") as f:
            for im in self.imgs:
                for i in range(0, MEMSZ, 4):
                    f.write(h(int.from_bytes(im[i:i + 4], "little"), 32) + "\n")


def rand_smask(rng, S):
    if S == 1:
        m = 0
        for lane in range(4):
            if rng.random() < 0.8:
                m |= 1 << (4 * lane)
        return m
    return rng.getrandbits(16) | (0xFFFF if rng.random() < 0.3 else 0)


def surface(rng, S, ps, W=None, H=None):
    """Pick an aligned surface inside MEMSZ: base multiple of 64, stride multiple of 2*S*ps."""
    unit = 2 * S * ps
    while True:
        W = W or rng.choice([2, 4, 6, 8, 10, 16])
        H = H or rng.choice([2, 4, 8, 16])
        stride = (W // 2) * unit + unit * rng.choice([0, 0, 1, 3])
        size = stride * H
        if size + 64 <= MEMSZ:
            base = 64 * rng.randrange((MEMSZ - size) // 64 + 1)
            if base + size <= MEMSZ:
                return base, stride, W, H
        W = H = None


def zbuf(rng, fmt, mem, region):
    for a in range(region[0], region[1]):
        mem[a] = rng.randrange(256)
    if fmt == "d32f":
        for a in range(region[0] & ~3, region[1], 4):
            mem[a:a + 4] = f2b(float(np.float32(rng.random()))).to_bytes(4, "little")


def zvals(rng, fmt, sdepth_pool):
    """A depth near the stored values (equal ones included) or random."""
    r = rng.random()
    if sdepth_pool and r < 0.3:
        return rng.choice(sdepth_pool)
    if r < 0.35:
        return rng.choice([0, 0x3F800000, 0x80000000, 0x40000000, 0xBF800000, QNAN])
    return f2b(float(np.float32(rng.random())))


def run(g, rng, fmt_bit, depth, sec_quads=24, S=None, ops=None, fronts="rand", beats=False,
        bounds=None, dbg_rate=0.1, W=None, H=None, overlap=False, surf=None):
    S = S or rng.choice([1, 4])
    fmt = M.fmt_of(fmt_bit)
    ps = 2 if fmt == "d16" else 4
    base, stride, W, H = surf or surface(rng, S, ps, W, H)
    mem = bytearray(MEMSZ)
    zbuf(rng, fmt, mem, (0, MEMSZ))
    g.begin(mem)
    g.state(M.S_MS_CTRL, 2 if S == 4 else rng.choice([0, 1, 3, 0x103]))
    g.state(M.S_DS_BASE, base)
    g.state(M.S_DS_STRIDE, stride)
    g.state(M.S_DEBUG_COLOR, rng.getrandbits(32))
    g.state(M.S_DEPTH, depth | (rng.getrandbits(22) << 10))
    g.state(M.S_STENCIL_FRONT, rand_stencil_word(rng) | (rng.getrandbits(5) << 27))
    g.state(M.S_STENCIL_BACK, rand_stencil_word(rng) | (rng.getrandbits(5) << 27))
    g.state(M.S_STENCIL_OPS, (ops if ops is not None else rng.getrandbits(25)) | (rng.getrandbits(7) << 25))
    lo, hi = bounds or (0, 0x3F800000)
    g.state(M.S_DBOUNDS_MIN, lo)
    g.state(M.S_DBOUNDS_MAX, hi)
    spots = [(rng.randrange(W // 2) * 2, rng.randrange(H // 2) * 2) for _ in range(3)]
    for k in range(sec_quads):
        if overlap:
            x, y = rng.choice(spots)
        else:
            x, y = rng.randrange(W // 2) * 2, rng.randrange(H // 2) * 2
        sm = rand_smask(rng, S)
        if rng.random() < 0.05:
            sm = 0
        pool = []
        for lane in range(4):
            for s in range(S):
                a = base + (y + (lane >> 1)) * stride + (S * (x + (lane & 1)) + s) * ps
                st = int.from_bytes(g.model.mem[a:a + ps], "little") if a + ps <= MEMSZ else 0
                pool.append(M.z_a_of(fmt, st))
        sd = 0
        for i in range(16):
            sd |= zvals(rng, fmt, pool) << (32 * i)
        front = rng.randrange(2) if fronts == "rand" else fronts
        dbg = int(rng.random() < dbg_rate)
        g.quad((y << 16) | x, sm, beat=1 | (rng.getrandbits(3) << 1), front=front, dbg=dbg, sdepth=sd)
        if beats:
            for b in range(rng.choice([0, 1, 3])):
                # a later beat: its own smask is ignored (the first beat's survivors go out)
                g.quad((y << 16) | x, rng.getrandbits(16), beat=(rng.getrandbits(3) << 1), front=front,
                       dbg=int(rng.random() < dbg_rate), sdepth=rng.getrandbits(512))
    g.end()


def gen_ds(rng):
    g = DSGen(rng)
    # ---- funcs: all 8 depth functions, D32F, write on/off, 1 and 4 samples
    for func in range(8):
        for wr in range(2):
            run(g, rng, M.D32F, M.D32F | 1 | (wr << 1) | (func << 2), S=1 + 3 * (wr ^ (func & 1)))
    g.secend(0)
    # ---- stencil: D24S8 with ops, random faces
    for k in range(14):
        depth = M.D24 | (1 << 8) | (rng.randrange(8) << 2) | rng.randrange(4)
        run(g, rng, M.D24, depth, S=[1, 4][k & 1])
    g.secend(1)
    # ---- raw: overlapping quads in order (incl. both rows in one line, AMB error lines)
    for k in range(10):
        fmt = rng.choice([M.D32F, M.D24])
        depth = fmt | 1 | 2 | (rng.choice([1, 3, 4, 6]) << 2) | ((fmt == M.D24) << 8)
        run(g, rng, fmt, depth, sec_quads=40, S=[1, 4][k & 1], overlap=True)
    # two rows in one line: S=1, D32F, W=2 (row 8 bytes), stride 8
    for k in range(2):
        run(g, rng, M.D32F, M.D32F | 3 | (1 << 2), sec_quads=30, S=1, overlap=True, surf=(64 * k, 8, 2, 8))
    # error lines: the surface runs past the memory (reads return 0, writes are lost)
    run(g, rng, M.D24, M.D24 | 3 | (6 << 2) | (1 << 8), sec_quads=20, S=1, overlap=True,
        surf=(MEMSZ - 64, 64, 4, 4))
    g.secend(2)
    # ---- d16
    for k in range(10):
        depth = M.D16 | 1 | (rng.randrange(2) << 1) | (rng.randrange(8) << 2) | (rng.randrange(2) << 8)
        run(g, rng, M.D16, depth, S=[1, 4][k & 1])
    g.secend(3)
    # ---- bounds: three formats
    for k in range(12):
        fmt = [M.D32F, M.D24, M.D16][k % 3]
        lo = f2b(float(np.float32(rng.random() * 0.5)))
        hi = f2b(float(np.float32(0.5 + rng.random() * 0.5)))
        if k >= 9:
            lo, hi = (QNAN, hi) if k == 9 else (lo, QNAN) if k == 10 else (0, 0x3F800000)
        depth = fmt | (1 << 9) | (rng.randrange(4)) | (rng.randrange(8) << 2) | ((fmt == M.D24) << 8)
        run(g, rng, fmt, depth, S=[1, 4][(k // 3) & 1], bounds=(lo, hi))
    g.secend(4)
    # ---- beats: later beats, the direct path, passthrough (tests off / no or two formats)
    for k in range(6):
        fmt = rng.choice([M.D32F, M.D24, M.D16])
        depth = fmt | 3 | (rng.choice([1, 3, 4, 6]) << 2)
        run(g, rng, fmt, depth, S=[1, 4][k & 1], beats=True, dbg_rate=0.3)
    for depth in [M.D32F | 2, 0x003 | (1 << 2), M.D24 | M.D32F | 3 | (1 << 9), M.D24 | (1 << 1)]:
        run(g, rng, M.D32F, depth, S=rng.choice([1, 4]), beats=True, dbg_rate=0.3)
    g.secend(5)
    g.write()
    return g.runs, len(g.cmd), len(g.exp)


def main():
    rng = random.Random(20261108)
    os.makedirs(VEC, exist_ok=True)
    n = gen_dtest(rng)
    runs, nc, ne = gen_ds(rng)
    print("dtest_vec.hex: %d records; ds: %d runs, %d commands, %d outputs" % (n, runs, nc, ne))


if __name__ == "__main__":
    main()
