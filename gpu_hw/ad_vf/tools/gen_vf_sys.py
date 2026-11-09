#!/usr/bin/env python3
"""gen_vf_sys.py SCENE | --list: vectors for the whole-VF test (sim/tb/ad_vf_tb.v).

A scene is one or more DRAWs on one 64 KiB memory image.  For each draw this script runs the
reference chain: index walk (below) -> tools/asm_model.py assemble() -> tools/fetch_model.py
(element, address, size, ATTR_LIMIT) -> tools/fmtmodel.py words(), and writes
  sim/vec/vf_<scene>_img.hex    memory image, one byte per line
  sim/vec/vf_<scene>_cmd.hex    commands: {op[3:0], idx[8:0], data[31:0]}: op 1 STATE write,
                                op 2 DRAW, op 3 STATE write sent right after the previous DRAW
                                (while the VF is busy: it must not change that draw), op 5 a DRAW
                                whose index buffer faults (rsp_error): the TB checks only that busy
                                falls with no read in flight, then resets the VF; op 0 end.  The TB
                                waits for busy low after the op 3 writes that follow a DRAW.
  sim/vec/vf_<scene>_vl.hex     expected vl writes in order: {warp[15:0], reg[5:0], lane[4:0], data[31:0]}
  sim/vec/vf_<scene>_warp.hex   expected vl_mask per warp (in order over all draws)
  sim/vec/vf_<scene>_prim.hex   expected primitives in order:
                                {last, free[2:0], kind[1:0], l2[4:0], l1[4:0], l0[4:0], warp[15:0]}
The TB grants warp w the PT base 32 * (w % 8) and checks prim_vtx = ptbase(warp) + lane per slot.
"""
import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fmtmodel  # noqa: E402
from asm_model import assemble  # noqa: E402
from fetch_model import FetchModel  # noqa: E402

MEM = 65536
M32 = 0xFFFFFFFF
S_TOPOLOGY, S_INDEX_BASE, S_INDEX_FORMAT, S_FIRST, S_COUNT = 0x020, 0x021, 0x022, 0x023, 0x024
S_FIRST_INSTANCE, S_INSTANCE_COUNT, S_VERTEX_OFFSET, S_PRIM_RESTART = 0x025, 0x026, 0x027, 0x028
S_PROVOKING = 0x05D
VKFMTS = sorted(fmtmodel.VK)


def s_base(k): return 0x030 + 2 * k
def s_desc(k): return 0x031 + 2 * k
def s_dst(k): return 0x1C0 + k
def s_limit(k): return 0x1D0 + k


def index_walk(st, mem):
    """ad_vf_index reference: the iv items of a draw."""
    fmt = st.get(S_INDEX_FORMAT, 0) & 3
    first, count = st.get(S_FIRST, 0), st.get(S_COUNT, 0)
    fi, ni = st.get(S_FIRST_INSTANCE, 0), st.get(S_INSTANCE_COUNT, 0)
    rs = st.get(S_PRIM_RESTART, 0) & 1
    items = []
    if count == 0 or ni == 0:
        return items
    size = 0 if fmt == 0 else (2 if fmt == 1 else 4)
    for i in range(ni):
        for n in range(count):
            if fmt == 0:
                v, r = (first + n) & M32, False
            else:
                a = (st.get(S_INDEX_BASE, 0) + (first + n) * size) & M32
                v = int.from_bytes(mem[a:a + size], 'little')
                r = bool(rs) and v == (0xFFFF if size == 2 else M32)
            items.append(dict(index=v, inst=(fi + i) & M32, restart=r, last=False))
    items[-1]['last'] = True
    return items


