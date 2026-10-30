#!/usr/bin/env python3
"""Reference model + vectors for the ad_rx end-to-end test (sim/ad_rx_tb.sv).

gen  : writes sim/rx_prims.txt (one primitive per line) and sim/rx_exp.txt
check: compares sim/rx_out.txt (from the testbench) with the expectation.

Model (the spec's construction): window = fp32((x * fp32(1/w)) * xs + xo);
snap RNE to 1/256; triangle corners ordered so D > 0; edge i: A = Pi.y - Pj.y,
B = Pj.x - Pi.x, E = A (cx - Pi.x) + B (cy - Pi.y) - bias, bias 0 on top-left
edges; covered when E >= 0 at the pixel centre for all three edges; bbox
floor(min/256) .. floor(max/256) + 1 clipped to the RT.  Lines and points are
covered as their two sub-triangles.  Near-clipped triangles (some z < 0) are
checked against a float64 model with a boundary tolerance.
"""
import sys, random, struct
import numpy as np

W, H = 64, 48
XS, YS, XO, YO, ZS, ZO = W/2, H/2, W/2, H/2, 1.0, 0.0
f32 = np.float32

def fbits(v): return struct.unpack('<I', struct.pack('<f', float(v)))[0]

def window(x, y, z, w):
    iw = f32(1.0) / f32(w)
    wx = f32(f32(f32(x) * iw) * f32(XS)) + f32(XO)
    wy = f32(f32(f32(y) * iw) * f32(YS)) + f32(YO)
    wz = f32(f32(f32(z) * iw) * f32(ZS)) + f32(ZO)
    return float(wx), float(wy), float(wz)

def snap(v):
    s = float(v) * 256.0                       # exact in float64
    r = round(s)                               # Python rounds half to even
    return max(-(2**22 - 1), min(2**22 - 1, int(r)))

def tri_cover(P, sc=None):
    """P: 3 snapped (x, y). Returns the set of covered pixels."""
    (x0, y0), (x1, y1), (x2, y2) = P
    D = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
    if D == 0: return set()
    if D < 0: P = [P[0], P[2], P[1]]
    xs = [p[0] for p in P]; ys = [p[1] for p in P]
    bx0, by0 = max(0, min(xs) >> 8), max(0, min(ys) >> 8)
    bx1, by1 = min(W, (max(xs) >> 8) + 1), min(H, (max(ys) >> 8) + 1)
    if sc:
        bx0, by0 = max(bx0, sc[0]), max(by0, sc[1]); bx1, by1 = min(bx1, sc[2]), min(by1, sc[3])
    out = set()
    edges = []
    for i in range(3):
        j = (i + 1) % 3
        A = P[i][1] - P[j][1]; B = P[j][0] - P[i][0]
        bias = 0 if (A > 0 or (A == 0 and B > 0)) else 1
        edges.append((A, B, P[i][0], P[i][1], bias))
    for py in range(by0, by1):
        for px in range(bx0, bx1):
            cx, cy = px * 256 + 128, py * 256 + 128
            if all(A * (cx - xi) + B * (cy - yi) - b >= 0 for A, B, xi, yi, b in edges):
                out.add((px, py))
    return out

def line_cover(a, b, hl=128):
    dx, dy = b[0] - a[0], b[1] - a[1]
    xm = abs(dx) >= abs(dy)
    if (abs(dx) if xm else abs(dy)) == 0: return [set(), set()]
    o = (0, hl) if xm else (hl, 0)
    am = (a[0] - o[0], a[1] - o[1]); ap = (a[0] + o[0], a[1] + o[1])
    bm = (b[0] - o[0], b[1] - o[1]); bp = (b[0] + o[0], b[1] + o[1])
    return [tri_cover([am, bm, bp]), tri_cover([am, bp, ap])]

def point_cover(p, h=128):
    mm = (p[0] - h, p[1] - h); pm = (p[0] + h, p[1] - h); pp = (p[0] + h, p[1] + h); mp = (p[0] - h, p[1] + h)
    return [tri_cover([mm, pm, pp]), tri_cover([mm, pp, mp])]

def gen(seed=11):
    r = random.Random(seed)
    prims = []
    def v(x, y, z, w): return (x * w, y * w, z * w, w)
    for _ in range(36):                                   # unclipped triangles
        w = [r.uniform(0.6, 2.0) for _ in range(3)]
        c = (r.uniform(-0.9, 0.9), r.uniform(-0.9, 0.9)); s = r.choice([0.05, 0.15, 0.4, 0.9])
        prims.append(('T', [v(c[0] + r.uniform(-s, s), c[1] + r.uniform(-s, s), r.uniform(0.1, 0.9), w[i]) for i in range(3)]))
    # shared edge pair, exact pixel-centre hits, a zero-area and a sub-pixel triangle
    prims.append(('T', [v(-0.5, -0.5, 0.5, 1), v(0.5, -0.5, 0.5, 1), v(0.5, 0.5, 0.5, 1)]))
    prims.append(('T', [v(-0.5, -0.5, 0.5, 1), v(0.5, 0.5, 0.5, 1), v(-0.5, 0.5, 0.5, 1)]))
    prims.append(('T', [v(-0.2, -0.2, 0.5, 1), v(0.0, 0.0, 0.5, 1), v(0.2, 0.2, 0.5, 1)]))
    prims.append(('T', [v(0.01, 0.01, 0.5, 1), v(0.02, 0.01, 0.5, 1), v(0.01, 0.02, 0.5, 1)]))
    prims.append(('T', [v(-1.0, -1.0, 0.3, 1), v(1.0, -1.0, 0.3, 1), v(-1.0, 1.0, 0.3, 1)]))
    for _ in range(8):                                    # lines
        a = (r.uniform(-0.9, 0.9), r.uniform(-0.9, 0.9)); b = (r.uniform(-0.9, 0.9), r.uniform(-0.9, 0.9))
        prims.append(('L', [v(a[0], a[1], 0.5, 1), v(b[0], b[1], 0.5, 1)]))
    prims.append(('L', [v(-0.5, 0.1, 0.5, 1), v(0.5, 0.1, 0.5, 1)]))   # horizontal
    prims.append(('L', [v(0.2, -0.6, 0.5, 1), v(0.2, 0.6, 0.5, 1)]))   # vertical
    for _ in range(6):                                    # points
        prims.append(('P', [v(r.uniform(-0.9, 0.9), r.uniform(-0.9, 0.9), 0.5, 1)]))
    for _ in range(6):                                    # near-clipped (some z < 0, all w > 0)
        w = [r.uniform(0.8, 1.5) for _ in range(3)]
        prims.append(('N', [(r.uniform(-0.6, 0.6) * w[i], r.uniform(-0.6, 0.6) * w[i],
                             r.uniform(-0.5, 0.6) * w[i], w[i]) for i in range(3)]))
    return prims

