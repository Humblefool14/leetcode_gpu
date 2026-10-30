"""Reference model of ad_rx_edge (written from the spec, not the RTL)."""
from fractions import Fraction as Fr
import fpref as M

HP, SP, EW = 128, 256, 48
EMAX = (1 << (EW - 1)) - 1


def s24(v):
    v &= 0xFFFFFF
    return v - (1 << 24) if v & 0x800000 else v


def edge(mode, regs, smin, smax, rts, cull, vprect, lhw=128, phs=128):
    """regs: dict reg -> fp32 bits.  Returns dict of outputs."""
    kind, sub, raw = mode & 3, (mode >> 2) & 1, (mode >> 3) & 1
    c = [s24(M.f2fix(regs[r])) for r in (31, 32, 34, 35, 37, 38, 76, 77, 78, 79)]
    a, b, cc = (c[0], c[1]), (c[2], c[3]), (c[4], c[5])
    dx, dy = b[0] - a[0], b[1] - a[1]
    xmaj = abs(dx) >= abs(dy)
    zlen = (abs(dx) == 0) if xmaj else (abs(dy) == 0)
    if kind == 1:
        hx, hy = (0, lhw) if xmaj else (lhw, 0)
        am, ap = (a[0] - hx, a[1] - hy), (a[0] + hx, a[1] + hy)
        bm, bp = (b[0] - hx, b[1] - hy), (b[0] + hx, b[1] + hy)
        w = [am, bm, bp] if not sub else [am, bp, ap]
        q = [a, b, (a[0] + (0 if xmaj else SP), a[1] + (SP if xmaj else 0))]
        pts = [am, ap, bm, bp]
    elif kind == 0:
        h = phs
        mm, pm = (a[0] - h, a[1] - h), (a[0] + h, a[1] - h)
        pp, mp = (a[0] + h, a[1] + h), (a[0] - h, a[1] + h)
        w = [mm, pm, pp] if not sub else [mm, pp, mp]
        q = [a, (a[0] + SP, a[1]), (a[0], a[1] + SP)]
        pts = [mm, pm, pp, mp]
    else:
        w = [a, b, cc]
        q = [a, b, cc]
        pts = [a, b, cc]
    bx0 = min(p[0] for p in pts); bx1 = max(p[0] for p in pts)
    by0 = min(p[1] for p in pts); by1 = max(p[1] for p in pts)
    xmn = max(0, (bx0 + HP - 1) >> 8); ymn = max(0, (by0 + HP - 1) >> 8)
    xmx = min(((bx1 - HP) >> 8) + 1, rts & 0xFFFF)
    ymx = min(((by1 - HP) >> 8) + 1, rts >> 16)
    if smax:
        xmn = max(xmn, smin & 0xFFFF); ymn = max(ymn, smin >> 16)
        xmx = min(xmx, smax & 0xFFFF); ymx = min(ymx, smax >> 16)
    if vprect and not raw:
        xmn = max(xmn, c[6] >> 8); xmx = min(xmx, c[7] >> 8)
        ymn = max(ymn, c[8] >> 8); ymx = min(ymx, c[9] >> 8)

    xmx, ymx = max(xmx, 0), max(ymx, 0)           # never a negative max
    xmn, ymn = min(xmn, xmx), min(ymn, ymx)       # an empty range keeps lo <= hi

    def area(t):
        return (t[1][0] - t[0][0]) * (t[2][1] - t[0][1]) - (t[2][0] - t[0][0]) * (t[1][1] - t[0][1])

    D = area(w)
    if D > 0:
        w = [w[0], w[2], w[1]]
    ocx, ocy = xmn * SP + HP, ymn * SP + HP
    edges = []
    for i in range(3):
        p0, p1 = w[i], w[(i + 1) % 3]
        A, B = p1[1] - p0[1], p0[0] - p1[0]
        E = (ocx - p0[0]) * A + (ocy - p0[1]) * B
        tl = A > 0 or (A == 0 and B > 0)
        E -= 0 if tl else 1
        E = max(-EMAX, min(EMAX, E))
        edges.append((E, B, A))
    ccw = D < 0
    fr = (ccw ^ ((cull >> 2) & 1)) if kind >= 2 else 1
    culled = kind >= 2 and ((cull & 1) if fr else ((cull >> 1) & 1))
    empty = (kind >= 2 and (D == 0 or culled)) or (kind == 1 and zlen) or xmn >= xmx or ymn >= ymx
    out_e = 0
    if not empty:
        for i, (E, B, A) in enumerate(edges):
            out_e |= (((E & ((1 << 48) - 1)) << 48) | ((B & 0xFFFFFF) << 24) | (A & 0xFFFFFF)) << (96 * i)
    bbox = 0 if empty else (ymx << 48) | (xmx << 32) | (ymn << 16) | xmn
    Dq = area(q)
    vals = [Fr(q[1][0] - q[0][0], 256), Fr(q[1][1] - q[0][1], 256),
            Fr(q[2][0] - q[0][0], 256), Fr(q[2][1] - q[0][1], 256),
            Fr(Dq, 65536), Fr(ocx - q[0][0], 256), Fr(ocy - q[0][1], 256)]
    wr = [M.rnd(1 if v < 0 else 0, abs(v)) if v != 0 else 0 for v in vals]
    return dict(edges=out_e, bbox=bbox, front=int(fr), empty=int(empty), wr=wr)
