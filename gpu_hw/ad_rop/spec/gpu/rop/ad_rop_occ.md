# ad_rop_occ

RTL: `rtl/gpu/rop/ad_rop_occ.v` (new).  Parent: ad_rop.

## 1. Purpose and place

The occlusion counter: counts the samples that pass every per-sample test while ROP_CTRL[0] is 1; the command processor's QUERY micro-op reads and clears it.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `st_we` | in | 1 | STATE broadcast: one-cycle write of STATE[st_idx]. |
| `st_idx` | in | 9 | STATE index. |
| `st_wdata` | in | 32 | STATE value; the module keeps ROP_CTRL[0] (0x08D). |
| `inc_valid` | in | 1 | One cycle: a quad's first beat left the depth/stencil test. |
| `inc_n` | in | 5 | Its passing samples (popcount of the mask after ad_rop_ds: lanes × samples, 0-16). |
| `clear` | in | 1 | One cycle, from ad_cp_seq (QUERY flags[0] or flags[1]). |
| `count` | out | 40 | The counter (to ad_cp_seq for QUERY); registered. |

9 ports.

## 4. Behaviour

count <= (clear ? 0 : count) + (inc_valid && ROP_CTRL[0] ? inc_n : 0): a clear and an increment in the same cycle leave the increment.  The counter wraps at 2^40 (never reached in practice).  ROP_CTRL[0] takes effect on the STATE write (the CP's waiting rules make the write come between draws).

## 5. State machine

None.

## 6. Latency and throughput

One increment per cycle; count is the value after the last cycle's update.

## 7. Corner cases and errors

- Reset clears the counter.
- A quad with no colour attachment (a nocol beat) still counts: ad_rop_ds passes it on and ad_rop gives inc_valid for the first beat of every quad.

## 8. What the TB checks

`sim/tb/ad_rop_occ_tb.v` prints:

- `PASS ad_rop_occ.count` — random increments against a model with ROP_CTRL[0] switched, clears alone and with an increment
- `PASS ad_rop_occ` at the end.

`MUT_OCC_BEAT` (in ad_rop: count every beat) is checked by `sim/tb/ad_rop_beat_tb.v` (`PASS ad_rop_beat.occ`), not here.

## 9. References

docs/ghci.md §7.3 (QUERY), §8.5 (ROP_CTRL), design §16.8.  Values referenced: Vulkan specification, Occlusion Queries, Sample Counting.

## 10. Status

Implemented 2026-10-25: every PASS of §8.  Wired in ad_rop (inc_valid = ad_rop_ds's d_valid and d_ready of a first beat, d_beat[0]; inc_n its d_smask's popcount) and to ad_cp_seq's QUERY through ad_top.

2026-11-08 (rtl/rop/ad_rop_occ.v rebuilt in this tree): `sim/tb/ad_rop_occ_tb.v` prints every PASS of §8 (20000 random cycles against an in-TB model, ROP_CTRL[0] switched, clear alone and with an increment, reset).  Formal `formal/ad_rop_occ/`: count equals a reference register, clear+inc leaves inc, ROP_CTRL[0]=0 never increments: bmc (abc bmc3, depth 12) PASS, prove (abc pdr) PASS.  Mutation `-DMUT_OCC_EN` (ignore ROP_CTRL[0]) fails the TB and bmc.
ASSUMPTION: RTL path is `rtl/rop/ad_rop_occ.v` (repository layout), not `rtl/gpu/rop/`.
ASSUMPTION: ROP_CTRL[0] is reset to 0 with the other STATE words; a STATE write to 0x08D takes effect from the next cycle (the increment in the write's own cycle uses the old bit).
