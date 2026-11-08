#!/usr/bin/env python3
# gen_gfx_vectors.py: vectors of the SU's graphics-side testbenches.
#
#   python3 -I tools/gen_gfx_vectors.py [--seed N] [--batches B]
#
# sim/vec/gfx_exp_cmd.hex, gfx_exp_beats.hex (sim/tb/ad_su_exp_tb.v): batches of four slots
# (fragment, vertex or empty warps), each batch a random GSI1 program of exp instructions run by
# tools/gsi1model.py --warps (its --exp-out and --ms-out are the expected beats, written by
# write_exports()).  The command stream (one word per line) is what the testbench drives:
#   1 slot reg lane data          RX register write (fl_we)
#   2 slot addr data              RX primitive-table write (fl_pw_we)
#   3 slot cov seq front          fl_go (fl_info = {front, seq, cov})
#   4 warp kind target side d0..d31   one exp instruction (the side-effect lanes, rs2 per lane)
#   5 warp                        wc_end
#   6 nbeats                      wait until nbeats beats in all have been taken and every
#                                 ended warp has been released
#   0                             end
# The beats file: per beat 28 words: the 22 words of --exp-out, the --ms-out word, d_s[0..3]
# (the RX's 0xFF8-0xFFB words of the warp, 0 when none) and {cdef[3:0], front} (cdef: the lanes
# that exported the beat's attachment, whose colour is defined; front: the warp's facing).
#
# sim/vec/gfx_pt_cmd.hex, gfx_pt_exp.hex (sim/tb/ad_su_pt_tb.v): one vertex warp's exp
# instructions (same command 4 format, then 0) and gsi1model.py --pt-out (entry 0..31,
# word 0..19, 1 + value or 0 when not written).
#
# sim/vec/gfx_mesh_lds.hex, gfx_mesh_cmd.hex, gfx_mesh_exp.hex (sim/tb/ad_su_exp_mesh_tb.v):
# the LDS image (1024 words), the meshlets' base addresses (count, then one per kick), and the
# expected packages (count, then per package 24 words: {last, id} and the 702-bit package in
# 22 words, word 0 = bits 31:0).  The meshlet layout and package of spec ad_su_exp_mesh.md §4.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import argparse
import os
import random
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
VEC = os.path.join(ROOT, "sim", "vec")
M32 = 0xFFFFFFFF


def f32(x):
    return struct.unpack("<I", struct.pack("<f", x))[0]


def write_hex(path, words):
    with open(path, "w") as f:
        for w in words:
            f.write("%08x\n" % (w & M32))


def run_model(prog, warps, init, extra):
    """Runs gsi1model.py --warps; returns the files it wrote (dict name -> list of ints)."""
    with tempfile.TemporaryDirectory() as td:
        ps = os.path.join(td, "p.s")
        with open(ps, "w") as f:
            f.write(prog)
        wf = os.path.join(td, "w.hex")
        write_hex(wf, warps)
        inf = os.path.join(td, "i.hex")
        with open(inf, "w") as f:
            for k in range(4):
                for n in range(32):
                    for ln in range(32):
                        v = init[k][n][ln]
                        f.write("000000000\n" if v is None else "1%08x\n" % (v & M32))
        outs = {}
        args = [sys.executable, "-I", os.path.join(HERE, "gsi1model.py"), ps, "--warps", wf,
                "--init", inf, "-o", os.path.join(td, "o.exp")]
        for opt, name in extra:
            args += [opt, os.path.join(td, name)]
        subprocess.run(args, check=True)
        for opt, name in extra:
            with open(os.path.join(td, name)) as f:
                outs[name] = [int(ln, 16) for ln in f if ln.strip()]
        return outs


# ---------------------------------------------------------------- exp ----------
# registers: r1, r2 SAMPLE_MASK data, r3 z, r4 x+0.5, r5 y+0.5, r6 the RX's sample mask,
# r7 depth data, r0 other targets' data, r8..r23 colour data (attachment k component c:
# r8 + 4k + c), r24..r30 the Booleans of exec.set (24 + k attachment k, 28 depth, 29/30 the
# two SAMPLE_MASK exports), r31 the vertex targets' Boolean.
B_DEP, B_S1, B_S2, B_OTH = 28, 29, 30, 31


