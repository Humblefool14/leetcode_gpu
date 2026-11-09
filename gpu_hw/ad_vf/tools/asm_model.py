#!/usr/bin/env python3
"""asm_model -- reference of ad_vf_asm (spec/gpu/vf/ad_vf_asm.md section 4), bit-exact at the
level of warps (vb lanes, vb_last, vl_mask) and of the primitive stream (lanes, kind,
prim_free, prim_last).

Public API (import with sys.path.insert(0, 'tools'); from asm_model import assemble):

    assemble(topology, provoking, items, vertex_offset=0, indexed=True) -> dict

      topology       TOPOLOGY[2:0]: 0 point list, 1 line list, 2 line strip, 3 triangle list,
                     4 triangle strip, 5 triangle fan, 6/7 reserved (assembled as points).
      provoking      PROVOKING[0]: 0 first vertex, 1 last vertex.
      items          iv items in order, each a dict {'index', 'inst', 'restart', 'last'}
                     (or a 4-tuple (index, inst, restart, last)); 'last' must be on the final
                     item only (ad_vf_index's iv_last).
      vertex_offset  VERTEX_OFFSET (added mod 2**32 when indexed).
      indexed        INDEX_FORMAT != 0.

    returns {
      'warps': [ {'verts': [ {'index', 'inst', 'lane', 'last'} ... ]   # vb_* in order
                  'mask':  int,                                       # vl_mask
                  'nprims': int } ... ],                              # primitives naming it
      'prims': [ {'warp': w,              # warp ordinal (0, 1, ...) whose PT block it names
                  'lanes': (l0, l1, l2),  # slot s names PT entry ptbase(w) + lanes[s]
                  'kind': 0|1|2,          # prim_vtx[25:24]
                  'free': int,            # prim_free[2:0]
                  'last': bool,           # prim_last
                  'verts': ((index, inst), x3) } ... ] }   # vertex of each slot (vb values)

    prim_vtx(ptbases, prim) -> 26-bit prim_vtx given the PT base of each warp (list or dict).

    reference(topology, provoking, items, vertex_offset=0, indexed=True)
      -> [(((index, inst), x3), kind) ...]  Vulkan's primitive order without warps (used as an
         independent check of assemble()).

Rules (spec section 4, with the readings recorded in its section 10):
  * every vertex item gets its own lane; a warp closes when its 32 lanes are used, before a list
    primitive (line/triangle list) that no longer fits in the lanes left, or at the last item;
  * vertices later primitives still need are re-sent into the next warp's lanes 0 and 1
    (strip: the last two; fan: first and last; line strip: the last; list: the started ones --
    never needed in practice because of the fit rule);
  * a restart marker or a change of instance ends the strip / fan / incomplete list primitive
    (carried vertices are dropped when the next warp's first vertex is of another instance);
  * prim orders: list (A,B,V) / last (V,A,B); strip i first (i, i+1+i%2, i+2-i%2), last
    (i+2, i+i%2, i+1-i%2); fan (i+1, i+2, 0) / last (i+2, 0, i+1); line (a,b,b) / last (b,a,a);
    point (p,p,p);
  * prim_free: within a warp, the last primitive naming a lane sets the bit of the lowest slot
    naming it; vl_mask = lanes named by some primitive of the warp.
"""

M32 = (1 << 32) - 1
POINT, LLIST, LSTRIP, TLIST, TSTRIP, FAN = 0, 1, 2, 3, 4, 5


def cls_of(topology):
    t = topology & 7
    return POINT if t >= 6 else t


def kind_of(topology):
    c = cls_of(topology)
    return 0 if c == POINT else (1 if c in (LLIST, LSTRIP) else 2)


def _norm(it):
    if isinstance(it, dict):
        return (it['index'] & M32, it['inst'] & M32, bool(it.get('restart', False)), bool(it.get('last', False)))
    i, n, r, l = it
    return (i & M32, n & M32, bool(r), bool(l))


def order(cls, prov, par, x, y, z):
    """Provoking / rotation order (the ad_vf_asm_order leaf).  Inputs in assembly order:
    lines (a, b, -), triangle list (A, B, V), strip (v_i, v_i+1, v_i+2) with par = i % 2,
    fan (v_i+1, v_i+2, v_0), point (p, -, -)."""
    if cls == POINT:
        return (x, x, x)
    if cls in (LLIST, LSTRIP):
        return (y, x, x) if prov else (x, y, y)
    if cls == TLIST:
        return (z, x, y) if prov else (x, y, z)
    if cls == TSTRIP:
        if par:
            return (z, y, x) if prov else (x, z, y)
        return (z, x, y) if prov else (x, y, z)
    # fan
    return (y, z, x) if prov else (x, y, z)


