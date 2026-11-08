"""ds_model.py -- bit-exact reference models of ad_rop_dtest and ad_rop_ds.

dtest(...)   : one (lane, sample) entry, spec ad_rop_dtest.md §4 (on tools/admodel.py).
DSModel      : ad_rop_ds on a byte array (spec ad_rop_ds.md §4 and its §10 assumptions):
               STATE words + a quad sequence -> the quads sent (d_xy, d_smask, d_beat,
               d_color) and the final depth/stencil buffer.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from admodel import cmp_op, fp_cmp, f2unorm, unorm2f, is_nan  # noqa: E402

# STATE indices (rtl/include/ad_rop_state.vh)
S_MS_CTRL = 0x05E
S_DS_BASE = 0x073
S_DS_STRIDE = 0x074
S_DEBUG_COLOR = 0x075
S_DEPTH = 0x076
S_STENCIL_FRONT = 0x077
S_STENCIL_OPS = 0x078
S_STENCIL_BACK = 0x079
S_DBOUNDS_MIN = 0x08B
S_DBOUNDS_MAX = 0x08C

D24, D32F, D16 = 1 << 5, 1 << 6, 1 << 7


def stencil_op(op, s, ref):
    return [s, 0, ref, min(s + 1, 255), max(s - 1, 0), (~s) & 0xFF,
            (s + 1) & 0xFF, (s - 1) & 0xFF][op]


def fmt_of(depth):
    f = (depth >> 5) & 7
    return {1: "d24", 2: "d32f", 4: "d16"}.get(f)


def z_a_of(fmt, stored):
    if fmt == "d32f":
        return stored
    if fmt == "d16":
        return unorm2f(stored & 0xFFFF, 16)
    return unorm2f(stored & 0xFFFFFF, 24)


def dtest(depth, sfront, sback, sops, bmin, bmax, cov, front, zf, stored):
    """-> (pass, wword, wbe).  wword bytes outside wbe are don't-care (returned as computed)."""
    fmt = fmt_of(depth)
    if not cov:
        return 0, 0, 0
    if fmt is None:
        return 1, 0, 0
    # 1. depth bounds
    if (depth >> 9) & 1:
        za = z_a_of(fmt, stored)
        lt0, eq0, un0 = fp_cmp(za, bmin)
        lt1, eq1, un1 = fp_cmp(za, bmax)
        inside = (not un0) and (not lt0) and (not un1) and (lt1 or eq1)
        if not inside:
            return 0, 0, 0
    # 3. depth compare (needed by the stencil op choice)
    op = (depth >> 2) & 7
    if fmt == "d32f":
        lt, eq, un = fp_cmp(zf, stored)
        zword = zf
    else:
        n = 16 if fmt == "d16" else 24
        u = f2unorm(zf, n)
        sv = stored & ((1 << n) - 1)
        if is_nan(zf):
            lt, eq, un = 0, 0, 1
        else:
            lt, eq, un = int(u < sv), int(u == sv), 0
        zword = u
    dres = cmp_op(op, lt, eq, un) if depth & 1 else 1
    # 2. stencil
    sten = (depth >> 8) & 1 and fmt == "d24"
    spass, swr, sdiff = 1, (stored >> 24) & 0xFF, 0
    if sten:
        st = sfront if front else sback
        ops = sops & 0x1FF if front else (sops >> 16) & 0x1FF
        ref, cm, wm, cop = st & 0xFF, (st >> 8) & 0xFF, (st >> 16) & 0xFF, (st >> 24) & 7
        s_a = (stored >> 24) & 0xFF
        a, b = ref & cm, s_a & cm
        spass = cmp_op(cop, int(a < b), int(a == b), 0)
        sop = (ops & 7) if not spass else ((ops >> 3) & 7 if dres else (ops >> 6) & 7)
        new = stencil_op(sop, s_a, ref)
        swr = (s_a & ~wm & 0xFF) | (new & wm)
        sdiff = int(swr != s_a)
    dw = (depth >> 1) & 1 and spass and dres
    passed = int(spass and dres)
    if fmt == "d32f":
        return passed, zword, 0xF if dw else 0
    if fmt == "d16":
        return passed, zword, 0x3 if dw else 0
    return passed, (swr << 24) | zword, (sdiff << 3) | (0x7 if dw else 0)


