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
  for g in tools/gen_*_vectors.py; do case $g in *gen_ad_su_exec_vectors.py) continue;; esac; python3 -I "$g" > /dev/null || echo "GEN FAIL $g" | tee -a $out; done   # exec vectors are per-mode files, checked in
  run() {  # name, extra args...
    local tb=$1; shift
    local t0=$(date +%s)
    local tag=$(echo "$@" | md5sum | cut -c1-6) lbl="$*"
    case "$lbl" in *AD_REAL_BLEND*) lbl="-DAD_REAL_BLEND (+ blend RTL)";; esac
    if timeout 900 scripts/run_sim.sh "$tb" "$@" > build/sim_${tb}_$tag.log 2>&1; then r=PASS; else r=FAIL; fi
    printf "SIM    %-24s %-30s %s (%ss)\n" "$tb" "$lbl" "$r" $(( $(date +%s) - t0 )) | tee -a $out
  }
  for f in sim/tb/*_tb.v; do t=$(basename $f .v); [ "$t" = ad_su_tb ] && continue; run $t; done
  # the whole SU: every program at NPHYS 4, 8, 16, 32 against tools/gsi1model.py
  for p in alu fpu mem ctrl xu_div pk sub; do python3 -I tools/gen_su_sys.py $p $( [ $p = pk ] && echo --packed ) $( [ $p = sub ] && echo --subgroup ) > /dev/null; done
  for np in 4 8 16 32; do for p in alu fpu mem ctrl xu_div pk sub; do
    X=""; [ $p = pk ] && X="-Pad_su_tb.PACKED=1"; [ $p = sub ] && X="-Pad_su_tb.SUBGROUP=1"
    t0=$(date +%s)
    if PLUSARGS=+prog=$p timeout 900 scripts/run_sim.sh ad_su_tb -Pad_su_tb.NPHYS=$np $X > build/sim_ad_su_${p}_$np.log 2>&1; then r=PASS; else r=FAIL; fi
    printf "SIM    %-24s %-30s %s (%ss)\n" ad_su_tb "$p NPHYS $np" "$r" $(( $(date +%s) - t0 )) | tee -a $out
  done; done
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
