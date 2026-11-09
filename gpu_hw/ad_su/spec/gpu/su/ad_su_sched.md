# ad_su_sched

RTL: `rtl/gpu/su/ad_su_sched.v`.  Parent: ad_su.  Implemented in: p008 (compute), p009 (vertex/fragment).

## 1. Purpose and place

The SU's warp scheduler: warp slots and their PCs, slot allocation for vertex warps (VF), fragment warps (RX) and compute workgroups (DISPATCH), round-robin selection of a ready warp for fetch, and the warp-info word for special operands.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `NSU` | `1` | Number of SUs (compute workgroups are shared out: this SU takes wg_id % NSU == SU_INDEX). |
| `SU_INDEX` | `0` | This SU's number. |
| `FRAG_RESERVE` | `1` | Slots kept for fragment warps (design §3.8; KC705 2). |
| `GTO` | `1` | Scheduling policy: 1 = Greedy-Then-Oldest (Phase 012), 0 = Round-Robin. |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **STATE broadcast (from ad_cp_state)** | | | |
| `st_we` | in | 1 | One-cycle write of STATE[st_idx]. |
| `st_idx` | in | 9 | STATE index (design §2.3). |
| `st_wdata` | in | 32 | STATE value; the block keeps the words of its range. |
| `cs_kick` | in | 1 | DISPATCH: start the grid in STATE 0x1E9-0x1EB with WG_SIZE (0x199) and CS_BASE. |
| **Vertex warp allocation (VF, via ad_su ports vl_*)** | | | |
| `vl_req` | in | 1 | VF wants a vertex warp slot (level). |
| `vl_gnt` | out | 1 | One-cycle grant; vl_slot valid from now until vl_go. |
| `vl_slot` | out | WARP_W | The granted slot (also ad_su_wb's in-port warp). |
| `vl_go` | in | 1 | One-cycle: the attributes are written, start the warp. |
| `vl_mask` | in | 32 | With vl_go: valid vertices (initial EXEC). |
| **Fragment warp allocation (RX, via ad_su ports fl_*)** | | | |
| `fl_req` | in | 1 | RX wants a fragment slot. |
| `fl_gnt` | out | 1 | Grant. |
| `fl_slot` | out | WARP_W | Slot. |
| `fl_go` | in | 1 | Start. |
| `fl_mask` | in | 32 | With fl_go: quads touched (EXEC, quad-granular, design §3.1). |
| `fl_info` | in | 64 | With fl_go: [31:0] coverage mask, [47:32] sequence number, [48] front, [63:49] primitive id low bits. |
| **Fetch (to ad_su_fetch)** | | | |
| `f_valid` | out | 1 | Fetch the next instruction of f_warp. |
| `f_ready` | in | 1 | Taken. |
| `f_warp` | out | WARP_W | Warp. |
| `f_pc` | out | 16 | Instruction index. |
| `f_addr` | out | 32 | Byte address = program base (VS/FS/CS_BASE by kind) + 8 × f_pc. |
| **Feedback (from ad_su_sb and ad_su_exec)** | | | |
| `fb_valid` | in | 1 | The fetched instruction of fb_warp left the front end. |
| `fb_warp` | in | WARP_W | Warp. |
| `fb_kind` | in | 2 | 0 issued (next pc = pc+1), 1 issued, wait for wc_* (branch/end/bar), 2 replay (hazard: fetch the same pc after a wake). |
| `wake` | in | NWARPS | Pulses: an entry of that warp was released (replayed warps become ready). |
| `warp_ready` | in | NWARPS | Readiness mask from ad_su_sb: 1 when the warp has no outstanding long operations/hazards. |
| `wc_valid` | in | 1 | Warp control from ad_su_exec. |
| `wc_warp` | in | WARP_W | Warp. |
| `wc_op` | in | 2 | 0 continue at wc_pc, 1 end (free the slot after the export buffer drains), 2 barrier wait (continue at wc_pc when the workgroup arrives). |
| `wc_pc` | in | 16 | Next pc. |
| **Warp information** | | | |
| `q_warp` | in | WARP_W | Query (from ad_su_opd). |
| `q_info` | out | 160 | Warp-info word of q_warp (AD_WI_* of include/ad_su_uop.vh), combinational. |
| `init_valid` | out | 1 | A warp starts: initial EXEC to ad_su_exec. |
| `init_warp` | out | WARP_W | Warp. |
| `init_mask` | out | 32 | Initial EXEC. |
| `pt_ok` | in | 1 | ad_su_pt has a free 32-entry PT block (vertex grants wait otherwise). |
| `xr_valid` | in | 1 | ad_su_exp: the export buffer of xr_warp is drained (an ended warp's slot is free). |
| `xr_warp` | in | WARP_W | Warp. |
| `busy` | out | 1 | A warp is resident or a grid is not fully launched. |

39 ports.

## 4. Behaviour

- Slot states: FREE → ALLOC (granted, inputs being written) → READY ↔ (FETCHING → WAIT_FB) →
  {READY | WAIT_WC | REPLAY} … → ENDED → FREE (after xr_valid).
- Candidate readiness: a slot is selectable for fetch when in READY, its issue gap (32/NPHYS cycles)
  has counted out, and `warp_ready[slot]` from `ad_su_sb` is 1 (no outstanding scoreboard hazards).
- Selection (`GTO = 1`): Greedy-Then-Oldest policy:
  - **Greedy**: While the currently active warp remains ready and executing without hazard/stall,
    it continues to be fetched consecutively to maximize instruction cache and register file locality.
  - **Oldest**: When the active warp stalls (`warp_ready == 0`, e.g. memory load / long latency wait),
    the scheduler switches to the candidate warp that has been waiting the longest (maximum `wait_age`).
- Selection (`GTO = 0`): Legacy round-robin among ready candidates.
- Grants: a vertex grant needs a FREE slot beyond FRAG_RESERVE and pt_ok (pulse pt_take inside ad_su_pt is
  derived from vl_gnt by the parent); a fragment grant needs any FREE slot.  Compute: after cs_kick,
  one workgroup of WG_SIZE lanes is launched as ceil(size/32) warps when that many slots are free,
  workgroup ids in x, y, z order, only ids with id % NSU == SU_INDEX; LID per warp.
- Barrier: wc_op 2 parks the warp; when every warp of its workgroup is parked, all continue.

## 5. State machine

One FSM per slot as above (a small state register each); the selector is combinational.  Per the U38 rule a slot's FSM counts as the module's one state machine replicated NWARPS times.

## 6. Latency and throughput

One fetch per cycle; a warp issues at most every 32/NPHYS cycles.

## 7. Corner cases and errors

- cs_kick while busy with compute: the new grid waits for the old one (the sequencer waits for SU idle anyway).
- A workgroup bigger than NWARPS×32 lanes is a driver error (WG_SIZE checked by the firmware); the
  scheduler clamps to NWARPS warps.

## 8. What the TB checks

`sim/tb/ad_su_sched_tb.v` prints, in this order:

- `PASS ad_su_sched.rr` — round-robin among ready warps with the 32/NPHYS spacing
- `PASS ad_su_sched.alloc` — vertex grants respect FRAG_RESERVE and pt_ok; fragment grants take any slot
- `PASS ad_su_sched.feedback` — issued/wait/replay feedback and wake give the right next pc
- `PASS ad_su_sched.compute` — a 2×2 grid of 64-lane workgroups with NSU 2: this SU's ids, LIDs and q_info
- `PASS ad_su_sched.barrier` — bar releases only when all warps of a workgroup arrive
- `PASS ad_su_sched.end` — end frees the slot only after xr_valid
- `PASS ad_su_sched` at the end.

`sim/tb/ad_su_sched_gto_tb.v` verifies GTO scheduling (Phase 012):

- `PASS ad_su_sched_gto.greedy` — consecutive execution of the same ready warp
- `PASS ad_su_sched_gto.stall_switch` — immediate switch away upon `warp_ready` deassertion
- `PASS ad_su_sched_gto.oldest` — prioritization of the longest-waiting candidate warp
- `PASS ad_su_sched_gto.no_replay` — zero replay feedback events
- `PASS ad_su_sched_gto` at the end.

## 9. References

design §3.1, §3.5 (scheduler), §3.8 (slot reservation), §2.3 (program STATE 0x190-0x19A), include/ad_su_uop.vh (warp-info word).

## 10. Status

Implemented in WS288 p008 (branch p1-su; TB `sim/tb/ad_su_sched_tb.v`).  A fetch that is not taken keeps its warp on f_* (valid/ready).  Compute warps of a workgroup get EXEC = the lanes below WG_SIZE, LID = 32 × warp, and a 4-bit workgroup tag for barriers; a workgroup is launched one warp per cycle while vertex/fragment grants wait.  Vertex/fragment q_info: kind, front, sequence and coverage from fl_info; LID 0.
Phase 012 (ws001-p012): Scoreboard feedback `warp_ready` integrated and GTO scheduling policy added (`.GTO(1)`). TB `sim/tb/ad_su_sched_gto_tb.v`.

2026-11-08 (front-end builder, rtl/su/ad_su_sched.v + leaves rtl/su/ctl/ad_ctl_slot.v (the slot FSM: FREE, ALLOC, READY, FETCH, WAIT_FB, WAIT_WC, REPLAY, BAR, ENDED) and ad_ctl_wsel.v (GTO / round-robin selector)).  TBs `sim/tb/ad_su_sched_tb.v` (GTO 0, NPHYS 4 and 8, NSU 2) and `sim/tb/ad_su_sched_gto_tb.v` (GTO 1, NPHYS 8 and 32), environment `sim/tb/ad_su_sched_env.vh`; formal `formal/ad_su_sched` (GTO 1 and 0: grants only of FREE slots, FRAG_RESERVE, barrier, issue gap, ready candidate only; properties under AD_SCHED_FV in the RTL) and `formal/ad_ctl_slot`, `formal/ad_ctl_wsel`; mutations MUT_SCHED_RESERVE, MUT_SCHED_NO_WREADY.
- ASSUMPTION: a vertex grant needs more than FRAG_RESERVE FREE slots before the grant (this spec's "a FREE slot beyond FRAG_RESERVE"); spec/gpu/su/ad_su.md §8 says "leaves more than FRAG_RESERVE slots free", which would be one slot stricter.
- ASSUMPTION: one allocation per cycle (fragment > vertex > compute); at most one vertex and one fragment slot granted and not yet started; vl_gnt/fl_gnt are registered pulses (the cycle after the decision), vl_slot/fl_slot hold until the next grant; vl_go/fl_go without an outstanding grant are ignored.
- ASSUMPTION: one start (init_valid) per cycle, fragment > vertex > compute; the slot is READY from the start (EXEC is set in the same edge).
- ASSUMPTION: a workgroup reserves all of its slots at once (the lowest FREE ones) and starts one warp per cycle; FRAG_RESERVE does not apply to compute; WG_SIZE 0 gives one warp with EXEC 0.  Grid sizes and WG_SIZE are snapshot at the kick; a kick during a grid's launch is kept (one) and starts when that grid's last id is passed, with the STATE values of then.  Skipped ids (id % NSU != SU_INDEX) take a cycle each.
- ASSUMPTION: q_info: vertex KIND 0, MASK = vl_mask; fragment KIND 1, MASK = fl_info[31:0], SEQ = fl_info[47:32], FRONT = fl_info[48]; compute KIND 2, WGX/Y/Z, NWGX/Y/Z = the grid, LID = 32 k, MASK = the initial EXEC; all other bits 0.
- ASSUMPTION: f_* is registered: a selection is made when f_* is empty or taken in the cycle; f_addr = base(kind) + 8 pc with the base read at the selection.
- ASSUMPTION: issue gap = at least 32/NPHYS cycles between two fetches (f_valid && f_ready) of one warp.
- ASSUMPTION: GTO: the greedy warp is selected whenever it is a candidate; it stays greedy while it has warp_ready and is READY, FETCH or WAIT_FB (one instruction per warp is in the front end at a time, so other warps fill those cycles); otherwise the next selection (the oldest candidate) becomes greedy.  Age = cycles since the warp's last fetch or start (8 bits, saturating); ties go to the lowest slot.  Round-robin starts after the last selected warp.
- ASSUMPTION: feedback 2 with a wake of the warp in the same cycle makes it READY at once; a wake in other states is ignored (ad_su_sb checks with the releases of its own cycle, so no wake is lost).  fb_kind 3 behaves as 0 without pc+1 (READY); wc_op 3 as 0.
- ASSUMPTION: barrier membership is recorded at the start (the slots of the workgroup; a graphics warp alone); a freed slot leaves every membership; a BAR warp is released when every member is in BAR or ENDED.
- ASSUMPTION: busy = a slot not FREE, a grid being walked or kicked, a workgroup being started, or a grant/start pending.
