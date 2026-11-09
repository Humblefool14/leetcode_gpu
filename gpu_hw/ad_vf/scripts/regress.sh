#!/usr/bin/env bash
# regress.sh [sim|formal|all]  -- regenerates vectors, runs every testbench in
# sim/tb (+ variants) and every formal task in formal/*, writes build/regress.txt.
# Formal tasks run 2 at a time with a per-task timeout (FTIMEOUT seconds, default 1500).
set -uo pipefail
cd "$(dirname "$0")/.."
what=${1:-all}
mkdir -p build
out=${REGRESS_OUT:-build/regress.txt}; : > $out
FTIMEOUT=${FTIMEOUT:-1500}

if [ "$what" != formal ]; then
  for g in tools/gen_*_vectors.py; do python3 -I "$g" > /dev/null || echo "GEN FAIL $g" | tee -a $out; done
  run() {  # name, extra args...
    local tb=$1; shift
    local t0=$(date +%s)
    local tag=$(echo "$@" | md5sum | cut -c1-6) lbl="$*"
    if timeout 900 scripts/run_sim.sh "$tb" "$@" > build/sim_${tb}_$tag.log 2>&1; then r=PASS; else r=FAIL; fi
    printf "SIM    %-24s %-30s %s (%ss)\n" "$tb" "$lbl" "$r" $(( $(date +%s) - t0 )) | tee -a $out
  }
  for f in sim/tb/*_tb.v; do t=$(basename $f .v); [ "$t" = ad_vf_tb ] && continue; run $t; done
  # the whole VF: every scene, both line sizes, two latency seeds, against tools/vf_sys_model.py
  if [ -f tools/gen_vf_sys.py ]; then
    for sc in $(python3 -I tools/gen_vf_sys.py --list); do
      python3 -I tools/gen_vf_sys.py $sc > /dev/null || echo "GEN FAIL vf_sys $sc" | tee -a $out
      for lb in 32 64; do for sd in 7 11; do
        X="-Pad_vf_tb.LINE_BYTES=$lb -Pad_vf_tb.LINE_SHIFT=$([ $lb = 32 ] && echo 5 || echo 6)"; X="$X -Pad_vf_tb.SEED=$sd"
        t0=$(date +%s)
        if PLUSARGS=+scene=$sc timeout 900 scripts/run_sim.sh ad_vf_tb $X > build/sim_ad_vf_${sc}_${lb}_$sd.log 2>&1; then r=PASS; else r=FAIL; fi
        printf "SIM    %-24s %-30s %s (%ss)\n" ad_vf_tb "$sc line $lb seed $sd" "$r" $(( $(date +%s) - t0 )) | tee -a $out
      done; done
    done
  fi
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
