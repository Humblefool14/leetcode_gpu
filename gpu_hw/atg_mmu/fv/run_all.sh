#!/bin/sh
# Regenerate .sby files and run every formal target; prints one line per task.
# usage: ./run_all.sh [target ...]   (default: all)
cd "$(dirname "$0")"
python3 mk.py
T="${*:-arb ifc flt walker l1 l2 top}"
for t in $T; do
  for k in prove cover; do
    yowasp-sby -f $t.sby $k > /dev/null 2>&1
    printf '%-7s %-6s %s\n' "$t" "$k" "$(tail -1 ${t}_${k}/status 2>/dev/null || grep -o 'DONE ([A-Z]*' ${t}_${k}/logfile.txt | tail -1)"
  done
done
