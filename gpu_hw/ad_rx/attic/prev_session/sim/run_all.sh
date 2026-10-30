#!/usr/bin/env bash
# Reference-model simulations of ad_rx (Verilator 5).  Run from the repo root.
set -e
V="verilator --binary -j 2 --timing -Wno-fatal -Wno-lint -Wno-style"
ALL="rtl/ad_rx_pkg.sv $(ls rtl/*.sv | grep -v pkg | tr '\n' ' ')"
mkdir -p build sim/vec
python3 tools/lint_pkg.py

python3 sim/gen_fp_vec.py 20000
$V --top-module ad_rx_fp_tb -Mdir build/fp $ALL sim/tb/ad_rx_fp_tb.sv >/dev/null
./build/fp/Vad_rx_fp_tb | grep -E "PASS|FAIL"

python3 sim/gen_edge_vec.py 3000
$V --top-module ad_rx_edge_tb -Mdir build/edge $ALL sim/tb/ad_rx_edge_tb.sv >/dev/null
./build/edge/Vad_rx_edge_tb | grep -E "PASS|FAIL"

python3 sim/gen_cpoly_vec.py 400
$V --top-module ad_rx_cpoly_tb -Mdir build/cpoly $ALL sim/tb/ad_rx_cpoly_tb.sv >/dev/null
./build/cpoly/Vad_rx_cpoly_tb | grep -E "PASS|FAIL"

$V --top-module ad_rx_sys_tb -Mdir build/sys $ALL sim/tb/ad_rx_sys_tb.sv >/dev/null
for ms in 0 1; do
  python3 sim/sys_test.py gen $ms 40 >/dev/null
  ./build/sys/Vad_rx_sys_tb >/dev/null
  python3 sim/sys_test.py check
done
