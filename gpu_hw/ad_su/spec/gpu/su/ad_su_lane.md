# ad_su_lane

RTL: `rtl/gpu/su/ad_su_lane.v`.  Parent: ad_su.  Implemented in: p009.

## 1. Purpose and place

Cross-lane operations: qd (quad differences and swaps for derivatives, design §3.4.1) always; shfl/vote/ballot with SUBGROUP (staging registers).  Short results.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit). |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `UOP_W` | `104` | Width of the decoded instruction (= AD_UOP_W of include/ad_su_uop.vh). |
| `SUBGROUP` | `0` | shfl/vote/ballot present. |
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

qd works inside a lane group (quads never cross groups since NPHYS ≥ 4), one group per cycle: qdx = v[lane|1] − v[lane&~1], qdy = v[lane|2] − v[lane&~2] (fp32, two `ad_su_fadd` per quad, RNE, denormals flushed), qswap1/2/3 = v[lane^1/2/3], qbcast = v[lane&~3]; the partners are read whether or not they are in EXEC; the EXEC lanes are written.

shfl/vote/ballot (SUBGROUP = 1; without it ad_su_dec makes them ISA faults) need all 32 lanes.  The groups before the last are staged as they pass (x_ready 1); the last group is staged in its first cycle on the bus and then held there (x_ready 0) for G = 32/NPHYS more cycles, in which the results of groups 0..G-1 enter the result pipeline, one per cycle; x_ready is 1 in the last of them (x_end).  Group g's result therefore leaves SHORT_LAT cycles after cycle x_end − (G−1) + g, exactly as for an instruction whose groups pass one per cycle, so ad_su_sb's short interlock and ad_su_wb's one short result per cycle hold unchanged (the bus carries nothing else in those cycles).

Staged per warp lane: rs1, the EXEC bit, and for shfl the source lane s and whether it exists.  The rules (tools/gsi1model.py implements the same):

- shfl, lane l: s = rs2 (sub 0 idx), l XOR rs2 (1 xor), l − rs2 (2 up), l + rs2 (3 down), as integers without wraparound, or (l + rs2) mod 32 (4 rot, always in range) (rs2 is 32-bit unsigned).  The result is rs1 of lane s when s is 0..31 and lane s is in EXEC, else lane l's own rs1.  The EXEC lanes are written.
- ballot: B = the EXEC lanes whose rs1 ≠ 0, as a 32-bit mask; vote.any = (B ≠ 0), vote.all = (B = EXEC) (true when EXEC is empty), as Booleans.  Both write every lane of the warp, whatever EXEC is (design M13, like exec.save).
- Lanes outside EXEC are never read for a result (their rs1 and rs2 may be X in the RF).

## 5. State machine

