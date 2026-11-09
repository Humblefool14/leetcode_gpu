#!/usr/bin/env python3
"""gen_conv_vectors.py: vectors of ad_vf_conv (sim/tb/ad_vf_conv_tb.v) from tools/fmtmodel.py.

(The spec names the reference tools/vf-vectors.py; tools/fmtmodel.py is it here.)

Writes
  sim/vec/vf_conv.txt     legacy formats (ATTR_DESC[19:16], ATTR_DST[31:24] == 0): all 256 UNORM8 values,
                          fp16 zeros / denormals / infinities / NaNs, every legacy code 0..15 with random
                          bytes and every ATTR_DST count, fill, reserved codes, disabled attributes, oob
  sim/vec/vf_conv_vk.txt  every VkFormat 0..255 (CAPS[30]): many random texels, extreme field codes and
                          float specials per format, oob, disabled attributes
  sim/vec/vf_conv_<leaf>.hex  exhaustive leaf tables (index = input): h2f, un2, un8, un10, un16, sn8, sn16
Command lines (hex fields):
  S <idx> <data>                                     STATE write
  A <grp> <attr> <lane> <oob> <last> <gap> <raw:32 hex> <n> <reg> <w0> <w1> <w2> <w3>
        grp 0 formats, 1 fill, 2 vkformats, 3 oob; n words expected (0 disabled) to reg, reg+1, ...
  W                                                  wait for the batch to drain (every conv_done seen)
"""
import os, random, sys
sys.path.insert(0, 'tools')
import fmtmodel as fm

random.seed(288)
VEC = 'sim/vec'
G_FMT, G_FILL, G_VK, G_OOB = 0, 1, 2, 3

def s_desc(k): return 0x031 + 2 * k
def s_dst(k):  return 0x1C0 + k

def write_leaf_tables():
    tabs = {
        'h2f':  [fm.h2f(h) for h in range(1 << 16)],
        'un2':  [fm.unorm(c, 2) for c in range(4)],
        'un8':  [fm.unorm(c, 8) for c in range(256)],
        'un10': [fm.unorm(c, 10) for c in range(1024)],
        'un16': [fm.unorm(c, 16) for c in range(1 << 16)],
        'sn8':  [fm.snorm(c, 8) for c in range(256)],
        'sn16': [fm.snorm(c, 16) for c in range(1 << 16)],
    }
    for name, t in tabs.items():
        with open(os.path.join(VEC, 'vf_conv_%s.hex' % name), 'w') as f:
            f.write('\n'.join('%08x' % w for w in t) + '\n')

class Batcher:
    """Groups afs into batches of <= 16 attribute configurations (STATE is not written while busy)."""
    def __init__(self, path):
        self.f = open(path, 'w'); self.cfg = []; self.afs = []; self.n_af = 0
    def add(self, vk, legacy, dst_cnt, raw, oob=False, enable=True, grp=None):
        # attribute config: reuse an identical one in this batch, else allocate
        reg = random.choice([random.randrange(64), 60, 61, 62, 63, 0])
        hi = random.choice([0, 0, random.randrange(1 << 16)])     # ATTR_DST[23:8]: free bits
        dst = ((vk << 24) | (hi << 8) | (dst_cnt << 6) | reg) if enable else 0
        if enable and dst == 0:
            dst = 1 << 8                                          # enabled although reg/cnt/fmt are 0
        if len(self.cfg) == 16:
            self.flush()
        k = len(self.cfg)
        desc = (random.randrange(1 << 32) & ~(0xF << 16)) | (legacy << 16)
        self.cfg.append((desc, dst))
        if vk:
            n_fmt = fm.VK[vk]['ncomp'] if vk in fm.VK else 0
        else:
            n_fmt = fm.LEGACY[legacy][1] if legacy in fm.LEGACY else 0
        w = fm.words(vk, legacy, dst_cnt, raw, oob) if dst else []
        if grp is None:
            grp = G_OOB if oob else G_VK if vk else (G_FILL if dst and len(w) > n_fmt else G_FMT)
        # several afs may use the same attribute: a few extra afs with fresh raw bytes
        self.afs.append((grp, k, w, raw, oob, dst & 63))
        for _ in range(random.choice([0, 0, 1, 2])):
            raw2 = bytes(random.randrange(256) for _ in range(16))
            w2 = fm.words(vk, legacy, dst_cnt, raw2, oob) if dst else []
            self.afs.append((grp, k, w2, raw2, oob, dst & 63))
    def flush(self):
        if not self.afs:
            return
        for k, (desc, dst) in enumerate(self.cfg):
            self.f.write('S %03x %08x\nS %03x %08x\n' % (s_desc(k), desc, s_dst(k), dst))
        random.shuffle(self.afs)
        for i, (grp, k, w, raw, oob, reg) in enumerate(self.afs):
            last = 1 if (i == len(self.afs) - 1 or random.random() < 0.15) else 0
            gap = random.choice([0, 0, 0, 0, 1, 2, random.randrange(6)])
            ww = (w + [0, 0, 0, 0])[:4]
            self.f.write('A %x %x %02x %x %x %x %s %x %02x %08x %08x %08x %08x\n' % (
                grp, k, random.randrange(32), int(oob), last, gap, bytes(raw)[::-1].hex(),
                len(w), reg, *ww))
            self.n_af += 1
        self.f.write('W\n')
        self.cfg = []; self.afs = []
    def close(self):
        self.flush(); self.f.close()

