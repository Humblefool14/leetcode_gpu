#!/usr/bin/env python3
# gen_mem_vectors.py: vectors for the SU's memory-side testbenches
# (sim/tb/ad_su_lsu_tb.v, ad_su_lds_tb.v, ad_su_cbank_tb.v), from the memory
# semantics of tools/gsi1model.py (its atom(), lanes in order, lw/sw at
# rs1 + imm, atom at rs1, lds/sts at (rs1 + imm) >> 2, atoms at rs1 >> 2,
# lwc word (rs1 + imm) mod CONST_WORDS), extended by the units' error rule
# (spec ad_su_lsu §7: an access to a line outside the memory gives 0 and
# writes nothing).
#
#   python3 -I tools/gen_mem_vectors.py [--seed S]
#
# Writes sim/vec/ad_su_{lsu,lds,cbank}<N>_*.hex for NPHYS N = 4 and 8 (one 32-bit
# word per line).  Formats are described in the testbenches.
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gsi1model as M  # noqa: E402

M32 = 0xFFFFFFFF
LINE = 32
MEM_BYTES = 4096                # ad_amb_mem MEM_LINES 128 in the testbenches
LDS_WORDS = M.LDS_WORDS
CONST_WORDS = M.CONST_WORDS
VEC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sim", "vec")


def wr(path, words):
    with open(os.path.join(VEC, path), "w") as f:
        for w in words:
            f.write("%08x\n" % (w & M32))