def _psize(cls):
    return {LLIST: 2, TLIST: 3}.get(cls, 1)


class _Run:
    """Assembly state of the current strip / fan / list primitive (the ad_vf_asm_step leaf)."""

    def __init__(self, cls):
        self.cls = cls
        self.reset()

    def reset(self):
        self.n = 0
        self.par = 0
        self.inst = None
        self.r0 = None   # (lane, (index, inst))
        self.r1 = None

    def add(self, lane, val):
        """Adds a vertex; returns the primitive formed as (x, y, z, par) lanes or None."""
        c, n = self.cls, self.n
        self.inst = val[1]
        v = (lane, val)
        if c == POINT:
            return (v, v, v, 0)
        if c == LLIST:
            if n == 0:
                self.r0, self.n = v, 1
                return None
            self.n = 0
            return (self.r0, v, v, 0)
        if c == LSTRIP:
            p = (self.r1, v, v, 0) if n >= 1 else None
            self.r1, self.n = v, 1
            return p
        if c == TLIST:
            if n == 0:
                self.r0, self.n = v, 1
                return None
            if n == 1:
                self.r1, self.n = v, 2
                return None
            self.n = 0
            return (self.r0, self.r1, v, 0)
        if c == TSTRIP:
            if n == 0:
                self.r1, self.n = v, 1
                return None
            if n == 1:
                self.r0, self.r1, self.n = self.r1, v, 2
                return None
            p = (self.r0, self.r1, v, self.par)
            self.r0, self.r1, self.par = self.r1, v, self.par ^ 1
            return p
        # fan
        if n == 0:
            self.r0, self.n = v, 1
            return None
        if n == 1:
            self.r1, self.n = v, 2
            return None
        p = (self.r1, v, self.r0, 0)
        self.r1 = v
        return p

    def carry(self):
        """Slots re-sent into the next warp, in lane order (the ad_vf_asm_carry leaf)."""
        c, n = self.cls, self.n
        if n == 0 or c == POINT:
            return []
        if c in (TSTRIP, FAN, TLIST):
            if n >= 2:
                return ['r0', 'r1']
            return ['r1'] if c == TSTRIP else ['r0']
        if c == LSTRIP:
            return ['r1']
        return ['r0']  # line list, one started vertex


def assemble(topology, provoking, items, vertex_offset=0, indexed=True):
    cls = cls_of(topology)
    kind = kind_of(topology)
    prov = provoking & 1
    psize = _psize(cls)
    is_list = cls in (LLIST, TLIST)
    its = [_norm(x) for x in items]
    run = _Run(cls)
    warps, prims = [], []
    cur = None       # current warp: {'verts', 'prims'}

    def close():
        nonlocal cur
        cur['verts'][-1]['last'] = True
        warps.append(cur)
        cur = None

    k = 0
    while k < len(its):
        idx, inst, rst, last = its[k]
        if cur is None:                      # NEXT: between warps
            if rst:
                run.reset()
                k += 1
                continue
            if run.n and inst != run.inst:
                run.reset()
            cur = {'verts': [], 'prims': []}
            for lane, s in enumerate(run.carry()):
                ln_, val = getattr(run, s)
                cur['verts'].append({'index': val[0], 'inst': val[1], 'lane': lane, 'last': False})
                setattr(run, s, (lane, val))
        # SEND
        if rst:
            run.reset()
            k += 1
            if last:
                close()
            continue
        if run.n and inst != run.inst:
            run.reset()
        lane = len(cur['verts'])
        if is_list and run.n == 0 and lane + psize > 32:
            close()
            continue
        vidx = (idx + vertex_offset) & M32 if indexed else idx
        val = (vidx, inst)
        cur['verts'].append({'index': vidx, 'inst': inst, 'lane': lane, 'last': False})
        p = run.add(lane, val)
        if p is not None:
            x, y, z, par = p
            o = order(cls, prov, par, x, y, z)
            cur['prims'].append({'warp': len(warps), 'lanes': tuple(v[0] for v in o), 'kind': kind,
                                 'verts': tuple(v[1] for v in o)})
        k += 1
        if last or lane == 31:
            close()
    assert cur is None, "items must end with an item marked last"

    for w in warps:
        mask, lastuse = 0, {}
        for j, p in enumerate(w['prims']):
            for s, l in enumerate(p['lanes']):
                mask |= 1 << l
                lastuse[l] = j
        for j, p in enumerate(w['prims']):
            f, seen = 0, set()
            for s, l in enumerate(p['lanes']):
                if l not in seen and lastuse[l] == j:
                    f |= 1 << s
                seen.add(l)
            p['free'] = f
            p['last'] = False
            prims.append(p)
        w['mask'] = mask
        w['nprims'] = len(w['prims'])
        del w['prims']
    if prims:
        prims[-1]['last'] = True
    return {'warps': warps, 'prims': prims}


