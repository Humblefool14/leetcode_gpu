"""gen_wb_vectors.py -- vectors for ad_rop_wb_tb, ad_rop_mrt_tb and ad_rop_wpix_tb.

Writes (LB = 32 and 64):
  sim/vec/wb_cmd_<LB>.hex, wb_exp_<LB>.hex          ad_rop_wb_tb (sections write, blend, drain)
  sim/vec/wb_mrt_cmd_<LB>.hex, wb_mrt_exp_<LB>.hex  ad_rop_mrt_tb (sections one, four)
  sim/vec/wb_wpix_<LB>.hex                          ad_rop_wpix_tb
  sim/tb/ad_rop_wpix_tb.vh                          field offsets of the wpix records

Command record (608 bits, one per line): [607:600] op, [599:568] w0, [567:552] w1,
[551:512] w2, [511:0] colour.
  op 4 init memory   w0 = seed (byte i = wb_model.init_byte(i, seed))
  op 1 STATE write   w2[8:0] = index, w0 = value
  op 2 beat          w0 = xy, w1 = smask, w2[1:0] = rt, w2[2] = nocol, w2[15:8] = idle cycles before
  op 3 drain + check w0 = expected block, w1 = section
  op 0 end
Expected blocks: MEMB bytes each, 16 bytes a line (byte 0 in the low bits).
Run: python3 -I tools/gen_wb_vectors.py
"""
import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wb_model as M  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VEC = os.path.join(ROOT, "sim", "vec")
MEMB = 16384
RT_REGION = 4096
W = H = 8                      # render-target size, pixels
BLEND_ADD = 0x1 | (1 << 1) | (1 << 5) | (1 << 12) | (1 << 16)   # ONE, ONE, ADD (colour and alpha)


def f2b(x):
    return struct.unpack("<I", struct.pack("<f", x))[0]


def rand_f(rng):
    r = rng.random()
    if r < 0.04:
        return 0x7FC00000
    if r < 0.10:
        return rng.choice([0, 0x3F800000, 0x80000000, 0x3F000000, 0xBF800000, 0x7F800000])
    return f2b(rng.uniform(-0.25, 1.25))


def rand_color(rng, path):
    v = 0
    for i in range(16):
        w = rand_f(rng) if path in (0, 1) else rng.getrandbits(32)
        v |= w << (32 * i)
    return v


def rand_smask(rng, s4):
    r = rng.random()
    if s4:
        if r < 0.1:
            return 0xFFFF
        if r < 0.15:
            return 0
        return rng.getrandbits(16)
    m = rng.getrandbits(4) if r > 0.1 else 0xF
    return sum(((m >> l) & 1) << (4 * l) for l in range(4))


class Cmds:
    def __init__(self):
        self.lines = []
        self.exp = []

    def rec(self, op, w0=0, w1=0, w2=0, color=0):
        v = (op << 600) | ((w0 & 0xFFFFFFFF) << 568) | ((w1 & 0xFFFF) << 552) | ((w2 & ((1 << 40) - 1)) << 512) | color
        self.lines.append("%0152x" % v)

    def write(self, path_cmd, path_exp):
        self.rec(0)
        with open(path_cmd, "w") as fh:
            fh.write("\n".join(self.lines) + "\n")
        with open(path_exp, "w") as fh:
            for blk in self.exp:
                for i in range(0, MEMB, 16):
                    fh.write("%032x\n" % int.from_bytes(blk[i:i + 16], "little"))


def make_state(rng, fmts, s4, wms, blends, legacy=None):
    """fmts: VkFormat of RT 0..3 (0 absent).  legacy: RT_FORMAT code for RT 0 (fmts[0] = 0)."""
    st = {}
    S = 4 if s4 else 1
    st[M.S_MS_CTRL] = 2 if s4 else rng.choice([0, 1, 3])
    st[M.S_RT_FORMATS] = sum(f << (8 * k) for k, f in enumerate(fmts))
    st[M.S_RT_FORMAT] = legacy if legacy is not None else rng.choice([0, 1, 2])
    st[M.S_WRITE_MASK] = sum(w << (4 * k) for k, w in enumerate(wms))
    st[M.S_BLEND_CONST] = rng.getrandbits(32)
    st[M.S_ROP_CTRL] = rng.getrandbits(1) << 1
    for k in range(4):
        f = M.resolve_fmt(st, k)
        ps = M.fmt_info(f)[1] or 4
        stride = max(64, W * S * ps)
        extra = rng.choice([0, 0, 1, 2])
        if (stride + 64 * extra) * H <= RT_REGION:
            stride += 64 * extra
        st[M.S_RTK_BASE[k]] = k * RT_REGION
        st[M.S_RTK_STRIDE[k]] = stride
        st[M.S_BLENDK[k]] = blends[k]
    return st


