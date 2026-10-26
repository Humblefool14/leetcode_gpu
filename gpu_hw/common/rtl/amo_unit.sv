// =============================================================================
// amo_unit.sv  --  Atomic Memory Operation unit in front of a single-port SRAM
//
//   * Ops   : LD, ST, SWAP, ADD, AND, OR, XOR, MIN, MAX, MINU, MAXU, CAS
//   * Atomicity: req_rdy is held low for the whole read-modify-write, so no
//     other request through this unit can touch memory between the read and
//     the write. lock_o is exported to block any OTHER path to the same SRAM
//     (e.g. a DMA port) for the duration of the RMW.
//   * Response always returns the OLD value at the address (AMO contract).
//     For CAS, software checks success with (rsp_data == expected).
//   * SRAM model assumed: 1-cycle read latency, write takes effect at the
//     clock edge where mem_en && mem_we.
//
//   Timeline for an AMO:
//     cycle 0  S_IDLE  accept req, issue SRAM read
//     cycle 1  S_EXEC  mem_rdata valid -> ALU -> SRAM write (if needed)
//     cycle 2+ S_RESP  rsp_v until rsp_rdy
//   Plain ST : S_IDLE (write) -> S_RESP          (ack, rsp_data = 0)
//   Plain LD : S_IDLE (read)  -> S_EXEC -> S_RESP (no write)
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
  output logic [DW-1:0]  rsp_data,   // OLD value at req_addr
  output logic [IDW-1:0] rsp_id,

  // ---------------- single-port SRAM ----------------
  output logic           mem_en,
  output logic           mem_we,
  output logic [AW-1:0]  mem_addr,
  output logic [DW-1:0]  mem_wdata,
  input  logic [DW-1:0]  mem_rdata,

  // ---------------- lock to other SRAM masters ----------------
  output logic           lock_o,      // high while an RMW owns the SRAM
  output logic [AW-1:0]  lock_addr_o
);

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
      default : r = old;                      // OP_LD
    endcase
    return r;
  endfunction

  // ---------------------------------------------------------------------------
  // Handshake / control
  // ---------------------------------------------------------------------------
  logic accept;
  logic exec_write;
  logic [DW-1:0] alu_new;

  assign req_rdy  = (state == S_IDLE);        // <-- atomicity: nothing enters mid-RMW
  assign accept   = req_v && req_rdy;

  assign alu_new    = amo_alu(op_q, mem_rdata, src_q, cmp_q);
  assign exec_write = (state == S_EXEC) && (op_q != OP_LD)
                    && !(op_q == AMO_CAS && mem_rdata != cmp_q);   // CAS fail: no write

  assign lock_o      = (state == S_EXEC);
  assign lock_addr_o = addr_q;

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
      if (req_op == OP_ST) begin              // plain store: single-cycle write
        mem_we    = 1'b1;
        mem_wdata = req_data;
      end                                     // else: phase-1 read
    end else if (exec_write) begin            // phase-2: modify + write
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
          if (req_op == OP_ST) begin
            old_q <= '0;
            state <= S_RESP;
          end else begin
            state <= S_EXEC;
          end
        end

        S_EXEC: begin                         // read data valid this cycle
          old_q <= mem_rdata;
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
  // Only accept in IDLE
  a_rdy_only_idle: assert property (@(posedge clk) disable iff (!rst_n)
    req_rdy |-> state == S_IDLE);

  // SRAM writes only from a plain store accept or the EXEC phase
  a_write_window: assert property (@(posedge clk) disable iff (!rst_n)
    (mem_en && mem_we) |-> ((accept && req_op == OP_ST) || state == S_EXEC));

  // During RMW the SRAM is only ever addressed at the locked address
  a_exec_addr: assert property (@(posedge clk) disable iff (!rst_n)
    (state == S_EXEC && mem_en) |-> mem_addr == addr_q);

  // Loads never write
  a_ld_no_write: assert property (@(posedge clk) disable iff (!rst_n)
    (state == S_EXEC && op_q == OP_LD) |-> !mem_we);

  // CAS writes only on match
  a_cas_fail_no_write: assert property (@(posedge clk) disable iff (!rst_n)
    (state == S_EXEC && op_q == AMO_CAS && mem_rdata != cmp_q) |-> !mem_we);

  // Response stable under backpressure
  a_rsp_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (rsp_v && !rsp_rdy) |=> (rsp_v && $stable(rsp_data) && $stable(rsp_id)));

  // Every accepted request gets exactly one response before the next accept
  a_no_accept_while_busy: assert property (@(posedge clk) disable iff (!rst_n)
    (state != S_IDLE) |-> !accept);
`endif

endmodule
