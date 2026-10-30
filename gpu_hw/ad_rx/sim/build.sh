#!/bin/sh
# build the end-to-end simulation (Icarus); extra files (debug monitors) as arguments
R=../rtl
iverilog -g2012 -I$R -o rx.vvp $R/ad_rx_pkg.sv $R/ad_rx_fadd.sv $R/ad_rx_fmul.sv $R/ad_rx_fdiv.sv \
  $R/ad_rx_f2fix.sv $R/ad_rx_i2f.sv $R/ad_rx_f2un.sv $R/ad_rx_order.sv $R/ad_rx_cov.sv $R/ad_rx_coarse.sv \
  $R/ad_rx_hiz.sv $R/ad_rx_cpoly.sv $R/ad_rx_clip.sv $R/ad_rx_edge.sv $R/ad_rx_setup.sv $R/ad_rx_scan.sv \
  $R/ad_rx_bary.sv $R/ad_rx_frag.sv $R/ad_rx_state.sv $R/ad_rx.sv ad_rx_tb.sv "$@" 2>&1 | grep -iE "error" 
exit 0