def rnd_raw():
    return bytes(random.randrange(256) for _ in range(16))

def pack_fields(vals, bits):
    """raw bytes holding fields vals (of 'bits' each) little-endian, padded to 16 bytes."""
    if bits == 'p':                        # 10/10/10/2
        w = vals[0] | vals[1] << 10 | vals[2] << 20 | vals[3] << 30
        return w.to_bytes(4, 'little') + rnd_raw()[4:]
    nb = bits // 8
    out = b''.join(v.to_bytes(nb, 'little') for v in vals)
    return (out + rnd_raw())[:16]

def extremes(b):
    m = (1 << b) - 1
    return sorted({0, 1, 2, m, m - 1, 1 << (b - 1), (1 << (b - 1)) - 1, (1 << (b - 1)) + 1, m >> 1 ^ 0x5 & m})

H_SPEC = [0x0000, 0x8000, 0x0001, 0x8001, 0x0002, 0x0155, 0x0200, 0x03FF, 0x83FF, 0x0400, 0x3C00, 0xBC00,
          0x7BFF, 0xFBFF, 0x7C00, 0xFC00, 0x7C01, 0x7D00, 0x7E00, 0x7FFF, 0xFC01, 0xFE00, 0xFFFF, 0x3555]
F_SPEC = [0x00000000, 0x80000000, 0x00000001, 0x007FFFFF, 0x7F800000, 0xFF800000, 0x7FC00000, 0x7F800001,
          0xFFFFFFFF, 0x3F800000]

def legacy_vectors():
    b = Batcher(os.path.join(VEC, 'vf_conv.txt'))
    # all 256 UNORM8 values (legacy 8), every count
    for i in range(64):
        raw = bytes([4 * i, 4 * i + 1, 4 * i + 2, 4 * i + 3]) + rnd_raw()[4:]
        b.add(0, 8, 3, raw)
    for i in range(64):
        raw = bytes([255 - 4 * i - j for j in range(4)]) + rnd_raw()[4:]
        b.add(0, 8, random.randrange(4), raw)
    # fp16 specials (legacy 6, 7), each special in every component position
    for i in range(0, len(H_SPEC), 4):
        for rot in range(4):
            vals = [H_SPEC[(i + rot + j) % len(H_SPEC)] for j in range(4)]
            b.add(0, 7, 3, pack_fields(vals, 16)); b.add(0, 6, 1, pack_fields(vals, 16))
    for h in range(0, 0x10000, 97):        # a sweep over the whole fp16 space
        b.add(0, 7, 3, pack_fields([h, h ^ 0x8000, (h * 7) & 0xFFFF, (h + 0x3FF) & 0xFFFF], 16))
    # fp32 / uint32 specials pass through
    for i in range(0, len(F_SPEC), 2):
        for code in (0, 1, 2, 3, 4, 5):
            b.add(0, code, 3, pack_fields([F_SPEC[(i + j) % len(F_SPEC)] for j in range(4)], 32))
    # every legacy code 0..15 x every count, random bytes (includes fill and reserved codes)
    for code in range(16):
        for cnt in range(4):
            for _ in range(12):
                b.add(0, code, cnt, rnd_raw())
    # disabled attributes (ATTR_DST word 0), and enabled with only the free bits set
    for _ in range(40):
        b.add(0, random.randrange(16), random.randrange(4), rnd_raw(), enable=False)
    # oob (legacy kinds: float -> 1.0, uint -> 1)
    for code in range(16):
        for cnt in range(4):
            for _ in range(3):
                b.add(0, code, cnt, rnd_raw(), oob=True)
    b.close()
    return b.n_af

