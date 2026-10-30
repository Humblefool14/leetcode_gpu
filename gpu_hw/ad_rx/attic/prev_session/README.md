# ad_rx — rasterizer RTL

The atg_rx rasterizer, renamed `ad_rx_*`, rebuilt as parameterized SystemVerilog with
every constant in `rtl/ad_rx_pkg.sv` (names of at most 7 characters, no `` `define``).
The design document lives in the "ad_rx — Rasterizer Design & Verification Spec" doc.

```
rtl/        ad_rx_pkg.sv + 17 modules (ad_rx_setup_uc.sv is generated)
fpv/        run_fpv.py -> one .sby per module (SymbiYosys, prove + cover [+ bmc])
sim/        Python reference models, vector generators, Verilator testbenches
tools/      lint_pkg.py (naming rules), gen_setup_uc.py (setup micro-program)
```

Run:

```
python3 tools/lint_pkg.py          # naming rules
bash sim/run_all.sh                # reference-model simulations (Verilator 5)
python3 fpv/run_fpv.py             # all proofs   (sby or yowasp-sby, cvc5)
python3 fpv/run_fpv.py ad_rx_hiz   # one module
python3 tools/gen_setup_uc.py      # after editing the micro-program
```

Tool subset: the RTL reads in open-source Yosys 0.70 (package-scoped names, no
wildcard import, no `return`), Verilator 5 and commercial simulators.  Properties are
immediate assert/assume/cover under `` `ifdef FORMAL`` (JasperGold reads them too).
Multiplier-heavy equalities are under `` `ifdef FPV_BMC`` and run as bounded checks.