class Mem:
    """Byte-addressed data memory with the aperture of the testbench."""

    def __init__(self, rnd):
        self.w = [rnd.getrandbits(32) for _ in range(MEM_BYTES // 4)]

    def ok(self, a):
        return (a & M32) < MEM_BYTES

    def rd32(self, a):
        return self.w[(a & M32) >> 2] if self.ok(a) else 0

    def wr32(self, a, v):
        if self.ok(a):
            self.w[(a & M32) >> 2] = v & M32


def rnd_addrs(rnd, n, err=True):
    """n byte addresses with a random spread (coalescing from 1 to n lines)."""
    span = rnd.choice([4, 32, 64, 96, 256, 4096])
    base = rnd.randrange(0, MEM_BYTES, 32)
    if err and rnd.random() < 0.08:
        base = MEM_BYTES + rnd.randrange(0, 8) * 32     # error lines
    out = []
    for _ in range(n):
        a = base + rnd.randrange(span)
        if not err and a >= MEM_BYTES:
            a %= MEM_BYTES
        out.append(a & M32)
    return out


def rnd_mask(rnd, n):
    c = rnd.random()
    if c < 0.1:
        return 0
    if c < 0.35:
        return (1 << n) - 1
    return rnd.getrandbits(n)


def rec(n, hdr, a, b, c, e):
    assert len(hdr) == 12
    return hdr + a + b + c + e


# ---------------------------------------------------------------- LSU
def gen_lsu(n, rnd):
    mem = Mem(rnd)
    snaps = [list(mem.w)]
    recs = []
    groups = 32 // n

    def instr(sec, op, sub, wrd, rd, ngrp, fixed_side=None):
        imm = rnd.choice([0, 0, 4, -4, 32, -64, 100]) & M32
        for g in range(ngrp):
            exe = rnd_mask(rnd, n) if fixed_side is None else fixed_side
            side = exe & rnd_mask(rnd, n) if rnd.random() < 0.6 else exe
            if fixed_side is not None:
                side = fixed_side
            if op == 2:
                # atomics: few words, often all lanes on one word
                words = [rnd.randrange(0, 64) * 4 for _ in range(rnd.choice([1, 2, 4]))]
                addrs = [rnd.choice(words) + rnd.randrange(4) for _ in range(n)]
                if rnd.random() < 0.1:
                    addrs[rnd.randrange(n)] = MEM_BYTES + 8
            else:
                addrs = rnd_addrs(rnd, n)
            a = [(x - (0 if op == 2 else imm)) & M32 for x in addrs]
            b = [rnd.getrandbits(32) if rnd.random() < 0.7 else rnd.randrange(8) for _ in range(n)]
            c = [rnd.getrandbits(32) for _ in range(n)]
            e = [0] * n
            lanes = 0
            nreq = 0
            if op == 0:
                pend = exe
                lanes = exe
                for i in range(n):
                    if pend >> i & 1:
                        e[i] = mem.rd32(addrs[i])
            elif op == 1:
                pend = exe if sub & 1 else side
                for i in range(n):
                    if pend >> i & 1:
                        mem.wr32(addrs[i], b[i])
            elif op == 2:
                pend = side
                lanes = side
                for i in range(n):
                    if side >> i & 1:
                        # cmpxchg: make the compare equal half of the time
                        if (sub & 15) >= 10 and rnd.random() < 0.5:
                            c[i] = mem.rd32(addrs[i])
                        old = mem.rd32(addrs[i])
                        if mem.ok(addrs[i]):
                            mem.wr32(addrs[i], M.atom(sub & 15, old, b[i], c[i]))
                        e[i] = old
            else:
                pend = 0
            if op in (0, 1):
                nreq = len({addrs[i] >> 5 for i in range(n) if pend >> i & 1})
            elif op == 2:
                nreq = bin(pend).count("1")
            ewr = int(bool(wrd) and lanes != 0 and op in (0, 2))
            hdr = [op, sub, imm, wrd, exe, side, int(g == ngrp - 1), lanes, ewr, nreq, sec, rd]
            recs.append(rec(n, hdr, a, b, c, e))

    # section 0: coalesce (lw)
    for _ in range(150):
        instr(0, 0, 0, 1, rnd.randrange(32), rnd.choice([1, groups]))
    snaps.append(list(mem.w))
    # section 1: store (sw, sw.x, with lw to read back)
    for _ in range(200):
        k = rnd.random()
        if k < 0.6:
            instr(1, 1, rnd.choice([0, 1]), 0, 0, rnd.choice([1, groups]))
        else:
            instr(1, 0, 0, 1, rnd.randrange(32), rnd.choice([1, groups]))
    snaps.append(list(mem.w))
    # section 2: atom (every operation, mixed with lw and sw)
    for _ in range(200):
        k = rnd.random()
        if k < 0.6:
            instr(2, 2, rnd.randrange(11), rnd.choice([0, 1, 1]), rnd.randrange(32),
                  rnd.choice([1, groups]))
        elif k < 0.8:
            instr(2, 0, 0, 1, rnd.randrange(32), 1)
        elif k < 0.9:
            instr(2, 3, 0, 0, 0, 1)
        else:
            instr(2, 1, 0, 0, 0, 1)
    snaps.append(list(mem.w))
    # section 3: empty masks (every op) and fence
    for _ in range(60):
        op = rnd.choice([0, 1, 1, 2, 3])
        instr(3, op, rnd.randrange(11) if op == 2 else 0, 1 if op == 0 else rnd.randrange(2),
              rnd.randrange(32), rnd.choice([1, groups]), fixed_side=0)
    snaps.append(list(mem.w))
    wr("ad_su_lsu%d_ops.hex" % n, [len(recs)] + [w for r in recs for w in r])
    for k, s in enumerate(snaps):
        wr("ad_su_lsu%d_mem%d.hex" % (n, k), s)


# ---------------------------------------------------------------- LDS
def gen_lds(n, rnd):
    lds = [0] * LDS_WORDS
    snaps = [list(lds)]
    recs = []
    groups = 32 // n

    def instr(sec, op, sub, wrd, rd, ngrp, words=None, side_sub=True):
        imm = rnd.choice([0, 4, -8, 64, 1 << 12, 3]) & M32
        for g in range(ngrp):
            exe = rnd_mask(rnd, n)
            side = (exe & rnd_mask(rnd, n)) if side_sub and rnd.random() < 0.6 else exe
            if words is not None:
                addrs = [rnd.choice(words) * 4 + rnd.randrange(4) for _ in range(n)]
            else:
                addrs = [rnd.randrange(0, 1 << 32) if rnd.random() < 0.1 else rnd.randrange(0, 512)
                         for _ in range(n)]
            a = [(x - (0 if op == 2 else imm)) & M32 for x in addrs]
            b = [rnd.getrandbits(32) if rnd.random() < 0.7 else rnd.randrange(8) for _ in range(n)]
            c = [rnd.getrandbits(32) for _ in range(n)]
            e = [0] * n
            lanes = 0
            if op == 0:
                lanes = exe
                for i in range(n):
                    if exe >> i & 1:
                        e[i] = lds[((a[i] + imm) & M32) >> 2 & (LDS_WORDS - 1)]
            elif op == 1:
                for i in range(n):
                    if side >> i & 1:
                        lds[((a[i] + imm) & M32) >> 2 & (LDS_WORDS - 1)] = b[i]
            else:
                lanes = side
                for i in range(n):
                    if side >> i & 1:
                        w = (a[i] & M32) >> 2 & (LDS_WORDS - 1)
                        if (sub & 15) >= 10 and rnd.random() < 0.5:
                            c[i] = lds[w]
                        e[i] = lds[w]
                        lds[w] = M.atom(sub & 15, lds[w], b[i], c[i]) & M32
            ewr = int(bool(wrd) and lanes != 0 and op in (0, 2))
            hdr = [op, sub, imm, wrd, exe, side, int(g == ngrp - 1), lanes, ewr, 0, sec, rd]
            recs.append(rec(n, hdr, a, b, c, e))

    for _ in range(150):                                    # rw
        instr(0, rnd.choice([1, 1, 0]), 0, 1, rnd.randrange(32), rnd.choice([1, groups]))
    snaps.append(list(lds))
    for _ in range(150):                                    # mask
        instr(1, rnd.choice([1, 0]), 0, 1, rnd.randrange(32), rnd.choice([1, groups]),
              words=list(range(32)))
    snaps.append(list(lds))
    for _ in range(300):                                    # atom
        k = rnd.random()
        words = rnd.choice([[5], [7, 9], [1, 2, 3, 4]])
        if k < 0.7:
            instr(2, 2, 16 | rnd.randrange(11), rnd.choice([0, 1, 1]), rnd.randrange(32),
                  rnd.choice([1, groups]), words=words)
        else:
            instr(2, rnd.choice([0, 1]), 0, 1, rnd.randrange(32), 1, words=words)
    snaps.append(list(lds))
    wr("ad_su_lds%d_ops.hex" % n, [len(recs)] + [w for r in recs for w in r])
    for k, s in enumerate(snaps):
        wr("ad_su_lds%d_mem%d.hex" % (n, k), s)


# ---------------------------------------------------------------- cbank
def gen_cbank(n, rnd):
    """Events: 0 LOAD (region, addr, words), 1 lwc group, 2 inv.
    Record: 12 header words, a[n], exp[n]; and per event the visible bank."""
    mem = Mem(rnd)
    bank = [0] * CONST_WORDS
    valid = [False] * CONST_WORDS
    recs, snaps = [], []
    groups = 32 // n

    def visible():
        return [bank[i] if valid[i] else 0 for i in range(CONST_WORDS)]

    def load(region, addr, words):
        if region != 0:
            return
        cnt = min(words, CONST_WORDS)
        cur = addr & ~3 & M32
        for i in range(cnt):
            if not mem.ok(cur):
                return              # the error line ends the load
            bank[i] = mem.rd32(cur)
            valid[i] = True
            cur = (cur + 4) & M32

    def lwc(rd, wrd, ngrp):
        imm = rnd.choice([0, 1, 31, 255, 300, (-5) & M32])
        for g in range(ngrp):
            exe = rnd_mask(rnd, n)
            a = [rnd.getrandbits(32) if rnd.random() < 0.2 else rnd.randrange(300) for _ in range(n)]
            vis = visible()
            e = [vis[(a[i] + imm) & (CONST_WORDS - 1)] if exe >> i & 1 else 0 for i in range(n)]
            ewr = int(bool(wrd) and exe != 0)
            hdr = [1, 0, imm, wrd, exe, 0, int(g == ngrp - 1), exe, ewr, 0, 1, rd]
            recs.append(hdr + a + e)
            snaps.append(vis)

    events = [(0, 256, 256), (0, 0x40, 300), (0, 0x104, 17), (1, 0x200, 100), (0, 0x300, 0),
              (0, 0xF00, 256), ("inv",), (0, 0x10, 5), (0, 0x0, 64), ("inv",), ("inv",),
              (0, 0x7E4, 40), (0, 0x80, 256)]
    for ev in events:
        if ev[0] == "inv":
            for i in range(CONST_WORDS):
                valid[i] = False
            hdr = [2] + [0] * 11
            recs.append(hdr + [0] * (2 * n))
        else:
            load(*ev)
            hdr = [0, ev[0], ev[1], ev[2]] + [0] * 6 + [0, 0]
            recs.append(hdr + [0] * (2 * n))
        snaps.append(visible())
        for _ in range(6):
            lwc(rnd.randrange(32), rnd.choice([1, 1, 0]), rnd.choice([1, groups]))
    wr("ad_su_cbank%d_ops.hex" % n, [len(recs)] + [w for r in recs for w in r])
    wr("ad_su_cbank%d_bank.hex" % n, [w for s in snaps for w in s])
    wr("ad_su_cbank%d_mem.hex" % n, mem.w)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()
    os.makedirs(VEC, exist_ok=True)
    for n in (4, 8):
        gen_lsu(n, random.Random(args.seed * 100 + n))
        gen_lds(n, random.Random(args.seed * 100 + n + 1))
        gen_cbank(n, random.Random(args.seed * 100 + n + 2))


if __name__ == "__main__":
    main()
