// =============================================================================
// amo_unit_fv.sv  --  Formal (FPV) harness for amo_unit
//
// Proof strategy
// --------------
//  * Symbolic tracked address: fv_addr is a free input held constant for the
//    whole trace, so every property below is proven for ALL addresses at once,
//    at full AW/DW, without modelling the whole SRAM.  Only mem[fv_addr] is
//    stored (fv_word); reads of any other address return a free value.
//  * fv_word has no reset -> arbitrary initial memory contents.
//  * A second SRAM master ("DMA", port B) may write ANY address at ANY time,
//    constrained only by the lock contract (and no same-edge write collision).
//    This is what makes the atomicity / lock checks meaningful.
//  * End-to-end reference: on every accept the harness records the expected
//    OLD value and expected NEW value (independent spec model, below), then
//    checks the response, the SRAM write, and the final memory contents.
//  * The request side is completely unconstrained: req_* may change at any
//    time and req_op ranges over all 16 encodings (12..15 are illegal and must
//    behave like a load: no write, old value returned, no lock).
//
// Style: immediate assert/assume/cover in clocked blocks, so the same file
// runs in JasperGold, VC Formal and Yosys/SymbiYosys.  Asserts are checked
// only while out of reset.
// =============================================================================
`timescale 1ns/1ps

module amo_unit_fv #(
  parameter int AW  = 16,
  parameter int DW  = 32,
  parameter int IDW = 4
) (
  input  logic           clk,
  input  logic           rst_n,

  // ---- free request / response-ready inputs ----
  input  logic           req_v,
  input  logic [3:0]     req_op_raw,       // all 16 encodings
  input  logic [AW-1:0]  req_addr,
  input  logic [DW-1:0]  req_data,
  input  logic [DW-1:0]  req_cmp,
  input  logic [IDW-1:0] req_id,
  input  logic           rsp_rdy,

  // ---- symbolic tracked address + read data for untracked addresses ----
  input  logic [AW-1:0]  fv_addr,
  input  logic [DW-1:0]  fv_other_rdata,

  // ---- second SRAM master (port B), write-only ----
  input  logic           dma_we,
  input  logic [AW-1:0]  dma_addr,
  input  logic [DW-1:0]  dma_wdata
);

  // ---------------------------------------------------------------------------
  // Op encodings (kept local so the harness is independent of amo_pkg)
  // ---------------------------------------------------------------------------
  localparam logic [3:0] C_LD = 4'd0, C_ST = 4'd1, C_SWAP = 4'd2, C_ADD = 4'd3,
                         C_AND = 4'd4, C_OR = 4'd5, C_XOR = 4'd6, C_MIN = 4'd7,
                         C_MAX = 4'd8, C_MINU = 4'd9, C_MAXU = 4'd10, C_CAS = 4'd11;

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  logic           req_rdy;
  logic           rsp_v;
  logic [DW-1:0]  rsp_data;
  logic [IDW-1:0] rsp_id;
  logic           mem_en, mem_we;
  logic [AW-1:0]  mem_addr;
  logic [DW-1:0]  mem_wdata, mem_rdata;
  logic           lock_o;
  logic [AW-1:0]  lock_addr_o;

  amo_unit #(.AW(AW), .DW(DW), .IDW(IDW)) dut (
    .clk, .rst_n,
    .req_v, .req_rdy,
`ifdef YOSYS
    .req_op      (req_op_raw),
