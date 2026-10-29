# atg_mmu — Amaterrace GPU MMU (GHCI 1.0 §11.2 / §11.6)

```
rtl/atg_mmu_pkg.vh     configuration package (every define is 7 chars: AMU_xxx)
rtl/atg_mmu.v          top: L1s, arbiter, L2, walker, root table, flush sequencer, CP registers
rtl/atg_tlb_l1.v       per-client L1 TLB (fully associative, 1-cycle hit)
rtl/atg_tlb_l2.v       shared L2 TLB (set associative, 2-stage, hit-under-miss)
rtl/atg_mmu_walker.v   2-level page-table walker, AXI4 64-bit read master
rtl/atg_mmu_arb.v      round-robin miss arbiter
rtl/atg_mmu_ifc.v      in-flight tracker (2 epochs, thermometer counters)
rtl/atg_mmu_flt.v      first-fault capture
rtl/atg_mmu_ram.v      1R1W synchronous RAM (L2 tag/data)
fv/fv_*.sv             formal harnesses (environment, port checks, covers)
fv/mk.py, run_all.sh   generate .sby files and run every target
lint.ys, lintf.ys      Yosys lint (synthesis view / formal view)
```

Verilog-2005 RTL, single clock `clk`, synchronous active-low reset `rst_n`.
Properties are embedded in each RTL file under `ifdef FORMAL`; the
AMU_FVA / AMU_FVI / AMU_FV1 / AMU_FV2 macros (set by the .sby files) turn a
module's interface rules into assumptions when it is proved on its own.

Run: `cd fv && ./run_all.sh` (needs SymbiYosys + Yosys + z3).
`topw.sby` task `bmc` is the production-width bounded check of the top.
