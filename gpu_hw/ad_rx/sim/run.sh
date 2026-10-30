#!/bin/sh
# ad_rx simulations (Icarus Verilog 12, Python 3 + numpy).
#   1. fp units bit-exact against tools/fpref.py (20000 vectors)
#   2. end to end (state -> clip -> setup -> scan, direct path) against tools/rx_ref.py
set -e
cd "$(dirname "$0")"
R=../rtl
python3 ../tools/fpref.py 20000 fp_vec.txt
iverilog -g2012 -o fp.vvp $R/ad_rx_pkg.sv $R/ad_rx_fadd.sv $R/ad_rx_fmul.sv $R/ad_rx_fdiv.sv ad_rx_fp_tb.sv 2>/dev/null
vvp -n fp.vvp | grep -E "PASS|FAIL|MISMATCH"
python3 ../tools/rx_ref.py gen
./build.sh
vvp -n rx.vvp | grep -E "DONE|TIMEOUT"
python3 ../tools/rx_ref.py check
# 3. the same primitives on the warp path (HAS_SU = 1): pixels rebuilt from r4 / r5 and fl_info
R=../rtl
iverilog -g2012 -I$R -o rxw.vvp $R/ad_rx_pkg.sv $R/ad_rx_fadd.sv $R/ad_rx_fmul.sv $R/ad_rx_fdiv.sv \
  $R/ad_rx_f2fix.sv $R/ad_rx_i2f.sv $R/ad_rx_f2un.sv $R/ad_rx_order.sv $R/ad_rx_cov.sv $R/ad_rx_coarse.sv \
  $R/ad_rx_hiz.sv $R/ad_rx_cpoly.sv $R/ad_rx_clip.sv $R/ad_rx_edge.sv $R/ad_rx_setup.sv $R/ad_rx_scan.sv \
  $R/ad_rx_bary.sv $R/ad_rx_frag.sv $R/ad_rx_state.sv $R/ad_rx.sv ad_rx_warp_tb.sv 2>/dev/null
vvp -n rxw.vvp | grep -E "DONE|warp checks|TIMEOUT"
python3 ../tools/rx_ref.py check