class DSModel:
    """ad_rop_ds on a byte array of memsz bytes (addresses >= memsz: AMB error ->
    reads are zero, writes are lost)."""

    def __init__(self, mem, stencil=1):
        self.mem = mem              # bytearray
        self.stencil = stencil
        self.st = {}
        self.surv = 0

    def write_state(self, idx, val):
        self.st[idx] = val & 0xFFFFFFFF

    def g(self, idx):
        return self.st.get(idx, 0)

    def _rd(self, a, n):
        v = 0
        for k in range(n):
            ak = (a + k) & 0xFFFFFFFF
            v |= (self.mem[ak] if ak < len(self.mem) else 0) << (8 * k)
        return v

    def _wr(self, a, val, be):
        for k in range(4):
            ak = (a + k) & 0xFFFFFFFF
            if (be >> k) & 1 and ak < len(self.mem):
                self.mem[ak] = (val >> (8 * k)) & 0xFF

    def depth(self):
        d = self.g(S_DEPTH) & 0x3FF
        if not self.stencil:
            d &= ~(1 << 8)
        return d

    def tests_on(self):
        d = self.depth()
        fmt = fmt_of(d)
        return fmt is not None and (d & 1 or (d >> 9) & 1 or ((d >> 8) & 1 and fmt == "d24"))

    def color_out(self, q):
        if not q["dbg"]:
            return q["color"]
        dc = self.g(S_DEBUG_COLOR)
        lane = 0
        for c in range(4):
            lane |= unorm2f((dc >> (8 * c)) & 0xFF, 8) << (32 * c)
        v = 0
        for lnum in range(4):
            v |= lane << (128 * lnum)
        return v

    def quad(self, q):
        """q: dict xy, smask, beat, front, dbg, sdepth, color.  -> output dict or None (dropped)."""
        first = q["beat"] & 1
        if not first:
            sm = self.surv
        elif not self.tests_on():
            sm = q["smask"]
            self.surv = sm
        else:
            sm = self._test(q)
            self.surv = sm
        if sm == 0:
            return None
        return dict(xy=q["xy"], smask=sm, beat=q["beat"], color=self.color_out(q))

    def _test(self, q):
        d = self.depth()
        fmt = fmt_of(d)
        ps = 2 if fmt == "d16" else 4
        S = 4 if (self.g(S_MS_CTRL) & 0xF) == 2 else 1
        x, y = q["xy"] & 0xFFFF, q["xy"] >> 16
        base, stride = self.g(S_DS_BASE), self.g(S_DS_STRIDE)
        args = (d, self.g(S_STENCIL_FRONT) & 0x7FFFFFF, self.g(S_STENCIL_BACK) & 0x7FFFFFF,
                self.g(S_STENCIL_OPS) & 0x1FFFFFF, self.g(S_DBOUNDS_MIN), self.g(S_DBOUNDS_MAX))
        out = 0
        for r in range(2):
            res = []
            for px in range(2):
                lane = 2 * r + px
                for s in range(S):
                    bit = 4 * lane + s
                    if not (q["smask"] >> bit) & 1:
                        continue
                    a = (base + (y + r) * stride + (S * (x + px) + s) * ps) & 0xFFFFFFFF
                    stored = self._rd(a, ps)
                    zf = (q["sdepth"] >> (32 * bit)) & 0xFFFFFFFF
                    p, ww, be = dtest(*args, 1, q["front"], zf, stored)
                    res.append((bit, a, p, ww, be))
            for bit, a, p, ww, be in res:     # a row is tested on the line, then merged
                out |= p << bit
                self._wr(a, ww, be)
        return out
