// ============================================================
// AXI-Lite register file, split into three layers:
//
//   AXI-Lite master
//        |
//   axil2native     : AXI-Lite handshakes -> single-cycle wr_en / rd_en strobes
//        |            (accepts AW and W independently, 1 outstanding write + 1 read)
//   blk_decoder     : bounds + alignment check, rebase address to block-local
//        |            0x0/0x4, per-block wr/rd enables, error on miss
//   reg_blk x2      : two 32-bit registers each, WSTRB byte enables
//
// Register map (absolute):
//   0x00 -> reg0  (blk0, local 0x0)
//   0x04 -> reg1  (blk0, local 0x4)
//   0x08 -> reg2  (blk1, local 0x0)
//   0x0C -> reg3  (blk1, local 0x4)
//   anything else / unaligned -> SLVERR, RDATA = 0
// ============================================================

// ------------------------------------------------------------
// 1. AXI-Lite -> native bus converter
// ------------------------------------------------------------
module axil2native #(
  parameter int unsigned ADDR_W = 4,
  parameter int unsigned DATA_W = 32
) (
  input  logic                 ACLK,
  input  logic                 ARESETn,

  // AXI-Lite slave
  input  logic                 AWVALID,
  output logic                 AWREADY,
  input  logic [ADDR_W-1:0]    AWADDR,
  input  logic                 WVALID,
  output logic                 WREADY,
  input  logic [DATA_W-1:0]    WDATA,
  input  logic [DATA_W/8-1:0]  WSTRB,
  output logic                 BVALID,
  input  logic                 BREADY,
  output logic [1:0]           BRESP,
  input  logic                 ARVALID,
  output logic                 ARREADY,
  input  logic [ADDR_W-1:0]    ARADDR,
  output logic                 RVALID,
  input  logic                 RREADY,
  output logic [DATA_W-1:0]    RDATA,
  output logic [1:0]           RRESP,

  // Native bus (master side) -- single-cycle strobes, same-cycle response
  output logic                 wr_en,
  output logic [ADDR_W-1:0]    wr_addr,
  output logic [DATA_W-1:0]    wr_data,
  output logic [DATA_W/8-1:0]  wr_strb,
  input  logic                 wr_err,

  output logic                 rd_en,
  output logic [ADDR_W-1:0]    rd_addr,
  input  logic [DATA_W-1:0]    rd_data,
  input  logic                 rd_err
);

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;

  // ---------------- Write path ----------------
  logic                aw_seen, w_seen;
  logic [ADDR_W-1:0]   awaddr_q;
  logic [DATA_W-1:0]   wdata_q;
  logic [DATA_W/8-1:0] wstrb_q;

  // Accept each channel independently while no response is pending
  assign AWREADY = !aw_seen && !BVALID;
  assign WREADY  = !w_seen  && !BVALID;

  wire aw_hs = AWVALID && AWREADY;
  wire w_hs  = WVALID  && WREADY;

  // Address/data either already captured or arriving this cycle
  wire                aw_avail = aw_seen || aw_hs;
  wire                w_avail  = w_seen  || w_hs;

  // Fire the native write as soon as both halves are available.
  // Bypass muxes let a same-cycle AW+W complete with no extra latency.
  assign wr_en   = aw_avail && w_avail && !BVALID;
  assign wr_addr = aw_seen ? awaddr_q : AWADDR;
  assign wr_data = w_seen  ? wdata_q  : WDATA;
  assign wr_strb = w_seen  ? wstrb_q  : WSTRB;

  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      aw_seen  <= 1'b0;
      w_seen   <= 1'b0;
      awaddr_q <= '0;
      wdata_q  <= '0;
      wstrb_q  <= '0;
      BVALID   <= 1'b0;
      BRESP    <= RESP_OKAY;
    end else begin
      if (wr_en) begin
        // Write done: clear capture flags, raise response
        aw_seen <= 1'b0;
        w_seen  <= 1'b0;
        BVALID  <= 1'b1;
        BRESP   <= wr_err ? RESP_SLVERR : RESP_OKAY;
      end else begin
        if (aw_hs) begin aw_seen <= 1'b1; awaddr_q <= AWADDR; end
        if (w_hs)  begin w_seen  <= 1'b1; wdata_q  <= WDATA; wstrb_q <= WSTRB; end
      end
      // Hold BVALID until BREADY
      if (BVALID && BREADY) BVALID <= 1'b0;
    end
  end

  // ---------------- Read path ----------------
  assign ARREADY = !RVALID;
  assign rd_en   = ARVALID && ARREADY;
  assign rd_addr = ARADDR;

  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      RVALID <= 1'b0;
      RDATA  <= '0;
      RRESP  <= RESP_OKAY;
    end else begin
      if (rd_en) begin
        RVALID <= 1'b1;
        RDATA  <= rd_err ? '0 : rd_data;
        RRESP  <= rd_err ? RESP_SLVERR : RESP_OKAY;
      end else if (RVALID && RREADY) begin
        // Hold RVALID/RDATA until RREADY
        RVALID <= 1'b0;
      end
    end
  end

