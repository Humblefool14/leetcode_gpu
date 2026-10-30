#!/usr/bin/env python3
"""Random triangles, lines and points for ad_rx_edge -> sim/vec/edge.hex."""
import pathlib, random, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import fpref as M
import edgeref as R
from fractions import Fraction as Fr

N = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
r = random.Random(0xED6E)


def fp(v):
    v = Fr(v)
    return M.rnd(1 if v < 0 else 0, abs(v)) if v != 0 else 0


def coord(scale):
    k = r.random()
    if k < 0.1:
        return fp(Fr(r.randint(-64, 700 * 256), 256))          # on the subpixel grid
    if k < 0.15:
        return fp(Fr(2 * r.randint(0, 1 << 16) + 1, 512))       # RNE ties
    if k < 0.18:
        return fp(r.choice([-20000, 20000, 1e9, -1e9]))         # saturation
    return fp(Fr(r.randint(-scale * 1000, scale * 1000), 1000))


with open(pathlib.Path(__file__).parent / "vec" / "edge.hex", "w") as f:
    for i in range(N):
        kind = r.choice([0, 1, 2, 2, 2, 3])
        sub = r.getrandbits(1)
        raw = r.random() < 0.1 and kind >= 2
        mode = kind | (sub << 2) | (raw << 3)
        sc = r.choice([4, 64, 700, 5000])
        regs = {k: coord(sc) for k in (31, 32, 34, 35, 37, 38)}
        if kind == 1 and r.random() < 0.3:     # axis-aligned and diagonal lines
            regs[35] = regs[32] if r.random() < 0.5 else regs[35]
        xo, yo = r.randint(0, 800), r.randint(0, 600)
        xs, ys = r.randint(1, 600), r.randint(1, 500)
        regs[76], regs[77] = fp(xo - xs), fp(xo + xs)
        regs[78], regs[79] = fp(yo - ys), fp(yo + ys)
        rts = (r.randint(1, 1200) << 16) | r.randint(1, 1600)
        if r.random() < 0.5:
            smin = (r.randint(0, 300) << 16) | r.randint(0, 300)
            smax = (r.randint(0, 900) << 16) | r.randint(0, 1200)
        else:
            smin = smax = 0
        cull = r.randint(0, 7)
        vprect = r.getrandbits(1)
        lhw = 128 if r.random() < 0.6 else r.randint(1, 8 * 128)
        phs = 128 if r.random() < 0.6 else r.randint(1, 16 * 128)
        o = R.edge(mode, regs, smin, smax, rts, cull, vprect, lhw, phs)
        regline = "".join(f"{regs[k]:08x}" for k in (31, 32, 34, 35, 37, 38, 76, 77, 78, 79))
        wrline = "".join(f"{w:08x}" for w in o["wr"])
        f.write(f"{lhw:06x}{phs:06x}{mode:01x}{smin:08x}{smax:08x}{rts:08x}{cull:01x}{vprect:01x}{regline}"
                f"{o['edges']:072x}{o['bbox']:016x}{o['front']:01x}{o['empty']:01x}{wrline}\n")
print(f"wrote {N} edge vectors")
