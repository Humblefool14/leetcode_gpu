#!/usr/bin/env python3
# gen_dec_vectors.py: the vectors of sim/tb/ad_su_dec_tb.v, all decoded by
# tools/gsi1asm.py's decode() (the reference).
#
#   sim/vec/dec_table.hex   gsi1asm.py --dec-table (CFGS[0], CFGS[1]: 2 uops a line)
#   sim/vec/dec_cfg.hex     the same instructions under the six CFG below
#   sim/vec/dec_sweep.hex   every used opcode x funct3 x funct7, and the sub values
#   sim/vec/dec_opd.hex     every table row with random word1 / operand fields
#   sim/vec/dec_fault.hex   illegal encodings (word0[1:0], undefined funct/sub,
#                           operands past NREGS, rq, features)
#   sim/vec/dec_texszs.hex  texsz.s (imm 3) with random fields
# Format: "%016x" instruction then one "%027x" uop per configuration.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gsi1asm as A  # noqa: E402

# The six decoders of the TB (ad_su_dec_tb.v, u_dec0..u_dec5): NREGS, PACKED,
# SUBGROUP, HAS_SA, MS4.  CFG[0] and CFG[1] are gsi1asm.CFGS.
CFG = [dict(NREGS=32, PACKED=0, SUBGROUP=0, HAS_SA=0, MS4=0),
       dict(NREGS=64, PACKED=1, SUBGROUP=1, HAS_SA=1, MS4=1),
       dict(NREGS=32, PACKED=1, SUBGROUP=0, HAS_SA=0, MS4=1),
       dict(NREGS=64, PACKED=0, SUBGROUP=1, HAS_SA=0, MS4=0),
       dict(NREGS=32, PACKED=0, SUBGROUP=1, HAS_SA=1, MS4=0),
       dict(NREGS=48, PACKED=1, SUBGROUP=1, HAS_SA=0, MS4=1)]
assert CFG[0] == A.CFGS[0] and CFG[1] == A.CFGS[1]


def base_word(rnd, e):
    """A random instruction with the row's fixed fields."""
    w0 = rnd.getrandbits(32)
    w0 = (w0 & ~0x7F) | e["opc"]
    if e["fmt"] != "U" and isinstance(e["f3"], int):
        w0 = (w0 & ~(7 << 12)) | e["f3"] << 12
    elif e["f3"] == "rm":
        w0 = (w0 & ~(7 << 12)) | rnd.choice([0, 1, 2, 3, 4, 7]) << 12
    elif e["f3"] == "rm4":
        w0 = (w0 & ~(7 << 12)) | rnd.randrange(4) << 12
    if (e["fmt"] == "R" and e["f7"] is not None) or e.get("shift"):
        w0 = (w0 & ~(0x7F << 25)) | e["f7"] << 25
    if "rs2" in e:
        w0 = (w0 & ~(31 << 20)) | e["rs2"] << 20
    if "immv" in e:
        w0 = (w0 & ~(0xFFF << 20)) | e["immv"] << 20
    if e["fmt"] == "R4" and e["opc"] != A.OPC["C0"]:
        w0 &= ~(3 << 25)
    w1 = rnd.getrandbits(32)
    if "subv" in e:
        w1 = (w1 & ~(31 << 17)) | e["subv"] << 17
    if e.get("sub") == "atom":
        w1 = (w1 & ~(15 << 17)) | rnd.randrange(11) << 17
    if e["unit"] == A.U_TEX:
        w1 &= ~(16 << 17)
    return w0, w1


def set_ops(w0, w1, rd=None, rs1=None, rs2=None, rs3=None):
    if rd is not None:
        w0 = (w0 & ~(31 << 7)) | (rd & 31) << 7
        w1 = (w1 & ~3) | rd >> 5
    if rs1 is not None:
        w0 = (w0 & ~(31 << 15)) | (rs1 & 31) << 15
        w1 = (w1 & ~(3 << 2)) | (rs1 >> 5) << 2
    if rs2 is not None:
        w0 = (w0 & ~(31 << 20)) | (rs2 & 31) << 20
        w1 = (w1 & ~(3 << 4)) | (rs2 >> 5) << 4
    if rs3 is not None:
        w0 = (w0 & ~(31 << 27)) | (rs3 & 31) << 27
        w1 = (w1 & ~(3 << 6)) | (rs3 >> 5) << 6
    return w0 | w1 << 32


EDGE = [0, 1, 30, 31, 32, 46, 47, 48, 59, 60, 61, 62, 63, 64, 93, 94, 95, 96, 125, 126, 127]