def emit_run(c, rng, st, nbeats, sec, seed, nocol_rate=0.0, gap_long=0.05, rts=None):
    mem = bytearray(M.init_byte(i, seed) for i in range(MEMB))
    c.rec(4, w0=seed)
    for idx, val in sorted(st.items()):
        c.rec(1, w0=val, w2=idx)
    for _ in range(nbeats):
        rt = rng.choice(rts) if rts else rng.randrange(4)
        f = M.resolve_fmt(st, rt)
        path = M.fmt_info(f)[2]
        x = 2 * rng.randrange(W // 2)
        y = 2 * rng.randrange(H // 2)
        s4 = (st[M.S_MS_CTRL] & 0xF) == 2
        smask = rand_smask(rng, s4)
        color = rand_color(rng, path)
        nocol = rng.random() < nocol_rate
        gap = rng.choice([0, 0, 0, 1, 2, 3]) if rng.random() > gap_long else rng.choice([17, 20, 30])
        c.rec(2, w0=(y << 16) | x, w1=smask, w2=(gap << 8) | (int(nocol) << 2) | rt, color=color)
        M.apply_beat(mem, st, rt, (y << 16) | x, smask, color, nocol)
    c.rec(3, w0=len(c.exp), w1=sec)
    c.exp.append(bytes(mem))


def rand_wm(rng, full_rate=0.5):
    r = rng.random()
    if r < full_rate:
        return 0xF
    if r < full_rate + 0.05:
        return 0
    return rng.randrange(1, 16)


def gen_wb(LB, seed):
    rng = random.Random(seed)
    c = Cmds()
    run = 0

    def R(fmts, s4, wms, blends, sec, nb=24, legacy=None, rts=None, gap_long=0.05):
        nonlocal run
        st = make_state(rng, fmts, s4, wms, blends, legacy)
        emit_run(c, rng, st, nb, sec, 100 + run, rts=rts, gap_long=gap_long)
        run += 1

    # ---- section 0: write (pixels reach memory) ----
    R([37, 0, 0, 0], False, [0xF] * 4, [0] * 4, 0, rts=[0])
    R([0, 0, 0, 0], False, [0xF] * 4, [0] * 4, 0, legacy=0, rts=[0])          # legacy BGRA8
    R([0, 0, 0, 0], False, [0xF] * 4, [0] * 4, 0, legacy=1, rts=[0])          # legacy RGBA8
    R([0, 98, 0, 0], False, [0xF] * 4, [0] * 4, 0, rts=[1])                   # R32_UINT
    R([0, 0, 107, 0], False, [0xF] * 4, [0] * 4, 0, rts=[2])                  # R32G32B32A32_UINT
    R([0, 0, 0, 107], True, [0xF] * 4, [0] * 4, 0, rts=[3])                   # several lines
    R([0, 98, 0, 0], True, [0xF] * 4, [0] * 4, 0, rts=[1])
    for s4 in (False, True):
        for _ in range(2):
            fm = rng.sample(M.PATH2_FORMATS, 4)
            R(fm, s4, [rand_wm(rng) for _ in range(4)], [rng.choice([0, BLEND_ADD]) for _ in range(4)], 0)
    # ---- section 1: blend (read-modify-write) ----
    R([37, 0, 0, 0], False, [0xF] * 4, [BLEND_ADD, 0, 0, 0], 1, rts=[0])
    R([44, 0, 0, 0], True, [0xF] * 4, [BLEND_ADD, 0, 0, 0], 1, rts=[0])
    for s4 in (False, True):
        for _ in range(2):
            R([rng.choice([37, 44, 51]), rng.choice([9, 16, 37]), 64, rng.choice(M.PATH2_FORMATS)], s4,
              [rand_wm(rng, 0.2) for _ in range(4)], [BLEND_ADD, rng.choice([0, BLEND_ADD]), 0, BLEND_ADD], 1)
    # ---- section 2: drain (long runs, idle gaps that flush in the middle) ----
    for s4 in (False, True):
        fm = [rng.choice(M.PATH0_TB), 64, rng.choice(M.PATH2_FORMATS), rng.choice([0] + M.PATH2_FORMATS)]
        R(fm, s4, [rand_wm(rng) for _ in range(4)], [rng.choice([0, BLEND_ADD]), 0, 0, 0], 2, nb=48, gap_long=0.25)
    return c


ALL_TB_FORMATS = M.PATH0_TB + M.PATH1_TB + M.PATH2_FORMATS


def gen_mrt(LB, seed):
    rng = random.Random(seed)
    c = Cmds()
    run = 0
    for sec, s4 in ((0, False), (1, True)):
        for i in range(12):
            fm = rng.sample(ALL_TB_FORMATS, 4)
            legacy = None
            if i % 4 == 1:
                fm[rng.randrange(1, 4)] = 0                    # an absent attachment
            if i % 4 == 2:
                fm[0] = 0
                legacy = rng.choice([0, 1])                    # attachment 0 by RT_FORMAT's code
            if i % 4 == 3:
                fm[rng.randrange(4)] = rng.choice([0, 200, 45])   # absent / unsupported
            if i < 2:                                          # several-line rows at both sizes
                fm[3] = rng.choice([107, 108, 109])
                fm[2] = rng.choice([95, 96, 101, 102, 103])
            blends = [BLEND_ADD if (M.fmt_info(M.resolve_fmt({M.S_RT_FORMATS: sum(f << (8 * k) for k, f in enumerate(fm)),
                                                               M.S_RT_FORMAT: legacy or 0}, k))[2] != 1 and rng.random() < 0.5)
                      else 0 for k in range(4)]
            wms = [rand_wm(rng, 0.4) for _ in range(4)]
            st = make_state(rng, fm, s4, wms, blends, legacy)
            emit_run(c, rng, st, 24, sec, 500 + run, nocol_rate=0.15)
            run += 1
    return c


# ---------------------------------------------------------------- wpix vectors
WPIX_FIELDS = [  # (name, width), MSB first
    ("rt", 2), ("fmts", 32), ("rtfmt", 2), ("base", 32), ("stride", 32), ("ms", 4), ("wm", 16),
    ("blend", 32), ("xy", 32), ("smask", 16), ("r", 1), ("j", 2), ("g", 2), ("off0", 8), ("off1", 8),
    ("bpix", 128), ("color", 512), ("line0", 512), ("line1", 512),
    ("e_addr", 32), ("e_nl", 2), ("e_np", 2), ("e_multi", 1), ("e_drop", 1), ("e_read", 1), ("e_path", 2),
    ("e_lw", 1), ("e_mask", 4), ("e_ent", 4), ("e_soff", 32), ("e_ps", 5), ("e_bdst", 128), ("e_res", 512),
    ("e_chk", 1),
]
WPIX_W = sum(w for _, w in WPIX_FIELDS)
WPIX_WH = (WPIX_W + 3) // 4 * 4


def write_wpix_vh():
    off = WPIX_WH
    out = ["// generated by tools/gen_wb_vectors.py -- field offsets of sim/vec/wb_wpix_<LB>.hex records",
           "localparam WPIX_W = %d;" % WPIX_WH]
    for n, w in WPIX_FIELDS:
        off -= w
        out.append("`define WP_%s %d +: %d" % (n.upper(), off, w))
    with open(os.path.join(ROOT, "sim", "tb", "ad_rop_wpix_tb.vh"), "w") as fh:
        fh.write("\n".join(out) + "\n")


def wpix_vec(rng, LB, fmt, rt, s4, r=None, j=None, g=None, aligned=True):
    LS = LB.bit_length() - 1
    st = {}
    fmts = rng.getrandbits(32) & ~(0xFF << (8 * rt)) | (fmt << (8 * rt))
    rtfmt = rng.randrange(4)
    if rt == 0 and fmt == 0 and rng.random() < 0.7:
        rtfmt = rng.choice([0, 1, 2, 3])
    st[M.S_RT_FORMATS] = fmts
    st[M.S_RT_FORMAT] = rtfmt
    st[M.S_MS_CTRL] = 2 if s4 else rng.choice([0, 1, 3, 4, 15])
    wm = rng.getrandbits(16)
    if rng.random() < 0.4:
        wm |= 0xF << (4 * rt)
    st[M.S_WRITE_MASK] = wm
    blend = rng.getrandbits(32)
    st[M.S_BLENDK[rt]] = blend
    f = M.resolve_fmt(st, rt)
    sup, ps, path, chm = M.fmt_info(f)
    pse = ps or 4
    S = 4 if s4 else 1
    if aligned:
        base = rng.getrandbits(26) << 6
        stride = (rng.randrange(1, 64) * 2 * S * pse) & 0xFFFFFFFF
        x = 2 * rng.randrange(1 << 14)
        y = 2 * rng.randrange(1 << 14)
    else:
        base, stride = rng.getrandbits(32), rng.getrandbits(32)
        x, y = rng.getrandbits(16), rng.getrandbits(16)
    st[M.S_RTK_BASE[rt]] = base
    st[M.S_RTK_STRIDE[rt]] = stride
    rowb = 2 * S * pse
    multi = rowb > LB
    nl = rowb // LB - 1 if multi else 0
    if r is None:
        r = rng.randrange(2)
    if j is None:
        j = rng.randrange(nl + 1)
    if g is None:
        g = rng.randrange(S)
    if aligned and not multi:
        off0 = rng.randrange(LB // rowb) * rowb
        off1 = rng.randrange(LB // rowb) * rowb
    elif aligned:
        off0 = off1 = 0
    else:
        off0, off1 = rng.randrange(LB), rng.randrange(LB)
    smask = rand_smask(rng, s4) if rng.random() < 0.8 else rng.getrandbits(16)
    color = rand_color(rng, path)
    line0, line1 = rng.getrandbits(8 * LB), rng.getrandbits(8 * LB)
    bpix = rng.getrandbits(128)
    xy = (y << 16) | x
    e = M.wpix_eval(st, rt, xy, smask, color, r, j, g, off0, off1, line0, line1, bpix, LB)
    soff = sum((e["soff"][k] & 0xFF) << (8 * k) for k in range(4))
    vals = dict(rt=rt, fmts=fmts, rtfmt=rtfmt, base=base, stride=stride, ms=st[M.S_MS_CTRL], wm=wm,
                blend=blend, xy=xy, smask=smask, r=r, j=j, g=g, off0=off0, off1=off1, bpix=bpix,
                color=color, line0=line0, line1=line1,
                e_addr=e["addr"], e_nl=e["nl"], e_np=e["np"], e_multi=e["multi"], e_drop=e["drop"],
                e_read=e["read"], e_path=e["path"], e_lw=e["lw"], e_mask=e["mask"], e_ent=e["ent"],
                e_soff=soff, e_ps=e["ps"], e_bdst=e["bdst"], e_res=e["res"], e_chk=e["chk_res"])
    v = 0
    for n, w in WPIX_FIELDS:
        assert 0 <= vals[n] < (1 << w), (n, vals[n])
        v = (v << w) | vals[n]
    v <<= WPIX_WH - WPIX_W
    return "%0*x" % (WPIX_WH // 4, v)


def gen_wpix(LB, seed):
    rng = random.Random(seed)
    lines = []
    # directed: every path-2 format, S = 1 and 4, both rows, every line / pass
    for f in M.PATH2_FORMATS:
        for s4 in (False, True):
            ps = M.fmt_info(f)[1]
            S = 4 if s4 else 1
            nl = max(1, 2 * S * ps // LB)
            for r in (0, 1):
                for j in range(nl):
                    for g in range(S):
                        lines.append(wpix_vec(rng, LB, f, rng.randrange(4), s4, r, j, g))
    # directed: the other formats and unsupported codes
    for f in M.PATH0_TB + [4, 8] + [43, 50, 57, 64, 76, 83, 97] + [0, 1, 45, 110, 255]:
        for s4 in (False, True):
            for _ in range(4):
                lines.append(wpix_vec(rng, LB, f, rng.randrange(4), s4))
    # legacy RT_FORMAT codes on attachment 0
    for _ in range(40):
        lines.append(wpix_vec(rng, LB, 0, 0, rng.random() < 0.5))
    # random
    pool = list(M.FMT) + [0, 2, 45, 200]
    for i in range(2500):
        lines.append(wpix_vec(rng, LB, rng.choice(pool), rng.randrange(4), rng.random() < 0.5,
                              aligned=(i % 5 != 0)))
    with open(os.path.join(VEC, "wb_wpix_%d.hex" % LB), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    return len(lines)


def main():
    os.makedirs(VEC, exist_ok=True)
    write_wpix_vh()
    for LB in (32, 64):
        c = gen_wb(LB, 11 + LB)
        c.write(os.path.join(VEC, "wb_cmd_%d.hex" % LB), os.path.join(VEC, "wb_exp_%d.hex" % LB))
        n1 = len(c.exp)
        c = gen_mrt(LB, 23 + LB)
        c.write(os.path.join(VEC, "wb_mrt_cmd_%d.hex" % LB), os.path.join(VEC, "wb_mrt_exp_%d.hex" % LB))
        n2 = gen_wpix(LB, 37 + LB)
        print("LB %d: wb %d runs, mrt %d runs, wpix %d vectors" % (LB, n1, len(c.exp), n2))


if __name__ == "__main__":
    main()
