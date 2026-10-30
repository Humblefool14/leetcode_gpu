"""Reference model of ad_rx_cpoly's cut (from the spec, RX fp32 arithmetic)."""
import fpref as M

WMIN, G = 0x37800000, 0x467FFC00


def is_in(d):
    e, m = (d >> 23) & 0xFF, d & 0x7FFFFF
    if e == 0xFF and m:
        return False
    return not (d >> 31) or e == 0


def dist(v, pl, vp):
    x, y, z, w = v[0], v[1], v[2], v[3]
    xs, ys, xo, yo = vp
    if pl == 0:
        return M.fadd(w, WMIN, 1)
    if pl == 1:
        return z
    if pl == 2:
        return M.fadd(w, z, 1)
    c, o, s = (y, yo, ys) if pl in (5, 6) else (x, xo, xs)
    t1 = M.fmul(o, w)
    t2 = M.fmul(s, c)
    t3 = M.fadd(t1, t2)
    gw = M.fmul(G, w)
    return M.fadd(gw, t3, 1 if pl in (3, 5) else 0)


def cut(poly, line, pl, vp):
    """poly: list of 7-word vertices.  Returns the new polygon."""
    n = len(poly)
    d = [dist(v, pl, vp) for v in poly]
    ins = [is_in(x) for x in d]
    if all(ins):
        return poly
    if not any(ins):
        return []
    if line:
        s, ne = 0, 1
    else:
        s = next(i for i in range(n) if ins[i] and not ins[i - 1])
        ne = n
    out = []
    for k in range(ne):
        p, q = (s + k) % n, (s + k + 1) % n
        if ins[p]:
            out.append(poly[p])
        if ins[p] != ins[q]:
            a, b = (p, q) if ins[p] else (q, p)
            den = M.fadd(d[a], d[b], 1)
            t = M.fdiv(d[a], den)
            nv = []
            for c in range(7):
                diff = M.fadd(poly[b][c], poly[a][c], 1)
                nv.append(M.fadd(poly[a][c], M.fmul(diff, t)))
            out.append(nv)
    if line and ins[1]:
        out.append(poly[1])
    return out