endmodule


// ------------------------------------------------------------
// 2. Block decoder
//    - bounds check against each block's [BASE, BASE+SIZE)
//    - word-alignment check
//    - rebase to block-local address (0x0 / 0x4)
//    - per-block wr/rd enables gated by the native strobes
// ------------------------------------------------------------
module blk_decoder #(
  parameter int unsigned ADDR_W   = 4,
  parameter int unsigned DATA_W   = 32,
  parameter int unsigned N_BLK    = 2,
  parameter int unsigned LOCAL_W  = 3,                       // 2 regs * 4 B = 8 B
  // Flattened per-block tables (slice i = block i) for tool portability
  parameter logic [N_BLK*ADDR_W-1:0]     BLK_BASE = {4'h8, 4'h0},
  parameter logic [N_BLK*(ADDR_W+1)-1:0] BLK_SIZE = {5'd8, 5'd8}   // bytes
) (
  // From converter
  input  logic                 wr_en,
  input  logic [ADDR_W-1:0]    wr_addr,
  input  logic [DATA_W-1:0]    wr_data,
  input  logic [DATA_W/8-1:0]  wr_strb,
  output logic                 wr_err,

  input  logic                 rd_en,
  input  logic [ADDR_W-1:0]    rd_addr,
  output logic [DATA_W-1:0]    rd_data,
  output logic                 rd_err,

  // To blocks
  output logic [N_BLK-1:0]     blk_wr_en,
  output logic [N_BLK-1:0]     blk_rd_en,
  output logic [LOCAL_W-1:0]   blk_wr_addr,   // rebased, shared by all blocks
  output logic [LOCAL_W-1:0]   blk_rd_addr,
  output logic [DATA_W-1:0]    blk_wr_data,
  output logic [DATA_W/8-1:0]  blk_wr_strb,
  input  logic [N_BLK*DATA_W-1:0] blk_rd_data
);

  logic [N_BLK-1:0] wr_hit, rd_hit;
  logic             wr_aligned, rd_aligned;

  function automatic logic [ADDR_W-1:0] base(input int i);
    return BLK_BASE[i*ADDR_W +: ADDR_W];
  endfunction
  function automatic logic [ADDR_W:0] limit(input int i);   // base + size (exclusive)
    return {1'b0, BLK_BASE[i*ADDR_W +: ADDR_W]} + BLK_SIZE[i*(ADDR_W+1) +: (ADDR_W+1)];
  endfunction

  assign wr_aligned = (wr_addr[1:0] == 2'b00);
  assign rd_aligned = (rd_addr[1:0] == 2'b00);

  // Bounds check: base <= addr < base + size
  always_comb begin
    for (int i = 0; i < N_BLK; i++) begin
      wr_hit[i] = wr_aligned &&
                  (wr_addr >= base(i)) && ({1'b0, wr_addr} < limit(i));
      rd_hit[i] = rd_aligned &&
                  (rd_addr >= base(i)) && ({1'b0, rd_addr} < limit(i));
    end
  end

  // Rebase: local = addr - base of the hit block (gives 0x0 / 0x4)
  always_comb begin
    blk_wr_addr = '0;
    blk_rd_addr = '0;
    for (int i = 0; i < N_BLK; i++) begin
      if (wr_hit[i]) blk_wr_addr = LOCAL_W'(wr_addr - base(i));
      if (rd_hit[i]) blk_rd_addr = LOCAL_W'(rd_addr - base(i));
    end
  end

  // Enables: native strobe (already = VALID && READY) AND address hit
  assign blk_wr_en   = {N_BLK{wr_en}} & wr_hit;
  assign blk_rd_en   = {N_BLK{rd_en}} & rd_hit;
  assign blk_wr_data = wr_data;
  assign blk_wr_strb = wr_strb;

  // Read mux (one-hot)
  always_comb begin
    rd_data = '0;
    for (int i = 0; i < N_BLK; i++)
      if (rd_hit[i]) rd_data = blk_rd_data[i*DATA_W +: DATA_W];
  end

  // Miss -> SLVERR
  assign wr_err = (wr_hit == '0);
  assign rd_err = (rd_hit == '0);

endmodule


// ------------------------------------------------------------
// 3. Register block: two 32-bit registers at local 0x0 / 0x4
// ------------------------------------------------------------
module reg_blk #(
  parameter int unsigned DATA_W  = 32,
  parameter int unsigned LOCAL_W = 3
) (
  input  logic                 ACLK,
  input  logic                 ARESETn,
  input  logic                 wr_en,
  input  logic [LOCAL_W-1:0]   wr_addr,
  input  logic [DATA_W-1:0]    wr_data,
  input  logic [DATA_W/8-1:0]  wr_strb,
  input  logic                 rd_en,      // available for read side-effects
  input  logic [LOCAL_W-1:0]   rd_addr,
  output logic [DATA_W-1:0]    rd_data,
  output logic [DATA_W-1:0]    r0,
  output logic [DATA_W-1:0]    r1
);

  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      r0 <= '0;
      r1 <= '0;
    end else if (wr_en) begin
      for (int b = 0; b < DATA_W/8; b++) begin
        if (wr_strb[b]) begin
          if (wr_addr[2] == 1'b0) r0[8*b +: 8] <= wr_data[8*b +: 8];
          else                    r1[8*b +: 8] <= wr_data[8*b +: 8];
        end
      end
    end
  end

  assign rd_data = (rd_addr[2] == 1'b0) ? r0 : r1;

endmodule


// ------------------------------------------------------------
// Top: original port list, now built from the three layers
// ------------------------------------------------------------
module axi_reg_file #(
  parameter int unsigned ADDR_W = 4,
  parameter int unsigned DATA_W = 32
) (
  input  logic                 ACLK,
  input  logic                 ARESETn,
  input  logic                 AWVALID,
  output logic                 AWREADY,
  input  logic [ADDR_W-1:0]    AWADDR,
  input  logic                 WVALID,
  output logic                 WREADY,
  input  logic [DATA_W-1:0]    WDATA,
  input  logic [DATA_W/8-1:0]  WSTRB,
  output logic                 BVALID,
  input  logic                 BREADY,
  output logic [1:0]           BRESP,
  input  logic                 ARVALID,
  output logic                 ARREADY,
  input  logic [ADDR_W-1:0]    ARADDR,
  output logic                 RVALID,
  input  logic                 RREADY,
  output logic [DATA_W-1:0]    RDATA,
  output logic [1:0]           RRESP
);

  localparam int unsigned N_BLK   = 2;
  localparam int unsigned LOCAL_W = 3;

  logic [DATA_W-1:0] reg0, reg1, reg2, reg3;

  // Native bus
  logic                wr_en, wr_err, rd_en, rd_err;
  logic [ADDR_W-1:0]   wr_addr, rd_addr;
  logic [DATA_W-1:0]   wr_data, rd_data;
  logic [DATA_W/8-1:0] wr_strb;

  // Block bus
  logic [N_BLK-1:0]    blk_wr_en, blk_rd_en;
  logic [LOCAL_W-1:0]  blk_wr_addr, blk_rd_addr;
  logic [DATA_W-1:0]   blk_wr_data;
  logic [DATA_W/8-1:0] blk_wr_strb;
  logic [N_BLK*DATA_W-1:0] blk_rd_data;

  axil2native #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) u_conv (
    .ACLK, .ARESETn,
    .AWVALID, .AWREADY, .AWADDR,
    .WVALID, .WREADY, .WDATA, .WSTRB,
    .BVALID, .BREADY, .BRESP,
    .ARVALID, .ARREADY, .ARADDR,
    .RVALID, .RREADY, .RDATA, .RRESP,
    .wr_en, .wr_addr, .wr_data, .wr_strb, .wr_err,
    .rd_en, .rd_addr, .rd_data, .rd_err
  );

  blk_decoder #(
    .ADDR_W(ADDR_W), .DATA_W(DATA_W), .N_BLK(N_BLK), .LOCAL_W(LOCAL_W),
    .BLK_BASE({4'h8, 4'h0}), .BLK_SIZE({5'd8, 5'd8})
  ) u_dec (
    .wr_en, .wr_addr, .wr_data, .wr_strb, .wr_err,
    .rd_en, .rd_addr, .rd_data, .rd_err,
    .blk_wr_en, .blk_rd_en, .blk_wr_addr, .blk_rd_addr,
    .blk_wr_data, .blk_wr_strb, .blk_rd_data
  );

  reg_blk #(.DATA_W(DATA_W), .LOCAL_W(LOCAL_W)) u_blk0 (
    .ACLK, .ARESETn,
    .wr_en(blk_wr_en[0]), .wr_addr(blk_wr_addr), .wr_data(blk_wr_data), .wr_strb(blk_wr_strb),
    .rd_en(blk_rd_en[0]), .rd_addr(blk_rd_addr), .rd_data(blk_rd_data[0*DATA_W +: DATA_W]),
    .r0(reg0), .r1(reg1)
  );

  reg_blk #(.DATA_W(DATA_W), .LOCAL_W(LOCAL_W)) u_blk1 (
    .ACLK, .ARESETn,
    .wr_en(blk_wr_en[1]), .wr_addr(blk_wr_addr), .wr_data(blk_wr_data), .wr_strb(blk_wr_strb),
    .rd_en(blk_rd_en[1]), .rd_addr(blk_rd_addr), .rd_data(blk_rd_data[1*DATA_W +: DATA_W]),
    .r0(reg2), .r1(reg3)
  );

endmodule