`else
    .req_op      (amo_pkg::op_e'(req_op_raw)),
`endif
    .req_addr, .req_data, .req_cmp, .req_id,
    .rsp_v, .rsp_rdy, .rsp_data, .rsp_id,
    .mem_en, .mem_we, .mem_addr, .mem_wdata, .mem_rdata,
    .lock_o, .lock_addr_o
  );

  // ---------------------------------------------------------------------------
  // SRAM model: only mem[fv_addr] is real.  1-cycle read latency.
  // Port A = AMO unit, port B = DMA (write only).
  // ---------------------------------------------------------------------------
  logic [DW-1:0] fv_word;                 // NO reset: arbitrary initial content

  always @(posedge clk) begin
    if (mem_en && !mem_we)
      mem_rdata <= (mem_addr == fv_addr) ? fv_word : fv_other_rdata;

    if (mem_en && mem_we && mem_addr == fv_addr)
      fv_word <= mem_wdata;
    else if (dma_we && dma_addr == fv_addr)
      fv_word <= dma_wdata;
  end

  // ---------------------------------------------------------------------------
  // Independent spec model of the RMW result
  // ---------------------------------------------------------------------------
  function automatic logic [DW-1:0] spec_new(logic [3:0] op, logic [DW-1:0] old,
                                             logic [DW-1:0] src, logic [DW-1:0] cmp);
    case (op)
      C_ST, C_SWAP: spec_new = src;
      C_ADD :       spec_new = old + src;
      C_AND :       spec_new = old & src;
      C_OR  :       spec_new = old | src;
      C_XOR :       spec_new = old ^ src;
      C_MIN :       spec_new = ($signed(old) <= $signed(src)) ? old : src;
      C_MAX :       spec_new = ($signed(old) >= $signed(src)) ? old : src;
      C_MINU:       spec_new = (old <= src) ? old : src;
      C_MAXU:       spec_new = (old >= src) ? old : src;
      C_CAS :       spec_new = (old == cmp) ? src : old;
      default:      spec_new = old;          // LD and illegal ops: no change
    endcase
  endfunction

  function automatic logic is_rmw(logic [3:0] op);   // ops that must be atomic
    is_rmw = (op >= C_SWAP) && (op <= C_CAS);
  endfunction

  // ---------------------------------------------------------------------------
  // Transaction tracker (black-box view of the DUT)
  //   c0 = accept cycle, c1 = first cycle after accept (t_age == 0), c2 ...
  // ---------------------------------------------------------------------------
  wire accept   = req_v && req_rdy;
  wire acc_hit  = accept && (req_addr == fv_addr);
  wire acc_rmw  = accept && is_rmw(req_op_raw);
  wire dma_hit  = dma_we && (dma_addr == fv_addr);

  logic           f_past_valid;
  logic           t_busy;          // accepted, response not yet consumed
  logic [1:0]     t_age;           // cycles since accept (saturating)
  logic [3:0]     t_op;
  logic           t_hit;           // request targeted fv_addr
  logic [IDW-1:0] t_id;
  logic [DW-1:0]  t_old;           // expected rsp_data
  logic [DW-1:0]  t_new;           // expected mem[fv_addr] after the op
  logic [DW-1:0]  t_cmp;

  always @(posedge clk) begin
    if (!rst_n) begin
      f_past_valid <= 1'b0;
      t_busy       <= 1'b0;
      t_age        <= 2'd0;
    end else begin
      f_past_valid <= 1'b1;
      if (accept) begin
        t_busy <= 1'b1;
        t_age  <= 2'd0;
        t_op   <= req_op_raw;
        t_hit  <= (req_addr == fv_addr);
        t_id   <= req_id;
        t_cmp  <= req_cmp;
        t_old  <= (req_op_raw == C_ST) ? '0 : fv_word;
        t_new  <= spec_new(req_op_raw, fv_word, req_data, req_cmp);
      end else if (t_busy) begin
        if (t_age != 2'd3) t_age <= t_age + 2'd1;
        if (rsp_v && rsp_rdy) t_busy <= 1'b0;
      end
    end
  end

  wire t_exec = t_busy && (t_age == 2'd0);   // c1: the RMW write cycle

  // ---------------------------------------------------------------------------
  // Environment assumptions
  // ---------------------------------------------------------------------------
`ifdef YOSYS
  // Reset: low in the first cycle, then high forever (JasperGold: use the
  // `reset -expression {!rst_n}` command instead).
  initial assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);
`endif

  always @(posedge clk) begin
    // tracked address is a constant
    if (f_past_valid) assume (fv_addr == $past(fv_addr));

    // DMA honours the lock (this is the contract lock_o advertises)
    assume (!(dma_we && lock_o && dma_addr == lock_addr_o));

    // No same-edge write/write collision on the dual-port SRAM
    assume (!(dma_we && mem_en && mem_we && dma_addr == mem_addr));
  end

  // ---------------------------------------------------------------------------
  // Assertions
  // ---------------------------------------------------------------------------
  always @(posedge clk) if (rst_n && f_past_valid) begin

    // ===== Handshake / protocol =====
    // single outstanding request
    a_no_accept_while_busy : assert (!(accept && t_busy));
    // no response without a request
    a_rsp_needs_req        : assert (!(rsp_v && !t_busy));
    // never deadlocks: ready whenever nothing is outstanding
    a_rdy_when_idle        : assert (t_busy || req_rdy);
    // ...and never ready while something is (also closes k-induction)
    a_not_rdy_when_busy    : assert (!(t_busy && req_rdy));
    // the only busy cycle with no response is c1 of a non-store
    a_quiet_only_in_c1     : assert (!(t_busy && !rsp_v) || (t_exec && t_op != C_ST));
    // fixed latency: ST responds in c1, everything else in c2
    a_lat_c1               : assert (!t_exec || (rsp_v == (t_op == C_ST)));
    a_lat_c2               : assert (!(t_busy && t_age == 2'd1 && t_op != C_ST) || rsp_v);
    // response held stable under backpressure
    if ($past(rsp_v && !rsp_rdy)) begin
      a_rsp_hold           : assert (rsp_v && $stable(rsp_data) && $stable(rsp_id));
    end
    // response ID matches request ID
    a_rsp_id               : assert (!rsp_v || rsp_id == t_id);
    // SRAM port sanity
    a_we_implies_en        : assert (!mem_we || mem_en);

    // ===== Data correctness (end-to-end, any address) =====
    // returned value: OLD value for LD/AMO/illegal, 0 for ST
    a_rsp_data             : assert (!(rsp_v && (t_hit || t_op == C_ST)) || rsp_data == t_old);

    // every SRAM write to fv_addr is legitimate and carries the right value
    if (mem_en && mem_we && mem_addr == fv_addr) begin
      a_write_legal        : assert ( (acc_hit && req_op_raw == C_ST && mem_wdata == req_data)
                                   || (t_exec && t_hit && is_rmw(t_op) && mem_wdata == t_new) );
    end

    // design intent (power): a failed CAS issues no SRAM write at all
    a_cas_fail_no_write    : assert (!(t_exec && t_hit && t_op == C_CAS && t_old != t_cmp && mem_we));

    // memory holds the spec result once the op has committed
    a_st_result            : assert (!(t_exec && t_hit && t_op == C_ST)              || fv_word == t_new);
    a_rmw_result           : assert (!(t_busy && t_age == 2'd1 && t_hit && is_rmw(t_op)) || fv_word == t_new);

    // ===== Atomicity / lock =====
    // no foreign write to the RMW location between its read (c0) and write (c1)
    a_atomic_c0            : assert (!(acc_hit && acc_rmw && dma_hit));
    a_atomic_c1            : assert (!(t_exec && t_hit && is_rmw(t_op) && dma_hit));
    // lock is not over-conservative: only during an RMW's c0/c1
    a_lock_minimal         : assert (!lock_o || acc_rmw || (t_exec && is_rmw(t_op)));
  end

  // ---------------------------------------------------------------------------
  // Covers (non-vacuity / reachability)
  // ---------------------------------------------------------------------------
  genvar k;
  generate
    for (k = 0; k < 12; k = k + 1) begin : g_cov_op
      always @(posedge clk) if (rst_n)
        cover (rsp_v && rsp_rdy && t_hit && t_op == k);
    end
  endgenerate

  always @(posedge clk) if (rst_n && f_past_valid) begin
    c_cas_success     : cover (rsp_v && t_hit && t_op == C_CAS && rsp_data == t_cmp && t_new != t_old);
    c_cas_fail        : cover (rsp_v && t_hit && t_op == C_CAS && rsp_data != t_cmp);
    c_illegal_op      : cover (rsp_v && t_hit && t_op >= 4'd12);
    c_backpressure    : cover (rsp_v && $past(rsp_v) && $past(rsp_v, 2));
    c_back_to_back    : cover (acc_hit && acc_rmw && $past(rsp_v && rsp_rdy));
    c_dma_before_amo  : cover (acc_hit && acc_rmw && $past(dma_hit));
    c_dma_after_amo   : cover (rsp_v && t_hit && is_rmw(t_op) && dma_hit);
    c_dma_other_addr  : cover (lock_o && dma_we && dma_addr != lock_addr_o);
    c_min_signed      : cover (rsp_v && t_hit && t_op == C_MIN && t_old[DW-1] != t_new[DW-1]);
  end

endmodule
