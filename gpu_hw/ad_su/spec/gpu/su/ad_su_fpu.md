# ad_su_fpu

RTL: `rtl/gpu/su/ad_su_fpu.v`.  Parent: ad_su.  Implemented in: p008.

## 1. Purpose and place

The fp32 unit of the SU, NPHYS lanes: fadd/fsub/fmul/fmadd family (FMA on DSPs), fmin/fmax, fsgnj, fround, fcvt, feq/flt/fle/fne (Boolean), fract, sat; also the integer mul* (DSP).  Short pipeline.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit). |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `UOP_W` | `108` | Width of the decoded instruction (= AD_UOP_W of include/ad_su_uop.vh; the former 104 is stale). |
| `SHORT_LAT` | `6` | Cycles from x_valid to the short result (one fixed pipeline for classes a and f, design §3.1.1); at least 3 (the fw4 tap is stage SHORT_LAT − 2). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Issued instruction, one lane group per cycle (from ad_su_opd, shared by all units)** | | | |
| `x_valid` | in | 1 | A lane group of an instruction; this unit acts only when the uop's unit field is its own. |
| `x_warp` | in | WARP_W | Warp slot. |
| `x_grp` | in | GRP_W | Lane group (lanes x_grp*NPHYS .. +NPHYS-1). |
| `x_last` | in | 1 | Last group of the instruction. |
| `x_sbe` | in | (SBE_W)+1 | Scoreboard entry of the instruction (all ones = none). |
| `x_pc` | in | 16 | Instruction index (branches, faults). |
| `x_uop` | in | UOP_W | The decoded instruction (include/ad_su_uop.vh). |
| `x_a` | in | NPHYS*32 | Operand rs1 per lane (modifiers applied). |
| `x_b` | in | NPHYS*32 | Operand rs2. |
| `x_c` | in | NPHYS*32 | Operand rs3 (or rs1+1 for the PAIR instructions). |
| `x_mask` | in | 2*NPHYS | [NPHYS-1:0] EXEC lanes of the group, [2*NPHYS-1:NPHYS] side-effect lanes (EXEC & coverage & ~KILLED). |
| `x_info` | in | 32 | x_info [15:0] fragment sequence number, [17:16] warp kind (0 vertex, 1 fragment, 2 compute), [18] front facing, [31:19] 0. |
| `x_ready` | out | 1 | This unit can take a group of its own this cycle (ad_su_opd waits otherwise). |
| **Short result to ad_su_wb (exactly SHORT_LAT cycles after x_valid)** | | | |
| `s_valid` | out | 1 | Result of one lane group. |
| `s_warp` | out | WARP_W | Warp. |
| `s_grp` | out | GRP_W | Group. |
| `s_rd` | out | 7 | Destination operand (63 = push to rq). |
| `s_data` | out | NPHYS*32 | Data per lane. |
| `s_lanes` | out | NPHYS | Lanes written (EXEC). |
| **Forwarding taps to ad_su_opd (its `fwd_fpu_ex4_*` / `fwd_fpu_ex5_*`)** | | | |
| `fw4_valid` | out | 1 | The pipeline register that becomes s_* 2 cycles later (stage SHORT_LAT − 2, "EX4") holds a result that writes a register: WRD and rd < 63. |
| `fw4_warp` | out | WARP_W | Its warp (= s_warp 2 cycles later). |
| `fw4_grp` | out | GRP_W | Its lane group. |
| `fw4_rd` | out | 7 | Its destination operand. |
| `fw4_data` | out | NPHYS*32 | Its data per lane (the final result: the lane datapath is before the first stage). |
| `fw4_lanes` | out | NPHYS | Its lanes (EXEC). |
| `fw5_valid` | out | 1 | The same for the register that becomes s_* 1 cycle later (stage SHORT_LAT − 1, "EX5"). |
| `fw5_warp` | out | WARP_W | |
| `fw5_grp` | out | GRP_W | |
| `fw5_rd` | out | 7 | |
| `fw5_data` | out | NPHYS*32 | |
| `fw5_lanes` | out | NPHYS | |

