# ad_su feature roadmap

Proposed plan for one engineer, starting 2026-11-16. Durations include each feature's own tests and
formal harnesses. The timeline chart is in the architecture document (Feature roadmap section).

## Phase 1: close verification (v1 sign-off, end of December 2026)

| # | Feature | Why | Effort | Target |
|---|---|---|---|---|
| 1 | Directed tests: denormal FFMA inputs, ballot over an empty EXEC, a texture program | mutations MUT_FFMA_DENORM, MUT_EXEC_BALL, MUT_SB_NO_SRC5 survive the whole-SU test | 1 wk | Nov 2026 |
| 2 | Relax the short-result interlock (`ad_ctl_sb_sil`) so the forwarding taps are used | dependent short ops wait for write-back; MUT_FWD_PRIO survives | 2 wk | Nov 2026 |
| 3 | Close the open proofs: `ad_ctl_sb_sil` prove, `ad_su_lane` prove | both BMC only today | 2 wk | Dec 2026 |
| 4 | PK_SHARED (fp16 ops on the FPU's fp32 datapath) | defined by ad_su_pk.md, not built; area saving | 2 wk | Dec 2026 |

## Phase 2: performance (Jan - Apr 2027)

| # | Feature | Why | Effort | Target |
|---|---|---|---|---|
| 5 | DIV buffers the whole instruction | the operand stage waits after each lane group | 2 wk | Jan 2027 |
| 6 | Performance counters (issue, replay, stall reasons, cache misses) | needed to tune the rest | 2 wk | Jan 2027 |
| 7 | Pipelined XU, more than one lane in flight | XU processes one lane at a time | 3 wk | Feb 2027 |
| 8 | 2-way D$ and store combining | 1 KiB direct-mapped conflicts; write-through sends every store | 3 wk | Feb 2027 |
| 9 | Dual issue: one short + one long instruction per cycle | single issue caps throughput | 6 wk | Mar - Apr 2027 |

## Phase 3: features (Apr - Jun 2027)

| # | Feature | Why | Effort | Target |
|---|---|---|---|---|
| 10 | SA queue (HAS_SA = 1, rq operand) | decoded today; faults without an SA | 4 wk | Apr - May 2027 |
| 11 | MS4: 4x multisampling (texsz.s, per-sample exports) | CAPS[29] | 3 wk | May 2027 |
| 12 | Per-unit clock gating | idle long units still toggle | 2 wk | Jun 2027 |

Later candidates, not scheduled: fp64 or fp16 transcendentals, more than 8 warps per SU, ECC on the
RF (beyond scrub), a hardware breakpoint / single-step debug port.
