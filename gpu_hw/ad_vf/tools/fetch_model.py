#!/usr/bin/env python3
"""fetch_model.py: reference model of ad_vf_fetch (spec/gpu/vf/ad_vf_fetch.md section 4).

FetchModel(line_bytes, mem, memsize).write(idx, data) snoops STATE; .warp(vertices) takes the
vertices of one warp [(index, inst, lane, last), ...] and returns the afs, in order, as dicts
  attr, lane, raw (bytes, the format's size), oob, last, size, err (a byte of the attribute lies
  in a line that answers rsp_error, i.e. at or above memsize: it reads as 0)
and counts the AMB line reads in .nreq.  The line-buffer policy (4 streams s = k[1:0] x 8 entries,
round-robin allocation from a pointer skipping the entry the other line of the attribute hits,
cleared with pointer 0 at warp end) is that of rtl/vf/fetch/ad_vf_fetch_lbuf.v, so the read count
is exact.  Sizes come from tools/fmtmodel.py info().
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fmtmodel  # noqa: E402

M32 = 0xFFFFFFFF
S_FIRST_INSTANCE = 0x025


def s_base(k):
    return 0x030 + 2 * k


def s_desc(k):
    return 0x031 + 2 * k


def s_dst(k):
    return 0x1C0 + k


def s_limit(k):
    return 0x1D0 + k


def element(desc, index, inst, first):
    """Vulkan's rule: per vertex the index; per instance FIRST + (inst - FIRST) / divisor, divisor 0 -> FIRST."""
    if not (desc >> 20) & 1:
        return index & M32
    div = (desc >> 24) & 0xFF
    if div == 0:
        return first & M32
    return (first + ((inst - first) & M32) // div) & M32


class FetchModel:
    def __init__(self, line_bytes=32, mem=b'', memsize=65536, addr_w=32):
        self.lb = line_bytes
        self.ls = line_bytes.bit_length() - 1
        self.mem = mem
        self.memsize = memsize
        self.lmask = (1 << (addr_w - self.ls)) - 1
        self.base = [0] * 16
        self.desc = [0] * 16
        self.dst = [0] * 16
        self.lim = [0] * 16
        self.first = 0
        self.nreq = 0
        self._clear()

    def _clear(self):
        self.valid = [[False] * 8 for _ in range(4)]
        self.tag = [[0] * 8 for _ in range(4)]
        self.ptr = [0] * 4

    def write(self, idx, data):
        data &= M32
        for k in range(16):
            if idx == s_base(k):
                self.base[k] = data
            if idx == s_desc(k):
                self.desc[k] = data
            if idx == s_dst(k):
                self.dst[k] = data
            if idx == s_limit(k):
                self.lim[k] = data
        if idx == S_FIRST_INSTANCE:
            self.first = data

    def byte(self, a):
        a &= M32
        return self.mem[a] if a < self.memsize else 0

    def info(self, k):
        return fmtmodel.info((self.dst[k] >> 24) & 0xFF, (self.desc[k] >> 16) & 0xF)

    def attr(self, k, index, inst):
        """(addr, size, oob, lines) of attribute k of a vertex."""
        size = self.info(k)[0]
        el = element(self.desc[k], index, inst, self.first)
        offset = (self.desc[k] & 0xFFFF) * el
        addr = (self.base[k] + offset) & M32
        lim = self.lim[k]
        oob = bool(lim >> 31) and (offset + size > (lim & 0x7FFFFFFF))
        l0 = (addr >> self.ls) & self.lmask
        l1 = (((addr + size - 1) & M32) >> self.ls) & self.lmask
        return addr, size, oob, (l0, l1)

    def _lookup(self, s, line):
        for e in range(8):
            if self.valid[s][e] and self.tag[s][e] == line:
                return True, e
        return False, 0

    def _fetch_lines(self, s, l0, l1):
        two = l0 != l1
        h0, he0 = self._lookup(s, l0)
        h1, he1 = self._lookup(s, l1)
        m0 = not h0
        m1 = two and not h1
        p = self.ptr[s]
        ae0 = (p + 1) % 8 if (two and h1 and p == he1) else p
        b1 = (ae0 + 1) % 8 if m0 else p
        ae1 = (b1 + 1) % 8 if (not m0 and h0 and b1 == he0) else b1
        if m0:
            self.tag[s][ae0] = l0
            self.valid[s][ae0] = True
            self.nreq += 1
        if m1:
            self.tag[s][ae1] = l1
            self.valid[s][ae1] = True
            self.nreq += 1
        if m1:
            self.ptr[s] = (ae1 + 1) % 8
        elif m0:
            self.ptr[s] = (ae0 + 1) % 8

    def warp(self, verts):
        out = []
        en = [k for k in range(16) if self.dst[k] != 0]
        for (index, inst, lane, last) in verts:
            for i, k in enumerate(en):
                addr, size, oob, (l0, l1) = self.attr(k, index, inst)
                if not oob:
                    self._fetch_lines(k & 3, l0, l1)
                raw = bytes(self.byte(addr + b) for b in range(size))
                err = any(((addr + b) & M32) >= self.memsize for b in range(size))
                out.append(dict(attr=k, lane=lane, raw=raw, oob=oob, last=bool(last and i == len(en) - 1),
                                size=size, err=err and not oob))
            if not en and last:
                out.append(dict(attr=0, lane=lane, raw=b'', oob=False, last=True, size=0, err=False))
        self._clear()
        return out
