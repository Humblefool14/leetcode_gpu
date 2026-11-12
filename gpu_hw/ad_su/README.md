# ad_su: shader unit (SU), RTL + verification

The GPU's shader unit, renamed from `atg_su` to `ad_su`. It runs 32-lane warps of GSI1 code
(64-bit instructions) for vertex, fragment and compute work on NPHYS = 4, 8, 16 or 32 physical lanes,
with 12 execution units on one bus. Every module is split into small leaf IPs. Each is checked by a
self-checking testbench against your Python models (`tools/gsi1fp.py`, `tools/gsi1model.py`,
`tools/gsi1asm.py`) and by SymbiYosys (BMC + unbounded proof).

Architecture document (diagrams, hierarchy, encoding, verification, spec issues, roadmap):
https://claude.ai/artifact/JjFEWJ8zHrQV2Ax21feu7Z. Summary in `docs/ARCHITECTURE.md`, roadmap in `docs/ROADMAP.md`.

## Layout

| Path | Contents |
| --- | --- |
| `spec/gpu/su/` | Module specs (renamed atg_ to ad_; section 10 records every `ASSUMPTION:` and the build status). New: leaf specs for the fp/pk leaves and exp_mesh, `ad_amb_mux.md`. |
| `rtl/include/` | `ad_su_uop.vh`, `ad_su_xu_tab.vh` (yours, renamed); `ad_su_state.vh` (STATE indices, mostly ASSUMED). |
| `rtl/su/` | `ad_su.v` (top) and 34 modules; 61 leaf IPs in `core/ ctl/ dec/ div/ fp/ gfx/ lane/ mem/ pk/ xu/`. |
| `sim/tb/` | Unit testbenches (`<tb>.v` + `<tb>.f`); `ad_su_tb` is the whole-SU test, programs in `sim/tb/su/*.s`. |
| `sim/common/` | AMB memory models. |
| `sim/vec/` | Generated vectors and program images. |
| `tools/` | Your reference tools (renamed) and the vector generators (`gen_*_vectors.py`, `gen_su_sys.py`, `gen_isa_doc.py`). |
| `formal/<block>/` | `<block>.sby` + `fv_<block>.sv` for 84 blocks; `formal/common/` shared AMB client properties. |
| `scripts/` | `run_sim.sh`, `run_formal.sh`, `regress.sh`, `abc_compat.sh`. |
| `docs/` | `GSI1_ISA.md` (encoding table generated from gsi1asm.py), `CONVENTIONS.md`, `ARCHITECTURE.md`, `ROADMAP.md`. |

## Running

```
python3 tools/gen_su_sys.py fpu                                  # assemble + reference-run one program
PLUSARGS=+prog=fpu scripts/run_sim.sh ad_su_tb -Pad_su_tb.NPHYS=8  # whole SU on that program
scripts/run_sim.sh ad_su_fpu_tb                                  # one unit
scripts/run_formal.sh ad_su_ffma_p                               # one block: bmc + prove
scripts/regress.sh                                               # everything (sim ~10 min, formal ~1.5 h on 2 CPUs)
scripts/regress.sh sim | formal                                  # one half
```
The pk program needs `--packed` / `-Pad_su_tb.PACKED=1` and sub needs `--subgroup` / `-Pad_su_tb.SUBGROUP=1`
(see `scripts/regress.sh`).

Tools: Icarus Verilog 12, Python 3 + numpy, SymbiYosys/Yosys (YoWASP build) with ABC and z3.
`scripts/run_formal.sh` calls `yowasp-sby` with `--abc scripts/abc_compat.sh`. With a matched native
OSS CAD Suite, plain `sby -f` works. Formal tasks whose name ends in `_open` are known not to close
and are skipped by `regress.sh`.

## Status (2026-11-08)

- Simulation: 32 unit testbenches PASS; whole SU: 7 programs x NPHYS {4, 8, 16, 32} = 28 runs PASS
  (every written register lane and 4,096 memory words match gsi1model.py, no fault).
- Formal: 84 harnesses, BMC PASS on all; unbounded proof PASS on 82. `ad_ctl_sb_sil` and the
  `ad_su_lane` top are BMC only (`prove_open`). 195 tasks PASS, 0 fail.
- Decoder matches gsi1asm.py bit for bit (67,096 vectors, 6 configs).
- Finding: the short-result interlock is conservative, so forwarding is never used (correct, slower).
- Assumptions to confirm: STATE indices, exp_mesh format, PK_SHARED (not built), extra top ports.
  Details in `docs/ARCHITECTURE.md`.

## Common library (2026-11-11)

Generic primitives (arbiters, FIFOs, delay lines, skid buffers, RAMs, popcount, ad_amb_mux) now
come from `../ad_common/rtl/common/` (one copy, one parameterized proof each; see
`../ad_common/README.md`). This repository must sit next to `ad_common/`. The private copies and
their formal directories were removed; `18` files and directories
in all (log of the migration: `docs/MIGRATION_COMMON.txt`).
