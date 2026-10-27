// =============================================================================
// amo_unit.sv  --  Atomic Memory Operation unit in front of a single-port SRAM
//
//   * Ops   : LD, ST, SWAP, ADD, AND, OR, XOR, MIN, MAX, MINU, MAXU, CAS
//   * Atomicity: req_rdy is held low for the whole read-modify-write, so no
//     other request through this unit can touch memory between the read and
//     the write. lock_o is exported to block any OTHER path to the same SRAM
//     (e.g. a DMA port) for the duration of the RMW.
//
//   * Response contract:
//       - LD, and all AMO_* ops : rsp_data = OLD value at req_addr
//       - Plain ST              : rsp_data = 0  (single-cycle store, no read)
//     For CAS, software checks success with (rsp_data == expected).
//
//   * Outstanding requests: ONE.  A new request is only accepted after the
//     previous response has been consumed (state S_IDLE).
//
//   * SRAM model assumed: 1-cycle read latency; mem_rdata valid in the cycle
//     AFTER mem_en with mem_we=0; write takes effect at the clock edge where
//     mem_en && mem_we.  The RMW depends on this exact timing (see
//     exec_write, which consumes mem_rdata combinationally in S_EXEC).
//
//   * Lock: asserted only for AMO_* ops (plain LD/ST need no protection),
//     COMBINATIONALLY in the accept cycle and held through the S_EXEC write
//     cycle.  Integration note: this creates a combinational path
//     req_v/req_op -> lock_o.  Make sure the other master's arbiter does not
//     feed back into whatever generates req_v, or you get a comb loop.
//
//   Timeline for an AMO:
//     cycle 0  S_IDLE  accept req, issue SRAM read      lock_o = 1 (comb)
//     cycle 1  S_EXEC  mem_rdata -> ALU -> SRAM write    lock_o = 1
//     cycle 2+ S_RESP  rsp_v until rsp_rdy               lock_o = 0
//   Plain ST : S_IDLE (write) -> S_RESP            (ack, rsp_data = 0, no lock)
//   Plain LD : S_IDLE (read)  -> S_EXEC -> S_RESP  (no write, no lock)
// =============================================================================

