#!/usr/bin/env bash
# regress.sh [sim|formal|all]  -- regenerates vectors, runs every testbench in
# sim/tb (+ variants) and every formal task in formal/*, writes build/regress.txt.
# Formal tasks run 2 at a time with a per-task timeout (FTIMEOUT seconds, default 1500).
set -uo pipefail
cd "$(dirname "$0")/.."
what=${1:-all}
mkdir -p build
out=build/regress.txt; : > $out
FTIMEOUT=${FTIMEOUT:-1500}

if [ "$what" != formal ]; then
  for g in tools/gen_*_vectors.py; do python3 -I "$g" > /dev/null || echo "GEN FAIL $g" | tee -a $out; done
  run() {  # name, extra args...
    local tb=$1; shift
    local t0=$(date +%s)
    local tag=$(echo "$@" | md5sum | cut -c1-6) lbl="$*"
    case "$lbl" in *AD_REAL_BLEND*) lbl="-DAD_REAL_BLEND (+ blend RTL)";; esac
    if timeout 900 scripts/run_sim.sh "$tb" "$@" > build/sim_${tb}_$tag.log 2>&1; then r=PASS; else r=FAIL; fi
    printf "SIM    %-24s %-30s %s (%ss)\n" "$tb" "$lbl" "$r" $(( $(date +%s) - t0 )) | tee -a $out
  }
  for f in sim/tb/*_tb.v; do run $(basename $f .v); done
  run ad_rop_ds_tb -Pad_rop_ds_tb.LB=64
  run ad_rop_sys_tb -Pad_rop_sys_tb.LB=64
  run ad_rop_sys_tb -DAD_OOO_MEM
  RB="-DAD_REAL_BLEND rtl/rop/ad_rop_blend.v $(ls rtl/rop/blend/*.v | tr '\n' ' ') rtl/common/ad_rop_div255.v"
  run ad_rop_wb_tb $RB
  run ad_rop_mrt_tb $RB
fi

if [ "$what" != sim ]; then
  jobs_list=()
  for d in formal/*/; do b=$(basename $d); [ -f formal/$b/$b.sby ] || continue
    for t in $(awk '/^\[tasks\]/{f=1;next} /^\[/{f=0} f&&NF{print $1}' formal/$b/$b.sby); do
      case $t in *_open) printf "FORMAL %-24s %-30s %s\n" $b $t "OPEN (known not to close; not run)" >> $out;; *) jobs_list+=("$b $t");; esac
    done
  done
  printf "%s\n" "${jobs_list[@]}" | xargs -P 2 -L 1 bash -c 't0=$(date +%s); r=$(timeout '"$FTIMEOUT"' scripts/run_formal.sh $0 $1 | awk "{print \$4}"); printf "FORMAL %-24s %-30s %s (%ss)\n" $0 $1 "${r:-TIMEOUT}" $(( $(date +%s) - t0 ))' | tee -a $out
fi
echo "---"; grep -c " PASS " $out | xargs echo "PASS:"; grep -v " PASS " $out | grep -E "^(SIM|FORMAL|GEN)" || echo "no failures"