class Scene:
    def __init__(self, name, seed):
        self.name, self.rng = name, random.Random(seed)
        self.mem = bytearray(self.rng.getrandbits(8) for _ in range(MEM))
        self.cmds, self.vl, self.warps, self.prims = [], [], [], []
        self.st = {}
        self.nwarp = 0

    def put_floats(self, addr, vals):
        for i, v in enumerate(vals):
            self.mem[addr + 4 * i:addr + 4 * i + 4] = struct.pack('<f', v)

    def w(self, idx, data):
        data &= M32
        self.st[idx] = data
        self.cmds.append((1, idx, data))

    def w_busy(self, idx, data):
        data &= M32
        self.st[idx] = data
        self.cmds.append((3, idx, data))

    def fault_draw(self):
        self.cmds.append((5, 0, 0))

    def draw(self):
        self.cmds.append((2, 0, 0))
        st, mem = self.st, bytes(self.mem)
        items = index_walk(st, mem)
        if not items:
            return
        indexed = (st.get(S_INDEX_FORMAT, 0) & 3) != 0
        res = assemble(st.get(S_TOPOLOGY, 0) & 7, st.get(S_PROVOKING, 0) & 1, items,
                       st.get(S_VERTEX_OFFSET, 0), indexed)
        fm = FetchModel(32, mem, MEM)
        for idx, d in st.items():
            fm.write(idx, d)
        w0 = self.nwarp
        for wi, wp in enumerate(res['warps']):
            self.warps.append(wp['mask'])
            verts = [(v['index'], v['inst'], v['lane'], v['last']) for v in wp['verts']]
            for af in fm.warp(verts):
                k = af['attr']
                dst = fm.dst[k]
                if dst == 0:
                    continue
                words = fmtmodel.words((dst >> 24) & 0xFF, (fm.desc[k] >> 16) & 0xF, (dst >> 6) & 3,
                                       af['raw'], af['oob'])
                for c, word in enumerate(words):
                    self.vl.append((w0 + wi, ((dst & 63) + c) & 63, af['lane'], word))
        for p in res['prims']:
            self.prims.append((w0 + p['warp'], p['lanes'], p['kind'], p['free'], p['last']))
        self.nwarp += len(res['warps'])

    def save(self, outdir='sim/vec'):
        b = os.path.join(outdir, 'vf_%s_' % self.name)
        with open(b + 'img.hex', 'w') as f:
            f.write('\n'.join('%02x' % x for x in self.mem) + '\n')
        with open(b + 'cmd.hex', 'w') as f:
            for op, idx, d in self.cmds + [(0, 0, 0)]:
                f.write('%011x\n' % ((op << 41) | (idx << 32) | d))
        with open(b + 'vl.hex', 'w') as f:
            for wv, reg, lane, d in self.vl:
                f.write('%015x\n' % ((wv << 43) | (reg << 37) | (lane << 32) | d))
        with open(b + 'warp.hex', 'w') as f:
            for m in self.warps:
                f.write('%08x\n' % m)
        with open(b + 'prim.hex', 'w') as f:
            for wv, (l0, l1, l2), kind, free, last in self.prims:
                v = (int(last) << 37) | (free << 34) | (kind << 32) | (l2 << 26) | (l1 << 21) | (l0 << 16) | wv
                f.write('%010x\n' % v)
        return len(self.vl), len(self.warps), len(self.prims)


# ---------------------------------------------------------------------------------------------
def attr_legacy(sc, k, fmt, base, stride, reg, cnt, inst=False, div=0, limit=0):
    sc.w(s_base(k), base)
    sc.w(s_desc(k), (div << 24) | (int(inst) << 20) | (fmt << 16) | stride)
    sc.w(s_dst(k), (cnt << 6) | reg)
    sc.w(s_limit(k), limit)


def attr_vk(sc, k, vk, base, stride, reg, cnt, inst=False, div=0, limit=0):
    sc.w(s_base(k), base)
    sc.w(s_desc(k), (div << 24) | (int(inst) << 20) | stride)
    sc.w(s_dst(k), (vk << 24) | (cnt << 6) | reg)
    sc.w(s_limit(k), limit)


def clear_attrs(sc):
    for k in range(16):
        sc.w(s_dst(k), 0)


def common(sc, topo, prov=0, fmt=0, first=0, count=0, fi=0, ni=1, voff=0, restart=0, ibase=0):
    for idx, d in ((S_TOPOLOGY, topo), (S_PROVOKING, prov), (S_INDEX_FORMAT, fmt), (S_FIRST, first),
                   (S_COUNT, count), (S_FIRST_INSTANCE, fi), (S_INSTANCE_COUNT, ni),
                   (S_VERTEX_OFFSET, voff), (S_PRIM_RESTART, restart), (S_INDEX_BASE, ibase)):
        sc.w(idx, d)


