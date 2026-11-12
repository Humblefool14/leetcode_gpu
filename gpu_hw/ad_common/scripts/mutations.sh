#!/usr/bin/env bash
# Each primitive's mutation must make its harness fail (one small configuration each).
cd "$(dirname "$0")/.." || exit 1
X="$PWD/scripts/abc_compat.sh"; bad=0
check() {  # prim task define
  local p=$1 t=$2 d=$3
  sed "s/^read -formal /read -formal -D$d /" formal/$p/$p.sby > formal/$p/mut.sby
  local out; out=$(cd formal/$p && timeout 900 yowasp-sby --yosys yowasp-yosys --witness yowasp-yosys-witness \
      --smtbmc yowasp-yosys-smtbmc --abc "$X" -f mut.sby "$t" 2>&1)
  rm -rf formal/$p/mut.sby formal/$p/mut_*
  if echo "$out" | grep -q "Status returned by engine: FAIL\|DONE (FAIL"; then echo "MUT $p $d: caught"
  else echo "MUT $p $d: NOT caught"; bad=1; fi
}
check ad_fifo      bmc_w8_depth4          MUT_FIFO_NOFULL   # overflow needs DEPTH+1 pushes: BMC
check ad_delay     prove_n6_w4_di         MUT_DELAY_SHORT
check ad_skid      prove_w4_di            MUT_SKID_LOSS
check ad_ram_1r1w  prove_dw4_aw3_depth8_di MUT_RAM_WFIRST
check ad_ram_tdp   prove_depth10_aw4_dw4_di MUT_RAM_TDP_WFIRST
check ad_ram_sp_be prove_depth8_aw3_nbytes2_di MUT_RAM_BE_ALL
check ad_popcount  prove_w32              MUT_POPC_SKIP0
check rr_arbiter   prove_n5               MUT_RR_STUCK
check qos_arbiter  prove_n4_hi_burst2     MUT_QOS_NOCNT
check ad_amb_mux   bmc                    MUT_MUX_NOLOCK
exit $bad