def exp_program(rnd):
    blocks = []
    for k in range(4):
        blocks.append(["exec.set r%d" % (24 + k)] +
                      ["exp r%d, 0x%x" % (8 + 4 * k + c, 0x100 + 16 * k + c) for c in range(4)])
    blocks.append(["exec.set r%d" % B_DEP, "exp r7, 0x104"])
    blocks.append(["exec.set r%d" % B_OTH, "exp r0, 0x108", "exp r0, 0x10b", "exp r0, 0x000",
                   "exp r0, 0x010", "exp r0, 0x114", "exp r0, 0x106"])
    rnd.shuffle(blocks)
    # the two SAMPLE_MASK exports in order (the last value counts), somewhere
    s1 = rnd.randrange(len(blocks) + 1)
    blocks.insert(s1, ["exec.set r%d" % B_S1, "exp r1, 0x105"])
    s2 = rnd.randrange(s1 + 1, len(blocks) + 1)
    blocks.insert(s2, ["exec.set r%d" % B_S2, "exp r2, 0x105"])
    lines = [ln for b in blocks for ln in b] + ["end"]
    return "\n".join(lines) + "\n"


def bool_reg(rnd, mode):
    """32 lanes of a Boolean register: mode 0 all false, 1 random, 2 all true."""
    if mode == 0:
        return [0] * 32
    if mode == 2:
        return [rnd.choice([1, 0xFFFFFFFF, 0x3F800000]) for _ in range(32)]
    return [rnd.choice([0, 0, 1, 0xDEADBEEF]) for _ in range(32)]


def gen_exp(rnd, nbatch):
    cmds, beats = [], []
    seq = 0x100
    total = 0
    for bi in range(nbatch):
        prog = exp_program(rnd)
        kinds = [rnd.choice([1, 1, 1, 0, 2]) for _ in range(4)]
        if bi == 0:
            kinds = [1, 1, 0, 1]
        frags = [k for k in range(4) if kinds[k] == 1]
        order = frags[:]
        rnd.shuffle(order)
        seqs = {k: (seq + i) & 0xFFFF for i, k in enumerate(order)}
        seq += len(order)
        warps, init, ds, front, r6s = [], [], {}, {}, {}
        for k in range(4):
            regs = [[None] * 32 for _ in range(32)]
            kind = kinds[k]
            if kind == 1:
                nq = rnd.choice([1, 2, 3, 4, 5, 6, 7, 8, 8, 8])
                cov = 0
                for q in range(nq):
                    nib = rnd.randrange(1, 16) if rnd.random() < 0.6 else 15
                    cov |= nib << (4 * q)
                exec0 = 0
                for q in range(nq):
                    exec0 |= 15 << (4 * q)
                fr = rnd.randrange(2)
            else:
                cov = rnd.getrandbits(32)
                exec0 = rnd.getrandbits(32) | cov
                fr = 0
            front[k] = fr
            warps += [kind, exec0, cov, seqs.get(k, 0), fr]
            for n in [0, 1, 2, 7] + list(range(8, 24)):
                regs[n] = [rnd.getrandbits(32) for _ in range(32)]
            for n in (1, 2):
                regs[n] = [rnd.choice([0, 15, rnd.getrandbits(32)]) for _ in range(32)]
            regs[3] = [rnd.getrandbits(32) for _ in range(32)]
            # positions: x + 0.5, y + 0.5 per lane of a 2x2 quad
            regs[4], regs[5] = [None] * 32, [None] * 32
            for q in range(8):
                x, y = rnd.randrange(0, 4096, 2), rnd.randrange(0, 4096, 2)
                for i in range(4):
                    ln = 4 * q + i
                    regs[4][ln] = f32(x + (i & 1) + 0.5)
                    regs[5][ln] = f32(y + (i >> 1) + 0.5)
            r6 = rnd.random() < 0.5
            r6s[k] = r6
            if r6:
                regs[6] = [rnd.choice([0, 15, 15, rnd.randrange(16), rnd.getrandbits(32)])
                           for _ in range(32)]
            # Booleans
            only0 = rnd.random() < 0.5
            nocol = rnd.random() < 0.15
            for kk in range(4):
                if nocol:
                    mode = 0
                elif only0:
                    mode = 2 if kk == 0 else 0
                else:
                    mode = rnd.choice([0, 1, 2, 2])
                regs[24 + kk] = bool_reg(rnd, mode)
            regs[B_DEP] = bool_reg(rnd, rnd.choice([0, 1, 2]))
            twice = rnd.random() < 0.5
            regs[B_S1] = bool_reg(rnd, rnd.choice([1, 2]) if twice else 0)
            regs[B_S2] = bool_reg(rnd, rnd.choice([1, 2]) if twice else 0)
            regs[B_OTH] = bool_reg(rnd, 2)
            init.append(regs)
            if kind == 1:
                ds[k] = [rnd.getrandbits(32) for _ in range(4)] if rnd.random() < 0.5 else None
        outs = run_model(prog, warps, init, [("--exp-out", "x.xexp"), ("--ms-out", "x.msexp")])
        xexp, msexp = outs["x.xexp"], outs["x.msexp"]
        nb = xexp[0]
        # the RX's writes and fl_go of the fragment warps
        for k in frags:
            regs = init[k]
            wr = [(n, ln) for n in (0, 3, 4, 5) for ln in range(32)]
            if r6s[k]:
                wr += [(6, ln) for ln in range(32)]
            rnd.shuffle(wr)
            for n, ln in wr:
                v = regs[n][ln]
                cmds += [1, k, n, ln, v]
            pws = [(0xFFF, 0), (0x005, rnd.getrandbits(32)), (0x0C3, rnd.getrandbits(32))]
            if ds[k] is not None:
                pws += [(0xFF8 + i, ds[k][i]) for i in range(4)]
            rnd.shuffle(pws)
            for a, v in pws:
                cmds += [2, k, a, v]
            cmds += [3, k, warps[5 * k + 2], seqs[k], front[k]]
        # each live warp's exp instructions, interleaved; then its end
        streams = {}
        for k in range(4):
            if kinds[k] == 2:
                continue
            streams[k] = exp_stream(prog, init[k], warps[5 * k + 1], warps[5 * k + 2], kinds[k])
        live = list(streams)
        while live:
            k = rnd.choice(live)
            if streams[k]:
                t, side = streams[k].pop(0)
                reg = exp_src(prog, t)
                cmds += [4, k, kinds[k], t[1], side] + [init[k][reg][ln] or 0 for ln in range(32)]
            else:
                cmds += [5, k]
                live.remove(k)
        total += nb
        cmds += [6, total]
        # expected beats
        for b in range(nb):
            w = xexp[1 + 22 * b:1 + 22 * (b + 1)]
            sq = w[0] >> 16
            k = [kk for kk in frags if seqs[kk] == sq][0]
            rt = w[0] >> 13 & 3
            nocol = w[0] >> 10 & 1
            cdef = 0
            if not nocol:
                q = beat_quad(xexp, msexp, b, frags, seqs)
                bo = init[k][24 + rt]
                cov = warps[5 * k + 2]
                for i in range(4):
                    ln = 4 * q + i
                    if bo[ln] and cov >> ln & 1:
                        cdef |= 1 << i
            d = ds[k] if ds[k] is not None else [0] * 4
            beats += w + [msexp[b]] + d + [cdef << 1 | front[k]]
    cmds += [0]
    return cmds, [total] + beats


