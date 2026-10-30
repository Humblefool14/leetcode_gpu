#!/bin/sh
# Tests of the fixed legacy blocks (Verilator 5, Python 3).
#   rc_tb: rasterizer_core vs an exact pixel-centre / top-left model (320 triangles)
#   ez_tb: early_z_unit directed checks T1 (RAW hazard), T2 (partial tile), T3 (full tile)
set -e
cd "$(dirname "$0")"
python3 rc_check.py gen
rm -rf obj_dir
verilator --binary -j 2 --assert -Wno-fatal -Wno-WIDTH -Wno-lint --top-module rc_tb ../rasterizer_core.sv rc_tb.sv -o rc_sim > build.log 2>&1
./obj_dir/rc_sim > /dev/null
python3 rc_check.py check
rm -rf obj_dir
verilator --binary -j 2 --assert -Wno-fatal -Wno-WIDTH -Wno-lint --top-module ez_tb ../early_z_unit.sv ez_tb.sv -o ez_sim > ez_build.log 2>&1
./obj_dir/ez_sim | grep -E "T[123]|early_z_unit"
