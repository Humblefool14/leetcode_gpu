#!/usr/bin/env bash
# Open-source FPV flow for amo_unit (what SymbiYosys runs under the hood).
#   ./run_fv.sh [depth]            default depth 24
# Runs: BMC (bounded proof) -> cover (non-vacuity) -> k-induction (full proof).
# Needs: python3, yosys >= 0.33, yosys-smtbmc, z3 (or SOLVER=yices / bitwuzla).
set -euo pipefail
DEPTH=${1:-24}
SOLVER=${SOLVER:-z3}
OUT=${OUT:-fv_out}
mkdir -p "$OUT"

# --- Yosys syntax shim -------------------------------------------------------
# Yosys' open-source front end lacks module-header package import, 'inside'
# and 'return'.  Rewrite them mechanically (same logic) into $OUT/amo_unit_yosys.sv.
# JasperGold / VC Formal read amo_unit.sv directly and do not need this.
python3 - "$OUT/amo_unit_yosys.sv" <<'EOF'
import re, sys
s = open('amo_unit.sv').read()
s = re.sub(r"package amo_pkg;.*?endpackage\n", "", s, flags=re.S)
s = s.replace("module amo_unit\n  import amo_pkg::*;\n#(", "module amo_unit\n#(")
s = re.sub(r"\bop_e\b", "logic [3:0]", s)
lp = ("  localparam logic [3:0] OP_LD=4'd0, OP_ST=4'd1, AMO_SWAP=4'd2, AMO_ADD=4'd3, AMO_AND=4'd4,\n"
      "    AMO_OR=4'd5, AMO_XOR=4'd6, AMO_MIN=4'd7, AMO_MAX=4'd8, AMO_MINU=4'd9, AMO_MAXU=4'd10, AMO_CAS=4'd11;\n")
anchor = "  // ---------------------------------------------------------------------------\n  // Parameter sanity checks"
assert anchor in s, "shim anchor not found - update run_fv.sh"
s = s.replace(anchor, lp + anchor, 1)
s = re.sub(r"return \(op inside \{.*?\}\);", "return (op <= 4'd11);", s, flags=re.S)
s = s.replace("op_is_legal(op) && (op != OP_LD)", "(op <= 4'd11) && (op != OP_LD)")
s = re.sub(r"function automatic (logic(?: \[[^\]]+\])?) (\w+)\(.*?endfunction",
           lambda m: re.sub(r"\breturn\b", m.group(2) + " =", m.group(0)), s, flags=re.S)
open(sys.argv[1], 'w').write(s)
EOF

# --- Elaborate to SMT2 -------------------------------------------------------
yosys -q -l "$OUT/yosys.log" -p "
  read_verilog -sv -formal -D SYNTHESIS $OUT/amo_unit_yosys.sv
  read_verilog -sv -formal amo_unit_fv.sv
  prep -top amo_unit_fv
  async2sync
  dffunmap
  write_smt2 -wires $OUT/model.smt2
" 2> >(grep -v translate_off >&2)

run() {  # name, extra smtbmc args
  local name=$1; shift
  yosys-smtbmc -s "$SOLVER" --presat "$@" "$OUT/model.smt2" > "$OUT/$name.log" 2>&1 || true
  printf "%-10s %s\n" "$name" "$(grep -oE 'Status: \w+' "$OUT/$name.log" | tail -1)"
  grep -E "Assert failed|Temporal induction failed" "$OUT/$name.log" | sed 's/^.*  //' || true
}

echo "depth $DEPTH, solver $SOLVER"
run bmc    -t "$DEPTH" --dump-vcd "$OUT/bmc_cex.vcd"
run cover  -c -t "$DEPTH" --dump-vcd "$OUT/cover_%.vcd"
echo "  covers reached: $(grep -c 'Reached cover statement' "$OUT/cover.log" || true)," \
     "unreached: $(grep -c 'Unreached cover statement' "$OUT/cover.log" || true)"
grep -E "Unreached cover statement" "$OUT/cover.log" | sed 's/^.*  /  /' || true
run induct -i -t "$DEPTH" --dump-vcd "$OUT/induct_cti.vcd"
