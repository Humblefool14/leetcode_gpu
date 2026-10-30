#!/usr/bin/env python3
"""Generates rtl/ad_rx_setup_uc.svh: the micro-program of ad_rx_setup.

Instruction (28 bits): {op[4:0], d[8:0], a[6:0], b[6:0]}.
d is a register (0-127) or, for BRA/JMP, the 9-bit target; a is BRA's condition.

Register map (fp32):
   0-11  clip-space x y z w of v0..v2         12-20 weights b_i0 b_i1 b_i2 of v0..v2
  21-26  VIEWPORT xs ys xo yo zs zo           27    1.0
  28-30  1/w of v0..v2                        31-39 window x y z of v0..v2 (x, y at 31+3i)
  40-46  DX1 DY1 DX2 DY2 DF OX OY (ad_rx_edge) 48-55 temporaries (53: depth bias o)
  56-58  b0/w of v0..v2                        59-61 b1/w of v0..v2
  76-79  viewport rectangle x0 x1 y0 y1        80-91 planes z, 1/w, b0/w, b1/w as (A, B, C)
  92-93  zmin, zmax (Hi-Z)
 120-127 read only: DB_CONST DB_SLOPE DB_CLAMP 0.5 0 r(D16/D24) LINE_WIDTH/2 POINT_SIZE/2
"""
import os, sys

OPS = dict(NOP=0, ADD=1, SUB=2, MUL=3, DIV=4, ABS=5, MAX=6, MIN=7, MXS=8, ULP=9, BCL=10,
           INT=11, OUT=12, END=13, BRA=14, JMP=15, MOV=16)
COND = dict(point=0, line=1, nobias=2, notd32=3, norect=4, empty=5, raw=6)

prog, labels, fix = [], {}, []

def emit(op, d=0, a=0, b=0):
    prog.append([op, d, a, b])
def L(name): labels[name] = len(prog)
def BRA(cond, tgt): fix.append((len(prog), tgt)); emit('BRA', 0, COND[cond], 0)
def JMP(tgt): fix.append((len(prog), tgt)); emit('JMP', 0, 0, 0)

ONE, HALF, ZERO, RCST = 27, 123, 124, 125
T0, T1, T2, T3, IDF, BIAS = 48, 49, 50, 51, 52, 53

def vtx(v):
    x, y, z, w = 4*v, 4*v+1, 4*v+2, 4*v+3
    iw = 28 + v
    emit('DIV', iw, ONE, w)
    for c, s, o, dst in ((x, 21, 23, 31+3*v), (y, 22, 24, 32+3*v), (z, 25, 26, 33+3*v)):
        emit('MUL', T0, c, iw); emit('MUL', T0, T0, s); emit('ADD', dst, T0, o)
    emit('MUL', 56+v, 12+3*v, iw)
    emit('MUL', 59+v, 13+3*v, iw)

def rect(tag):
    BRA('norect', 'rect_' + tag)
    emit('ABS', T0, 21); emit('SUB', 76, 23, T0); emit('ADD', 77, 23, T0)
    emit('ABS', T0, 22); emit('SUB', 78, 24, T0); emit('ADD', 79, 24, T0)
    L('rect_' + tag)

def plane(f0, f1, f2, dst):
    A, B, C = dst, dst+1, dst+2
    emit('SUB', T0, f1, f0); emit('SUB', T1, f2, f0)
    emit('MUL', T2, T0, 43); emit('MUL', T3, T1, 41); emit('SUB', T2, T2, T3); emit('MUL', A, T2, IDF)
    emit('MUL', T2, T1, 40); emit('MUL', T3, T0, 42); emit('SUB', T2, T2, T3); emit('MUL', B, T2, IDF)
    emit('MUL', T2, A, 45); emit('MUL', T3, B, 46); emit('ADD', T2, T2, T3); emit('ADD', C, f0, T2)

def planes():
    emit('DIV', IDF, ONE, 44)
    plane(33, 36, 39, 80); plane(28, 29, 30, 83); plane(56, 57, 58, 86); plane(59, 60, 61, 89)

