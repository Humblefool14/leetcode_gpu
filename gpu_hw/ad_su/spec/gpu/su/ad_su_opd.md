# ad_su_opd

RTL: `rtl/gpu/su/ad_su_opd.v`.  Parent: ad_su.  Implemented in: p008.

## 1. Purpose and place

Operand collection: for each lane group of an issued instruction, reads the GPRs, the constant operands c0-c31, the special operands (design §3.2) and rq, applies the float modifiers, computes the lane masks, and drives the execution bus x_* to the units.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit). |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `UOP_W` | `104` | Width of the decoded instruction (= AD_UOP_W of include/ad_su_uop.vh). |
| `WARP_BASE` | `0` | The `warp` operand of slot 0 (ad_su: SU_INDEX × NWARPS), so that `warp` numbers the GPU's resident warps (docs/ghci.md section 12.3). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **From ad_su_sb** | | | |
| `i_valid` | in | 1 | Issued instruction. |
| `i_ready` | out | 1 | Taken: its 32/NPHYS groups follow on x_*. |
| `i_warp` | in | WARP_W | Warp. |
| `i_pc` | in | 16 | pc. |
| `i_uop` | in | UOP_W | Micro-op. |
| `i_sbe` | in | (SBE_W)+1 | Entry. |
| **Register file (ad_su_rf read port)** | | | |
| `r_en` | out | 1 | Read. |
| `r_warp` | out | WARP_W | Warp. |
| `r_grp` | out | GRP_W | Group. |
| `r_regs` | out | 18 | {reg3, reg2, reg1}, 6 bits each. |
| `r_data` | in | 3*NPHYS*32 | {data3, data2, data1}, next cycle. |
| **Constant bank (ad_su_cbank)** | | | |
| `cr_en` | out | 1 | Read c-operands. |
| `cr_idx` | out | 15 | Three 5-bit indices (c0-c31). |
| `cr_data` | in | 96 | Three words, next cycle. |
| **Warp state** | | | |
| `q_warp` | out | WARP_W | Query warp (to ad_su_sched and ad_su_exec). |
| `q_info` | in | 160 | Warp-info word. |
| `q_exec` | in | 32 | EXEC of q_warp. |
| `q_killed` | in | 32 | KILLED of q_warp. |
| **rq (ad_su_rq)** | | | |
| `rq_pop` | out | 1 | Pop one entry (a source is 63). |
| `rq_data` | in | NPHYS*32 | The popped data, next cycle. |
| **Execution bus (to every unit)** | | | |
| `x_valid` | out | 1 | Group valid. |
| `x_warp` | out | WARP_W | Warp. |
| `x_grp` | out | GRP_W | Group. |
| `x_last` | out | 1 | Last group. |
| `x_sbe` | out | (SBE_W)+1 | Entry. |
| `x_pc` | out | 16 | pc. |
| `x_uop` | out | UOP_W | Micro-op. |
| `x_a` | out | NPHYS*32 | rs1. |
| `x_b` | out | NPHYS*32 | rs2. |
| `x_c` | out | NPHYS*32 | rs3 or rs1+1. |
| `x_mask` | out | 2*NPHYS | {side-effect lanes, EXEC lanes} of the group. |
| `x_info` | out | 32 | x_info [15:0] fragment sequence number, [17:16] warp kind (0 vertex, 1 fragment, 2 compute), [18] front facing, [31:19] 0. |
| `unit_ready` | in | 16 | x_ready of each unit, indexed by AD_UNIT_*; the group waits until its unit is ready. |
| **Forwarding / Bypass (ALU EX4/5, FPU EX4/5, WB)** | | | |
| `fwd_alu_ex4_valid` | in | 1 | ALU EX4 forwarding valid. |
| `fwd_alu_ex4_warp` | in | WARP_W | ALU EX4 warp. |
| `fwd_alu_ex4_grp` | in | GRP_W | ALU EX4 lane group. |
| `fwd_alu_ex4_rd` | in | 7 | ALU EX4 destination register ([6]=long, [5:0]=reg index). |
| `fwd_alu_ex4_data` | in | NPHYS*32 | ALU EX4 result data vector. |
| `fwd_alu_ex4_lanes` | in | NPHYS | ALU EX4 active lane mask. |
| `fwd_alu_ex5_valid` | in | 1 | ALU EX5 forwarding valid. |
| `fwd_alu_ex5_warp` | in | WARP_W | ALU EX5 warp. |
| `fwd_alu_ex5_grp` | in | GRP_W | ALU EX5 lane group. |
| `fwd_alu_ex5_rd` | in | 7 | ALU EX5 destination register ([6]=long, [5:0]=reg index). |
| `fwd_alu_ex5_data` | in | NPHYS*32 | ALU EX5 result data vector. |
| `fwd_alu_ex5_lanes` | in | NPHYS | ALU EX5 active lane mask. |
| `fwd_fpu_ex4_valid` | in | 1 | FPU EX4 forwarding valid. |
| `fwd_fpu_ex4_warp` | in | WARP_W | FPU EX4 warp. |
| `fwd_fpu_ex4_grp` | in | GRP_W | FPU EX4 lane group. |
| `fwd_fpu_ex4_rd` | in | 7 | FPU EX4 destination register ([6]=long, [5:0]=reg index). |
| `fwd_fpu_ex4_data` | in | NPHYS*32 | FPU EX4 result data vector. |
| `fwd_fpu_ex4_lanes` | in | NPHYS | FPU EX4 active lane mask. |
| `fwd_fpu_ex5_valid` | in | 1 | FPU EX5 forwarding valid. |
| `fwd_fpu_ex5_warp` | in | WARP_W | FPU EX5 warp. |
| `fwd_fpu_ex5_grp` | in | GRP_W | FPU EX5 lane group. |
| `fwd_fpu_ex5_rd` | in | 7 | FPU EX5 destination register ([6]=long, [5:0]=reg index). |
| `fwd_fpu_ex5_data` | in | NPHYS*32 | FPU EX5 result data vector. |
| `fwd_fpu_ex5_lanes` | in | NPHYS | FPU EX5 active lane mask. |
| `fwd_wb_valid` | in | 1 | WB forwarding valid (active on all RF writes). |
| `fwd_wb_warp` | in | WARP_W | WB warp. |
| `fwd_wb_grp` | in | GRP_W | WB lane group. |
| `fwd_wb_rd` | in | 7 | WB destination register ([6]=long, [5:0]=reg index). |
| `fwd_wb_data` | in | NPHYS*32 | WB result data vector. |
| `fwd_wb_lanes` | in | NPHYS | WB active lane mask. |