def vk_vectors():
    b = Batcher(os.path.join(VEC, 'vf_conv_vk.txt'))
    for vk in range(256):
        legacy = random.randrange(16)         # must be ignored when vk != 0
        e = fm.VK.get(vk)
        for _ in range(24):
            b.add(vk, legacy, random.randrange(4), rnd_raw())
        b.add(vk, legacy, 3, bytes(16)); b.add(vk, legacy, 3, bytes([255] * 16))
        if e:
            bits = 'p' if e['packed'] else e['bits']
            if e['packed']:
                ex = [extremes(10), extremes(10), extremes(10), [0, 1, 2, 3]]
            else:
                ex = [extremes(e['bits'])] * 4
            for t in range(max(len(x) for x in ex)):
                vals = [ex[j][(t + j) % len(ex[j])] for j in range(4)]
                b.add(vk, legacy, 3, pack_fields(vals, bits))
            if e['kind'] == fm.K_FLOAT:
                sp = H_SPEC if e['bits'] == 16 else F_SPEC
                for t in range(0, len(sp), 2):
                    b.add(vk, legacy, 3, pack_fields([sp[(t + j) % len(sp)] for j in range(4)], e['bits']))
            if e['bits'] == 8 and not e['packed']:   # all 256 codes of each 8-bit format
                for i in range(64):
                    b.add(vk, legacy, 3, bytes([4 * i + j for j in range(4)]) + rnd_raw()[4:])
        for cnt in range(4):
            b.add(vk, legacy, cnt, rnd_raw(), oob=True)
        b.add(vk, legacy, random.randrange(4), rnd_raw(), enable=False, grp=G_VK)
    b.close()
    return b.n_af

def write_desc_ref(path='formal/ad_vf_fmt_desc/fmt_desc_ref.vh'):
    """Reference table of ad_vf_fmt_desc for the formal harnesses: {ncomp, kind, bw, bgra} per format."""
    def ent(n, kind, bits, packed, swz):
        bw = 3 if packed else {8: 0, 16: 1, 32: 2}[bits]
        return (n << 6) | (kind << 3) | (bw << 1) | int(tuple(swz) != (0, 1, 2, 3))
    lines = ['// generated by tools/gen_conv_vectors.py from tools/fmtmodel.py: do not edit',
             '// {ncomp[2:0], kind[2:0], bw[1:0], bgra} of VkFormat v (v != 0) / legacy code (v == 0)',
             'function [8:0] fmt_desc_ref;', '    input [7:0] v; input [3:0] lg;',
             '    begin', '        fmt_desc_ref = 9\'d0;', '        if (v == 8\'d0) case (lg)']
    for code, (size, n, kind, bits) in sorted(fm.LEGACY.items()):
        lines.append("            4'd%d: fmt_desc_ref = 9'h%03x;" % (code, ent(n, kind, bits, None, (0, 1, 2, 3))))
    lines += ['            default: fmt_desc_ref = 9\'d0;', '        endcase', '        else case (v)']
    for code, e in sorted(fm.VK.items()):
        lines.append("            8'd%d: fmt_desc_ref = 9'h%03x;" % (code, ent(e['ncomp'], e['kind'], e['bits'], e['packed'], e['swz'])))
    lines += ['            default: fmt_desc_ref = 9\'d0;', '        endcase', '    end', 'endfunction', '']
    with open(path, 'w') as f:
        f.write('\n'.join(lines))

if __name__ == '__main__':
    os.makedirs(VEC, exist_ok=True)
    write_leaf_tables()
    write_desc_ref()
    n1 = legacy_vectors(); n2 = vk_vectors()
    print('gen_conv_vectors: %d legacy afs, %d VkFormat afs, leaf tables written' % (n1, n2))