def sc_tri_list(sc):
    """Non-indexed triangle list of 100 vertices: position RGBA32F, colour RGBA8 UNORM, uv RG16F."""
    clear_attrs(sc)
    sc.put_floats(0x2000, [sc.rng.uniform(-100, 100) for _ in range(4 * 120)])
    attr_legacy(sc, 0, 3, 0x2000, 16, 0, 3)
    attr_legacy(sc, 1, 8, 0x4000, 4, 4, 3)
    attr_legacy(sc, 2, 6, 0x5001, 4, 8, 1)          # unaligned
    common(sc, topo=3, count=100, first=2)
    sc.draw()
    common(sc, topo=3, prov=1, count=7, first=40)    # a second draw: provoking last, a dropped tail
    sc.draw()


def sc_strip(sc):
    """u16 indexed triangle strip with restart, VERTEX_OFFSET, VkFormat attributes."""
    clear_attrs(sc)
    n = 90
    idx = [sc.rng.randrange(0, 200) for _ in range(n)]
    for p in (17, 40, 41, 77):
        idx[p] = 0xFFFF
    for i, v in enumerate(idx):
        sc.mem[0x1000 + 2 * (i + 3):0x1000 + 2 * (i + 4)] = v.to_bytes(2, 'little')
    attr_vk(sc, 0, 109, 0x6000, 16, 0, 3)            # R32G32B32A32_SFLOAT
    attr_vk(sc, 1, 37, 0x9000, 4, 4, 3)              # R8G8B8A8_UNORM
    attr_vk(sc, 5, 77, 0xA003, 6, 8, 1)              # R16G16_UNORM, odd stride
    attr_vk(sc, 6, 44, 0xB000, 4, 10, 3)             # B8G8R8A8_UNORM
    common(sc, topo=4, fmt=1, first=3, count=n, voff=5, restart=1, ibase=0x1000)
    sc.draw()


def sc_fan_inst(sc):
    """u32 indexed fan, 3 instances, a per-instance attribute (divisor 2), ATTR_LIMIT."""
    clear_attrs(sc)
    n = 40
    for i in range(n):
        v = sc.rng.randrange(0, 64) if i != 25 else M32
        sc.mem[0x0800 + 4 * i:0x0800 + 4 * i + 4] = v.to_bytes(4, 'little')
    attr_legacy(sc, 0, 2, 0x3000, 12, 0, 2)                      # RGB32F
    attr_vk(sc, 1, 98, 0x7000, 4, 3, 0, inst=True, div=2)        # R32_UINT per instance
    attr_vk(sc, 2, 64, 0x7800, 4, 4, 3, limit=(1 << 31) | 160)   # A2B10G10R10, limit 40 elements
    attr_legacy(sc, 3, 9, 0x7C00, 4, 8, 3, inst=True, div=0)     # RGBA8UI, divisor 0
    common(sc, topo=5, fmt=2, count=n, fi=4, ni=3, restart=1, ibase=0x0800)
    sc.draw()


def sc_lines(sc):
    """Line strip (provoking last) then line list and point list, instance changes."""
    clear_attrs(sc)
    attr_vk(sc, 0, 100, 0x2000, 4, 0, 0)            # R32_SFLOAT
    attr_vk(sc, 1, 90, 0x2400, 6, 1, 3)             # R16G16B16_SFLOAT
    attr_vk(sc, 2, 71, 0x2800, 2, 5, 1)             # R16_SNORM, fills
    common(sc, topo=2, prov=1, count=50, ni=2)
    sc.draw()
    common(sc, topo=1, count=71, first=5)
    sc.draw()
    common(sc, topo=0, count=33)
    sc.draw()


def sc_vk_all(sc):
    """Point list with 16 attributes of random VkFormats (including values without the feature)."""
    clear_attrs(sc)
    for k in range(16):
        vk = sc.rng.choice(VKFMTS + [0x0F, 0x7B, 0xC8])
        attr_vk(sc, k, vk, sc.rng.randrange(0, 0xE000), sc.rng.randrange(0, 40), (k * 4) % 64,
                sc.rng.randrange(0, 4), inst=sc.rng.random() < 0.3, div=sc.rng.randrange(0, 4),
                limit=sc.rng.choice([0, (1 << 31) | sc.rng.randrange(0, 400)]))
    common(sc, topo=0, count=70, ni=2, fi=1)
    sc.draw()


