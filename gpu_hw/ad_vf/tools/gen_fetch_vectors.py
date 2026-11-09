#!/usr/bin/env python3
"""gen_fetch_vectors.py: vectors for sim/tb/ad_vf_fetch_tb.v (and the fmt_info formal table).

Writes (repo-relative):
  sim/vec/fetch_mem.hex     64 KiB memory image, one byte per line
  sim/vec/fetch_cmd.hex     command stream, 80-bit words:
                              [79:76] op: 1 STATE {idx[40:32], data[31:0]}
                                          2 VERT  {last[69], lane[68:64], inst[63:32], index[31:0]}
                                          3 SECT  {id[2:0]}   (follows a WAIT)
                                          4 WAIT  {n_af[31:0]}: all afs up to n_af taken and !busy
                                          15 END
  sim/vec/fetch_exp.hex     expected afs, 160-bit words: {sect[147:145], err[144], size[143:139],
                              last[138], oob[137], lane[136:132], attr[131:128], raw[127:0]}
  sim/vec/fetch_cnt.hex     {number of commands, number of afs}
  sim/vec/fetch_nreq32.hex, fetch_nreq64.hex   AMB reads per section (8 words) for LINE_BYTES 32 / 64
  formal/ad_vf_fmt_info/fmt_info_ref.vh       the case table of fmtmodel.info() for 256 x 16 inputs

Sections (spec section 8): 0 addr, 1 cross, 2 limit, 3 limit0, 4 size12.
"""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import fmtmodel  # noqa: E402
from fetch_model import FetchModel, s_base, s_desc, s_dst, s_limit, S_FIRST_INSTANCE  # noqa: E402

MEMSIZE = 65536
SECTIONS = ['addr', 'cross', 'limit', 'limit0', 'size12']
VK_ALL = list(range(1, 256))
SUPPORTED_VK = sorted(fmtmodel.VK)


