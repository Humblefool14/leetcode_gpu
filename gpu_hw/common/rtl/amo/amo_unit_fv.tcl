# =============================================================================
# amo_unit_fv.tcl  --  JasperGold FPV for amo_unit
#   jg amo_unit_fv.tcl
# Bounded proof to depth 24, plus full proof attempts by the default engines.
# =============================================================================
clear -all

# FORMAL also enables the DUT's own embedded SVA (incl. the s_eventually
# liveness check and its rsp_rdy fairness assumption).
analyze -sv12 +define+FORMAL amo_unit.sv
analyze -sv12 amo_unit_fv.sv
elaborate -top amo_unit_fv

clock clk
reset -expression {!rst_n}

# --- bounded proof settings --------------------------------------------------
set_max_trace_length 24
set_prove_per_property_time_limit 10m
set_engine_mode {Hp Ht N B}     ;# full-proof engines first, B/BMC for bounds

# --- run ---------------------------------------------------------------------
prove -all

# Bounded-only alternative (pure BMC to depth 24):
#   prove -all -engine_mode B -bg ; or: prove -property {*} -bound 24

report -summary
# Expect: every assert 'proven' (or 'undetermined, bounded 24' if an engine
# times out), every cover 'covered', no 'cex'.
