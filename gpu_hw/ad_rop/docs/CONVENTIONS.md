# ad_rop repository conventions

Read this before writing any RTL, testbench or formal harness here.

## Layout

| Path | What |
| --- | --- |
| `spec/gpu/rop/ad_*.md` | Module specs (renamed from atg_*). The source of truth for ports and behaviour. |
| `rtl/include/ad_rop_state.vh` | STATE indices and field layouts. `include it; never hard-code an index. |
| `rtl/common/` | Shared arithmetic IPs (read-only for module builders; report bugs instead of editing). |
| `rtl/rop/` | ROP modules and their leaf IPs. Leaf IPs: `rtl/rop/<parent>/<leaf>.v` or `rtl/rop/ad_rop_<leaf>.v`. |
| `sim/tb/<tb>.v` + `sim/tb/<tb>.f` | Self-checking testbench + file list (one path per line, repo-relative). |
| `sim/common/ad_amb_mem.v` | Behavioural AMB memory (random ready, random in-order latency, backdoor `mem[]`). |
| `sim/vec/` | Generated vectors (`.hex` via `$readmemh`, `_` separators allowed). |
| `tools/admodel.py` | Bit-exact Python models of the shared IPs (fp32 FTZ add/mul, f2unorm, unorm2f, div255...). |
| `tools/<x>_model.py`, `tools/gen_<x>_vectors.py` | Per-module reference models and vector generators. |
| `formal/<block>/<block>.sby` + `fv_<block>.sv` | SymbiYosys task file and formal harness (wrapper that instantiates the DUT). |
| `formal/common/ad_amb_client_props.sv` | Reusable AMB client-port properties (assert hold-until-ready, assume legal responses). |

## Running

- Simulation: `scripts/run_sim.sh <tb_name>` (compiles `sim/tb/<tb_name>.v` + its `.f`, runs from repo root,
  fails unless the log ends with `PASS <tb_name minus _tb>` and has no `FAIL` line).
- Formal: `scripts/run_formal.sh <block> [task]` prints `FORMAL <block> <task> PASS|FAIL|...`.
  Python: run generators with `python3 -I tools/gen_x.py`.

## RTL style

- Verilog-2005 (plus `$clog2`), must compile under `iverilog -g2012 -Wall` with no errors and parse in Yosys
  (`read -formal`). Avoid SystemVerilog-only constructs in RTL (no `logic`, `always_ff`, interfaces, structs).
  Do not use Verilog keywords as names (`small`, `large`, `medium`, `strong0`...).
- Clock `clk`, synchronous active-low reset `rst_n`. Every state register is reset unless it is pure datapath
  qualified by a reset valid bit.
- Ports and parameters exactly as the spec's §2 and §3 say (names, widths, directions). If the spec is
  ambiguous or self-contradictory, pick the most reasonable reading, implement it, and record it in the
  module's spec §10 Status as `ASSUMPTION:` lines (and in your report).
- STATE: blocks snoop `st_we/st_idx/st_wdata` and keep the words of their range in registers (reset to 0).
- Split big modules into leaf IPs (one job each, roughly 30-300 lines) so each leaf can be unit-tested and
  formally checked alone. Combinational leaves are preferred; the parent owns pipeline registers.
- Shared arithmetic in `rtl/common/` (use, do not copy):
  `ad_rop_div255` (round(x/255), x<=65025), `ad_rop_f2u8` (fp32->unorm8), `ad_f2unorm #(N)` (fp32->unormN RNE,
  N<=24), `ad_unorm2f #(N)` (unormN->fp32 RNE), `ad_fp_add` (a +/- b, RNE, FTZ in/out, canonical NaN 0x7FC00000),
  `ad_fp_mul` (RNE, FTZ, flush before rounding), `ad_fp_cmp` (lt/eq/un, -0 = +0), `ad_cmp_op` (VkCompareOp
  from lt/eq/un; unordered passes only NOT_EQUAL and ALWAYS).
  Python twins live in `tools/admodel.py` (`fp_add`, `fp_mul`, `fp_cmp`, `cmp_op`, `f2unorm`, `unorm2f`, `div255`).

## Testbenches

- Self-checking against a Python reference model (vectors written by `tools/gen_*.py`) and/or an in-TB
  scoreboard. Print exactly the `PASS <name>.<section>` lines the spec's §8 lists (with the `ad_` prefix),
  then `PASS <name>` at the end, or `FAIL ...` lines. Keep runtime under ~2 minutes per TB.
- Mutations named in the spec (`MUT_*` defines) should be implemented as `ifdef` in RTL where practical and
  shown to make the TB fail (note the result in your report).

## Formal

- One directory per block: `formal/<block>/<block>.sby`, harness `fv_<block>.sv` instantiating the DUT.
  Harness may use SystemVerilog immediate assertions in `always @(*)` / `always @(posedge clk)`,
  `assume`, `assert`, `cover`, and `(* anyconst *)` / `(* anyseq *)` regs. No concurrent SVA (`|->`, `##`):
  write the past-value registers by hand (see `formal/common/ad_amb_client_props.sv`).
- Free inputs: purely combinational harnesses take inputs as `(* anyconst *) reg` (ABC needs state);
  sequential harnesses expose free inputs as module ports (they become free each cycle) or `(* anyseq *)`.
  Reset: assume `!rst_n` in the first cycle (`reg init = 1; always @(posedge clk) init <= 0;`).
- Every `.sby` has at least tasks `bmc` and `prove`:
  ```
  [tasks]
  bmc
  prove
  [options]
  bmc: mode bmc
  bmc: depth <N>          # enough cycles to cover the block's longest transaction
  prove: mode prove
  [engines]
  bmc: abc bmc3           # or smtbmc z3 for word-level designs
  prove: abc pdr          # or smtbmc z3 (k-induction); state which in your report
  [script]
  read -formal <files>
  prep -top fv_<block>
  [files]
  <paths relative to formal/<block>/>
  ```
  Add `cover` tasks where useful (`mode cover`). If `prove` cannot close in ~10 minutes, keep `bmc`
  passing at a meaningful depth, report the depth and why the proof did not close (and any helper invariants
  tried). Large datapaths may be blackboxed or reduced (e.g. fewer lanes via a parameter) in the harness;
  say so.
- Engines available: `abc bmc3`, `abc pdr`, `smtbmc z3` (no yices/boolector). The runner reports FAIL when an
  engine returns a counterexample even if trace conversion crashes; to see a trace, re-run with
  `smtbmc z3` (VCD in `<task dir>/engine_0/trace.vcd`).
- Do a mutation sanity check: break the RTL on purpose once, confirm the harness FAILs, restore.
- Machine has 2 CPUs and other jobs run in parallel: keep each formal task under ~10 minutes (use `timeout`).
