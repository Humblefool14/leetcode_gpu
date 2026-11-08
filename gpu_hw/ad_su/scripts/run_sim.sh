#!/usr/bin/env bash
# run_sim.sh <tb_name> [extra iverilog args]
# Compiles sim/tb/<tb_name>.v with every file listed in sim/tb/<tb_name>.f
# (one path per line, relative to the repo root; # comments allowed) and runs it
# from the repo root.  Exit status 1 when the log has a FAIL line or no final PASS.
set -euo pipefail
cd "$(dirname "$0")/.."
tb=$1; shift || true
mkdir -p build/sim
files=$(grep -v '^\s*#' "sim/tb/$tb.f" | grep -v '^\s*$' || true)
iverilog -g2012 -Wall -Wno-timescale -I rtl/include -o "build/sim/$tb.vvp" -s "$tb" "$@" $files "sim/tb/$tb.v" 2> "build/sim/$tb.build.log" || { cat "build/sim/$tb.build.log"; exit 1; }
grep -E "error|Error" "build/sim/$tb.build.log" && exit 1 || true
vvp -n "build/sim/$tb.vvp" ${PLUSARGS:-} | tee "build/sim/$tb.log"
if grep -q "^FAIL" "build/sim/$tb.log" || ! grep -q "^PASS ${tb%_tb}$" "build/sim/$tb.log"; then exit 1; fi
