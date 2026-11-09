# ad_su_lsu

RTL: `rtl/gpu/su/ad_su_lsu.v`.  Parent: ad_su.  Implemented in: p008.

## 1. Purpose and place

Global memory: lw/sw/atom of NPHYS lanes per group through the coalescer (lanes merged into line requests), the SU's D$ (ad_su_dcache) and the MC's atomic unit; fence's acquire invalidate.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit). |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `UOP_W` | `104` | Width of the decoded instruction (= AD_UOP_W of include/ad_su_uop.vh). |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |

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
| **AMB client port (design §4.1)** | | | |
| `dc_req_valid` | out | 1 | Request valid; payload held until `dc_req_ready`. |
| `dc_req_ready` | in | 1 | The MC (or mux) takes the request this cycle. |
| `dc_req_write` | out | 1 | 1 write, 0 read. |
| `dc_req_line` | out | ADDR_W-LINE_SHIFT | Line address (byte address >> LINE_SHIFT). |
| `dc_req_be` | out | LINE_BYTES | Byte enables of a write (one per byte of the line). |
| `dc_req_wdata` | out | LINE_BYTES*8 | Write data, byte 0 in bits 7:0. |
| `dc_req_tag` | out | 8 | The client's tag, returned with the response. |
| `dc_rsp_valid` | in | 1 | Response, one cycle, no back-pressure; one per request. |
| `dc_rsp_write` | in | 1 | The response is a write's (after BRESP). |
| `dc_rsp_tag` | in | 8 | Tag of the request answered. |
| `dc_rsp_rdata` | in | LINE_BYTES*8 | Read data (valid for reads). |
| `dc_rsp_error` | in | 1 | Aperture or AXI error; the line was not accessed. |
| **Atomic port (to ad_mc_atom)** | | | |
| `at_valid` | out | 1 | One atomic operation (one lane). |
| `at_ready` | in | 1 | Taken. |
| `at_op` | out | 4 | and or xor xchg add sub smax smin umax umin cmpxchg (IR order, design §3.4.1). |
| `at_addr` | out | 30 | Word address. |
| `at_a` | out | 32 | Operand (rs2). |
| `at_b` | out | 32 | cmpxchg compare value (rs3). |
| `at_rsp_valid` | in | 1 | Old value (in order). |
| `at_old` | in | 32 | Old value. |
| `at_error` | in | 1 | Aperture error. |
| `dc_inv` | out | 1 | Invalidate the D$ (fence acquire, atom). |

48 ports; 37 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

- lw: per group, the addresses (rs1 + imm per lane) are grouped by line; one D$ request per distinct
  line; returned words are scattered to the lanes; one beat per group, l_last after the last.
- sw: per line, one write with byte enables of the active (side-effect) lanes (sw.x, the uop's
  sub[0]: the EXEC lanes, helper and killed lanes included: a warp's scratch memory); completion beat
  (l_wr 0) after all write responses (cm falls, design §3.1.1).
- atom: one at_* per side-effect lane, serial; the D$ line is invalidated; the old value is the
  result when rd is written.
- EXEC (side-effect mask) all 0: no request, immediate completion beat.

## 5. State machine

IDLE → COALESCE (per group) → ISSUE → WAIT → RETURN → IDLE.

## 6. Latency and throughput

A fully coalesced lw: one D$ request per group, about 4 cycles on a hit (design §3.4.2).

## 7. Corner cases and errors

- dc_rsp_error / at_error: the lanes get 0 and the MC has already raised the aperture fault.

## 8. What the TB checks

`sim/tb/ad_su_lsu_tb.v` prints, in this order:

- `PASS ad_su_lsu.coalesce` — random lane addresses: request count equals distinct lines
- `PASS ad_su_lsu.store` — byte enables and completion after responses
- `PASS ad_su_lsu.atom` — each atomic op through a model of ad_mc_atom
- `PASS ad_su_lsu.empty` — EXEC 0 gives an immediate completion
- `PASS ad_su_lsu` at the end.

## 9. References

design §3.4.1 (LOAD, STORE, custom-0 atom/fence), §3.5 (coalescer), §4.1 (atomic port).

## 10. Status

Implemented in WS288 p008 part 2 (branch p1-su2; TB `sim/tb/ad_su_lsu_tb.v`).  One lane group at a time, one D$ request outstanding; the coalescer takes the first pending lane's line and every pending lane in it (one request per distinct line); sw waits for each write's response before the next line; when two lanes of a store write one word the higher lane wins; atom invalidates the D$ when it starts and is serial per lane; fence acquire pulses dc_inv one cycle after it is issued (no beat).  Addresses ignore bits 1:0.

2026-11-08 (p008 memory side, rtl/su/ad_su_lsu.v; leaves rtl/su/mem/ad_lsu_coalesce.v, ad_lsu_scatter.v, ad_lsu_wbe.v): implemented as above.  TB `sim/tb/ad_su_lsu_tb.v` (NPHYS 4 and 8, ad_su_dcache + ad_amb_mem + a model of ad_mc_atom, vectors from `tools/gen_mem_vectors.py` on gsi1model's semantics): PASS coalesce/store/atom/empty.  Formal `formal/ad_su_lsu` (NPHYS 4, ADDR_W 8, 8-byte lines; bmc abc bmc3 depth 24, prove smtbmc z3 k-induction depth 4 with helper invariants on `fv_st`) and `formal/ad_mem_lsu_{coalesce,scatter,wbe}` (abc pdr): all PASS.  Mutations: `MUT_LSU_EARLY` (a store completes when its last write is accepted) fails the TB (store, atom) and the formal (completion before the write response); `MUT_LSU_NOINV` fails the TB (atom); `MUT_CO_ALL` (coalescer serves every pending lane) fails the TB and the coalescer proof.
- ASSUMPTION: one beat per lane group (l_last = the group's x_last); a sw group's beat (l_wr 0, l_lanes 0) comes after the group's last write response.
- ASSUMPTION: l_lanes = EXEC for lw, the side-effect lanes for atom, 0 for sw; l_wr = WRD and l_lanes not 0 (an empty group's completion has l_wr 0).
- ASSUMPTION: every fence pulses dc_inv one cycle after it is taken (the acquire bit of imm[2:0] is not defined in this repository); a fence is taken only when no group is in flight; no beat.
- ASSUMPTION: an atom group with at least one side-effect lane pulses dc_inv one cycle after it is taken; at_addr = rs1[31:2] (no immediate, as tools/gsi1model.py), at_op = sub[3:0], at_a = rs2, at_b = rs3; at_error or dc_rsp_error give 0 (spec §7).
- ASSUMPTION: an LSU op above 3 completes like an empty group.  dc_req_tag is 0; dc_rsp_tag/dc_rsp_write are not used (one request outstanding).
- ASSUMPTION: UOP_W default 108 (AD_UOP_W).  Under `ifdef FORMAL` only, an output `fv_st` (the state) for the harness.