def sc_random(sc):
    """Several random draws: every topology, both index sizes, restart, instances, random attributes."""
    for d in range(6):
        clear_attrs(sc)
        for k in sc.rng.sample(range(16), sc.rng.randrange(0, 5)):
            if sc.rng.random() < 0.5:
                attr_legacy(sc, k, sc.rng.randrange(0, 16), sc.rng.randrange(0, 0xE000),
                            sc.rng.randrange(0, 33), sc.rng.randrange(0, 64), sc.rng.randrange(0, 4),
                            inst=sc.rng.random() < 0.3, div=sc.rng.randrange(0, 5))
            else:
                attr_vk(sc, k, sc.rng.choice(VKFMTS), sc.rng.randrange(0, 0xE000),
                        sc.rng.randrange(0, 33), sc.rng.randrange(0, 64), sc.rng.randrange(0, 4))
        fmt = sc.rng.randrange(0, 4)
        count = sc.rng.randrange(1, 70)
        base = 0xE000 + 0x400 * d
        size = 2 if fmt == 1 else 4
        for i in range(count + 8):
            v = sc.rng.randrange(0, 300) if sc.rng.random() > 0.08 else (1 << (8 * size)) - 1
            sc.mem[base + size * i:base + size * (i + 1)] = (v & ((1 << (8 * size)) - 1)).to_bytes(size, 'little')
        common(sc, topo=sc.rng.randrange(0, 8), prov=sc.rng.randrange(0, 2), fmt=fmt,
               first=sc.rng.randrange(0, 8), count=count, fi=sc.rng.randrange(0, 3),
               ni=sc.rng.randrange(1, 4), voff=sc.rng.randrange(0, 10), restart=sc.rng.randrange(0, 2),
               ibase=base)
        sc.draw()


def sc_race(sc):
    """PROVOKING and ATTR_LIMIT written right after a DRAW (while the VF is busy) for the next draw."""
    clear_attrs(sc)
    attr_legacy(sc, 0, 3, 0x2000, 16, 0, 3, limit=(1 << 31) | 0x400)
    attr_vk(sc, 1, 37, 0x4000, 4, 4, 3)
    common(sc, topo=4, prov=0, count=80)
    sc.draw()
    sc.w_busy(S_PROVOKING, 1)
    sc.w_busy(s_limit(0), (1 << 31) | 0x100)
    sc.w_busy(s_limit(0), (1 << 31) | 0x200)          # a newer value overwrites the held one
    common(sc, topo=5, prov=1, count=70)               # (re-writes PROVOKING = 1 when idle)
    sc.draw()
    sc.w_busy(S_PROVOKING, 0)
    sc.w_busy(s_limit(0), 0)
    sc.draw()


def sc_fault(sc):
    """An index buffer whose later lines lie past the end of memory, then a normal draw after reset."""
    clear_attrs(sc)
    attr_legacy(sc, 0, 0, 0x2000, 4, 0, 0)
    common(sc, topo=3, fmt=2, count=600, ibase=MEM - 64)
    sc.fault_draw()
    sc.st = {}                                          # the reset clears the VF's STATE copies
    clear_attrs(sc)
    attr_legacy(sc, 0, 3, 0x2000, 16, 0, 3)
    common(sc, topo=3, count=45)
    sc.draw()


SCENES = dict(race=sc_race, fault=sc_fault, tri_list=sc_tri_list, strip=sc_strip, fan_inst=sc_fan_inst, lines=sc_lines,
              vk_all=sc_vk_all, random=sc_random)

if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--list':
        print(' '.join(SCENES))
        sys.exit(0)
    names = sys.argv[1:] or list(SCENES)
    for i, nm in enumerate(names):
        sc = Scene(nm, 1000 + list(SCENES).index(nm))
        SCENES[nm](sc)
        print(nm, 'vl %d warps %d prims %d' % sc.save())
