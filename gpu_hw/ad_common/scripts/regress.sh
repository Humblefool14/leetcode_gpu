#!/usr/bin/env bash
# Every formal task of the common primitives (tasks ending in _open are skipped), then the
# common simulation tests.  Writes build/regress.txt.  FTIMEOUT: seconds per formal task (900).
cd "$(dirname "$0")/.." || exit 1
mkdir -p build; out=build/regress.txt; : > $out; fail=0
for d in formal/*/; do b=$(basename "$d"); [ -f "$d/$b.sby" ] || continue
  for t in $(awk '/^\[tasks\]/{f=1;next}/^\[/{f=0}f&&NF' "$d/$b.sby"); do
    case $t in *_open) echo "FORMAL $b $t OPEN (skipped)" | tee -a $out; continue;; esac
    t0=$(date +%s)
    r=$(timeout "${FTIMEOUT:-900}" scripts/run_formal.sh "$b" "$t" 2>&1 | tail -1)
    [ -z "$r" ] && r="FORMAL $b $t TIMEOUT"
    echo "$r ($(( $(date +%s) - t0 ))s)" | tee -a $out
    case $r in *PASS) ;; *) fail=1;; esac
  done
done
for f in sim/tb/*_tb.v; do t=$(basename $f .v)
  if scripts/run_sim.sh $t > build/sim_$t.log 2>&1 && grep -q "^PASS ${t%_tb}$" build/sim_$t.log; then r=PASS; else r=FAIL; fail=1; fi
  echo "SIM $t $r" | tee -a $out
done
echo "--- PASS: $(grep -c ' PASS' $out)  OPEN: $(grep -c OPEN $out)  other: $(grep -vc ' PASS\|OPEN' $out)"
exit $fail
