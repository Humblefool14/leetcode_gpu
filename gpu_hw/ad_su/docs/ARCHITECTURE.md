# ad_su architecture (summary)

Full document with diagrams: https://claude.ai/artifact/JjFEWJ8zHrQV2Ax21feu7Z

## Overview

ad_su is one shader unit. It runs 32-lane warps of GSI1 code (64-bit instructions) for vertex,
fragment and compute work on NPHYS physical lanes (4, 8, 16 or 32), so one instruction takes
32/NPHYS cycles. It issues one instruction per cycle from up to NWARPS (2/4/8) resident warps.

Pipeline: sched (warp slots, round-robin or GTO pick) -> fetch + icache -> dec (64-bit word to the
108-bit uop of `rtl/include/ad_su_uop.vh`) -> sb (issue / hold / replay) -> opd (operands, one lane
group per cycle, forwarding) -> 12 execution units on one bus -> wb (single RF write port).

- Short units (result exactly SHORT_LAT = 6 cycles after the take): alu, fpu, pk, lane, lda, exec.
- Long units (beats with ready, scoreboard entry until the last beat): lsu, lds, cbank, tex, xu, div.
- wb priority: short > VF/RX input writes > long beats.

## Memory paths

- lsu -> coalescer -> dcache (1 KiB direct-mapped, write-through, read-allocate) -> d_* AMB client.
- lsu atomics -> MC atomic unit port (bypasses the D$).
- icache (2 KiB direct-mapped) + cbank (256 words, LOAD_CONST) -> ad_amb_mux -> i_* AMB client.
- lds: 4 KiB dual-port block RAM inside the SU (lds/sts/atoms), no memory port.

## Graphics outputs

- ad_su_pt: post-transform buffer of 32-entry blocks, read by the RX.
- ad_su_exp + exp_drain: fragment colour/depth exports, drained to the ROP in sequence order.
- ad_su_exp_mesh: mesh/primitive output stream (format invented here, see below).

## Hierarchy

35 module files in `rtl/su/`, 61 leaf IPs in `rtl/su/{core,ctl,dec,div,fp,gfx,lane,mem,pk,xu}/`,
about 8,700 non-comment lines. Every leaf has a testbench or a formal harness of its own; most have both.

## Encoding

Derived from `tools/gsi1asm.py` (source of truth) into `docs/GSI1_ISA.md` (147 instructions) by
`tools/gen_isa_doc.py`. The RTL decoder matches it bit for bit on 67,096 vectors in 6 configurations.

## Spec inconsistencies (resolved as noted)

| Where | Specs say | RTL does |
|---|---|---|
| ad_su.md and unit specs | UOP_W = 104 | 108, as in ad_su_uop.vh |
| ad_su_opd vs ad_su_rf | opd expects 3 RF read ports, rf has 2 | 2 ports; a group needing 3 GPRs takes 2 slots |
| ad_su_pipe | references am_* ports, no section 8 | built from the rest; used only by its own test |
| ad_su.md vs ad_su_sched | FRAG_RESERVE worded differently | follows ad_su_sched |
| tex_dec notes | stale texsz / use3 notes | follows gsi1asm.py |
| gsi1model.py | decode config lacks MS4 | MS4 = 0 added |
| uop SAMP_SLOT | no TU port carries it | decoded, unused |

## Assumptions to confirm

- STATE indices in `rtl/include/ad_su_state.vh` (0x190 - 0x1EE), marked ASSUMED.
- exp_mesh output format (tri/last/id stream), BMC only.
- PK_SHARED not implemented.
- Extra top ports `scrub`/`scrub_busy` and `mesh_*`.

## Finding: forwarding unused

`ad_ctl_sb_sil` holds a dependent short instruction until its producer's result reaches the RF, so
the forwarding taps in `ad_su_opd` never win: MUT_FWD_PRIO survives all 28 whole-SU runs (only the unit testbench
`ad_su_forwarding_tb` catches it). Correct, but slower
than intended. Roadmap item 2.
