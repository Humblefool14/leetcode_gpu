# ad_su_pipe

RTL: `rtl/gpu/su/ad_su_pipe.v`. Parent: ad_su. Implemented in: ws001-p010.

## 1. Purpose and place

The unified 6-stage physical execution pipeline of the Shader Unit (SU), NPHYS lanes.
It integrates integer ALU and floating-point FPU pipelines into a physically balanced 6-stage architecture (EX1..EX5 + WB), replacing the former fake stage-0 combinational pipeline to achieve timing closure at 200 MHz on Xilinx 7-Series FPGAs (WNS > 2.0 ns) and 1 GHz+ ASIC scalability.

### Physical Pipeline Balancing

- **Stage 1 (EX1 - Alignment & Shifter Prep)**:
  Operand latching and unpacking, sign and exponent alignment calculation, bitwise logic operations (AND, OR, XOR, ANDN, ORN, XNOR, SEL, MOVI), bit reversal and arithmetic right shift preparation.
- **Stage 2 (EX2 - Multiply / Add Stage 1)**:
  33-bit addition and subtraction (`am_addsub`), FMA 33x33 multiplier first pipeline stage with DSP48E1 input registers (`AREG/BREG = 1`).
- **Stage 3 (EX3 - Cascade / Add Stage 2)**:
  33-bit barrel shifter (`am_shift`), magnitude and signed/unsigned comparison evaluation (`SLT`, `SLTU`, `MIN`, `MAX`, `MINU`, `MAXU`), DSP48E1 multiplier cascade pipeline stage (`MREG = 1`).
- **Stage 4 (EX4 - Normalization & Rounding / Result MUX)**:
  FMA post-addition with DSP48E1 pipeline output register (`PREG = 1`), leading-zero detection, floating-point normalization and rounding (`am_fp_rnd`), ALU operation result multiplexing.
- **Stage 5 (EX5 - Writeback Preparation & Formatting)**:
  Packed FP16 half-precision formatting and saturation clamp (`ad_su_hsat`), writeback data alignment.
- **Stage 6 (WB - Output Stage)**:
  Registered outputs driving the short-result writeback bus (`s_*`) exactly `SHORT_LAT` (6) cycles after `x_valid`.

Pipeline hold: All internal pipeline stages are gated by clock enable `en`. When `en` is low, every internal register freezes its current state.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp. |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `UOP_W` | `104` | Width of the decoded instruction (= `AD_UOP_W` of `include/ad_su_uop.vh`). |
| `SHORT_LAT` | `6` | Cycles from `x_valid` to the short result (one fixed pipeline for classes a and f, design §3.1.1). |
| `PACKED` | `0` | Packed fp16 arithmetic present (`ad_su_pk`). |
| `PK_SHARED` | `0` | With PACKED: packed fp16 operations on fp32 datapath. |

## 3. Ports

Clock/reset domain: `clk` (gclk) unless otherwise stated. Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `en` | in | 1 | Clock enable. Freezes all internal pipeline registers when low. |
| **Issued instruction, one lane group per cycle (from ad_su_opd)** | | | |
| `x_valid` | in | 1 | A lane group of an instruction. |
| `x_warp` | in | WARP_W | Warp slot. |
| `x_grp` | in | GRP_W | Lane group (lanes `x_grp*NPHYS .. +NPHYS-1`). |
| `x_last` | in | 1 | Last group of the instruction. |
| `x_sbe` | in | (SBE_W)+1 | Scoreboard entry of the instruction. |
| `x_pc` | in | 16 | Instruction index. |
| `x_uop` | in | UOP_W | Decoded instruction (`include/ad_su_uop.vh`). |
| `x_a` | in | NPHYS*32 | Operand rs1 per lane. |
| `x_b` | in | NPHYS*32 | Operand rs2 per lane. |
| `x_c` | in | NPHYS*32 | Operand rs3 per lane. |
| `x_mask` | in | 2*NPHYS | [NPHYS-1:0] EXEC lanes of the group, [2*NPHYS-1:NPHYS] side-effect lanes. |
| `x_info` | in | 32 | Auxiliary warp execution information. |
| `x_ready` | out | 1 | Asserted when the execution pipeline can accept a group this cycle. |
| **Short result to ad_su_wb (exactly SHORT_LAT cycles after x_valid)** | | | |
| `s_valid` | out | 1 | Result valid of one lane group. |
| `s_warp` | out | WARP_W | Warp. |
| `s_grp` | out | GRP_W | Group. |
| `s_rd` | out | 7 | Destination operand register. |
| `s_data` | out | NPHYS*32 | Result data per physical lane. |
| `s_lanes` | out | NPHYS | Active lane write mask. |

