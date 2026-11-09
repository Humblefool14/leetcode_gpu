# ad_su_div

RTL: `rtl/gpu/su/ad_su_div.v`.  Parent: ad_su.  Implemented in: p008.

## 1. Purpose and place

The SU's shared integer divider: div, divu, rem, remu (RISC-V semantics), lane by lane, results as long beats.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit). |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `UOP_W` | `104` | Width of the decoded instruction (= AD_UOP_W of include/ad_su_uop.vh). |

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
| **Long result to ad_su_wb (any time; wb may refuse with l_ready = 0)** | | | |
| `l_valid` | out | 1 | A result beat: one register of one lane group, or a completion without data. |
| `l_ready` | in | 1 | Taken by ad_su_wb. |
| `l_warp` | out | WARP_W | Warp. |
| `l_grp` | out | GRP_W | Group. |
| `l_rd` | out | 7 | Register written (texture: rd..rd+3 one beat each). |
| `l_data` | out | NPHYS*32 | Data. |
| `l_lanes` | out | NPHYS | Lanes written. |
| `l_wr` | out | 1 | 1: write the register; 0: completion only (stores, atomics without rd). |
| `l_last` | out | 1 | Last beat of the instruction: release its scoreboard entry and counter. |
| `l_sbe` | out | (SBE_W)+1 | The scoreboard entry (from x_sbe). |
| `l_cls` | out | 3 | Class (m, t or x) whose counter falls with l_last. |

26 ports.

## 4. Behaviour

Like ad_su_xu: buffer the instruction, 34 cycles per lane, beats per group.  Division by zero and INT_MIN/-1 as RISC-V.

## 5. State machine

IDLE → LOAD → DIVIDE → RETURN → IDLE.

## 6. Latency and throughput

34 cycles per active lane.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/ad_su_div_tb.v` prints, in this order:

- `PASS ad_su_div.ops` — random and corner divisions against the model
- `PASS ad_su_div` at the end.

## 9. References

design §3.4.2 (division class x).

## 10. Status

Implemented in WS288 p008 part 2 (branch p1-su2; TB `sim/tb/ad_su_div_tb.v`).  Difference from §4: v0 takes one lane group at a time (x_ready 0 while its lanes divide) instead of buffering the whole instruction, so the operand stage waits for the unit after each group (the same results and beats; buffering the instruction is a later optimisation).  34 cycles per EXEC lane (load, 32 restoring steps, sign fix).

2026-11-08 (rebuild in rtl/su/): `rtl/su/ad_su_div.v` with leaves in `rtl/su/div/`: `ad_div_ctl` (group sequencer IDLE → RUN → RET, lowest EXEC lane first, the next lane starting in the cycle the previous one is done), `ad_div_lane` (one lane in exactly 34 cycles: the start cycle loads the magnitudes, 32 restoring steps, the sign fix), `ad_div_rstep` (one restoring step), `ad_div_sign` (magnitudes before, signs and the RISC-V special cases after).  TB `sim/tb/ad_su_div_tb.v` (vectors `tools/gen_div_vectors.py` → `sim/vec/div_ops.hex`, 6144 lane divisions from `tools/gsi1fp.py` `div()`: random, /0, INT_MIN/−1, every op on every pair of 15 corner operands) on NPHYS 8 and 4 with random EXEC, X outside EXEC, idle cycles, other units' groups and random l_ready: `PASS ad_su_div.ops`, `PASS ad_su_div`.  Formal: `formal/ad_div_rstep` (full 32-bit width: {r, bin} = q·d + r_n and r_n < d given r < d, so by induction over the steps the core gives q·b + r = a, r < b for every 32-bit a, b ≠ 0), `formal/ad_div_sign` (the special cases at 32 bits; every op against Verilog's signed `/` `%` at 8 bits), `formal/ad_div_lane` (the whole lane, RISC-V result and the 34 = W + 2 cycle latency: bmc at W 8, prove at W 4 with helper invariants inside `ifdef FORMAL`), `formal/ad_su_div` (protocol, lane engine stubbed).  Mutation `MUT_DIV_SIGN` (INT_MIN/−1 gives 0) fails the TB and formal/ad_div_sign.
- ASSUMPTION: UOP_W defaults to 108 (AD_UOP_W), not the 104 of §2.
- ASSUMPTION: x_ready is 1 only in IDLE (the next group is taken after the previous beat is accepted).
- ASSUMPTION: one beat per group even without EXEC lanes (l_lanes 0); l_lanes = EXEC lanes, l_wr = the uop's WRD, l_rd = RD, l_cls = the uop's CLS field; l_data of lanes outside EXEC is 0.
- ASSUMPTION: the operation is OP[1:0] (0 div, 1 divu, 2 rem, 3 remu); a = x_a, b = x_b.