def expect(kind, vs):
    if kind == 'N':
        return None
    S = [snap_xy(vv) for vv in vs]
    if kind == 'T': return tri_cover(S)
    if kind == 'L': return line_cover(S[0], S[1])
    return point_cover(S[0])

def snap_xy(vv):
    wx, wy, _ = window(*vv)
    return (snap(wx), snap(wy))

def near_ref(vs):
    """float64: pixel centres inside the projected triangle with interpolated z_clip >= 0."""
    P = []
    for x, y, z, w in vs:
        P.append((x / w * XS + XO, y / w * YS + YO, z, w))
    out_in, out_edge = set(), set()
    (x0, y0, _, _), (x1, y1, _, _), (x2, y2, _, _) = P
    D = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
    if abs(D) < 1e-9: return out_in, out_edge
    for py in range(H):
        for px in range(W):
            cx, cy = px + 0.5, py + 0.5
            l1 = ((cx - x0) * (y2 - y0) - (x2 - x0) * (cy - y0)) / D
            l2 = ((x1 - x0) * (cy - y0) - (cx - x0) * (y1 - y0)) / D
            l0 = 1 - l1 - l2
            # perspective-correct z_clip
            iw = l0 / P[0][3] + l1 / P[1][3] + l2 / P[2][3]
            zc = (l0 * P[0][2] / P[0][3] + l1 * P[1][2] / P[1][3] + l2 * P[2][2] / P[2][3]) / iw
            m = min(l0, l1, l2) * abs(D) / max(1e-9, max(abs(x1-x0)+abs(y1-y0), abs(x2-x0)+abs(y2-y0)))
            if min(l0, l1, l2) >= 0 and zc >= 0:
                out_in.add((px, py))
            if abs(m) < 0.02 or abs(zc) < 0.02:
                out_edge.add((px, py))
    return out_in, out_edge

def main_gen():
    prims = gen()
    with open('rx_prims.txt', 'w') as f:
        for k, vs in prims:
            kind = {'T': 2, 'N': 2, 'L': 1, 'P': 0}[k]
            vv = vs + [vs[-1]] * (3 - len(vs))
            f.write(f"{kind} " + ' '.join(f"{fbits(c):08x}" for vx in vv for c in vx) + "\n")
    print(f"{len(prims)} primitives")

def main_check():
    prims = gen()
    got, cur = [], None
    for line in open('rx_out.txt'):
        t = line.split()
        if t[0] == 'P': cur = {}; got.append(cur)
        elif t[0] == 'Q':
            x, y, m = int(t[1]), int(t[2]), int(t[3], 16)
            for l in range(4):
                if m >> l & 1:
                    p = (x + (l & 1), y + (l >> 1)); cur[p] = cur.get(p, 0) + 1
    assert len(got) == len(prims), (len(got), len(prims))
    bad = 0; n_px = 0
    for i, ((k, vs), g) in enumerate(zip(prims, got)):
        dup = [p for p, c in g.items() if c > 1]
        if dup:
            print(f"prim {i} {k}: pixels covered twice: {dup[:5]}"); bad += 1
        gs = set(g)
        n_px += len(gs)
        if k == 'N':
            inside, edge = near_ref(vs)
            miss = (inside - gs) - edge; extra = (gs - inside) - edge
            if miss or extra:
                print(f"prim {i} N: missing {sorted(miss)[:5]} extra {sorted(extra)[:5]}"); bad += 1
            continue
        e = expect(k, vs)
        if isinstance(e, list):
            if e[0] & e[1]:
                print(f"prim {i} {k}: reference sub-triangles overlap"); bad += 1
            e = e[0] | e[1]
        if gs != e:
            print(f"prim {i} {k}: missing {sorted(e - gs)[:6]} extra {sorted(gs - e)[:6]}"); bad += 1
    # shared edge pair (prims 36, 37): no pixel in both, union = the square
    a, b = set(got[36]), set(got[37])
    if a & b: print("shared edge: pixels in both triangles", sorted(a & b)[:5]); bad += 1
    print(("PASS" if bad == 0 else "FAIL") + f" ad_rx.e2e: {len(prims)} primitives, {n_px} pixels, {bad} mismatching")

if __name__ == '__main__':
    {'gen': main_gen, 'check': main_check}[sys.argv[1]]()