## 4. Verification

Verification is performed via:
- `sim/tb/ad_su_pipe_real_tb.v`: Real pipeline 6-cycle fixed latency, 1-op/cycle throughput, and pipeline stall/freeze behavior under `en = 0`.
- `sim/tb/ad_su_alu_tb.v`: Arithmetic, logical, shift, and compare correctness across all operations.
- `sim/tb/ad_su_fpu_tb.v`: Full IEEE-754 single-precision and packed half-precision floating-point compliance on 6,000 reference test vectors.
- Arithmetic lint: 0 operators outside `rtl/library/arith/` (checked with `tools/arith-lint.py`).

## 10. Status

2026-11-08 (core builder): implemented in `rtl/su/ad_su_pipe.v`.  It instantiates `ad_su_alu` and
`ad_su_fpu` (the real unit, `rtl/su/ad_su_fpu.v`; `sim/common/ad_su_fpu_stub.v` is a stand-in with
the same ports for runs without it) and merges their short results.  The SU top does NOT use this
module: `ad_su` instantiates `ad_su_alu` and `ad_su_fpu` directly (they are its children in
`ad_su.md`, and their fw4_/fw5_ taps feed ad_su_opd's forwarding); ad_su_pipe is the alternative
packaging with a pipeline hold.  The EX1..WB stage split of §1 is the children's (each lane
combinational before the first of SHORT_LAT stages); §4's references to am_* arithmetic and DSP
registers are not part of this tree.
- The hold: x_ready = en (and the unit's x_ready); a token line of SHORT_LAT stages advances only
  while en and marks each taken ALU/FPU group that writes rd; the children's results wait in a FIFO
  (`rtl/su/core/ad_su_fifo.v`, depth >= SHORT_LAT + 1) until their token reaches the last stage.
  s_* = the FIFO head (or the child's result of this cycle when the FIFO is empty) while the last token
  stage is valid: exactly SHORT_LAT en-cycles after the group, held while en is 0.
- ASSUMPTION: "freezes every stage" is read as observable behaviour: s_* holds (s_valid stays 1 with the
  same data) while en is 0, and nothing is taken (x_ready 0); the children's own registers keep
  running (they have no enable; the FIFO absorbs it).  The consumer of s_* is frozen too.
- ASSUMPTION: PACKED / PK_SHARED are accepted and unused (ad_su_pk stays a separate short unit); no
  forwarding taps on this wrapper.
- TB `sim/tb/ad_su_pipe_tb.v` (with the real FPU; `-DPIPE_FPU_STUB` with the stub): `PASS
  ad_su_pipe.lat` (en = 1: exactly SHORT_LAT, back to back), `PASS ad_su_pipe.data` (ALU vs
  gsi1model.alu, FPU vs gsi1fp.fpu vectors `sim/vec/core_fpu.hex`), `PASS ad_su_pipe.freeze` (random
  en), `PASS ad_su_pipe`.  (§4's `ad_su_pipe_real_tb` is this TB.)
- Formal `formal/ad_su_pipe` (NPHYS 1, SHORT_LAT 3, the FPU stub): s_* equals an ideal frozen
  pipeline (a harness delay line advancing only while en) every cycle, x_ready == en; bmc abc bmc3
  depth 16 full data; prove abc pdr with 2-bit operand values and bitwise ALU ops (define REDUCE;
  the arithmetic is proven in ad_su_alu).  Mutation `MUT_PIPE_FREEZE` (token line ignores en): TB and
  formal FAIL.
