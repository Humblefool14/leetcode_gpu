#!/usr/bin/env python3
"""ad_rx system test: random clip-space triangles (some crossing the near
plane and the guard band) through the whole RTL; warps checked against
sim/sysref.py.

    python3 sim/sys_test.py gen  [ms4] [n]   -> sim/vec/sys_*.hex
    python3 sim/sys_test.py check            <- build/sys_frags.txt
"""
import json, pathlib, random, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import fpref as M
import sysref as S
from fractions import Fraction as Fr

D = pathlib.Path(__file__).parent / "vec"
ROOT = pathlib.Path(__file__).parent.parent


def fp(x):
    x = Fr(x).limit_denominator(1 << 40) if not isinstance(x, Fr) else x
    return 0 if x == 0 else M.rnd(1 if x < 0 else 0, abs(x))


def gen(ms4, n):
    r = random.Random(0x5E5 + ms4)
    W, H = 64, 48
    vp = [fp(W / 2), fp(H / 2), fp(W / 2), fp(H / 2), fp(1), fp(0)]   # xs ys xo yo zs zo
    st = [(0x050 + i, vp[i]) for i in range(6)]
    st += [(0x073, (H << 16) | W), (0x05B, 2), (0x05E, 2 if ms4 else 0), (0x059, 0),
           (0x05A, 0), (0x058, 0), (0x05F, 0), (0x066, 7)]
    pt = {}
    prims = []
    tris = {}
    for t in range(n):
        vs = []
        for k in range(3):
            w = Fr(r.randint(500, 2500), 1000)
            if r.random() < 0.12:
                w = Fr(r.randint(-800, 300), 1000)          # behind / near the eye
            xw, yw = Fr(r.randint(-8 * 256, (W + 8) * 256), 256), Fr(r.randint(-8 * 256, (H + 8) * 256), 256)
            if r.random() < 0.05:
                xw = Fr(r.choice([-200000, 200000]))       # far outside: guard band
            zw = Fr(r.randint(0, 1000), 1000)
            aw = abs(w) if w != 0 else Fr(1, 1000)
            x = (xw - W / 2) / (W / 2) * aw
            y = (yw - H / 2) / (H / 2) * aw
            vs.append([fp(x), fp(y), fp(zw * aw), fp(w)])
        ents = [3 * t + k for k in range(3)]
        for k in range(3):
            pt[ents[k]] = vs[k] + [t, 0xC0DE0000 | k]
        prims.append((2, ents, 7, int(t == n - 1)))
        tris[t] = vs
    with open(D / "sys_state.hex", "w") as fh:
        for i, d in st:
            fh.write(f"{i:03x}{d:08x}\n")
    with open(D / "sys_pt.hex", "w") as fh:
        for e in range(256):
            words = pt.get(e, [0] * 6)
            for wd in range(8):
                fh.write(f"{(words[wd] if wd < len(words) else 0):08x}\n")
    with open(D / "sys_prims.hex", "w") as fh:
        for kind, ents, fr, last in prims:
            fh.write(f"{kind:01x}{ents[2]:02x}{ents[1]:02x}{ents[0]:02x}{fr:01x}{last:01x}\n")
    json.dump(dict(ms4=ms4, n=n, vp=vp, W=W, H=H,
                   tris={k: [[int(c) for c in v] for v in vs] for k, vs in tris.items()}),
              open(D / "sys_cfg.json", "w"))
    print(f"generated {n} triangles, ms4={ms4}")


def check():
    cfg = json.load(open(D / "sys_cfg.json"))
    ms4, vp = cfg["ms4"], cfg["vp"]
    rts = (cfg["H"] << 16) | cfg["W"]
    frags, frees = {}, []
    for line in open(ROOT / "build" / "sys_frags.txt"):
        p = line.split()
        if p[0] == "F":
            tri = int(p[1], 16)
            x, y = int(S.f(int(p[2], 16)) - 0.5), int(S.f(int(p[3], 16)) - 0.5)
            frags.setdefault(tri, []).append((x, y, int(p[4], 16), *[S.f(int(v, 16)) for v in p[5:9]]))
        elif p[0] == "P":
            frees.append(int(p[1], 16))
    err, npix, nclip, worst = 0, 0, 0, 0.0
    for k, vs in cfg["tris"].items():
        t = int(k)
        fan = S.clip_tri(vs, vp[:4])
        nclip += len(fan) != 1 or fan and fan[0][0][4:] != [S.ONE, 0, 0]
        ref = [S.cover(tri, vp, rts, ms4) for tri in fan]
        union = {}
        for rf in ref:
            for xy, v in rf.items():
                union[xy] = union.get(xy, 0) | v[0]
        got = {}
        for x, y, bits, b0, b1, b2, z in frags.get(t, []):
            if got.get((x, y), 0) & bits:
                err += 1; print(f"tri {t}: ({x},{y}) sample covered twice")
            got[(x, y)] = got.get((x, y), 0) | bits
            # attributes against the fan triangle that covers the centre
            for rf in ref:
                if (x, y) in rf and rf[(x, y)][1]:
                    zr = rf[(x, y)][5] if ms4 else min(1.0, max(0.0, rf[(x, y)][5]))
                    e = max(abs(b0 - rf[(x, y)][2]), abs(b1 - rf[(x, y)][3]),
                            abs(b2 - rf[(x, y)][4]), abs(z - zr))
                    worst = max(worst, e)
                    if e > 2e-3:
                        err += 1
                        if err < 10:
                            print(f"tri {t} ({x},{y}) attr err {e:.2e}: got {b0:.5f} {b1:.5f} {b2:.5f} {z:.5f} "
                                  f"exp {rf[(x, y)][2]:.5f} {rf[(x, y)][3]:.5f} {rf[(x, y)][4]:.5f} {rf[(x, y)][5]:.5f}")
        if got != union:
            err += 1
            miss = set(union) - set(got); extra = set(got) - set(union)
            diff = [xy for xy in set(got) & set(union) if got[xy] != union[xy]]
            if err < 10:
                print(f"tri {t}: coverage differs: {len(miss)} missing, {len(extra)} extra, {len(diff)} bit diffs "
                      f"{sorted(miss)[:4]} {sorted(extra)[:4]}")
        npix += len(union)
    want = sorted(3 * int(k) + j for k in cfg["tris"] for j in range(3))
    if sorted(frees) != want:
        err += 1; print(f"PT frees: {len(frees)} of {len(want)}")
    tag = "ms4" if ms4 else "ms1"
    if err == 0:
        print(f"PASS ad_rx.sys.{tag} ({len(cfg['tris'])} triangles, {nclip} clipped, {npix} pixels, "
              f"worst attribute error {worst:.1e}, every PT entry freed once)")
    else:
        print(f"FAIL ad_rx.sys.{tag}: {err} problems")
    return err


if __name__ == "__main__":
    if sys.argv[1] == "gen":
        gen(int(sys.argv[2]) if len(sys.argv) > 2 else 0, int(sys.argv[3]) if len(sys.argv) > 3 else 40)
    else:
        sys.exit(1 if check() else 0)
