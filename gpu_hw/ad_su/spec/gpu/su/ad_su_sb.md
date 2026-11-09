# ad_su_sb

RTL: `rtl/gpu/su/ad_su_sb.v`.  Parent: ad_su.  Implemented in: p008.

## 1. Purpose and place

The issue stage with the per-warp scoreboard (design §3.1.1): checks the operand ranges of an instruction against the warp's outstanding long operations, the wait counters, rq and write-back stalls; issues to ad_su_opd with an entry, or replays.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `SB_ENTRIES` | `4` | Scoreboard entries per warp (KC705 8). |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `UOP_W` | `104` | Width of the decoded instruction (= AD_UOP_W of include/ad_su_uop.vh). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **From ad_su_dec** | | | |
| `u_valid` | in | 1 | Instruction. |
| `u_ready` | out | 1 | Taken (issued or replayed). |
| `u_warp` | in | WARP_W | Warp. |
| `u_pc` | in | 16 | pc. |
| `u_uop` | in | UOP_W | Micro-op. |
| **To ad_su_opd** | | | |
| `i_valid` | out | 1 | Issue. |
| `i_ready` | in | 1 | Taken (all of its groups will follow). |
| `i_warp` | out | WARP_W | Warp. |
| `i_pc` | out | 16 | pc. |
| `i_uop` | out | UOP_W | Micro-op. |
| `i_sbe` | out | (SBE_W)+1 | Entry taken (all ones: none). |
| **To ad_su_sched** | | | |
| `fb_valid` | out | 1 | Feedback. |
| `fb_warp` | out | WARP_W | Warp. |
| `fb_kind` | out | 2 | 0 issued, 1 issued and wait for warp control (unit EXEC), 2 replay. |
| `wake` | out | NWARPS | Entry or counter released for the warp. |
| **Releases (from ad_su_wb)** | | | |
| `rel_valid` | in | 1 | A long instruction finished. |
| `rel_warp` | in | WARP_W | Warp. |
| `rel_sbe` | in | (SBE_W)+1 | Entry (all ones: none). |
| `rel_cls` | in | 3 | Counter to decrement. |
| `wb_stall` | in | 1 | ad_su_wb needs this cycle's write port: do not issue. |
| `rq_empty` | in | 1 | No entry to pop. |
| `rq_full` | in | 1 | No room to push. |
| `busy` | out | 1 | Any entry or counter is not zero. |
| `fault` | out | 1 | ISA fault pulse (uop ILL issued). |
| `fault_pc` | out | 16 | Its pc. |

27 ports.

## 4. Behaviour

- Entry: {valid, dst base, width (1 or 4), class}.  Hazard: any used source (rs1, rs2, rs3, rs1+1
  for PAIR, rs3 + 1 for a texture .3 form with Dref) or the destination range overlaps a valid entry's range → replay.
- Counters per warp: cm (stores/atomics outstanding), ct, cx.  `wait` (CTL) replays until the
  counters are ≤ its limits; `fence` (CTL) replays until cm = 0 (global) and then issues to the LSU
  for its D$ invalidate (acquire); `end` waits for all counters 0 (design §3.1.1).
- Long instructions (classes m, t, x with lanes) take an entry when they write a register (ndst > 0)
  and always increment their class counter; no free entry → replay.  EXEC all 0 (known from the
  operand stage: ad_su_opd suppresses the work and still sends an l_last completion) — v1 issues
  them normally; the unit reports completion without requests.
- rq: a source 63 with rq_empty, or rd 63 with rq_full → replay (design §3.9.1, v1 never sees it).

## 5. State machine

None (per-warp entry and counter registers, combinational check).

## 6. Latency and throughput

One check per cycle; the overlap check is about 400 LUT at 8 entries × 5 operands (design §3.1.1).

## 7. Corner cases and errors

- A release and an allocation of the same entry in one cycle: the release first.
- ILL: issue nothing, pulse fault, feedback 1 (the warp stops; the CP faults the device).

## 8. What the TB checks

`sim/tb/ad_su_sb_tb.v` prints, in this order:

- `PASS ad_su_sb.raw` — a read of a pending destination replays until the release
- `PASS ad_su_sb.waw` — a write over a pending texture rd..rd+3 replays; a texture .3 form with Dref whose rs1+3 (rs3 + 1) is in it replays, the same form without .3 issues
- `PASS ad_su_sb.full` — entries full: long instruction replays; other warps issue
- `PASS ad_su_sb.wait` — wait/fence/end with counters
- `PASS ad_su_sb.fault` — ILL gives fault with the pc
- `PASS ad_su_sb` at the end.

