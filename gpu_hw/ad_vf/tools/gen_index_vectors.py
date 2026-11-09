#!/usr/bin/env python3
"""gen_index_vectors -- reference model of ad_vf_index (spec/gpu/vf/ad_vf_index.md section 4) and
vectors for sim/tb/ad_vf_index_tb.v.

index_items(mem, base, fmt, first, count, finst, icount, restart_en) -> [(index, inst, restart, last)]
  The iv stream of one draw: non-indexed FIRST + n; indexed: the u16 (zero-extended) / u32 at
  INDEX_BASE + (FIRST + n) * size (little endian), restart = PRIM_RESTART[0] and all ones;
  the walk repeated per instance (inst = FIRST_INSTANCE + i); last on the final item.
  COUNT 0 or INSTANCE_COUNT 0: nothing.

Files:
  sim/vec/index_mem.hex  memory image, one byte per line (MEM_BYTES bytes); bytes at or above
                         MEM_BYTES answer rsp_error in the TB's ad_amb_mem.
  sim/vec/index_vec.hex  32-bit words: T, then per draw: section, fmt, base, first, count, finst,
                         icount, restart_en, error (1: the walk must stop on rsp_error, the items
                         given are the in-range prefix), dbl_kick, n_items, items (index, inst,
                         {last, restart}).
Sections: 0 direct, 1 u16u32 (+ rsp_error draws), 2 restart, 3 inst.
"""
import os
import random

M32 = (1 << 32) - 1
MEM_BYTES = 65536


def index_items(mem, base, fmt, first, count, finst, icount, restart_en, limit=None):
    out = []
    if count == 0 or icount == 0:
        return out
    size = 0 if fmt == 0 else (2 if fmt == 1 else 4)
    for i in range(icount):
        for n in range(count):
            last = (i == icount - 1 and n == count - 1)
            inst = (finst + i) & M32
            if size == 0:
                out.append(((first + n) & M32, inst, False, last))
                continue
            a = (base + (first + n) * size) & M32
            if limit is not None and a + size > limit:
                return out
            v = int.from_bytes(bytes(mem[a:a + size]), 'little')
            rs = bool(restart_en) and v == (0xFFFF if size == 2 else 0xFFFFFFFF)
            out.append((v, inst, rs, last))
    return out


def main():
    rnd = random.Random(1109)
    mem = [rnd.getrandbits(8) for _ in range(MEM_BYTES)]
    # sprinkle restart values (aligned u16 / u32 all-ones) in the second half
    for _ in range(600):
        a = rnd.randrange(32768, MEM_BYTES - 4) & ~3
        if rnd.random() < 0.5:
            mem[a] = mem[a + 1] = 0xFF
        else:
            mem[a:a + 4] = [0xFF] * 4
    draws = []

    def add(sec, fmt, base, first, count, finst=0, icount=1, rst=0, err=0, dbl=0):
        lim = MEM_BYTES if err else None
        its = index_items(mem, base, fmt, first, count, finst, icount, rst, lim)
        if not err and fmt:
            size = 2 if fmt == 1 else 4
            assert base + (first + count) * size <= MEM_BYTES
        draws.append((sec, fmt, base, first, count, finst, icount, rst, err, dbl, its))

    # 0 direct: non-indexed draws (+ COUNT 0 / INSTANCE_COUNT 0 send nothing)
    for count in (1, 2, 3, 7, 32, 33, 100):
        add(0, 0, rnd.getrandbits(32), rnd.getrandbits(32), count, rnd.getrandbits(32) & 0xFF)
    add(0, 0, 0, 0xFFFFFFFE, 5)                     # FIRST + n wraps
    add(0, 0, 0, 5, 0)                              # COUNT 0
    add(0, 0, 0, 5, 4, 0, 0)                        # INSTANCE_COUNT 0
    add(0, 1, 0x100, 5, 0)                          # indexed COUNT 0
    # 1 u16u32: both sizes, unaligned FIRST, every line offset, reserved format 3
    for fmt in (1, 2, 3):
        size = 2 if fmt == 1 else 4
        for _ in range(14):
            base = rnd.randrange(0, 16384) & ~(size - 1)
            add(1, fmt, base, rnd.randrange(0, 70), rnd.randint(1, 90))
        for first in range(0, 33):                   # every start offset in a 64-byte line
            add(1, fmt, 0x2000 + 4 * first, first, rnd.randint(1, 40))
    add(1, 1, 0, 0, 1)
    add(1, 2, 0x7FFC, 0, 1)
    # rsp_error: the index buffer runs past the memory (the walk stops without iv_last)
    for fmt in (1, 2):
        size = 2 if fmt == 1 else 4
        add(1, fmt, MEM_BYTES - 40 * size, 0, 120, err=1)
        add(1, fmt, MEM_BYTES + 0x100, 0, 50, err=1)
    add(1, 2, 0x3000, 1, 50)                        # a normal draw right after
    # 2 restart: restart markers (u16 0xFFFF / u32 0xFFFFFFFF) on and off
    for fmt in (1, 2):
        for rst in (1, 0, 1):
            for _ in range(8):
                size = 2 if fmt == 1 else 4
                base = rnd.randrange(32768, MEM_BYTES - 4096) & ~(size - 1)
                add(2, fmt, base, rnd.randrange(0, 40), rnd.randint(1, 200), rst=rst)
    # a buffer of only restarts, ending with one
    mem[0x1000:0x1040] = [0xFF] * 64
    add(2, 1, 0x1000, 0, 32, rst=1)
    add(2, 2, 0x1000, 3, 13, rst=1, icount=2)
    add(2, 0, 0, 0xFFFFFFFF, 3, rst=1)              # non-indexed: no restart
    # 3 inst: instances (the lines read again), FIRST_INSTANCE, a kick while busy is ignored
    for fmt in (0, 1, 2):
        for icount in (1, 2, 3, 5):
            size = 2 if fmt == 1 else 4
            add(3, fmt, rnd.randrange(0, 16384) & ~3, rnd.randrange(0, 40), rnd.randint(1, 40),
                rnd.getrandbits(32), icount, rst=1, dbl=rnd.randrange(2))
    add(3, 1, 0x200, 0, 1, 0xFFFFFFFF, 4)          # one index, inst wraps
    add(3, 2, 0x204, 0, 1, 7, 6)

    words = [len(draws)]
    for sec, fmt, base, first, count, finst, icount, rst, err, dbl, its in draws:
        words += [sec, fmt, base & M32, first & M32, count, finst & M32, icount, rst, err, dbl, len(its)]
        for v, inst, rs, last in its:
            words += [v, inst, (int(last) << 1) | int(rs)]
    os.makedirs('sim/vec', exist_ok=True)
    with open('sim/vec/index_vec.hex', 'w') as f:
        f.write(''.join('%08x\n' % (w & M32) for w in words))
    with open('sim/vec/index_mem.hex', 'w') as f:
        f.write(''.join('%02x\n' % b for b in mem))
    print('gen_index_vectors: %d draws, %d words' % (len(draws), len(words)))


if __name__ == '__main__':
    main()