class Gen:
    def __init__(self, seed=7):
        self.rng = random.Random(seed)
        self.mem = bytes(self.rng.randrange(256) for _ in range(MEMSIZE))
        self.models = {lb: FetchModel(lb, self.mem, MEMSIZE) for lb in (32, 64)}
        self.cmd = []
        self.exp = []
        self.nreq = {32: [0] * 8, 64: [0] * 8}
        self.sect = 0

    # ---- command helpers
    def wait(self):
        self.cmd.append((4 << 76) | len(self.exp))

    def section(self, i):
        self.wait()
        self.sect = i
        self.cmd.append((3 << 76) | i)

    def state(self, idx, data):
        self.cmd.append((1 << 76) | (idx << 32) | (data & 0xFFFFFFFF))
        for m in self.models.values():
            m.write(idx, data)

    def draw(self, attrs, first=0):
        """attrs: list of 16 dicts (base, desc, dst, lim) or None (disabled: every word 0)."""
        self.wait()
        self.state(S_FIRST_INSTANCE, first)
        for k in range(16):
            a = attrs[k] or dict(base=0, desc=0, dst=0, lim=0)
            self.state(s_base(k), a['base'])
            self.state(s_desc(k), a['desc'])
            self.state(s_dst(k), a['dst'])
            self.state(s_limit(k), a['lim'])

    def warp(self, verts):
        for (index, inst, lane, last) in verts:
            self.cmd.append((2 << 76) | (int(last) << 69) | (lane << 64) | ((inst & 0xFFFFFFFF) << 32) |
                            (index & 0xFFFFFFFF))
        outs = {}
        for lb, m in self.models.items():
            n0 = m.nreq
            outs[lb] = m.warp(verts)
            self.nreq[lb][self.sect] += m.nreq - n0
        assert outs[32] == outs[64]
        for af in outs[32]:
            raw = int.from_bytes(af['raw'], 'little') if af['raw'] else 0
            w = (self.sect << 145) | (int(af['err']) << 144) | (af['size'] << 139) | (int(af['last']) << 138) | \
                (int(af['oob']) << 137) | (af['lane'] << 132) | (af['attr'] << 128) | raw
            self.exp.append(w)

    # ---- random pieces
    def dst_word(self, vk):
        r = self.rng
        if vk:
            return (vk << 24) | (r.choice([0, r.randrange(1 << 8)]))      # may go to r0 with one component
        while True:
            w = r.randrange(1, 256)
            if w:
                return w

    def desc_word(self, stride, fmt, inst=False, div=0):
        return (stride & 0xFFFF) | ((fmt & 0xF) << 16) | (int(inst) << 20) | ((div & 0xFF) << 24)

    def rand_attr(self, fmt_vk=None, fmt_lg=None, lim=0):
        r = self.rng
        vk = fmt_vk if fmt_vk is not None else (r.choice(VK_ALL) if r.random() < 0.5 else 0)
        lg = fmt_lg if fmt_lg is not None else r.randrange(16)
        stride = r.choice([0, 4, 8, 12, 16, 20, 7, 33, 100, r.randrange(0, 512), r.randrange(0, 512)])
        inst = r.random() < 0.4
        div = r.choice([0, 1, 2, 3, 7, 255, r.randrange(2, 256)])
        base = r.randrange(0, 40000)
        return dict(base=base, desc=self.desc_word(stride, lg, inst, div), dst=self.dst_word(vk), lim=lim)

    def rand_warps(self, first, nwarps, maxlanes=32, big=0.05):
        r = self.rng
        for _ in range(nwarps):
            n = r.randrange(1, maxlanes + 1)
            inst = first + r.choice([0, 1, 2, 5, 6, 13, r.randrange(0, 600)])
            if r.random() < big:
                inst = r.randrange(1 << 32)
            verts = []
            for lane in range(n):
                idx = r.randrange(0, 120)
                if r.random() < big:
                    idx = r.randrange(1 << 32)
                verts.append((idx, inst & 0xFFFFFFFF, lane, lane == n - 1))
            self.warp(verts)

    # ---- sections
    def sec_addr(self):
        r = self.rng
        self.section(0)
        # random draws: strides, offsets, per instance with divisors, disabled attributes
        for d in range(12):
            first = r.choice([0, 0, 3, 100, r.randrange(0, 5000)])
            attrs = [self.rand_attr() if r.random() < 0.6 else None for _ in range(16)]
            self.draw(attrs, first)
            self.rand_warps(first, 3)
        # every divisor named in spec section 8 on the same instances (memo hits and misses)
        for first in (0, 9):
            attrs = []
            for k in range(16):
                div = [0, 1, 2, 3, 7, 255][k % 6]
                attrs.append(dict(base=r.randrange(0, 30000), desc=self.desc_word(r.choice([4, 12, 16, 40]),
                              r.randrange(10), True, div), dst=self.dst_word(0), lim=0))
            self.draw(attrs, first)
            for inst in (first, first + 1, first + 2, first + 6, first + 7, first + 254, first + 255, first + 1000,
                         first + 1000):
                n = r.randrange(1, 9)
                self.warp([(r.randrange(100), inst, l, l == n - 1) for l in range(n)])
        # every format (VkFormat 1..255 and legacy 0..15), 16 per draw
        fmts = [(vk, 0) for vk in VK_ALL] + [(0, lg) for lg in range(16)]
        r.shuffle(fmts)
        for i in range(0, len(fmts), 16):
            attrs = [None] * 16
            for k, (vk, lg) in enumerate(fmts[i:i + 16]):
                attrs[k] = self.rand_attr(fmt_vk=vk, fmt_lg=lg)
            self.draw(attrs, 0)
            self.rand_warps(0, 1, maxlanes=4)
        # a draw without any enabled attribute: one dummy af per warp
        self.draw([None] * 16, 0)
        for n in (1, 5, 32):
            self.warp([(l, 0, l, l == n - 1) for l in range(n)])
        # enabled by VkFormat only (ATTR_DST = vk << 24: register 0, one component)
        attrs = [dict(base=r.randrange(30000), desc=self.desc_word(8, 0), dst=(r.choice(SUPPORTED_VK) << 24), lim=0)
                 for _ in range(4)] + [None] * 12
        self.draw(attrs, 0)
        self.rand_warps(0, 2)

    def sec_cross(self):
        r = self.rng
        self.section(1)
        for d in range(6):
            attrs = []
            for k in range(16):
                vk = r.choice([0, 107, 109, 104, 106, 101, 91, 97, 84, 77, 98, 42, 16, 9])
                lg = r.choice([3, 2, 1, 7])
                j = r.randrange(1, 16)
                base = 64 * r.randrange(1, 600) - j
                stride = 64 * r.randrange(0, 4) + r.choice([0, 0, 0, 1, 3, 5, 17])
                attrs.append(dict(base=base, desc=self.desc_word(stride, lg, r.random() < 0.2, r.choice([0, 1, 2])),
                                  dst=self.dst_word(vk), lim=0))
            self.draw(attrs, 0)
            self.rand_warps(0, 3, big=0.0)
        # every byte alignment 1..15 below a 64-byte boundary, 16-byte format
        attrs = [dict(base=64 * (100 + k) - (k + 1), desc=self.desc_word(64, 3), dst=self.dst_word(0), lim=0)
                 for k in range(15)] + [None]
        self.draw(attrs, 0)
        self.rand_warps(0, 2, big=0.0)
        # crossing the end of the memory (second line answers rsp_error -> zeros)
        attrs = [dict(base=MEMSIZE - 8 - k, desc=self.desc_word(0, 3), dst=self.dst_word(0), lim=0)
                 for k in range(4)] + [None] * 12
        self.draw(attrs, 0)
        self.rand_warps(0, 1, big=0.0)

    def sec_limit(self):
        r = self.rng
        self.section(2)
        for d in range(8):
            first = r.choice([0, 4])
            attrs = []
            for k in range(16):
                vk = r.choice([0, 106, 109, 9, 16, 70, 84, 64, 199])
                lg = r.randrange(10)
                size = fmtmodel.info(vk, lg)[0]
                stride = r.choice([size, 16, 20, 7, 1, 0, 100])
                inst = (k % 3 == 2)
                div = r.choice([1, 1, 2, 3]) if inst else 0
                e0 = r.randrange(0, 8)
                delta = r.choice([-1, 0, 1])
                lim = (1 << 31) | max(0, stride * e0 + size + delta)
                attrs.append(dict(base=r.randrange(0, 30000), desc=self.desc_word(stride, lg, inst, div),
                                  dst=self.dst_word(vk), lim=lim))
            # far beyond 2^31 (bits above 30 of offset + size) and the largest limit
            attrs[15] = dict(base=0, desc=self.desc_word(0xFFFF, 0), dst=self.dst_word(0), lim=0xFFFFFFFF)
            self.draw(attrs, first)
            for w in range(3):
                inst = first + r.randrange(0, 8)
                n = 8
                verts = [(l, inst, l, l == n - 1) for l in range(n)]
                if w == 2:
                    verts[3] = (0x80000000 + r.randrange(1 << 20), inst, 3, False)
                    verts[5] = (0xFFFFFFFF, inst, 5, False)
                    verts[6] = (32767, inst, 6, False)
                self.warp(verts)

    def sec_limit0(self):
        r = self.rng
        self.section(3)
        for d in range(2):
            attrs = []
            for k in range(16):
                a = self.rand_attr(lim=1 << 31)
                attrs.append(a)
            self.draw(attrs, 0)
            self.rand_warps(0, 2)

    def sec_size12(self):
        r = self.rng
        self.section(4)
        for d in range(3):
            attrs = []
            for k in range(16):
                vk = r.choice([104, 105, 106])
                attrs.append(dict(base=r.randrange(0, 40000), desc=self.desc_word(r.choice([12, 13, 16, 24, 31]),
                              r.randrange(16)), dst=self.dst_word(vk), lim=0))
            self.draw(attrs, 0)
            self.rand_warps(0, 2, big=0.0)

    def run(self):
        self.sec_addr()
        self.sec_cross()
        self.sec_limit()
        self.sec_limit0()
        self.sec_size12()
        self.wait()
        self.cmd.append(15 << 76)