33 ports.

## 4. Behaviour

IEEE-754 binary32, denormals flushed (in and out), rounding from the uop's rm (default RNE); modifiers already applied to the operands by ad_su_opd, sat applied here (design §3.1).

## 5. State machine

None (pipeline).

## 6. Latency and throughput

NPHYS lanes per cycle; FMA 3 DSP + about 400 LUT per lane (design §3.6).

## 7. Corner cases and errors

- NaN handling: min/max return the non-NaN operand; compares with NaN are false except fne.

## 8. What the TB checks

`sim/tb/ad_su_fpu_tb.v` prints, in this order:

- `PASS ad_su_fpu.arith` — random fadd/fmul/fmadd against a soft-float reference (sim model); a PK_SHARED unit and a unit of NPHYS 4 (on the low 4 lanes) give the same outputs every cycle
- `PASS ad_su_fpu.cvt` — fcvt and fround in all rounding modes
- `PASS ad_su_fpu.cmp` — Boolean compares including NaN
- `PASS ad_su_fpu.mul` — integer mul/mulh*
- `PASS ad_su_fpu` at the end.

(2026-11-08) The TB runs on `sim/vec/fpu_grp.hex` of `tools/gen_fpu_vectors.py` (67,648 lane vectors in 8,456 groups of 8 lanes sharing op/rm/sat: 1,456 directed groups = corners of every op × rm 0–7 × sat 0/1, then 7,000 random groups in the style of gsi1fp.fpu_vec, all ops, rm 0–7, sat 15 %); expected values from `tools/gsi1fp.py` fpu().  Groups are interleaved with idle cycles, other units' groups and WRD = 0 uops (random junk in every other uop field).  It checks s_* exactly SHORT_LAT cycles after the take (valid, warp, grp, rd incl. 63, every lane's data, EXEC lanes), fw4_*/fw5_* against the takes of SHORT_LAT − 2 / − 1 cycles before (valid only for rd < 63), x_ready = 1, and a unit of NPHYS 4 (GRP_W 3, fed the low 4 lanes) equal to the NPHYS 8 unit's low 4 lanes every cycle.  Extra lines on failure: `FAIL ad_su_fpu.timing`, `FAIL ad_su_fpu.nphys4`.  Leaves: `sim/tb/ad_su_fp_leaf_tb.v` (their specs).

## 9. References

design §3.4.1 (OP-FP, MADD..., OP mul), §3.1 (precision).

## 10. Status