IDLE (qd passes; shfl/vote/ballot groups are staged as they pass; the last group stages and moves to EMIT) → EMIT (group e_cnt's result enters the pipeline each cycle; x_ready 1 in the last, back to IDLE).

## 6. Latency and throughput

All results SHORT_LAT after their slot on the bus.  qd one group per cycle; shfl/vote/ballot 2 × 32/NPHYS bus cycles (G groups, then G cycles holding the last).

## 7. Corner cases and errors

- EXEC empty: shfl writes nothing; ballot writes 0, vote.any 0, vote.all all ones, to every lane.
- A source lane outside EXEC or out of range gives the lane its own rs1 (no X reaches a written lane).
- `rd` = 63 (rq) passes through as for every short result.

## 8. What the TB checks

`sim/tb/ad_su_lane_tb.v` prints, in this order:

- `PASS ad_su_lane.qd` — qdx/qdy/qswap*/qbcast against the model (NPHYS 8), and a unit of NPHYS 4 equal to its low 4 lanes every cycle
- `PASS ad_su_lane.sub` — SUBGROUP = 1 and NPHYS 4, 8, 16, 32: 1500 random instructions each (every shfl mode with sources in range, out of range and outside EXEC; vote.any/all; ballot; qswap/qbcast between them) with EXEC full, empty, one lane, all but one and random, and X on the lanes outside EXEC: the data of the written lanes, s_lanes, rd, warp and group, the cycle of each result, and x_ready (0 for exactly G cycles on the last group only)
- `PASS ad_su_lane` at the end.

`sim/tb/ad_su_tb.v` runs `sim/tb/su/sub.s` (qd, shfl/vote/ballot with EXEC full, partial and empty, back to back and in dependent chains, 100 lanes) on SUs of NPHYS 4, 8, 16 and 32 against `tools/gsi1model.py --subgroup`, and on an SU with SUBGROUP 0, which must fault (ISA fault, the CP's kind 8) at the first shfl in every warp.

## 9. References

design §3.4.1 (custom-1 qd/shfl, custom-3 vote/ballot), §3.4.2, M13, U27; docs/ghci.md §12.5.

## 10. Status

Implemented in WS288 p008 (qd: branch p1-su; shfl/vote/ballot: branch p1-subgroup, 2026-10-24).

Readings where the specification is silent (docs/ghci.md §12 and the design define no semantics beyond the opcode map):

- The shfl source lane and the out-of-range rule (above): a source outside 0..31, or outside EXEC, gives the lane's own rs1 (as CUDA's shfl for out of range; Vulkan leaves both undefined).  Out of range is decided on the whole 32-bit rs2, without wraparound or masking.
- sub 4 is `rot` (2026-10-24 user decision, was `bfly` = `xor`): the source is (l + rs2) mod 32, as Vulkan subgroupShuffleRotate.
- vote/ballot write every lane regardless of EXEC (design M13), although ghci §12.2 says that lanes outside EXEC do not write registers (exec.save already does the same).
- The staging is registers (32 × (32 + 1 + 1 + 5) bits) and a 32:1 multiplexer per physical lane, not the distributed RAM of design §3.6 / §10.14 (+0.5k LUT/SU); the area is not measured (p025).
- The bus is held G cycles on the last group (design: "2 pass = 2 × 32/NPHYS cycle"), not a second pass of the groups through ad_su_opd; the earlier open point (results later than SHORT_LAT) is solved this way without changes to ad_su_sb or ad_su_wb.

2026-11-08 (rebuild in rtl/su/): `rtl/su/ad_su_lane.v` with leaves in `rtl/su/lane/`: `ad_lane_qd` (the quad ops of a group, two `ad_lane_fsub` per quad), `ad_lane_fsub` (fp32 a − b, RNE, flushed, equal to `tools/gsi1fp.py` `fpu(FSUB, a, b, 0, RNE)`; written locally because `rtl/su/fp/ad_su_fadd.v` did not exist), `ad_lane_srcl` (the shfl source lane and whether it exists), `ad_lane_stage` (the per-warp-lane staging registers), `ad_lane_sub` (the result of group e from the staging), `ad_lane_ctl` (IDLE/EMIT, x_ready).  A parameter `WARP` (default 32) was added so the formal harness can use a warp of 8 lanes.  TB `sim/tb/ad_su_lane_tb.v` (vectors `tools/gen_lane_vectors.py`, expected results from `tools/gsi1model.py` `Machine.lane()`): `PASS ad_su_lane.qd` (1200 qd instructions on NPHYS 8, the NPHYS 4 twin equal to the low lanes every cycle), `PASS ad_su_lane.sub` (1500 instructions on NPHYS 4, 8, 16, 32 with SUBGROUP 1), `PASS ad_su_lane`.  Formal: `formal/ad_su_lane` (the block on WARP 8, NPHYS 4, SHORT_LAT 3 against a reference of §4: results, their cycles, x_ready held exactly G cycles; bmc only, see below), `formal/ad_lane_ctl` (x_ready 0 for exactly G cycles on the last group, emission of groups 0..G−1), `formal/ad_lane_srcl` (the source rules on every 32-bit rs2), `formal/ad_lane_sub` (shfl/vote/ballot rules, lanes outside EXEC never influence a written result), `formal/ad_lane_qd` (quad partner selection), all bmc + prove.  Mutations `MUT_LANE_HOLD`, `MUT_LANE_VOTE`, `MUT_LANE_QD` fail the TB and formal (ad_lane_ctl, ad_lane_sub, ad_lane_qd).
- ASSUMPTION: UOP_W defaults to 108 (AD_UOP_W), not the 104 of §2.
- ASSUMPTION: x_ready is combinational on the bus in IDLE: 0 in the first cycle of the last group of a shfl/vote/ballot (x_valid, unit lane, op ≠ qd, x_last).  ad_su_opd must not make x_valid depend on x_ready (it holds the group while unit_ready is 0, §7 of its spec).
- ASSUMPTION: the groups of a subgroup instruction come in order 0..G−1 with no other lane-unit instruction between them (idle cycles and other units' groups may be between); the staging is indexed by x_grp.
- ASSUMPTION: qd sub 6/7 (not decoded) give the lane's own value; shfl sub 5-31 give the lane's own rs1; vote with sub ≠ 0 is vote.all (as gsi1model.py); ballot zero-extends the WARP-bit mask.
- ASSUMPTION: with WRD = 0 nothing is written (no s_valid) but the bus is still held G cycles on the last group of a subgroup op.
- ASSUMPTION: s_data of lanes not written is 0 for shfl; for qd it carries the computed value (s_lanes excludes those lanes).
- ASSUMPTION: with SUBGROUP = 0 shfl/vote/ballot uops (faulted by ad_su_dec) produce no result and x_ready stays 1.
- Limitation: the block-level `prove` of formal/ad_su_lane does not close with abc pdr in ~9 minutes (the staging and pipeline data of 8 × 32-bit lanes); bmc depth 12 covers more than one complete instruction and the rules are proven per leaf.  In formal/ad_su_lane and formal/ad_lane_qd the subtract is a non-commutative stub (the partner selection is what is proven; the subtract is checked bit for bit in simulation).
