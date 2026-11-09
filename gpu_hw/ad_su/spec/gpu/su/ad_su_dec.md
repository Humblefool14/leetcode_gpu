# ad_su_dec

RTL: `rtl/gpu/su/ad_su_dec.v`.  Parent: ad_su.  Implemented in: p008.

## 1. Purpose and place

Decodes a 64-bit GSI1 instruction (design §3.3, §3.4) into the SU micro-op of include/ad_su_uop.vh: unit, operation, operand numbers (7 bits), immediate, modifiers, latency class, destination count, and the ISA-fault flag.  Children: `ad_su_dec_tab` (RISC-V opcodes) and `ad_su_dec_tabc` (custom-0..3), the opcode table split in two (p008, U38's 400 lines).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `WARP_W` | `2` | log2(NWARPS). |
| `UOP_W` | `104` | Width of the decoded instruction (= AD_UOP_W of include/ad_su_uop.vh). |
| `NREGS` | `32` | GPRs per thread: 32 or 64 (r0..r62 at most; 63 is rq). |
| `PACKED` | `0` | 16-bit packed arithmetic present (else those opcodes are ISA faults; packh/unpackh always present). |
| `SUBGROUP` | `0` | shfl/vote/ballot present (CAPS[24]). |
| `HAS_SA` | `0` | rq/sactl/qstat/sastat/qtag usable (always 0 in v1). |
| `MS4` | `0` | texsz.s (immediate 3) present (CAPS[29]); else an ISA fault. |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `d_valid` | in | 1 | Instruction. |
| `d_ready` | out | 1 | Taken. |
| `d_warp` | in | WARP_W | Warp. |
| `d_pc` | in | 16 | pc. |
| `d_instr` | in | 64 | Instruction. |
| `u_valid` | out | 1 | Decoded instruction (registered). |
| `u_ready` | in | 1 | Taken by ad_su_sb. |
| `u_warp` | out | WARP_W | Warp. |
| `u_pc` | out | 16 | pc. |
| `u_uop` | out | UOP_W | The micro-op. |

12 ports.

## 4. Behaviour

- Operand numbers: rd/rs1/rs2 low 5 bits from word0's RISC-V positions, high 2 bits from word1[1:0],
  [3:2], [5:4]; rs3 from word0[31:27] and word1[7:6].  Immediates per §3.3 (sext(imm12) +
  (sext(imm_hi) << 12); B offsets in instructions; U/movi).
- Unit and class per the §3.4.1/§3.4.2 tables (e.g. OP funct7 0000001 div* → DIV/x, mul* → FPU/f).
  NDST 4 for texl/texb/texf, 1 for texsz and other writers, 0 for stores/branches.  PAIR for the
  texture instructions.  SIDE for sw/atom/atoms/exp/tex*/sts.  STORE: sub 0 `sw`, 1 `sw.x` (the uop's
  sub, which ad_su_lsu reads), any other sub undefined.
- ISA fault (ILL = 1, unit NONE): word0[1:0] ≠ 11, undefined opcode/funct/sub, a register ≥ NREGS
  (except 63 when HAS_SA, 64-127 as sources only), packed ops without PACKED, subgroup ops without
  SUBGROUP, rq/sactl without HAS_SA, class m/t/x with rd = 63.

## 5. State machine

None (one pipeline register).

## 6. Latency and throughput

One instruction per cycle, 1 cycle latency.

## 7. Corner cases and errors

- nop (custom-3 funct3 111 sub 0) decodes to unit NONE with no operands (it is not an addi r0).

## 8. What the TB checks

`sim/tb/ad_su_dec_tb.v` prints, in this order:

- `PASS ad_su_dec.table` — every opcode of design §3.4.1 against a table produced by the ISA model (sim/models or tools/gsi1asm.py)
- `PASS ad_su_dec.operands` — 7-bit operand numbers and immediates with random word1
- `PASS ad_su_dec.fault` — illegal encodings, NREGS, PACKED/SUBGROUP/HAS_SA = 0 give ILL
- `PASS ad_su_dec.texszs` — texsz.s faults without MS4 and decodes to TEX op 0x4B (no rs1) with it (the table's second decoder has MS4 1; `sim/tb/su/dec_table.hex` made again by `tools/gsi1asm.py --dec-table`)
- `PASS ad_su_dec` at the end.

## 9. References

design §3.2-§3.4, include/ad_su_uop.vh; docs/ghci.md section 12 (the GSI1 standard).

## 10. Status

Implemented in WS288 p008 (branch p1-su; TB `sim/tb/ad_su_dec_tb.v` on 4976 vectors of `tools/gsi1asm.py --dec-table`).  Choices made here (recorded in include/ad_su_uop.vh and gsi1asm.py, now in docs/ghci.md section 12):

- The OP field values per unit are the `AD_<UNIT>_*` localparams of include/ad_su_uop.vh; ALU OP bit 7 (`AD_ALU_IMMB`) means operand b is the immediate (I forms).
- An ILL uop has only the ILL bit set (all other fields 0).  U forms (lui/movi) have RS1-3, MOD, HSEL, SUB and RM 0; other forms carry all operand fields as encoded (used or not), RM = funct3.
- rm: 0-4 and 7 are accepted (7, "dynamic", is RNE: there is no CSR); 5 and 6 are faults; fround accepts 0-3 only.
- Undefined encodings that fault: OP funct7 0100000 with funct3 001/010/011, Zbb funct7 0000101 with funct3 0xx, R4 forms with fmt/funct2 ≠ 00 (except atom), any R-form custom instruction with funct7 ≠ its value (bar, end, exec.*, kill, qd, shfl, vote, ballot, sactl, nop; texl 0/1/2/3/6/10/14, texb 0/1/0x10, texf 0, each also with funct7 [5] (the .3 forms)), texsz with imm[11:0] other than 0, 1 or 2, a texture slot with sub[4] = 1, atom sub[3:0] > 10 (sub[4] selects the memory: 0 global, the LSU; 1 shared, the LDS unit), qd sub > 5, shfl sub > 4, transcendental sub > 6, exec.* sub > 3, vote sub > 1, unpackh sub > 1, nop sub ≠ 0.
- custom-2 funct7: fmin2 0 / fmax2 1 (funct3 100); iadd2 0 / isub2 1 / imul2 2 (101); fcmp2 lt 0 / ge 1 / eq 2 / ne 3 (110).
- fence is unit LSU, class a (ad_su_sb waits for cm = 0 before issuing it); a PAIR rs1 must leave rs1+1 inside the GPRs (rs1 ≤ NREGS-2, not 62) or be c0-c30 / a special other than 127.  A texture .c form (TEX op bit 2) or .3 form (funct7 [5]) reads rs1+2 (Dref or the third coordinate): the uop's rs3 is rs1+2 (use3), which must stay inside the GPRs (rs1 ≤ NREGS-3, not 61-62) or the constants (not c30, c31) or the specials (not 126, 127); a .3 form with .c also reads rs1+3 (Dref), one more (rs1 ≤ NREGS-4, not 60-62, not c29-c31, not 125-127).  A .3 form sets the uop's sub[4] (the slot is sub[3:0]).  The texture R forms' imm is their texel offsets {word1 [13:10], [29:26], [25:22]} (dw, dv, du; docs/ghci.md §12.9); texsz.d (imm 2) is TEX op 3 with bit 3.

2026-11-08 (ad_ rebuild, rtl/su/): `rtl/su/ad_su_dec.v` (pipeline register) over the combinational
`rtl/su/dec/ad_su_dec_core.v`, which instantiates `ad_su_dec_tab`, `ad_su_dec_tabc` and the leaves
`rtl/su/dec/ad_su_dec_fld.v` (fields, 7-bit operand numbers), `ad_su_dec_imm.v` (immediates),
`ad_su_dec_chk.v` (faults, rs3 = rs1+2 of .c/.3, NDST, RQS/RQD).  Bit-exact against
`tools/gsi1asm.py` decode() (the original tool, the source of truth; encoding table in
docs/GSI1_ISA.md, generated by tools/gen_isa_doc.py).  TB `sim/tb/ad_su_dec_tb.v`: six decoders
(NREGS/PACKED/SUBGROUP/HAS_SA/MS4 = 32/0/0/0/0, 64/1/1/1/1, 32/1/0/0/1, 64/0/1/0/0, 32/0/1/1/0,
48/1/1/0/1) on 5528 `--dec-table` vectors + the same under all six + 46096 opcode×funct3×funct7 /
sub sweep + 5880 operand + 3864 fault + 200 texsz.s vectors of tools/gen_dec_vectors.py, random
d_valid/u_ready.  Formal: formal/ad_su_dec (registered path), ad_dec_core, ad_dec_fld, ad_dec_imm,
ad_dec_chk, ad_su_dec_tab, ad_su_dec_tabc.  Mutations MUT_DEC_RS3 (chk), MUT_DEC_HOLD (dec).
- ASSUMPTION: UOP_W default 108 (AD_UOP_W), not 104.
- ASSUMPTION: the vectors live in sim/vec/dec_table.hex (and dec_cfg/sweep/opd/fault/texszs.hex),
  not sim/tb/su/dec_table.hex; regenerate with `python3 -I tools/gen_dec_vectors.py`.
- ASSUMPTION: the tables have no MS4 port: texsz.s (custom-1 funct3 011 imm 3) is a defined row of
  ad_su_dec_tabc and the MS4 fault is raised by ad_su_dec_core (need_ms4 into ad_su_dec_chk).
- ASSUMPTION: each table drives every output 0 when def = 0, and ad_su_dec_core ORs the halves
  (formal: never both def).  .c = tex && op[2], .3 = tex && funct7[5] are derived in the core.
- ASSUMPTION: d_ready = !u_valid || u_ready; u_warp/u_pc/u_uop are unreset datapath qualified by
  u_valid.
- ASSUMPTION: any NREGS 1..64 works (the checks are generic: GPR limit min(NREGS, 63)); 32, 48
  and 64 are tested.
- Texture R forms also fault with funct7[6] = 1 (the table has no such row).