Implemented in WS288 p008 part 2 (branch p1-su2; TB `sim/tb/ad_su_fpu_tb.v` on the 6000 vectors of `tools/gsi1fp.py --fpu-vec`, the exact soft-float reference).  Choices made here: one fused datapath per lane (`ad_su_ffma_p` in the lane's `ad_su_fpu_op`, with `ad_su_rint`, `ad_su_i2f` and `ad_su_f2i`; the packed halves through `ad_su_h2f` and `ad_su_hrnd`): fadd = a × 1 + b, fsub = a × 1 − b, fmul = a × b without an addend (so that the sign of a zero product survives RDN), fnmsub/fnmadd negate a; fract = RNE(x − fround(x, RDN)) through the same datapath; a result whose exponent after rounding is below the normal range is a zero of its sign; overflow follows rm (RTZ and the rounding away from it give the largest finite); fround keeps the sign of a zero result; fcvt.w(u).s saturates as RISC-V (NaN as +inf, negatives to 0 for wu); fmin/fmax return the non-NaN operand, −0 < +0, both NaN give the canonical NaN; fsgnj is a pure bit operation (no flush); sat applies to the float results (not to compares, fcvt to integer or mul*) and gives +0 for NaN, negatives and −0.  The whole lane is combinational before the first of the SHORT_LAT stages (v0; the timing at 100 MHz is not measured yet).

2026-11-08 (rebuild in ad_su, rtl/su/ad_su_fpu.v): rewritten from tools/gsi1fp.py with the leaves `rtl/su/fp/ad_su_ffma_p.v`, `ad_su_rint.v`, `ad_su_i2f.v`, `ad_su_f2i.v` (each with its spec) and `ad_su_fpu_mulops.v` (below), lane operation `rtl/su/ad_su_fpu_op.v`.  Per lane: ad_su_fpu_mulops → one 33 × 33 signed multiplier (`$signed(ma) * $signed(mb)`, low 64 bits = ad_su_fpu_op's pr; the fused datapath uses pr[47:0], mul* pr[31:0] / pr[63:32]) → ad_su_fpu_op, all combinational before stage 1; stages 1..SHORT_LAT are plain registers (valid reset, data qualified by valid); s_* = stage SHORT_LAT, fw4_* = stage SHORT_LAT − 2, fw5_* = stage SHORT_LAT − 1.

ad_su_fpu_mulops (`rtl/su/fp/ad_su_fpu_mulops.v`, combinational; ports `o` (5), `ia`, `ib` (32), `ma`, `mb` (33)): the float ops give the significands {e ≠ 0, m} zero-extended (b replaced by 1.0 = 0x800000 for fadd, fsub and fract); mul and mulh sign-extend both, mulhsu sign-extends a and zero-extends b, mulhu zero-extends both.

Verification: `sim/tb/ad_su_fpu_tb.v` (PASS ad_su_fpu.arith/.cvt/.cmp/.mul, PASS ad_su_fpu); `sim/tb/ad_su_fp_leaf_tb.v` (200,000 vectors per leaf, 0 differences).  Formal `formal/ad_su_fpu/` (lane datapath stubbed by `AD_SU_FPU_STUB`, NPHYS 4, SHORT_LAT 6; shadow pipeline: x_ready = 1, s_valid exactly SHORT_LAT cycles after a take with WRD and never otherwise, s_warp/grp/rd/data/lanes of that take, fw4/fw5 = the shadow's stages 4/5 with rd < 63 and, by past registers, = s_* 2/1 cycles later): bmc smtbmc z3 depth 14 PASS, prove smtbmc z3 k-induction depth 8 PASS, cover depth 10 PASS.  `formal/ad_su_fpu_op/` (combinational, pr free: Boolean compares, fne = ¬feq, fle = feq ∨ flt, symmetry, NaN compares, fmin/fmax symmetric with min ≤ max and results among the flushed operands, fsgnj, mul* = pr, sat in [+0, 1.0], canonical NaN and no denormal on float results but fsgnj's): bmc abc bmc3 depth 1 PASS, prove abc pdr PASS.  `formal/ad_su_fpu_mulops/`: bmc abc bmc3 / prove abc pdr PASS.  Mutation: `MUT_FPU_LAT` (s_* from stage SHORT_LAT − 1) fails the TB (timing and every section) and the formal bmc.

- ASSUMPTION: PK_SHARED (packed fp16 on this datapath, ad_su_pk.md) is not implemented here: the unit takes only AD_UNIT_FPU groups; the §8 arith comparison of "a PK_SHARED unit" is replaced by the NPHYS 4 vs NPHYS 8 comparison.
- ASSUMPTION: x_ready is constantly 1 (fully pipelined, one group per cycle).
- ASSUMPTION: s_valid (and fw*_valid) only when the uop has WRD; rd 63 (push to rq) gives s_valid but not fw*_valid; s_lanes = x_mask[NPHYS-1:0] (EXEC); s_data holds the computed result in every lane, EXEC or not.
- ASSUMPTION: the uop fields used: UNIT, OP[4:0] (codes 24–31 give 0), RM (rm 5–7 = RNE as gsi1fp), MOD bit 6 (sat), RD, WRD; x_last, x_sbe, x_pc, x_info and the side-effect lanes are ignored.
- ASSUMPTION: SHORT_LAT ≥ 3 so that both forwarding taps are registers.
- ASSUMPTION: the multiplier is in the combinational lane before stage 1 (as the former "whole lane combinational" choice); a DSP-pipelined version would move it into the stages without changing any port timing.
- Limitation: the timing at the target clock is not measured (the lane is one long combinational path: multiplier, rint → i2f → ffma for fract).
