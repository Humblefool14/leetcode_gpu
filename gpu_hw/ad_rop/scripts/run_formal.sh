#!/usr/bin/env bash
# run_formal.sh <block> [task...]
# Runs formal/<block>/<block>.sby with SymbiYosys (yowasp-sby, or sby when on PATH).
# Prints one line per task: "FORMAL <block> <task> PASS|FAIL|ERROR|TIMEOUT".
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE/../formal/$1"
SBY="yowasp-sby --yosys yowasp-yosys --witness yowasp-yosys-witness --smtbmc yowasp-yosys-smtbmc --abc $HERE/abc_compat.sh"
blk=$1; shift
tasks=${*:-$(awk '/^\[tasks\]/{f=1;next} /^\[/{f=0} f&&NF{print $1}' "$blk.sby")}
rc=0
for t in $tasks; do
  $SBY -f "$blk.sby" $t > /dev/null 2>&1
  st=$(grep -o "DONE ([A-Z]*" "${blk}_$t/logfile.txt" 2>/dev/null | tail -1 | sed 's/DONE (//')
  # ABC finds a counterexample but the witness conversion may crash: report FAIL
  if [ "$st" != "PASS" ] && grep -q "returned FAIL" "${blk}_$t/logfile.txt" 2>/dev/null; then st=FAIL; fi
  echo "FORMAL $blk $t ${st:-ERROR}"
  [ "$st" = "PASS" ] || rc=1
done
exit $rc
