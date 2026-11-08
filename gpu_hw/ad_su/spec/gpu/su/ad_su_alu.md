# ad_su_alu

RTL: `rtl/gpu/su/ad_su_alu.v`.  Parent: ad_su.  Implemented in: p008.

## 1. Purpose and place

The integer ALU of the SU, NPHYS lanes: add/sub/logic/shifts, Boolean compares (all ones/0), Zbb min/max/andn/orn/xnor, sel (bitwise), lui/movi; results on the short pipeline.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit). |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `UOP_W` | `104` | Width of the decoded instruction (= AD_UOP_W of include/ad_su_uop.vh). |
| `SHORT_LAT` | `6` | Cycles from x_valid to the short result (one fixed pipeline for classes a and f, design §3.1.1). |

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

21 ports.

## 4. Behaviour

Semantics of design §3.4 for unit ALU; compares (slt, sltu, slti, sltiu) write all ones or 0 (U23).  The result is delayed to SHORT_LAT cycles.

## 5. State machine

None (pipeline).

## 6. Latency and throughput

NPHYS lanes per cycle; about 150 LUT per lane (design §3.6).

## 7. Corner cases and errors

- Lanes outside EXEC are not written (s_lanes).

## 8. What the TB checks

`sim/tb/ad_su_alu_tb.v` prints, in this order:

- `PASS ad_su_alu.ops` — every ALU operation on random operands against the ISA model
- `PASS ad_su_alu.lat` — results come exactly SHORT_LAT cycles later with warp/group/rd
- `PASS ad_su_alu` at the end.

## 9. References

design §3.4.1 (OP, OP-IMM, LUI, custom-3 sel), §3.2 (Booleans).

## 10. Status

Implemented in WS288 p008 (branch p1-su; TB `sim/tb/ad_su_alu_tb.v`).  x_ready is always 1; operand b is the immediate when OP bit `AD_ALU_IMMB` is set; groups of other units and uops without WRD give no result.

2026-11-08 (core builder): rewritten in `rtl/su/ad_su_alu.v` with the leaves `rtl/su/core/ad_su_alu_lane.v`
(one lane, combinational, the semantics of `tools/gsi1model.py` alu()) and `rtl/su/core/ad_su_spipe.v`
(the SHORT_LAT-stage delay line).  New outputs: the forwarding taps `fw4_*` and `fw5_*` (valid, warp,
grp, rd[6:0], data, lanes) = the delay-line stages that deliver s_* 2 and 1 cycles later, valid only
for WRD uops with rd < 63 (ad_su_opd's `fwd_alu_ex4_*` / `fwd_alu_ex5_*`).  UOP_W default 108.
TB `sim/tb/ad_su_alu_tb.v` (NPHYS 8 and 4, vectors `sim/vec/core_alu.hex` from
`tools/gen_core_vectors.py`): `PASS ad_su_alu.ops`, `.lat`, `PASS ad_su_alu`.  Formal:
`formal/ad_core_alu_lane` (every op vs reference expressions; bmc smtbmc z3 depth 1, prove abc pdr),
`formal/ad_su_alu` (NPHYS 2: s_* and the taps vs a harness delay line of reference results; bmc
smtbmc z3 depth 10, prove smtbmc z3 k-induction depth 8), `formal/ad_core_spipe`.  Mutation
`MUT_ALU_LAT` (one stage short): TB and formal FAIL.
- ASSUMPTION: the result of every lane is computed (s_lanes = EXEC carries the write mask); SHORT_LAT >= 3
  (the taps are stages SHORT_LAT-2 and SHORT_LAT-1).
