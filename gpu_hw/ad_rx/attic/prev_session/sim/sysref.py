"""System-level reference for ad_rx: clip, project, snap, cover, interpolate.

Coverage is exact (integer edge functions on the snapped vertices, top-left
rule, pixel centres / standard 4x sample positions); attributes are compared
against double precision with a tolerance.
"""
import fpref as M
import clipref as C
import edgeref as R

ONE = 0x3F800000


def f(b):
    s, v = M.dec(b)
    if isinstance(v, str):
        return float("nan")
    return float(-v if s else v)


def window(v, vp):
    xs, ys, xo, yo, zs, zo = vp
    rw = M.fdiv(ONE, v[3])
    xd, yd, zd = M.fmul(v[0], rw), M.fmul(v[1], rw), M.fmul(v[2], rw)
    xw = M.fadd(M.fmul(xs, xd), xo)
    yw = M.fadd(M.fmul(ys, yd), yo)
    zw = M.fadd(M.fmul(zs, zd), zo)
    return xw, yw, zw


def clip_tri(verts, vp4, near=True):
    """verts: 3 x [x, y, z, w]; returns the fan triangles (7-word vertices)."""
    poly = [v + [ONE if j == k else 0 for j in range(3)] for k, v in enumerate(verts)]
    # trivial accept as the RTL (exact compares)
    def ok(v):
        x, y, z, w = (f(c) for c in v[:4])
        return w >= 2 ** -16 and (not near or z >= 0) and abs(x) <= 4 * w and abs(y) <= 4 * w
    if all(ok(v) for v in poly):
        return [poly]
    need_g = any(not (f(v[3]) >= 2 ** -16 and abs(f(v[0])) <= 4 * f(v[3]) and abs(f(v[1])) <= 4 * f(v[3])) for v in poly)
    planes = [0] + ([1] if near else []) + ([3, 4, 5, 6] if need_g else [])
    for pl in planes:
        poly = C.cut(poly, False, pl, vp4)
        if not poly:
            return []
    return [[poly[0], poly[i], poly[i + 1]] for i in range(1, len(poly) - 1)]


SAMP = [(-32, -96), (96, -32), (-96, 32), (32, 96)]


def cover(tri7, vp, rts, ms4):
    """Covered pixels of one (clipped) triangle -> {(x, y): (sample bits, b0, b1, b2, z)}."""
    win = [window(v, vp) for v in tri7]
    regs = {31: win[0][0], 32: win[0][1], 34: win[1][0], 35: win[1][1],
            37: win[2][0], 38: win[2][1], 76: 0, 77: 0, 78: 0, 79: 0}
    o = R.edge(2, regs, 0, 0, rts, 0, 0)
    if o["empty"]:
        return {}
    bb = o["bbox"]
    xmn, ymn, xmx, ymx = bb & 0xFFFF, (bb >> 16) & 0xFFFF, (bb >> 32) & 0xFFFF, bb >> 48
    edges = []
    for i in range(3):
        rec = (o["edges"] >> (96 * i)) & ((1 << 96) - 1)
        A = rec & 0xFFFFFF; A -= (1 << 24) if A >> 23 else 0
        B = (rec >> 24) & 0xFFFFFF; B -= (1 << 24) if B >> 23 else 0
        E = rec >> 48; E -= (1 << 48) if E >> 47 else 0
        edges.append((A, B, E))
    # double-precision attributes from window coordinates
    P = [(f(w[0]), f(w[1]), f(w[2])) for w in win]
    W = [f(v[3]) for v in tri7]
    WT = [[f(v[4 + k]) for k in range(3)] for v in tri7]
    den = (P[1][0] - P[0][0]) * (P[2][1] - P[0][1]) - (P[2][0] - P[0][0]) * (P[1][1] - P[0][1])
    out = {}
    for py in range(ymn, ymx):
        for px in range(xmn, xmx):
            def inside(dx, dy):
                return all(E + (px - xmn) * A * 256 + (py - ymn) * B * 256 + dx * A + dy * B >= 0
                           for A, B, E in edges)
            cen = inside(0, 0)
            bits = sum(1 << s for s, (dx, dy) in enumerate(SAMP) if inside(dx, dy)) if ms4 else int(cen)
            if not bits:
                continue
            cx, cy = px + 0.5, py + 0.5
            l1 = ((cx - P[0][0]) * (P[2][1] - P[0][1]) - (P[2][0] - P[0][0]) * (cy - P[0][1])) / den if den else 0
            l2 = ((P[1][0] - P[0][0]) * (cy - P[0][1]) - (cx - P[0][0]) * (P[1][1] - P[0][1])) / den if den else 0
            lam = [1 - l1 - l2, l1, l2]
            q = sum(lam[i] / W[i] for i in range(3))
            b = [sum(lam[i] * WT[i][k] / W[i] for i in range(3)) / q for k in range(3)]
            z = sum(lam[i] * P[i][2] for i in range(3))
            out[(px, py)] = (bits, cen, b[0], b[1], b[2], z)
    return out
