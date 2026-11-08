# ad_su_exp_drain

RTL: `rtl/gpu/su/ad_su_exp_drain.v` (new).  Parent: ad_su_exp.

## 1. Purpose and place

The drain of the fragment export buffer: picks the ended fragment warp whose sequence number is the ROP's next one, sends its quads to the ROP as beats (CAPS[30]: one per colour attachment the warp exported), and releases the slots.  Split off `ad_su_exp` for the line limit (design §16.13).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1, 1 | Clock, reset. |
| `fl_go`, `fl_slot`, `fl_seq` | in | 1, WARP_W, 16 | A fragment warp starts in a slot with its sequence number (ad_su_exp's snoop of fl_*). |
| `wc_end`, `wc_warp` | in | 1, WARP_W | ad_su_exec ended a warp. |
| `d_cov`, `d_rtw` | in | 32, 4 | The draining warp's coverage and the attachments it exported (ad_su_exp, selected by d_warp). |
| `d_warp`, `d_q`, `d_rt` | out | WARP_W, 3, 2 | The beat: warp, quad, attachment (ad_su_exp reads its data). |
| `d_first`, `d_lastb`, `d_nocol` | out | 1, 1, 1 | The quad's first beat, its last, a beat without colour. |
| `ex_valid` / `ex_ready` | out / in | 1, 1 | The beat to the ROP. |
| `ex_seq`, `ex_last` | out | 16, 1 | The warp's number; the warp's last beat. |
| `ex_next` | in | 16 | The ROP's next sequence number. |
| `xr_valid`, `xr_warp` | out | 1, WARP_W | Slot release (ad_su_sched). |

22 ports.

## 4. Behaviour

- Per slot: fragment, ended, sequence number (set at fl_go; ended at wc_end of a fragment warp; cleared at the release).
- An ended fragment warp whose number equals ex_next is drained: per quad with coverage (packed from lane 0, at most 8) one beat per attachment of d_rtw in ascending order, or one beat with d_nocol when d_rtw is 0.  ex_last on the last beat of the last quad, then xr_valid.
- Vertex and compute warps: xr_valid the cycle after wc_end; a drain's release waits a cycle when both fall together.

## 5. State machine

IDLE →(candidate)→ FIRST (d_rt = the lowest attachment) → DRAIN (one beat per ex_ready) →(last beat)→ RET (xr_valid; waits while a vertex release is out) → IDLE.

## 6. Latency and throughput

One beat per cycle; one cycle (FIRST) per warp before its first beat.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

Through `sim/tb/ad_su_exp_tb.v` (spec ad_su_exp.md §8).

## 9. References

design §3.8 (ROP order), §16.13; spec ad_su_exp.md, ad_rop_order.md.

## 10. Status

Implemented 2026-10-25 (CAPS[30], colour attachments).  A child of ad_su_exp rather than a sibling in ad_su (the design's text): ad_su keeps its wiring and ad_su_exp its 39 ports.

2026-11-08: rebuilt (rtl/su/ad_su_exp_drain.v).  Formal `formal/ad_su_exp_drain` (abc pdr, proven): beats only for an ended fragment warp whose number is ex_next, held while not taken, the attachment in d_rtw (nocol exactly when it is 0), exactly one ex_last per fragment warp before its release, xr_valid only for an ended warp, a vertex/compute warp's exactly the cycle after its wc_end.  `-DMUT_DRAIN_SEQ` (any ended warp drained) fails it.
- ASSUMPTION: with several ended fragment slots whose number equals ex_next (impossible when the RX numbers warps uniquely), the lowest slot is drained.
- ASSUMPTION: FIRST carries no beat; d_rt of a nocol beat is 0; a quad index past 7 never occurs (quads are packed from lane 0, the coverage's next nibble after quad 7 reads 0).