def prim_vtx(ptbases, prim):
    b = ptbases[prim['warp']]
    v = 0
    for s, l in enumerate(prim['lanes']):
        v |= ((b + l) & 0xFF) << (8 * s)
    return v | (prim['kind'] << 24)


def reference(topology, provoking, items, vertex_offset=0, indexed=True):
    """Vulkan's primitives without warps: runs split at restart markers and instance changes;
    orders straight from the spec formulas (vertex numbers within a run)."""
    cls, kind, prov = cls_of(topology), kind_of(topology), provoking & 1
    its = [_norm(x) for x in items]
    runs, cur, cinst = [], [], None
    for idx, inst, rst, last in its:
        if rst or (cur and inst != cinst):
            if cur:
                runs.append(cur)
            cur = []
        if not rst:
            cur.append(((idx + vertex_offset) & M32 if indexed else idx, inst))
            cinst = inst
    if cur:
        runs.append(cur)
    out = []
    for v in runs:
        n = len(v)
        tri = []
        if cls == POINT:
            tri = [(i, i, i) for i in range(n)]
        elif cls == LLIST:
            tri = [((2 * i + 1, 2 * i, 2 * i) if prov else (2 * i, 2 * i + 1, 2 * i + 1)) for i in range(n // 2)]
        elif cls == LSTRIP:
            tri = [((i + 1, i, i) if prov else (i, i + 1, i + 1)) for i in range(n - 1)]
        elif cls == TLIST:
            tri = [((3 * i + 2, 3 * i, 3 * i + 1) if prov else (3 * i, 3 * i + 1, 3 * i + 2)) for i in range(n // 3)]
        elif cls == TSTRIP:
            for i in range(n - 2):
                if prov:
                    tri.append((i + 2, i + i % 2, i + 1 - i % 2))
                else:
                    tri.append((i, i + 1 + i % 2, i + 2 - i % 2))
        else:
            for i in range(n - 2):
                tri.append((i + 2, 0, i + 1) if prov else (i + 1, i + 2, 0))
        for t in tri:
            out.append((tuple(v[a] for a in t), kind))
    return out


def check(topology, provoking, items, vertex_offset=0, indexed=True):
    """Self-consistency of assemble() against reference() and the PT last-use rules."""
    r = assemble(topology, provoking, items, vertex_offset, indexed)
    ref = reference(topology, provoking, items, vertex_offset, indexed)
    got = [(p['verts'], p['kind']) for p in r['prims']]
    assert got == ref, (topology, provoking, got[:4], ref[:4])
    for w, wr in enumerate(r['warps']):
        assert 1 <= len(wr['verts']) <= 32
        assert [v['lane'] for v in wr['verts']] == list(range(len(wr['verts'])))
        cnt = {}
        for p in r['prims']:
            if p['warp'] != w:
                continue
            for s, l in enumerate(p['lanes']):
                assert (wr['mask'] >> l) & 1
                assert wr['verts'][l]['index'] == p['verts'][s][0] and wr['verts'][l]['inst'] == p['verts'][s][1]
                if (p['free'] >> s) & 1:
                    assert l not in cnt
                    cnt[l] = 1
        assert sorted(cnt) == [l for l in range(32) if (wr['mask'] >> l) & 1]
    return r


if __name__ == '__main__':
    import random
    rnd = random.Random(1)
    n = 0
    for t in range(8):
        for prov in (0, 1):
            for _ in range(150):
                ln = rnd.randint(1, 120)
                its, inst = [], 0
                for k in range(ln):
                    if rnd.random() < 0.05:
                        inst += 1
                    rs = rnd.random() < 0.08
                    its.append((rnd.getrandbits(32), inst, rs, k == ln - 1))
                check(t, prov, its, rnd.getrandbits(32), rnd.random() < 0.7)
                n += 1
    print("asm_model self-check OK (%d draws)" % n)