def beat_quad(xexp, msexp, b, frags, seqs):
    """The quad number of beat b (count the qfirst beats of its warp before it)."""
    sq = xexp[1 + 22 * b] >> 16
    q = -1
    for i in range(b + 1):
        w0 = xexp[1 + 22 * i]
        if w0 >> 16 == sq and w0 >> 11 & 1:
            q += 1
    return q


def exp_lines(prog):
    return [ln.strip() for ln in prog.splitlines() if ln.strip()]


def exp_src(prog, t):
    return t[0]


def exp_stream(prog, regs, exec0, mask, kind):
    """The exp instructions of a warp: [((src reg, target), side)], as the model runs them."""
    out = []
    exec_m = exec0
    for ln in exp_lines(prog):
        op, *rest = ln.replace(",", " ").split()
        if op == "exec.set":
            r = int(rest[0][1:])
            exec_m = sum(1 << i for i in range(32) if regs[r][i])
        elif op == "exp":
            r, t = int(rest[0][1:]), int(rest[1], 0)
            out.append(((r, t), exec_m & mask))
    return out


# ---------------------------------------------------------------- pt -----------
def gen_pt(rnd):
    lines = []
    tg = [0, 1, 2, 3, 4, 0x10, 0x11, 0x15, 0x1F, 0x20, 0x22, 0x100, 0x104, 0x3]
    for t in tg + [rnd.choice(tg) for _ in range(6)]:
        r = rnd.randrange(8, 24)
        lines.append("exec.set r%d" % rnd.choice([24, 25, 26]))
        lines.append("exp r%d, 0x%x" % (r, t))
    lines.append("end")
    prog = "\n".join(lines) + "\n"
    regs = [[None] * 32 for _ in range(32)]
    for n in range(8, 24):
        regs[n] = [rnd.getrandbits(32) for _ in range(32)]
    regs[24] = bool_reg(rnd, 2)
    regs[25] = bool_reg(rnd, 1)
    regs[26] = bool_reg(rnd, 1)
    init = [regs] + [[[None] * 32 for _ in range(32)] for _ in range(3)]
    exec0, mask = M32, rnd.getrandbits(32) | 0xF
    warps = [0, exec0, mask, 0, 0] + [2, 0, 0, 0, 0] * 3
    outs = run_model(prog, warps, init, [("--pt-out", "x.pexp")])
    cmds = []
    for (r, t), side in exp_stream(prog, regs, exec0, mask, 0):
        cmds += [4, 0, 0, t, side] + [regs[r][ln] for ln in range(32)]
    # a fragment warp's exp of the same targets: not stored
    cmds += [4, 0, 1, 0x001, M32] + [0xBAD00000 + ln for ln in range(32)]
    cmds += [4, 0, 2, 0x011, M32] + [0xBAD10000 + ln for ln in range(32)]
    cmds += [0]
    return cmds, outs["x.pexp"]