def bias(tag):
    emit('MOV', BIAS, ZERO)
    BRA('nobias', 'bias_' + tag)
    emit('ABS', T0, 80); emit('ABS', T1, 81); emit('MAX', T0, T0, T1); emit('MUL', T0, T0, 121)
    BRA('notd32', 'r_' + tag)
    emit('ABS', T1, 33); emit('ABS', T2, 36); emit('MAX', T1, T1, T2)
    emit('ABS', T2, 39); emit('MAX', T1, T1, T2); emit('ULP', T1, T1)
    JMP('m_' + tag)
    L('r_' + tag); emit('MOV', T1, RCST)
    L('m_' + tag); emit('MUL', T1, T1, 120); emit('ADD', T0, T0, T1); emit('BCL', T0, T0, 122)
    emit('ADD', 82, 82, T0); emit('MOV', BIAS, T0)
    L('bias_' + tag)

def zrange():
    emit('MIN', 92, 33, 36); emit('MIN', 92, 92, 39); emit('MXS', 93, 33, 36); emit('MXS', 93, 93, 39)
    emit('ADD', 92, 92, BIAS); emit('ADD', 93, 93, BIAS)

# ---------------------------------------------------------------- dispatch
BRA('raw', 'RAW'); BRA('point', 'PNT'); BRA('line', 'LIN')
# triangle
for v in range(3): vtx(v)
rect('t'); emit('INT', 0)
BRA('empty', 'EEND')
planes(); bias('t'); zrange(); emit('END')
# line (a, b); plane triangle (a, b, c) with c's attributes copied from a
L('LIN')
vtx(0); vtx(1)
emit('MOV', 39, 33); emit('MOV', 30, 28); emit('MOV', 58, 56); emit('MOV', 61, 59)
rect('l'); emit('INT', 0)
planes(); emit('MOV', BIAS, ZERO); zrange()
emit('OUT'); emit('INT', 1); emit('END')
# point: z (0, 0, z), 1/w (0, 0, 1), PointCoord s (1/size, 0, 0.5 + OX/size), t (0, 1/size, 0.5 + OY/size)
L('PNT')
vtx(0)
rect('p'); emit('INT', 0)
emit('MOV', 80, ZERO); emit('MOV', 81, ZERO); emit('MOV', 82, 33)
emit('MOV', 83, ZERO); emit('MOV', 84, ZERO); emit('MOV', 85, ONE)
emit('DIV', 86, HALF, 127); emit('MOV', 87, ZERO)
emit('MUL', T0, 45, 86); emit('ADD', 88, HALF, T0)
emit('MOV', 89, ZERO); emit('MOV', 90, 86)
emit('MUL', T0, 46, 86); emit('ADD', 91, HALF, T0)
emit('MOV', 36, 33); emit('MOV', 39, 33); emit('MOV', BIAS, ZERO); zrange()
emit('OUT'); emit('INT', 1); emit('END')
# DRAW_RAW: screen-space positions, 1/w = 1, weights as given
L('RAW')
for v in range(3):
    emit('MOV', 31+3*v, 4*v); emit('MOV', 32+3*v, 4*v+1); emit('MOV', 33+3*v, 4*v+2)
    emit('MOV', 28+v, ONE); emit('MOV', 56+v, 12+3*v); emit('MOV', 59+v, 13+3*v)
emit('INT', 0)
BRA('empty', 'EEND')
planes(); emit('MOV', BIAS, ZERO); zrange(); emit('END')
L('EEND'); emit('END')

for pc, tgt in fix:
    prog[pc][1] = labels[tgt]

def word(i):
    op, d, a, b = i
    return (OPS[op] << 23) | (d << 14) | (a << 7) | b

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', 'rtl', 'ad_rx_setup_uc.svh')
with open(out, 'w') as f:
    f.write(f"// Generated by tools/ad_rx_ucode.py -- do not edit.  {len(prog)} micro-instructions.\n")
    f.write(f"localparam int UC_LEN = {len(prog)};\n")
    f.write("function automatic logic [27:0] ucode(input logic [8:0] pc);\n  case (pc)\n")
    for pc, i in enumerate(prog):
        f.write(f"    9'd{pc}: ucode = 28'h{word(i):07x};  // {i[0]} {i[1]} {i[2]} {i[3]}\n")
    f.write("    default: ucode = {5'd13, 23'd0};  // END\n  endcase\nendfunction\n")
print(f"{len(prog)} micro-instructions; labels {labels}")