def write_hex(path, words, digits):
    with open(path, 'w') as f:
        for w in words:
            f.write('%0*x\n' % (digits, w))


def fmt_table(path):
    with open(path, 'w') as f:
        f.write('// generated by tools/gen_fetch_vectors.py from tools/fmtmodel.py info(): do not edit\n')
        f.write('// {size[4:0], ncomp[2:0], kind[2:0]} for every {vkfmt[7:0], legacy[3:0]}\n')
        f.write('always @(*) begin\n    case ({ref_vk, ref_lg})\n')
        for vk in range(256):
            for lg in range(16):
                s, n, k = fmtmodel.info(vk, lg)
                f.write("        12'h%03x: ref_info = {5'd%d, 3'd%d, 3'd%d};\n" % ((vk << 4) | lg, s, n, k))
        f.write("        default: ref_info = 11'd0;\n    endcase\nend\n")


def main():
    g = Gen()
    g.run()
    os.makedirs(os.path.join(ROOT, 'sim/vec'), exist_ok=True)
    write_hex(os.path.join(ROOT, 'sim/vec/fetch_mem.hex'), g.mem, 2)
    write_hex(os.path.join(ROOT, 'sim/vec/fetch_cmd.hex'), g.cmd, 20)
    write_hex(os.path.join(ROOT, 'sim/vec/fetch_exp.hex'), g.exp, 40)
    write_hex(os.path.join(ROOT, 'sim/vec/fetch_cnt.hex'), [len(g.cmd), len(g.exp)], 8)
    for lb in (32, 64):
        write_hex(os.path.join(ROOT, 'sim/vec/fetch_nreq%d.hex' % lb), g.nreq[lb], 8)
    os.makedirs(os.path.join(ROOT, 'formal/ad_vf_fmt_info'), exist_ok=True)
    fmt_table(os.path.join(ROOT, 'formal/ad_vf_fmt_info/fmt_info_ref.vh'))
    nsect = [sum(1 for w in g.exp if (w >> 145) == i) for i in range(len(SECTIONS))]
    print('gen_fetch_vectors: %d commands, %d afs %s, reads32 %s, reads64 %s' %
          (len(g.cmd), len(g.exp), nsect, g.nreq[32][:5], g.nreq[64][:5]))


if __name__ == '__main__':
    main()
