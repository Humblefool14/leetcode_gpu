# ad_su_wb

RTL: `rtl/gpu/su/ad_su_wb.v`.  Parent: ad_su.  Implemented in: p008.

## 1. Purpose and place

Write-back arbitration: one RF write port shared by the short pipeline (one result per cycle), the long units' beats, and the VF/RX input writes; pushes rq results; releases scoreboard entries.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit). |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `NS` | `6` | Short sources (alu, fpu, pk, lane, lda, exec). |
| `NL` | `6` | Long sources (lsu, lds, cbank, tex, xu, div). |
| `SHORT_LAT` | `6` | Cycles from x_valid to the short result (ad_su's); sizes the input FIFOs. |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Short results (packed, source 0 in the low bits; at most one valid per cycle)** | | | |
| `s_valid` | in | NS | Valid. |
| `s_warp` | in | NS*WARP_W | Warp. |
| `s_grp` | in | NS*GRP_W | Group. |
| `s_rd` | in | NS*7 | rd. |
| `s_data` | in | NS*NPHYS*32 | Data. |
| `s_lanes` | in | NS*NPHYS | Lanes. |
| **Long results (packed)** | | | |
| `l_valid` | in | NL | Valid. |
| `l_ready` | out | NL | Taken. |
| `l_warp` | in | NL*WARP_W | Warp. |
| `l_grp` | in | NL*GRP_W | Group. |
| `l_rd` | in | NL*7 | rd. |
| `l_data` | in | NL*NPHYS*32 | Data. |
| `l_lanes` | in | NL*NPHYS | Lanes. |
| `l_wr` | in | NL | Write. |
| `l_last` | in | NL | Last beat. |
| `l_sbe` | in | NL*(SBE_W+1) | Entry. |
| `l_cls` | in | NL*3 | Class. |
| **Input writes (0 VF, 1 RX: one lane word per cycle)** | | | |
| `in_we` | in | 2 | Write. |
| `in_warp` | in | 2*WARP_W | Slot. |
| `in_reg` | in | 12 | Register, 6 bits each. |
| `in_lane` | in | 10 | Lane 0-31, 5 bits each. |
| `in_data` | in | 64 | Data, 32 bits each. |
| **Outputs** | | | |
| `w_en` | out | 1 | RF write. |
| `w_warp` | out | WARP_W | Warp. |
| `w_grp` | out | GRP_W | Group. |
| `w_reg` | out | 6 | Register. |
| `w_data` | out | NPHYS*32 | Data. |
| `w_lanes` | out | NPHYS | Lanes. |
| `rel_valid` | out | 1 | Release (to ad_su_sb). |
| `rel_warp` | out | WARP_W | Warp. |
| `rel_sbe` | out | (SBE_W)+1 | Entry. |
| `rel_cls` | out | 3 | Class. |
| `rq_push` | out | 1 | Push (rd 63) to ad_su_rq. |
| `rq_data` | out | NPHYS*32 | Data. |
| `wb_stall` | out | 1 | Ask ad_su_sb not to issue next cycle (a long beat waits). |

37 ports.

## 4. Behaviour

- Priority (design §3.5): (1) the short result of this cycle; (2) input writes (only to slots that
  are not running; they have no back-pressure, so they wait in a FIFO per source and raise
  wb_stall while waiting; the FIFO holds 2 × (SHORT_LAT + 2 G + 2) words rounded up to a power of
  two: the short results still to come after wb_stall (the units' pipelines, the instruction in
  ad_su_opd and one more issued in that cycle, two cycles of the stall's latency), twice since
  source 1 also waits for source 0's words.  32 for NPHYS 8, 16 and 32, 64 for NPHYS 4 at
  SHORT_LAT 6.  A write into a full FIFO prints an ERROR in simulation); (3) long beats, round-robin over the sources, in cycles without (1) or
  (2) — a beat waiting more than 4 cycles raises wb_stall so a free cycle comes SHORT_LAT cycles
  later.  A long beat without data (l_wr 0) is taken in any cycle.
- rd 63 → rq_push instead of the RF.  l_last → rel_* (also for l_wr 0).

## 5. State machine

None (a round-robin pointer and the wait counter).

## 6. Latency and throughput

One RF write per cycle.

## 7. Corner cases and errors

- Two short results in one cycle cannot happen (one issue per cycle, fixed latency); the TB checks the assertion.

## 8. What the TB checks

`sim/tb/ad_su_wb_tb.v` prints, in this order:

- `PASS ad_su_wb.prio` — short beats always win; long beats get free cycles; wb_stall after 4 cycles
- `PASS ad_su_wb.release` — l_last gives exactly one release, also without data
- `PASS ad_su_wb.input` — VF/RX lane writes become lane-masked group writes
- `PASS ad_su_wb` at the end.

## 9. References

design §3.5 (write port arbitration), §3.1.1.

## 10. Status

Implemented in WS288 p008 (branch p1-su; TB `sim/tb/ad_su_wb_tb.v`).  Differences from §4 (spec corrected here): the input writes have no back-pressure, so they go before long beats (short > input > long) and wait in a 16-entry FIFO per source while short results hold the port; a waiting input also raises wb_stall.  A long beat with l_wr = 0 (a store's completion) is taken in any cycle (it needs no port).  The VF/RX input path is exercised only by this TB until p009.

2026-10-26 (WS288 p024's preparation, P1): the input FIFOs were 16 words; with NPHYS 4 (G 8) the
short results held the port long enough after wb_stall that the RX's writes overflowed it
(ad_top_shade lost 18 writes, 7 pixels wrong).  The depth now follows SHORT_LAT and G (above,
the new parameter SHORT_LAT), and a lost write prints an ERROR in simulation.

2026-11-08 (core builder): rewritten in `rtl/su/ad_su_wb.v` with the leaves `rtl/su/core/ad_su_fifo.v`
(the input FIFOs) and `rtl/su/core/ad_su_rr_pick.v` (round-robin choice).  Outputs w_*, rq_*, rel_*,
l_ready are combinational in the cycle of the result (the short result is never delayed); wb_stall is
a function of registers.  Input FIFO depth: 2 x (SHORT_LAT + 2G + 2) rounded up to a power of two
(minimum 16): 32 for NPHYS 8/16/32, 64 for NPHYS 4.  New parameters FDEPTH (0 = that depth) and LW
(lane word bits, 32), used only by the formal harness.  TB `sim/tb/ad_su_wb_tb.v` (NPHYS 8 and 4):
`PASS ad_su_wb.prio`, `.release`, `.input`, `PASS ad_su_wb`.  Formal `formal/ad_su_wb` (NPHYS 4, NS 2,
NL 3, LW 2, FIFOs of 4): one result a cycle, at most one long beat taken, short results written in
their cycle, long beats with data only in free cycles and written when taken, taken-beat count =
written count, one release per l_last beat, rd 63 never writes the RF, no input FIFO overflow,
wb_stall as specified; bmc abc bmc3 depth 20, prove abc pdr.  Mutation `MUT_WB_LONG` (long beats ignore
the port): TB and formal FAIL; removing the short-density assumption makes the overflow check FAIL.
- ASSUMPTION: a long beat "waiting more than 4 cycles" raises wb_stall once 4 consecutive cycles have
  passed with a beat with data valid and none taken (counter >= 4).
- ASSUMPTION: the two input sources write at most one word a cycle together (two at one word a cycle
  each exceed the single port forever); the FIFO bound also assumes the spec's short-result density
  (no short result after wb_stall has been 1 for SHORT_LAT + 2G + 2 cycles in a row).  Formal assumes
  both.
- ASSUMPTION: an input write to register 63 is dropped (rd 63 never writes the RF; the VF/RX write
  r0-r62).  Short/long rd is below 64.
- ASSUMPTION: a long beat with l_wr 1 and rd 63 pushes rq in a free cycle; one RF write or one rq push
  a cycle.
