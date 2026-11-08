# ad_su_exec

RTL: `rtl/gpu/su/ad_su_exec.v`.  Parent: ad_su.  Implemented in: p008.

## 1. Purpose and place

Warp control: EXEC and KILLED per warp, the exec.set/and/or/save and kill instructions, warp-uniform branches (bany/bnone/ball/j/bexnz/bexz), end and bar; tells the scheduler where the warp continues.

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
| **Warp control (to ad_su_sched)** | | | |
| `wc_valid` | out | 1 | After the last group of a branch/end/bar instruction. |
| `wc_warp` | out | WARP_W | Warp. |
| `wc_op` | out | 2 | 0 continue at wc_pc, 1 end, 2 barrier. |
| `wc_pc` | out | 16 | Next pc. |
| **EXEC state** | | | |
| `q_warp` | in | WARP_W | Query (ad_su_opd). |
| `q_exec` | out | 32 | EXEC of q_warp. |
| `q_killed` | out | 32 | KILLED of q_warp. |
| `init_valid` | in | 1 | Warp start (ad_su_sched). |
| `init_warp` | in | WARP_W | Warp. |
| `init_mask` | in | 32 | Initial EXEC; KILLED cleared. |

31 ports.

## 4. Behaviour

- Branch conditions combine the groups: any/none/all over EXEC lanes of rs1 ≠ 0; the decision is
  made after the last group; target = pc + offset (instructions).  Not taken: wc_pc = pc + 1.
- exec.set/and/or update EXEC from the Boolean rs1 (≠ 0); exec.save rd writes each lane's EXEC bit as a
  Boolean (all-ones/0) to all 32 lanes through the short result; kill sets KILLED lanes (sticky).

## 5. State machine

None (registers per warp).

## 6. Latency and throughput

One group per cycle; wc_* comes the cycle after the last group of a branch/end/bar.

## 7. Corner cases and errors

- A warp issues nothing after a branch until wc_valid (the scheduler waits on feedback kind 1).

## 8. What the TB checks

`sim/tb/ad_su_exec_tb.v` prints, in this order:

- `PASS ad_su_exec.branch` — all six branches with mixed lanes over several groups
- `PASS ad_su_exec.exec` — exec.* and kill update the masks; exec.save writes the register
- `PASS ad_su_exec.endbar` — end and bar produce wc_op 1 and 2
- `PASS ad_su_exec` at the end.

## 9. References

design §3.1 (masks, branches), §3.4.1 (BRANCH, custom-3 exec/kill, custom-0 end/bar).

## 10. Status

Implemented in WS288 p008 (branch p1-su; TB `sim/tb/ad_su_exec_tb.v`).  Corrections here: wc_* comes one cycle after the last group (not SHORT_LAT); exec.save writes each lane's own EXEC bit as a Boolean to all 32 lanes (design §6.6's `exec.save rS` … `exec.set rS` needs that; a uniform EXEC word would not restore it).  ball over an empty EXEC is taken, bany is not.

2026-11-08 (front-end builder, rtl/su/ad_su_exec.v + leaves rtl/su/ctl/ad_ctl_exec_op.v (the whole-warp operation, tools/gsi1model.py semantics) and ad_ctl_spipe.v (the SHORT_LAT result pipeline)).  TB `sim/tb/ad_su_exec_tb.v` on NPHYS 4 and 8 with vectors of `tools/gen_ad_su_exec_vectors.py` (sim/vec/ad_su_exec_*.hex); formal `formal/ad_su_exec` (EXEC/KILLED per warp against a per-lane shadow, wc_* exactly once per branch/end/bar, the cycle after the last group) and `formal/ad_ctl_exec_op`, `formal/ad_ctl_spipe`; mutation MUT_EXEC_BALL.
- ASSUMPTION: x_ready is always 1; the groups of an EXEC-unit instruction come back to back on the bus without another EXEC-unit instruction between them (other units' groups may come in between); the Booleans are placed by x_grp, so their order does not matter.
- ASSUMPTION: EXEC/KILLED change at the end of the last group's cycle (q_exec/q_killed are registered, no bypass); init_* wins over an update of the same warp in the same cycle.
- ASSUMPTION: exec.save's short result has s_lanes all ones (every lane of every group is written, gsi1model writes all 32 lanes), data from the EXEC of the warp when the group is taken; s_* only when the uop has WRD.
- ASSUMPTION: wc_pc = (pc + imm) mod 2^16 when taken, else pc + 1 (also for end and bar).  Opcodes 6, 7 and 15 do nothing.  The Boolean is 0 when USE1 is 0.
- ASSUMPTION: SHORT_LAT >= 2.