def opd_vectors(rnd):
    vec = []
    for n, e in A.T.items():
        for _ in range(40):
            w0, w1 = base_word(rnd, e)
            keep = "rs2" in e or "immv" in e or e["fmt"] in ("I", "S", "B", "U") or \
                e.get("shift")
            ops = dict(rd=rnd.choice(EDGE + [rnd.randrange(128)] * 4),
                       rs1=rnd.choice(EDGE + [rnd.randrange(128)] * 4))
            if not keep:
                ops["rs2"] = rnd.choice(EDGE + [rnd.randrange(128)] * 4)
            if e["fmt"] == "R4" and e["opc"] != A.OPC["C0"]:
                ops["rs3"] = rnd.choice(EDGE[:13]) & ~0x60 | rnd.randrange(4) << 5
            w = set_ops(w0, w1, **ops)
            if e["fmt"] == "R4" and e["opc"] != A.OPC["C0"]:
                w &= ~(3 << 25)        # rs3 left fmt2 random: fix it to 00
            vec.append(w)
    return vec


def fault_vectors(rnd):
    vec = []
    for _ in range(600):            # word0[1:0] != 11
        vec.append(rnd.getrandbits(64) & ~3 | rnd.randrange(3))
    opcs = list(A.OPC.values())
    for _ in range(1500):           # a used opcode, random funct3/funct7/sub
        w = rnd.getrandbits(64) & ~0x7F | rnd.choice(opcs)
        vec.append(w)
    for n, e in A.T.items():        # one field of a row broken
        for _ in range(12):
            w0, w1 = base_word(rnd, e)
            k = rnd.randrange(5)
            if k == 0:
                w0 ^= 1 << rnd.randrange(12, 15)
            elif k == 1:
                w0 ^= 1 << rnd.randrange(25, 32)
            elif k == 2:
                w1 ^= 1 << rnd.randrange(17, 22)
            elif k == 3:
                w0 ^= 1 << rnd.randrange(20, 25)
            vec.append(set_ops(w0, w1, rd=rnd.choice(EDGE), rs1=rnd.choice(EDGE),
                               rs2=rnd.choice(EDGE)) if k == 4 else w0 | w1 << 32)
    return vec


def sweep_vectors(rnd):
    """Every used opcode x funct3 x funct7 (random sub, rs2 field and low
    operands), then every sub of the sub-selected rows."""
    vec = []
    for opc in A.OPC.values():
        for f3 in range(8):
            for f7 in range(128):
                rs2f = rnd.choice([0, 1, 2, 3, 4, rnd.randrange(32)])
                w0 = f7 << 25 | rs2f << 20 | rnd.randrange(32) << 15 | f3 << 12 | \
                    rnd.randrange(32) << 7 | opc
                w1 = rnd.getrandbits(32) & ~0x3FFFFF | rnd.randrange(32) << 17 | \
                    rnd.getrandbits(14) << 8
                vec.append(w0 | w1 << 32)
    for opc in A.OPC.values():
        for f3 in range(8):
            for f7 in (0, 1, 2, 3, 0x20, 0x21, 0x22, 0x30):
                for sub in range(32):
                    w0 = f7 << 25 | rnd.randrange(5) << 20 | rnd.randrange(32) << 15 | \
                        f3 << 12 | rnd.randrange(32) << 7 | opc
                    vec.append(w0 | (sub << 17 | rnd.getrandbits(10) << 22) << 32)
    for imm in range(16):           # texsz immediates
        vec.append((imm << 20 | 3 << 12 | 0x2B | 5 << 7 | 7 << 15) | rnd.getrandbits(10) << 54)
    return vec


def texszs_vectors(rnd):
    e = A.T["texsz.s"]
    vec = []
    for _ in range(200):
        w0, w1 = base_word(rnd, e)
        if rnd.random() < 0.7:
            w1 &= ~0x3          # rd mostly a low GPR
            w0 &= ~(0x10 << 7)
        vec.append(w0 | w1 << 32)
    return vec


def write(path, vec, ncfg):
    with open(path, "w") as f:
        for w in vec:
            f.write("%016x" % w + "".join("%027x" % A.decode(w, CFG[c]) for c in range(ncfg))
                    + "\n")


def main():
    rnd = random.Random(288)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sim", "vec")
    n = A.dec_table(os.path.join(out, "dec_table.hex"))
    with open(os.path.join(out, "dec_table.hex")) as f:
        tab = [int(ln[:16], 16) for ln in f if ln.strip()]
    write(os.path.join(out, "dec_cfg.hex"), tab, 6)
    swp = sweep_vectors(rnd)
    write(os.path.join(out, "dec_sweep.hex"), swp, 6)
    opd = opd_vectors(rnd)
    write(os.path.join(out, "dec_opd.hex"), opd, 6)
    flt = fault_vectors(rnd)
    write(os.path.join(out, "dec_fault.hex"), flt, 6)
    tsz = texszs_vectors(rnd)
    write(os.path.join(out, "dec_texszs.hex"), tsz, 6)
    ill = sum(1 for w in flt if A.decode(w, CFG[0]) >> A.F["ILL"][0] & 1)
    print("gen_dec_vectors: table %d, cfg %d, sweep %d, opd %d, fault %d (%d ILL in CFG 0), texszs %d"
          % (n, len(tab), len(swp), len(opd), len(flt), ill, len(tsz)))


if __name__ == "__main__":
    main()
