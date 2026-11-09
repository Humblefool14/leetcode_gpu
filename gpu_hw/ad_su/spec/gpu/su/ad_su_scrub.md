# ad_su_scrub

RTL: `rtl/gpu/su/ad_su_scrub.v`.  Parents: `ad_su_rf`, `ad_su_lds`, `ad_su_lda`, `ad_su_pt`,
`ad_su_cbank`, `ad_su_exp` (instance `sc` in each).  Written for session protection
(docs/ghci.md §11.6, 2026-10-25).

## 1. Purpose and place

The address counter of a memory's scrub: when the CP switches the units to another protected
session (ad_cp_prot), the shader unit writes 0 to every word that a warp could read without
having written it (registers, shared memory, varyings, constants, colour outputs).  Each memory
writes the zeros through its own write port (a mux in front of it; no added port, the RAMs'
declarations and reads unchanged).

## 2. Parameters

`DEPTH` (16), `AW` (clog2(DEPTH), at least 1).

## 3. Ports

Domain `clk`.  5 ports: `clk`, `rst_n`, `start` (one cycle), `on` (the memory writes 0 at `a`),
`a`.

## 4. Behaviour

`start` sets `on` for DEPTH cycles with a = 0 … DEPTH − 1; a start while on begins again.  The
memory's write has priority while `on` (the unit is idle: ad_cp_prot drains it first).  Each
memory's `scrub_busy` is its `on`; `ad_su`'s is the OR.

## 5. State machine

idle → (start) on → (a = DEPTH − 1) idle.

## 6. Latency and throughput

DEPTH cycles.  The SU: the longest memory (default NPHYS 8: the primitive table, 1536 words; the
KC705: the primitive table, 6144 words ≈ 61 µs at 100 MHz, estimate).  The memories run at once.

## 7. Corner cases and errors

rst_n stops it.  A memory with several copies or banks writes them all at once.

## 8. What the TB checks

`sim/tb/ad_su_scrub_tb.v`: ad_su (NPHYS 8) with every scrubbed memory filled with non-zero
words; after the scrub every word is 0 and `scrub_busy` lasted the longest memory's depth.

## 9. References

`spec/gpu/cp/ad_cp_prot.md`; the parents' specs.

## 10. Status

Implemented (session protection, R4).  Not done: the written-memory marks (ad_cp_prot counts
the µops that use the shader units instead), a wider write for the primitive table.

2026-11-08 (core builder): `rtl/su/ad_su_scrub.v` (DEPTH, AW).  TB `sim/tb/ad_su_scrub_tb.v` checks the
counter alone (DEPTH 16 and 12: the sequence, restart while on, rst_n stops it: `PASS
ad_su_scrub.counter`) and inside ad_su_rf (NPHYS 8 and 4: filled, scrubbed, busy exactly NWARPS x NREGS
x 32/NPHYS cycles, every word 0, a write during the scrub ignored: `PASS ad_su_scrub.rf`), then `PASS
ad_su_scrub`.  The whole-SU check of §8 (every scrubbed memory of ad_su) belongs to the ad_su
testbench.  Formal `formal/ad_su_scrub` (DEPTH 12): on exactly DEPTH cycles after the last start with
a = cycles since it; bmc abc bmc3 depth 30, prove abc pdr.  Mutation `MUT_SCRUB_SHORT`: TB and formal
FAIL.
