# Common brief for every ad_vf module builder

Repository: /home/claude/ad_vf (the GPU's vertex fetcher, "VF").  Three builders work in parallel in the
same tree: ONLY create/modify the files of your own blocks.  Never edit rtl/include/, scripts/,
sim/common/, formal/common/, tools/fmtmodel.py, docs/CONVENTIONS.md, or another builder's files; if
something shared is wrong, work around it and report it.

Read first: docs/CONVENTIONS.md (style, layout, running sim/formal: follow it exactly),
rtl/include/ad_vf_state.vh (STATE indices and fields: many are ASSUMED because the design document's
STATE table was not provided; use the macros, never literals), tools/fmtmodel.py (bit-exact reference of
every attribute format), spec/gpu/vf/ad_vf.md (the top: how your blocks are wired) and your own specs in
spec/gpu/vf/.  The specs were renamed atg_ -> ad_ (a spec's RTL path rtl/gpu/vf/ means rtl/vf/).

Tools: iverilog -g2012, scripts/run_sim.sh <tb>, scripts/run_formal.sh <block> [task] (yowasp-sby;
engines abc bmc3 / abc pdr / smtbmc z3).  The machine has 2 CPUs shared with the other builders: keep
each simulation under ~2 minutes and each formal task under ~10 minutes (use `timeout`), and never run
more than one formal job at a time.

Facts fixed for every builder (so the pieces fit at integration):
- Ports and parameters exactly as each spec's sections 2 and 3 (ADDR_W 32, LINE_BYTES 32, LINE_SHIFT 5
  defaults; support LINE_BYTES 64 where the spec says so and test both line sizes for AMB clients).
- STATE: snoop st_we/st_idx/st_wdata and keep the words of your range (reset 0).  The CP does not write
  the VF's STATE while the VF is busy (ad_vf.md section 10), so a block may read its STATE registers at any
  time during a draw.  PROVOKING (RX STATE 0x05D) is also snooped by ad_vf_asm.
- CAPS[30] (VkFormat path, ATTR_LIMIT, af_oob, prim kind) is treated as always present.
- Attribute enable: ATTR_DST[k] != 0 (whole word).  Format: ATTR_DST[31:24] != 0 -> that VkFormat,
  else ATTR_DESC[19:16] legacy format.  tools/fmtmodel.py info()/convert() define sizes, component
  counts, kinds and every converted word.
- AMB client ports as the ROP/SU (req_valid/ready, write, line, be, wdata, tag; rsp_valid, write, tag,
  rdata, error; payload held until ready; one response per request, no back-pressure; responses may come
  in any order only if the memory is the out-of-order model).  ad_vf_index uses tag bit 0 only;
  ad_vf_fetch tags {3'b0, stream[1:0], entry[2:0]}.  rtl/vf/ad_amb_mux.v (N = 2) merges them in ad_vf
  (index = requester 0, fetch = 1).  Behavioural memory: sim/common/ad_amb_mem.v (in order, random
  latency/ready; backdoor mem[]) and sim/common/ad_amb_mem_ooo.v.  Formal: formal/common/ad_amb_client_props.sv.
- Index stream iv_*, warp vertices vb_*, attributes af_*, register writes vl_we/vl_reg/vl_lane/vl_data,
  conv_done, vl_req/vl_gnt/vl_ptbase/vl_go/vl_mask, prim_*: exactly as the specs' port tables.

Deliverables per block: RTL split into leaf IPs (one job each, roughly 30-300 lines, in rtl/vf/<group>/),
a Python reference (reuse tools/fmtmodel.py where it covers the behaviour), a self-checking testbench
printing the spec's section 8 PASS lines (ad_ prefix) then `PASS <tb name without _tb>`, a formal dir per
block and per leaf with tasks `bmc` and `prove` (record engine and depth; if a proof does not close, keep
bmc at a meaningful depth, rename the task prove_open and say why), and one mutation check (RTL broken on
purpose under an `ifdef MUT_*` -> TB and a formal check FAIL; restore).  Append to each spec's section 10
a dated (2026-11-09) status entry with every `ASSUMPTION:` you made.

Final report (your last message, concise): files; each TB's PASS/FAIL lines; each formal task with
engine, depth and result; assumptions; limitations; anything wrong in shared files.
