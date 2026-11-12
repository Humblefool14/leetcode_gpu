# ad_rop — render output unit (ROP), RTL + verification

The ROP of the GPU, renamed from `atg_rop` to `ad_rop`: primitive-order retirement, multisample coverage,
depth/stencil, occlusion counting, unorm8 and fp32 blending into up to four colour attachments, and
write-back through one AMB memory port.  Every block is split into small leaf IPs, checked by a
self-checking testbench against a bit-exact Python model, and by SymbiYosys (BMC + unbounded proof).

Architecture document (diagrams, STATE map, verification results, spec issues, roadmap):
https://claude.ai/artifact/JmZP2Y2iAib55xbSFi1asr — summary in `docs/ARCHITECTURE.md`, roadmap in `docs/ROADMAP.md`.

## Layout

| Path | Contents |
| --- | --- |
| `spec/gpu/rop/` | Module specs (renamed atg_→ad_; §10 records every `ASSUMPTION:` and status). New: `ad_rop_order.md`, `ad_amb_mux.md`. |
| `rtl/include/ad_rop_state.vh` | STATE indices and fields (11 indices marked ASSUMED). |
| `rtl/common/` | Shared arithmetic IPs: div255, f2u8, f2unorm, unorm2f, fp32 add/mul/cmp, VkCompareOp. |
| `rtl/rop/` | `ad_rop.v` (top) and the blocks; leaf IPs in `blend/ fblend/ ds/ dtest/ ms/ wb/ wpix/ cache/ hazard/`. |
| `sim/tb/` | Testbenches (`<tb>.v` + `<tb>.f`). `ad_rop_sys_tb` is the whole-ROP test. |
| `sim/common/` | AMB memory models (in-order random latency; reads-overtake-writes), fblend stub. |
| `tools/` | Python reference models (`admodel.py`, `*_model.py`) and vector generators (`gen_*_vectors.py`). |
| `formal/<block>/` | `<block>.sby` + `fv_<block>.sv` harness for 46 blocks; `formal/common/` shared AMB properties. |
| `scripts/` | `run_sim.sh`, `run_formal.sh`, `regress.sh`, `abc_compat.sh`. |
| `docs/` | `CONVENTIONS.md` (coding/verification rules), `ARCHITECTURE.md`, `ROADMAP.md`. |

## Running

```
scripts/run_sim.sh ad_rop_sys_tb                 # whole ROP, 4 scenes, memory image + occlusion count
scripts/run_sim.sh ad_rop_sys_tb -DAD_OOO_MEM    # same with a memory whose reads can overtake writes
scripts/run_formal.sh ad_rop_ds                  # one block: bmc + prove (+ cover)
scripts/regress.sh                               # everything (sim ~7 min, formal ~45 min on 2 CPUs)
```
Tools: Icarus Verilog 12, Python 3 + numpy, SymbiYosys/Yosys (YoWASP build) with ABC and z3.
`scripts/run_formal.sh` calls `yowasp-sby` with `--abc scripts/abc_compat.sh` (adapts newer sby to an older
system `yosys-abc`); with a matched native OSS CAD Suite, plain `sby -f` works.

## Status (2026-11-08)

- 24 simulation runs PASS (all testbenches, both line sizes, real and model blend, reordering memory).
- 46 formal harnesses: BMC PASS for all; unbounded proof PASS for every block except the top level
  (BMC only, datapaths blackboxed) and wb liveness (bounded to 75 cycles; `live_prove_open`).
- Two bugs found by an independent review were fixed (logic op stale destination in wpix; wb read
  overtaking its own write-back) and have regressions (`ad_rop_lop_tb`, `ad_rop_raw_tb`).
- Not implemented (see ROADMAP): 8 attachments, wb streaming path, dual-source wiring upstream, logic ops
  outside the unorm8 path.  `ad_rop_cache` and `ad_rop_hazard` are verified standalone IPs, not yet wired.

## Common library (2026-11-11)

Generic primitives (arbiters, FIFOs, delay lines, skid buffers, RAMs, popcount, ad_amb_mux) now
come from `../ad_common/rtl/common/` (one copy, one parameterized proof each; see
`../ad_common/README.md`). This repository must sit next to `ad_common/`. The private copies and
their formal directories were removed; `5` files and directories
in all (log of the migration: `docs/MIGRATION_COMMON.txt`).