`timescale 1ns/1ps

package amo_pkg;
  typedef enum logic [3:0] {
    OP_LD    = 4'd0,
    OP_ST    = 4'd1,
    AMO_SWAP = 4'd2,
    AMO_ADD  = 4'd3,
    AMO_AND  = 4'd4,
    AMO_OR   = 4'd5,
    AMO_XOR  = 4'd6,
    AMO_MIN  = 4'd7,
    AMO_MAX  = 4'd8,
    AMO_MINU = 4'd9,
    AMO_MAXU = 4'd10,
    AMO_CAS  = 4'd11
  } op_e;
endpackage


module amo_unit
  import amo_pkg::*;
#(
  parameter int AW  = 16,   // word address width
  parameter int DW  = 32,   // data width
  parameter int IDW = 4     // request ID width
) (
  input  logic           clk,
  input  logic           rst_n,

  // ---------------- request (valid/ready) ----------------
  input  logic           req_v,
  output logic           req_rdy,
  input  op_e            req_op,
  input  logic [AW-1:0]  req_addr,
  input  logic [DW-1:0]  req_data,   // AMO operand / store data / CAS new value
  input  logic [DW-1:0]  req_cmp,    // CAS expected value (ignored otherwise)
  input  logic [IDW-1:0] req_id,

  // ---------------- response (valid/ready) ----------------
  output logic           rsp_v,
  input  logic           rsp_rdy,
  output logic [DW-1:0]  rsp_data,   // see response contract above
  output logic [IDW-1:0] rsp_id,

  // ---------------- single-port SRAM ----------------
  output logic           mem_en,
  output logic           mem_we,
  output logic [AW-1:0]  mem_addr,
  output logic [DW-1:0]  mem_wdata,
  input  logic [DW-1:0]  mem_rdata,

  // ---------------- lock to other SRAM masters ----------------
  output logic           lock_o,      // high from AMO accept through its write
  output logic [AW-1:0]  lock_addr_o  // valid only when lock_o
);

  // ---------------------------------------------------------------------------
  // Parameter sanity checks
  // ---------------------------------------------------------------------------
  // synthesis translate_off
  initial begin
    if (AW  < 1) $error("amo_unit: AW must be >= 1");
    if (DW  < 1) $error("amo_unit: DW must be >= 1");
    if (IDW < 1) $error("amo_unit: IDW must be >= 1");
  end
  // synthesis translate_on

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {S_IDLE, S_EXEC, S_RESP} state_e;
  state_e state;

  op_e            op_q;
  logic [AW-1:0]  addr_q;
  logic [DW-1:0]  src_q, cmp_q, old_q;
  logic [IDW-1:0] id_q;

  // ---------------------------------------------------------------------------
  // Op classification helpers
  // ---------------------------------------------------------------------------
  function automatic logic op_is_legal(op_e op);
    return (op inside {OP_LD, OP_ST, AMO_SWAP, AMO_ADD, AMO_AND, AMO_OR,
                       AMO_XOR, AMO_MIN, AMO_MAX, AMO_MINU, AMO_MAXU, AMO_CAS});
  endfunction

  function automatic logic op_is_st(op_e op);
    return (op == OP_ST);
  endfunction

  // Read-modify-write ops: the only ones that need the lock.
  function automatic logic op_is_amo(op_e op);
    return op_is_legal(op) && (op != OP_LD) && (op != OP_ST);
  endfunction

  // ---------------------------------------------------------------------------
  // Atomic ALU: new = f(old, src, cmp)
  // ---------------------------------------------------------------------------
  function automatic logic [DW-1:0] amo_alu(op_e op, logic [DW-1:0] old,
                                            logic [DW-1:0] src, logic [DW-1:0] cmp);
    logic [DW-1:0] r;
    unique case (op)
      AMO_SWAP, OP_ST: r = src;
      AMO_ADD : r = old + src;
      AMO_AND : r = old & src;
      AMO_OR  : r = old | src;
      AMO_XOR : r = old ^ src;
      AMO_MIN : r = ($signed(old) < $signed(src)) ? old : src;
      AMO_MAX : r = ($signed(old) > $signed(src)) ? old : src;
      AMO_MINU: r = (old < src) ? old : src;
      AMO_MAXU: r = (old > src) ? old : src;
      AMO_CAS : r = (old == cmp) ? src : old;
      default : r = old;                      // OP_LD or illegal op (write suppressed)
    endcase
    return r;
  endfunction

  // ---------------------------------------------------------------------------
  // Handshake / control
  // ---------------------------------------------------------------------------
  logic          accept;
  logic          amo_start;
  logic          exec_write;
  logic [DW-1:0] alu_new;

  assign req_rdy   = (state == S_IDLE);         // atomicity: nothing enters mid-RMW
  assign accept    = req_v && req_rdy;
  assign amo_start = accept && op_is_amo(req_op);

  assign alu_new    = amo_alu(op_q, mem_rdata, src_q, cmp_q);
  assign exec_write = (state == S_EXEC)
                    && (op_q != OP_LD)
                    && op_is_legal(op_q)                         // illegal op: no write
                    && !(op_q == AMO_CAS && mem_rdata != cmp_q); // CAS fail: no write

  // ---------------------------------------------------------------------------
  // Lock: combinational in the accept (read) cycle, held through the S_EXEC
  // (write) cycle.  lock_addr_o only switches to req_addr on an AMO accept, so
  // it stays quiet (and X-free) while idle.
  // ---------------------------------------------------------------------------
  assign lock_o      = amo_start || ((state == S_EXEC) && op_is_amo(op_q));
  assign lock_addr_o = amo_start ? req_addr : addr_q;

  // ---------------------------------------------------------------------------
  // SRAM drive
  // ---------------------------------------------------------------------------
  always_comb begin
    mem_en    = 1'b0;
    mem_we    = 1'b0;
    mem_addr  = addr_q;
    mem_wdata = '0;

    if (accept) begin
      mem_en   = 1'b1;
      mem_addr = req_addr;
      if (op_is_st(req_op)) begin                   // plain store: single-cycle write
        mem_we    = 1'b1;
        mem_wdata = req_data;
      end                                           // else: phase-1 read
    end else if (exec_write) begin                  // phase-2: modify + write
      mem_en    = 1'b1;
      mem_we    = 1'b1;
      mem_addr  = addr_q;
      mem_wdata = alu_new;
    end
  end

  // ---------------------------------------------------------------------------
  // FSM + capture
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state  <= S_IDLE;
      op_q   <= OP_LD;
      addr_q <= '0;
      src_q  <= '0;
      cmp_q  <= '0;
      old_q  <= '0;
      id_q   <= '0;
    end else begin
      unique case (state)
        S_IDLE: if (accept) begin
          op_q   <= req_op;
          addr_q <= req_addr;
          src_q  <= req_data;
          cmp_q  <= req_cmp;
          id_q   <= req_id;
          if (op_is_st(req_op)) begin
            old_q <= '0;                 // plain store: no read, rsp_data = 0
            state <= S_RESP;
          end else begin
            state <= S_EXEC;             // LD or AMO: read issued this cycle
          end
        end

        S_EXEC: begin                    // read data valid this cycle
          old_q <= mem_rdata;            // capture OLD value
          state <= S_RESP;
        end

        S_RESP: if (rsp_rdy) state <= S_IDLE;

        default: state <= S_IDLE;
      endcase
    end
  end

  assign rsp_v    = (state == S_RESP);
  assign rsp_data = old_q;
  assign rsp_id   = id_q;

  // ---------------------------------------------------------------------------
  // Assertions
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  // ---- handshake ----
  a_rdy_only_idle: assert property (@(posedge clk) disable iff (!rst_n)
    req_rdy |-> state == S_IDLE);

  a_rsp_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (rsp_v && !rsp_rdy) |=> (rsp_v && $stable(rsp_data) && $stable(rsp_id)));

  // Exactly one response per accepted request (simulation-friendly form:
  // a 1-bit outstanding tracker catches both missing and extra responses).
  logic outst;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n)                outst <= 1'b0;
    else if (accept)           outst <= 1'b1;
    else if (rsp_v && rsp_rdy) outst <= 1'b0;

  a_rsp_only_when_outst: assert property (@(posedge clk) disable iff (!rst_n)
    rsp_v |-> outst);
  a_no_accept_while_outst: assert property (@(posedge clk) disable iff (!rst_n)
    accept |-> !outst);

  // ---- SRAM write window ----
  a_write_window: assert property (@(posedge clk) disable iff (!rst_n)
    (mem_en && mem_we) |-> ((accept && op_is_st(req_op)) || state == S_EXEC));

  a_exec_addr: assert property (@(posedge clk) disable iff (!rst_n)
    (state == S_EXEC && mem_en) |-> mem_addr == addr_q);

  a_ld_no_write: assert property (@(posedge clk) disable iff (!rst_n)
    (state == S_EXEC && op_q == OP_LD) |-> !mem_we);

  a_cas_fail_no_write: assert property (@(posedge clk) disable iff (!rst_n)
    (state == S_EXEC && op_q == AMO_CAS && mem_rdata != cmp_q) |-> !mem_we);

  a_illegal_no_write: assert property (@(posedge clk) disable iff (!rst_n)
    (state == S_EXEC && !op_is_legal(op_q)) |-> !mem_we);

  // ---- lock ----
  // Lock covers the read cycle, at the request's address.
  a_lock_cycle0: assert property (@(posedge clk) disable iff (!rst_n)
    amo_start |-> (lock_o && lock_addr_o == req_addr));

  // Lock still held in the write cycle, at the RMW address.
  a_lock_write_cycle: assert property (@(posedge clk) disable iff (!rst_n)
    amo_start |=> (lock_o && lock_addr_o == addr_q && state == S_EXEC));

  // Any SRAM write from S_EXEC happens under the lock.
  a_write_under_lock: assert property (@(posedge clk) disable iff (!rst_n)
    (state == S_EXEC && mem_we) |-> lock_o);

  // Released once the write has committed.
  a_lock_released: assert property (@(posedge clk) disable iff (!rst_n)
    (state == S_EXEC) |=> !lock_o);

  // Plain LD/ST never take the lock.
  a_no_lock_ld_st: assert property (@(posedge clk) disable iff (!rst_n)
    (accept && !op_is_amo(req_op)) |-> !lock_o);

  // ---- input legality ----
  // The RTL tolerates illegal ops (no write, returns old value), so in
  // simulation this is a warning rather than a failure.  In formal it is an
  // input constraint.
`ifdef FORMAL
  m_op_legal: assume property (@(posedge clk) disable iff (!rst_n)
    accept |-> op_is_legal(req_op));

  // Liveness: needs a fairness assumption on the response channel.
  m_rsp_fair: assume property (@(posedge clk) disable iff (!rst_n)
    rsp_v |-> s_eventually rsp_rdy);
  a_rsp_eventually: assert property (@(posedge clk) disable iff (!rst_n)
    accept |-> s_eventually (rsp_v && rsp_rdy));
`else
  w_op_legal: assert property (@(posedge clk) disable iff (!rst_n)
    accept |-> op_is_legal(req_op))
    else $warning("amo_unit: illegal op %0d accepted (no write, old value returned)", req_op);
`endif
`endif

endmodule