## 9. References

design §3.1.1 (scoreboard), §3.4.2 (classes), §3.9 (rq).

## 10. Status

Implemented in WS288 p008 (branch p1-su; TB `sim/tb/ad_su_sb_tb.v`).  Spec change made in p008 (the spec lacked the short-result interlock of design §3.1.1): parameters `NPHYS` and `SHORT_LAT`, input `x_end` (the last group of an instruction leaves ad_su_opd: `x_valid && x_last && unit_ready[unit]`, wired in ad_su).  Issued instructions are listed in order until x_end; a short writer (class a/f with rd < 63) then counts SHORT_LAT+1 cycles.  A reader of its rd is held (u_ready 0, not replayed) while the writer is before the bus or the count is above 32/NPHYS + 1; a long writer of that rd is held until the count ends.  nop and a satisfied wait are consumed without issue (feedback 0).  Counters are 6 bits; a long instruction whose counter is at the maximum replays.  Feedback 1 for branches, end and bar.

2026-10-25 (p009 part F, P3): a fifth source for the texture .3 forms with Dref (`texl.3.c`, `texb.3.c`, `texg.3.c`): rs3 + 1 = rs1+3, checked like the others (`src5`: TEX unit, the uop's sub[4] and TEX op bit 2).

2026-11-08 (front-end builder, rtl/su/ad_su_sb.v + leaves rtl/su/ctl/ad_ctl_sb_ovl.v (overlap check) and ad_ctl_sb_sil.v (short-result interlock)).  Ports as above plus the §10 additions (NPHYS, SHORT_LAT, x_end) and the new output `warp_ready` (NWARPS bits, to ad_su_sched):

  warp_ready[w] = warp w has no valid scoreboard entry (no long destination pending), taken from the registers (a release shows the cycle after).  With ad_su_sched selecting only such warps, an instruction cannot meet an entry hazard or a full entry set, so the only replays left are the counter waits (wait, fence, end), a long instruction at a counter of 63, and rq.

TB `sim/tb/ad_su_sb_tb.v` (NPHYS 8; also run with -Pad_su_sb_tb.NPHYS=4 and 32) adds `PASS ad_su_sb.interlock`; formal `formal/ad_su_sb` (properties under AD_SB_FV in the RTL with a port-built shadow: never issues a reader or writer of a pending long destination, allocations take free entries, counters never underflow/overflow; in the harness: exactly one fault per ILL) and `formal/ad_ctl_sb_ovl` (equals a reference interval check), `formal/ad_ctl_sb_sil`; mutation MUT_SB_NO_SRC5.
- ASSUMPTION: hazards, free entries and counter limits use the state after this cycle's release (release before allocate and before check); a replay in the cycle of a release still gets that wake.
- ASSUMPTION: operand numbers 63-127 are not GPRs (no hazard); rs1+1 and rs3+1 are formed in 8 bits; the fifth source also needs USE3.  A NDST other than 4 means width 1.
- ASSUMPTION: wait checks no register hazard; fence (LSU op 3) and end check theirs too.  The counters count every long (m/t/x) instruction issued (stores and loads alike), whatever its EXEC.
- ASSUMPTION: holds (u_ready 0): wb_stall (only when the uop would issue), the short-result interlock, the in-order list of the interlock full (4 issued instructions without x_end), i_ready 0.  Consumed/replayed uops are never held.
- ASSUMPTION: the interlock list holds every issued instruction until its x_end (one per issued instruction); a short writer is class a/f with WRD and rd < 63; its tracker counts SHORT_LAT+1 in the cycle after x_end down to 1.  Readers are held while the count is above 32/NPHYS + 1, long writers of a covered rd while it counts at all.
- ASSUMPTION: fault/fault_pc are registered (one cycle after the ILL uop is consumed).  busy = an entry valid or a counter not zero (the interlock list is not included).
- ASSUMPTION: an rq replay gets no wake (v1 never replays on rq).
- 2026-11-08 formal note: formal/ad_ctl_sb_sil bmc (abc bmc3, depth 16, NPHYS 16/SHORT_LAT 4, registers reduced to 0/1/62/63, one source) passes; its prove (abc pdr, NPHYS 32/SHORT_LAT 2/OQ 2) does not close within 300 s (pdr stalls at frame 2); the interlock's hold timing is also checked by sim/tb/ad_su_sb_tb.v (.interlock).