# ---------------------------------------------------------------- mesh ---------
def mesh_ref(lds, base, aw=10):
    """The packages of the meshlet at base: [(last, id, package int)]."""
    msk = (1 << aw) - 1
    hdr = lds[base & msk]
    mid, nprim = hdr >> 16, hdr & 0xFF
    vb = base + 1 + nprim
    out = []
    for p in range(nprim):
        t = lds[(base + 1 + p) & msk]
        if t >> 31 & 1:
            continue
        pk = 0
        for j in range(3):
            vi = t >> (8 * j) & 0xFF
            for w in range(7):
                pk |= lds[(vb + 7 * vi + w) & msk] << (32 * (7 * j + w))
        pk |= (t & 0xFFFFFF) << 672
        pk |= (t >> 24 & 0x3F) << 696
        out.append([0, mid, pk])
    if out:
        out[-1][0] = 1
    return out


def gen_mesh(rnd):
    lds = [rnd.getrandbits(32) for _ in range(1024)]
    kicks, exp = [], []
    nprims = [3, 1, 6, 4, 0, 5, 2, 8] + [rnd.randrange(1, 10) for _ in range(6)]
    base = 0
    for mi, np_ in enumerate(nprims):
        nv = rnd.randrange(3, 12)
        size = 1 + np_ + 7 * nv
        if base + size > 1024:
            base = 0
        hdr = (rnd.getrandbits(16) << 16) | nv << 8 | np_
        lds[base] = hdr
        for p in range(np_):
            fl = rnd.getrandbits(8) & 0x7F
            if mi == 3 and p == np_ - 1:
                fl |= 0x80                  # the last primitive culled
            elif mi == 6:
                fl |= 0x80                  # every primitive culled
            elif rnd.random() < 0.3:
                fl |= 0x80
            idx = [rnd.randrange(nv) for _ in range(3)]
            lds[base + 1 + p] = fl << 24 | idx[2] << 16 | idx[1] << 8 | idx[0]
        kicks.append(base)
        for last, mid, pk in mesh_ref(lds, base):
            exp.append(last << 16 | mid)
            exp += [pk >> (32 * i) & M32 for i in range(22)]
            exp.append(0)
        base += size + rnd.randrange(0, 5)
    # one meshlet wrapping around the end of the LDS
    base = 1024 - 10
    lds[base] = 0xBEEF << 16 | 4 << 8 | 2
    lds[base + 1] = 0x05 << 24 | 0x00010203 & 0xFFFFFF
    lds[base + 2] = 0x01 << 24 | 0x00000102
    kicks.append(base)
    for last, mid, pk in mesh_ref(lds, base):
        exp.append(last << 16 | mid)
        exp += [pk >> (32 * i) & M32 for i in range(22)]
        exp.append(0)
    return lds, [len(kicks)] + kicks, [len(exp) // 24] + exp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--batches", type=int, default=40)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    os.makedirs(VEC, exist_ok=True)
    cmds, beats = gen_exp(rnd, a.batches)
    write_hex(os.path.join(VEC, "gfx_exp_cmd.hex"), cmds)
    write_hex(os.path.join(VEC, "gfx_exp_beats.hex"), beats)
    cmds, pexp = gen_pt(rnd)
    write_hex(os.path.join(VEC, "gfx_pt_cmd.hex"), cmds)
    with open(os.path.join(VEC, "gfx_pt_exp.hex"), "w") as f:
        for v in pexp:
            f.write("%09x\n" % v)
    lds, kicks, mexp = gen_mesh(rnd)
    write_hex(os.path.join(VEC, "gfx_mesh_lds.hex"), lds)
    write_hex(os.path.join(VEC, "gfx_mesh_cmd.hex"), kicks)
    write_hex(os.path.join(VEC, "gfx_mesh_exp.hex"), mexp)
    print("gen_gfx_vectors: %d beats, %d PT words, %d meshlets, %d packages"
          % (beats[0], len(pexp), kicks[0], mexp[0]))


if __name__ == "__main__":
    main()
