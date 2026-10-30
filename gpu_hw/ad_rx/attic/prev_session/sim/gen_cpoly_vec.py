#!/usr/bin/env python3
"""Random triangles / lines cut by sequences of planes -> sim/vec/cpoly.hex.

Line format (hex):  vp(128) line(4) nplanes(4) n0(4) 3 x vertex(224)
                    then per plane: plane(4) nout(4) 10 x vertex(224)
"""
import pathlib, random, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import fpref as M
import clipref as C
from fractions import Fraction as Fr

N = int(sys.argv[1]) if len(sys.argv) > 1 else 400
r = random.Random(0xC1F)
ONE, ZERO = 0x3F800000, 0


def fp(x):
    x = Fr(x)
    return 0 if x == 0 else M.rnd(1 if x < 0 else 0, abs(x))


def rv(scale):
    w = fp(Fr(r.randint(-200, 3000), 1000)) if r.random() < 0.3 else fp(Fr(r.randint(1, 3000), 1000))
    wv = M.dec(w)[1] * (-1 if w >> 31 else 1)
    x = fp(Fr(r.randint(-scale, scale), 100) * (abs(wv) if wv else 1))
    y = fp(Fr(r.randint(-scale, scale), 100) * (abs(wv) if wv else 1))
    z = fp(Fr(r.randint(-1500, 2500), 1000) * (abs(wv) if wv else 1))
    return [x, y, z, w]


lines = []
for i in range(N):
    line = r.random() < 0.25
    nv = 2 if line else 3
    sc = r.choice([100, 400, 3000000])
    vs = [rv(sc) for _ in range(nv)]
    for k, v in enumerate(vs):
        v += [ONE if j == k else ZERO for j in range(3)]
    vp = [fp(r.choice([320, 2048, 9000])), fp(r.choice([240, -2048, 9000])),
          fp(r.choice([320, 6144, 15000])), fp(r.choice([240, 6144]))]
    planes = r.sample(range(7), r.randint(1, 4)) if r.random() < 0.5 else list(range(7))
    planes = sorted(planes)
    poly = vs
    steps = []
    for pl in planes:
        poly = C.cut(poly, line, pl, vp) if poly else []
        steps.append((pl, [list(v) for v in poly]))
        if not poly:
            break
    s = "".join(f"{x:08x}" for x in reversed(vp)) + f"{int(line):01x}{len(steps):01x}{nv:01x}"
    for v in (vs + [[0] * 7] * (3 - nv)):
        s += "".join(f"{w:08x}" for w in reversed(v))
    for pl, pv in steps:
        s += f"{pl:01x}{len(pv):01x}"
        for v in pv + [[0] * 7] * (10 - len(pv)):
            s += "".join(f"{w:08x}" for w in reversed(v))
    lines.append(s)
w = max(len(x) for x in lines)
with open(pathlib.Path(__file__).parent / "vec" / "cpoly.hex", "w") as f:
    for s in lines:
        f.write(s.ljust(w, "0") + "\n")
print(f"wrote {N} cpoly cases, {w * 4} bits per line")
