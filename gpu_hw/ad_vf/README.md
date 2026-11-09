# ad_vf: vertex fetcher (VF), RTL + verification

The GPU's vertex fetcher, renamed from `atg_vf` to `ad_vf`. On each DRAW it walks the vertex range or
an index buffer (u16/u32, primitive restart, instances), packs vertices into 32-lane warps for the SU,
fetches and converts each attribute (legacy formats and 50 VkFormats, ATTR_LIMIT robustness) into the
SU's registers, and sends assembled primitives (points, lines, triangles; strips and fans; provoking
vertex; last-use flags) to the RX. Every block is split into small leaf IPs, checked by a self-checking
testbench against Python reference models, and by SymbiYosys (BMC + unbounded proof).

Architecture document (diagrams, STATE map, verification, review findings, spec issues, roadmap):
https://claude.ai/artifact/QGN7QryYxqK2sgqvxbHd2h. Summary in `docs/ARCHITECTURE.md`, roadmap in `docs/ROADMAP.md`.

## Layout

| Path | Contents |
| --- | --- |
| `spec/gpu/vf/` | Module specs (renamed atg_ to ad_; section 10 records every `ASSUMPTION:` and the build status). |
| `rtl/include/ad_vf_state.vh` | STATE indices and fields (most marked ASSUMED). |
| `rtl/vf/` | `ad_vf.v` (top), `ad_vf_index/asm/fetch/conv/vc.v`, `ad_amb_mux.v`; leaf IPs in `idx/ asm/ fetch/ fmt/ vc/ top/`. |
| `sim/tb/` | Unit testbenches (`<tb>.v` + `.f`); `ad_vf_tb` is the whole-VF test (`+scene=<name>`). |
| `sim/common/` | AMB memory models. |
| `tools/` | `fmtmodel.py` (format reference), `asm_model.py`, `fetch_model.py`, `gen_vf_sys.py` (whole-VF scenes), `gen_*_vectors.py`. |
| `formal/<block>/` | `<block>.sby` + `fv_<block>.sv` for 32 blocks; `formal/common/` shared AMB client properties. |
| `scripts/` | `run_sim.sh`, `run_formal.sh`, `regress.sh`, `abc_compat.sh`. |
| `docs/` | `CONVENTIONS.md`, `BRIEF_COMMON.md` (builder brief), `ARCHITECTURE.md`, `ROADMAP.md`, `regress_*.txt`. |

## Running

```
python3 tools/gen_vf_sys.py                                   # all whole-VF scenes (--list to name them)
PLUSARGS=+scene=strip scripts/run_sim.sh ad_vf_tb             # whole VF on one scene
PLUSARGS=+scene=strip scripts/run_sim.sh ad_vf_tb -Pad_vf_tb.LINE_BYTES=64 -Pad_vf_tb.LINE_SHIFT=6
scripts/run_sim.sh ad_vf_fetch_tb                              # one unit
scripts/run_formal.sh ad_vf_fmt_unorm                          # one block: bmc + prove
scripts/regress.sh                                             # everything (about 45 min on 2 CPUs)
```
Tools: Icarus Verilog 12, Python 3, SymbiYosys/Yosys (YoWASP build) with ABC and z3.
`scripts/run_formal.sh` calls `yowasp-sby` with `--abc scripts/abc_compat.sh`. Formal tasks whose name
ends in `_open` are known not to close and are skipped by `regress.sh`.

## Status (2026-11-09)

- Simulation: 6 unit testbenches + the reused ad_amb_mux test PASS; whole VF: 8 scenes x LINE_BYTES
  {32, 64} x 2 latency seeds = 32 runs PASS against tools/gen_vf_sys.py.
- Formal: 32 harnesses, BMC PASS on all; unbounded proof PASS on 31 (the top is BMC only, depth 20).
  87 tasks PASS, 3 open (asm 32-lane prove, vc pdr prove, top line-hold model artifact), 0 fail.
- An independent review found two contract bugs (STATE writes during a draw; busy stuck after an index
  fault). Both are fixed, each with a regression scene (`race`, `fault`) and a mutation.
- ad_vf_vc (vertex cache) is a verified standalone IP; the specs do not wire it into ad_vf.
- Assumptions to confirm: STATE indices, legacy format codes, the VkFormat set, CP/SU contracts.
