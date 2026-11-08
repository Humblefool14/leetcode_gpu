# Common brief for every ad_su module builder

Repository: /home/claude/ad_su (the GPU's shader unit, "SU").  Several builders work in parallel in the
same tree: ONLY create/modify the files of your own blocks.  Never edit rtl/include/, scripts/,
sim/common/, formal/common/, tools/gsi1fp.py, tools/gsi1model.py, docs/CONVENTIONS.md, or another
builder's files; if something shared is wrong, work around it and report it.

Read first: docs/CONVENTIONS.md (style, layout, running sim/formal — follow it exactly),
rtl/include/ad_su_uop.vh (the micro-op and warp-info word), rtl/include/ad_su_state.vh,
tools/gsi1fp.py (bit-exact arithmetic reference), tools/gsi1model.py (ISA-level model), spec/gpu/su/ad_su.md
(the top: how your blocks are wired) and your own specs in spec/gpu/su/.  The specs were renamed
atg_→ad_ (the RTL path in a spec header says rtl/gpu/su/; use rtl/su/).

Tools: iverilog -g2012, verilator --lint-only, scripts/run_sim.sh <tb>, scripts/run_formal.sh <block>
(yowasp-sby; engines abc bmc3 / abc pdr / smtbmc z3).  The machine has 2 CPUs shared with 7 other
builders: keep each simulation under ~2 minutes and each formal task under ~10 minutes (use `timeout`),
and do not run more than one formal job at a time.

Interfaces fixed for every builder (so the pieces fit at integration):
- Execution bus from ad_su_opd: x_valid, x_warp, x_grp, x_last, x_sbe, x_pc, x_uop[107:0] (UOP_W = 108,
  AD_UOP_W; the specs' 104 is stale), x_a/x_b/x_c (NPHYS*32), x_mask (2*NPHYS: [NPHYS-1:0] EXEC,
  [2*NPHYS-1:NPHYS] side-effect lanes), x_info (32), and each unit's x_ready.  A group is TAKEN by a unit
  when x_valid && x_uop[AD_UOP_UNIT+:4] == its unit && its x_ready.  x_ready may be 1 when idle even
  if the group is another unit's.
- Short units (alu, fpu, pk, lane, lda, exec): s_valid/s_warp/s_grp/s_rd/s_data/s_lanes exactly
  SHORT_LAT (default 6) cycles after the group was taken; s_lanes = EXEC lanes of the group;
  s_valid only when the uop writes rd (AD_UOP_WRD).
- Long units (lsu, lds, cbank, tex, xu, div): l_* beats with l_ready back-pressure; l_last on the
  instruction's last beat (also l_wr = 0 completions); l_sbe = x_sbe of the instruction; l_cls = the
  uop's class.
- Default parameters: NPHYS 8, NWARPS 4, WARP_W 2, GRP_W 2, SBE_W 2, SB_ENTRIES 4, NREGS 32,
  SHORT_LAT 6, LINE_BYTES 32, LINE_SHIFT 5, ADDR_W 32.  Support NPHYS 4/8/16/32 (GRP_W =
  log2(32/NPHYS), 1 for NPHYS 32) where the spec says so, and test at least NPHYS 4 and 8.
- AMB client ports exactly as the ROP's (req_valid/ready, write, line, be, wdata, tag; rsp_valid, write,
  tag, rdata, error; payload held until ready; one response per request, no back-pressure).  Behavioural
  memory: sim/common/ad_amb_mem.v (in order, random latency/ready; backdoor mem[]),
  sim/common/ad_amb_mem_ooo.v (reads may overtake writes).  Formal: formal/common/ad_amb_client_props.sv.

Deliverables per block: RTL split into leaf IPs (one job each), a Python reference (reuse gsi1fp.py /
gsi1model.py where they cover the behaviour), a self-checking testbench printing the spec's §8 PASS
lines (ad_ prefix) then `PASS <tb name without _tb>`, a formal dir per block and per leaf with tasks
`bmc` and `prove` (record engine and depth; if a proof does not close, keep bmc at a meaningful depth
and say why), and one mutation check (RTL broken on purpose → TB and a formal check FAIL; restore).
Append to each spec's §10 a dated status entry with every `ASSUMPTION:` you made.

Final report (your last message, concise): files; each TB's PASS/FAIL lines; each formal task with
engine, depth and result; assumptions; limitations; anything wrong in shared files.