65 ports.

## 4. Behaviour

- Per group: cycle 1 address the RF (and cbank, rq), cycle 2 select per operand: GPR 0-62, rq 63,
  c0-c31 64-95 (uniform), special 96-127 (zero, one, onei, half, two, mone, lane = group×NPHYS+i,
  warp = WARP_BASE + slot, exec, killed (Boolean of the lane's bit), wg*/lid*/lidn/prim/front/nwg* from q_info, oneh2,
  mask, qstat/sastat/qtag (0 without SA)); then n/a modifiers (float sign/abs) for float units; drive
  x_*.
- Lane masks: EXEC bits of the group from q_exec; side-effect = EXEC & coverage (q_info mask) &
  ~KILLED.
- PAIR (texl/texb/texf): x_c = rs1+1.
- PAIR with USE3 (a texture .c or .3 form: rs1, rs1+1, rs2 and rs3 = rs1+2, with .3.c also rs1+3; four or five sources for three read ports): each lane group goes out twice, back to back in the order (g, pass 0), (g, pass 1); the second pass reads rs3 as operand 1 (x_a) and rs3+1 as operand 3 (x_c; x_b as in the first), sets TEX op bit 7 on x_uop (AD_TEX_PASS2) and carries x_last on the last group; rq pops only on the first pass.  Such an instruction takes 2 × 32/NPHYS bus cycles.
- Operand Forwarding / Bypass Network (p011): When an operand source is a GPR (0-62), forwarding comparison logic checks if an active writer exists in ALU EX4/EX5, FPU EX4/EX5, WB, or the 1-cycle registered RF write bypass (`fwd_rf` covering BRAM same-cycle read-write collision) matching the same `warp`, `grp`, and register index (`rd < 63`). Priority is strictly ALU/FPU EX4 > ALU/FPU EX5 > WB > RF write bypass > RF read. Forwarding is performed per-lane: if `fwd_*_lanes[lane]` is active, the forwarded result word is taken; otherwise, the value from the RF read port (or lower-priority stage) is preserved. This eliminates RAW hazard pipeline bubbles for short instructions, enabling 1.0 IPC back-to-back issue.

## 5. State machine

A small sequencer over the 32/NPHYS groups: IDLE →(i_valid)→ GROUP 0..n-1 → IDLE.

## 6. Latency and throughput

One group per cycle when the unit is ready; 2 cycles from i_valid to the first x_valid.

## 7. Corner cases and errors

- unit_ready 0 holds x_* (a group is not dropped).  Operand 63 without HAS_SA never arrives (decoder fault).

## 8. What the TB checks

`sim/tb/ad_su_opd_tb.v` prints, in this order:

- `PASS ad_su_opd.gpr` — operands from a model RF for NPHYS 4/8/16/32
- `PASS ad_su_opd.special` — every special operand 96-122
- `PASS ad_su_opd.mods` — n/a modifiers on float units only
- `PASS ad_su_opd.mask` — EXEC and side-effect masks; unit_ready back-pressure
- `PASS ad_su_opd` at the end.

## 9. References

design §3.2 (operands), §3.1 (masks, helper lanes), include/ad_su_uop.vh.

## 10. Status

Implemented in WS288 p008 (branch p1-su; TB `sim/tb/ad_su_opd_tb.v` with NPHYS 8/16/32).  The n/a modifiers apply for units FPU, XU and PK (PK on both halves).  Gap in the warp-info word: q_info has no WG_SIZE, so in v0 `lidx` = `lidn` and `lidy` = `lidz` = `prim` = 0 (right for 1-D workgroups); fixing it needs a q_info field (proposal for p009).

2026-10-25 (p009 part E, P3): the second operand pass for PAIR + USE3 uops (§4), for the texture .c forms of docs/ghci.md §12.9.  Ports unchanged.  `sim/tb/ad_su_opd_tb.v` issues such uops at random and checks both passes.

2026-10-25 (p009 part F, P3): the second pass of a PAIR + USE3 uop reads rs3+1 as operand 3 (x_c), for the texture .3 forms with Dref (rs1+3).  Ports unchanged.  `sim/tb/ad_su_opd_tb.v` checks operand 3 of both passes.

2026-10-27 (p011, P1): Added operand forwarding / bypass network ports `fwd_ex4_*`, `fwd_ex5_*`, `fwd_wb_*` and per-lane bypass MUX logic (EX4 > EX5 > WB > RF) in Stage B. Enables 1.0 IPC back-to-back RAW execution without scoreboard stall bubbles. Verified with `sim/tb/ad_su_forwarding_tb.v` and `sim/tb/ad_su_opd_tb.v`.

2026-11-08 (core builder): rewritten in `rtl/su/ad_su_opd.v` with the leaves
`rtl/su/core/ad_su_opd_plan.v` (operand numbers and read slots of a pass), `ad_su_fwd_sel.v` (the
forwarding mux of one RF port), `ad_su_opd_src.v` (operand value: GPR, rq, c-operand, specials) and
`ad_su_fmod.v` (n/a modifiers).
- ASSUMPTION (interface; the specs disagree): the RF has two read ports (ad_su_rf.md), so the RF port
  is `r_en, r_warp, r_grp, r_reg1[5:0], r_reg2[5:0]` -> `r_data1, r_data2` (NPHYS*32 each) the next
  cycle, replacing `r_regs` / `r_data`.  A group whose pass reads three GPRs (USE3, or PAIR's rs1+1
  beside rs1 and rs2) takes two read slots (a and b, then c), so its groups come every other cycle.
- ASSUMPTION: the forwarding inputs are `fwd_alu_ex4_*`, `fwd_alu_ex5_*`, `fwd_fpu_ex4_*`,
  `fwd_fpu_ex5_*` (the units' fw4_/fw5_ taps) and `fwd_wb_*` (= ad_su_wb's w_* with rd = {0, w_reg});
  the registered RF-write bypass is internal (fwd_wb_* one cycle later).  Priority per lane: ALU/FPU
  EX4 > ALU/FPU EX5 > WB > bypass > RF (the two EX4 taps, and the two EX5 taps, never match together:
  one group a cycle).  Forwarding is per RF port (by the register the port reads).
- Timing: A (address RF/cbank/rq for one read slot) -> B (data, forwarding, operand values, modifiers,
  masks) -> x_* registers: x_valid 2 cycles after i_valid (3 with a two-slot group).  A consumer's
  group sees a producer's group from the producer's EX4 cycle: its x_valid must be at least 5 cycles
  after the producer group's take (EX4 = 4 cycles after the take; the select is the cycle before x).
  ad_su_sb's interlock (its §10: hold until count <= G + 1) leaves 7, so it is safe as is; issuing
  closer needs ad_su_sb to change.
- Back-pressure: x_* hold while unit_ready[unit] is 0; a slot in B that cannot move to x is read again
  each cycle (its RF data and forwarding stay current); rq is popped once per group (pass 0, the first
  read of the slot) and its data held.  i_ready = the instruction register is free and a slot can be
  issued (the first slot of the accepted instruction issues in the same cycle).
- ASSUMPTION: q_info / q_exec / q_killed answer q_warp combinationally (ad_su_sched.md says so for
  q_info) and are read in B; q_warp = the warp in B.
- ASSUMPTION: an operand that is not used gives 0 on x_*; several rq sources in one uop take the same
  popped entry; pass 1's rs3+1 is never rq (only pass 0 pops); constants are read for every slot.
- ASSUMPTION: specials per tools/gsi1model.py opv(): lidx = lidn = LID + lane (q_info has no workgroup
  shape), lidy = lidz = prim = 0, qstat/sastat/qtag = 0 (no SA), 123-127 = 0; wg*/nwg* are q_info's
  16-bit fields zero-extended; warp = WARP_BASE + slot.
- New parameter LW (lane word bits, default 32), used only by the formal harness.
- TBs: `sim/tb/ad_su_opd_tb.v` (NPHYS 4/8/16/32 against an in-TB reference: model RF, cbank, rq,
  warp state, random unit_ready; every special 96-122, modifiers on all units, PAIR and PAIR + USE3,
  the modifier leaf against `sim/vec/core_fmod.hex`): `PASS ad_su_opd.gpr`, `.special`, `.mods`,
  `.mask`, `.pass2`, `PASS ad_su_opd`.  `sim/tb/ad_su_forwarding_tb.v` (opd + alu + the real fpu + wb +
  rf, NPHYS 4/8/16/32, dependent chains at the minimum distance, random EXEC every cycle, random
  back-pressure in phase 2): `PASS ad_su_forwarding.b2b`, `.prio`, `.lanes`, `PASS ad_su_forwarding`.
- Formal: `formal/ad_su_opd` (NPHYS 16, LW 1, reduced uops): x_* stable while not ready; taken groups
  in instruction order, groups 0..G-1 (passes 0, 1 for PAIR + USE3 with AD_TEX_PASS2), warp/pc of the
  instruction, x_last on the last; bmc abc bmc3 depth 16, prove abc pdr.  Leaves: `formal/ad_core_fwd_sel`
  (forwarding priority per lane, exhaustive), `ad_core_opd_plan`, `ad_core_opd_src` (every operand
  number), `ad_core_fmod`.  Mutations: `MUT_OPD_HOLD` (ignores back-pressure: TB and formal FAIL),
  `MUT_OPD_MOD` (modifiers on every unit: TB FAIL), `MUT_FWD_PRIO` (reversed priority: forwarding TB
  and the leaf proof FAIL).
