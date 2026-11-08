// ad_rop_ds -- ROP depth/stencil (spec ad_rop_ds.md).
// Keeps MS_CTRL, DS_BASE, DS_STRIDE, DEBUG_COLOR, DEPTH, STENCIL_FRONT/OPS/BACK and
// DEPTH_BOUNDS_MIN/MAX.  One quad at a time:
//   IDLE  take the quad (q_ready)
//   DEC   later beat -> the first beat's survivors, no memory; first beat with the
//         tests off (format not one-hot, or no depth/stencil(D24S8)/bounds test)
//         -> q_smask, no memory; else the row addresses and lines
//   RD    read the line of each row with a covered entry (one read when both rows
//         are in one line); a read waits while a write of that line is outstanding
//   TST   row 0 then row 1 through ad_ds_row (8 ad_rop_dtest), merged into the line
//   WR    (waits for the previous quad's writes) one write per line with a byte enable set
//   OUT   d_valid until d_ready; a quad with no sample left is dropped
// Tags: {6'b0, write, slot}; slot = row (0 for the shared line).  rsp_error: a read
// gives zero data (the test proceeds), a write counts as completed.
// Rows are assumed aligned as ghci §8.5 requires (bases multiples of 64, strides of
// 2 S ps): a row's entries then lie in one line.  Spec §10 lists the assumptions.
module ad_rop_ds #(
    parameter ADDR_W     = 32,
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5,
    parameter STENCIL    = 0
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         st_we,
    input  wire [8:0]                   st_idx,
    input  wire [31:0]                  st_wdata,
    input  wire                         q_valid,
    output wire                         q_ready,
    input  wire [31:0]                  q_xy,
    input  wire [15:0]                  q_smask,
    input  wire [511:0]                 q_color,
    input  wire [511:0]                 q_sdepth,
    input  wire                         q_dbg,
    input  wire                         q_front,
    input  wire [3:0]                   q_beat,
    output wire                         d_valid,
    input  wire                         d_ready,
    output wire [31:0]                  d_xy,
    output wire [15:0]                  d_smask,
    output wire [511:0]                 d_color,
    output wire [3:0]                   d_beat,
    output wire                         busy,
    output reg                          req_valid,
    input  wire                         req_ready,
    output reg                          req_write,
    output reg  [ADDR_W-LINE_SHIFT-1:0] req_line,
    output reg  [LINE_BYTES-1:0]        req_be,
    output reg  [LINE_BYTES*8-1:0]      req_wdata,
    output reg  [7:0]                   req_tag,
    input  wire                         rsp_valid,
    input  wire                         rsp_write,
    input  wire [7:0]                   rsp_tag,
    input  wire [LINE_BYTES*8-1:0]      rsp_rdata,
    input  wire                         rsp_error
);
`include "ad_rop_state.vh"
    localparam LW = ADDR_W - LINE_SHIFT;
    localparam [2:0] S_IDLE = 3'd0, S_DEC = 3'd1, S_RD = 3'd2, S_TST = 3'd3, S_WR = 3'd4, S_OUT = 3'd5;

    // ---------------------------------------------------------------- STATE
    reg [31:0] r_base, r_stride, r_dbgc, r_bmin, r_bmax;
    reg [9:0]  r_depth;
    reg [26:0] r_sf, r_sb;
    reg [24:0] r_ops;
    reg [3:0]  r_ms;
    always @(posedge clk) begin
        if (!rst_n) begin
            r_base <= 0; r_stride <= 0; r_dbgc <= 0; r_bmin <= 0; r_bmax <= 0;
            r_depth <= 0; r_sf <= 0; r_sb <= 0; r_ops <= 0; r_ms <= 0;
        end else if (st_we) begin
            case (st_idx)
                `AD_S_DS_BASE:       r_base   <= st_wdata;
                `AD_S_DS_STRIDE:     r_stride <= st_wdata;
                `AD_S_DEBUG_COLOR:   r_dbgc   <= st_wdata;
                `AD_S_DEPTH:         r_depth  <= st_wdata[9:0];
                `AD_S_STENCIL_FRONT: r_sf     <= st_wdata[26:0];
                `AD_S_STENCIL_OPS:   r_ops    <= st_wdata[24:0];
                `AD_S_STENCIL_BACK:  r_sb     <= st_wdata[26:0];
                `AD_S_DBOUNDS_MIN:   r_bmin   <= st_wdata;
                `AD_S_DBOUNDS_MAX:   r_bmax   <= st_wdata;
                `AD_S_MS_CTRL:       r_ms     <= st_wdata[3:0];
                default: ;
            endcase
        end
    end
    wire [9:0] depth_e = (STENCIL != 0) ? r_depth : (r_depth & ~(10'd1 << `AD_DEPTH_STEN));
    wire [2:0] fmt     = depth_e[7:5];
    wire       f_d24   = (fmt == 3'b001);
    wire       f_d32   = (fmt == 3'b010);
    wire       f_d16   = (fmt == 3'b100);
    wire       tests_on = (f_d24 | f_d32 | f_d16) &&
                          (depth_e[`AD_DEPTH_TEST] || depth_e[`AD_DEPTH_BOUNDS] ||
                           (depth_e[`AD_DEPTH_STEN] && f_d24));
    wire       s4 = (r_ms == 4'd2);

    // ---------------------------------------------------------------- quad registers
    reg [2:0]   state;
    reg [15:0]  qx, qy, qsm;
    reg [511:0] qcol, qsd;
    reg         qdbg, qfront;
    reg [31:0]  qdbgc;          // DEBUG_COLOR when the quad was taken (d_color stable)
    reg [3:0]   qbeat;
    reg [15:0]  dsm, surv;
    reg [LW-1:0]         line0, line1;
    reg [LINE_SHIFT-1:0] off0, off1;
    reg         need0, need1, same;
    reg [1:0]   rd_i, wr_i, rpend, wv;
    reg         tr;
    reg [LW-1:0] wl0, wl1;
    reg [LINE_BYTES*8-1:0] lb0, lb1;
    reg [LINE_BYTES-1:0]   lbe0, lbe1;

    assign q_ready = (state == S_IDLE);
    assign d_valid = (state == S_OUT) && (dsm != 16'd0);
    assign d_xy    = {qy, qx};
    assign d_smask = dsm;
    assign d_beat  = qbeat;
    wire [511:0] dbg_color;
    ad_ds_dbgcol u_dbgcol (.rgba8(qdbgc), .color(dbg_color));
    assign d_color = qdbg ? dbg_color : qcol;
    assign busy = (state != S_IDLE) || (wv != 2'b00) || (rpend != 2'b00) || req_valid;

    // ---------------------------------------------------------------- addresses
    wire [LW-1:0]         a_line0, a_line1;
    wire [LINE_SHIFT-1:0] a_off0, a_off1;
    ad_ds_addr #(.ADDR_W(ADDR_W), .LINE_SHIFT(LINE_SHIFT)) u_addr (
        .base(r_base), .stride(r_stride), .x(qx), .y(qy), .s4(s4), .ps2(f_d16),
        .line0(a_line0), .line1(a_line1), .off0(a_off0), .off1(a_off1));
    wire [7:0] smsel = s4 ? 8'hFF : 8'h11;          // entries e = 4 px + s that exist
    wire [7:0] cov0  = qsm[7:0]  & smsel;
    wire [7:0] cov1  = qsm[15:8] & smsel;

    // ---------------------------------------------------------------- row test
    wire                    row_b   = tr && !same;             // line buffer of the row
    wire [7:0]              row_cov = tr ? (need1 ? cov1 : 8'd0) : (need0 ? cov0 : 8'd0);
    wire [7:0]              row_pass;
    wire [LINE_BYTES*8-1:0] row_line;
    wire [LINE_BYTES-1:0]   row_lbe;
    ad_ds_row #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_row (
        .depth(depth_e), .sfront(r_sf), .sback(r_sb), .sops(r_ops), .bmin(r_bmin), .bmax(r_bmax),
        .front(qfront), .s4(s4), .ps2(f_d16), .off(tr ? off1 : off0), .cov(row_cov),
        .zf(tr ? qsd[511:256] : qsd[255:0]),
        .line_in(row_b ? lb1 : lb0), .lbe_in(row_b ? lbe1 : lbe0),
        .pass(row_pass), .line_out(row_line), .lbe_out(row_lbe));

    // read-after-write: a line with an outstanding write
    // MUT_DS_NORAW: no wait (deliberate error for the TB and the formal harness)
`ifdef MUT_DS_NORAW
    wire conf0 = 1'b0;
    wire conf1 = 1'b0;
`else
    wire conf0 = (wv[0] && wl0 == line0) || (wv[1] && wl1 == line0);
    wire conf1 = (wv[0] && wl0 == line1) || (wv[1] && wl1 == line1);
`endif

    // ---------------------------------------------------------------- control
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; req_valid <= 1'b0; req_write <= 1'b0; req_line <= 0; req_be <= 0;
            req_wdata <= 0; req_tag <= 8'd0;
            rpend <= 2'b00; wv <= 2'b00; wl0 <= 0; wl1 <= 0; rd_i <= 2'd0; wr_i <= 2'd0; tr <= 1'b0;
            dsm <= 16'd0; surv <= 16'd0; need0 <= 1'b0; need1 <= 1'b0; same <= 1'b0;
            line0 <= 0; line1 <= 0; off0 <= 0; off1 <= 0; lbe0 <= 0; lbe1 <= 0;
            qx <= 0; qy <= 0; qsm <= 0; qdbg <= 0; qdbgc <= 0; qfront <= 0; qbeat <= 0;
        end else begin
            // ---- AMB request accepted / responses
            if (req_valid && req_ready) req_valid <= 1'b0;
            if (rsp_valid) begin
                if (rsp_write) begin
                    if (rsp_tag[0]) wv[1] <= 1'b0; else wv[0] <= 1'b0;
                end else begin
                    if (rsp_tag[0]) begin lb1 <= rsp_error ? {LINE_BYTES*8{1'b0}} : rsp_rdata; rpend[1] <= 1'b0; end
                    else            begin lb0 <= rsp_error ? {LINE_BYTES*8{1'b0}} : rsp_rdata; rpend[0] <= 1'b0; end
                end
            end
            case (state)
                S_IDLE: if (q_valid) begin
                    qx <= q_xy[15:0]; qy <= q_xy[31:16]; qsm <= q_smask; qcol <= q_color;
                    qsd <= q_sdepth; qdbg <= q_dbg; qdbgc <= r_dbgc; qfront <= q_front; qbeat <= q_beat;
                    state <= S_DEC;
                end
                S_DEC: begin
                    line0 <= a_line0; line1 <= a_line1; off0 <= a_off0; off1 <= a_off1;
                    need0 <= |cov0; need1 <= |cov1;
                    same  <= (|cov0) && (|cov1) && (a_line0 == a_line1);
                    lbe0 <= 0; lbe1 <= 0; rd_i <= 2'd0; wr_i <= 2'd0; tr <= 1'b0;
                    if (!qbeat[0]) begin
                        dsm <= surv; state <= S_OUT;
                    end else if (!tests_on) begin
                        dsm <= qsm; state <= S_OUT;
                    end else if (!(|cov0) && !(|cov1)) begin
                        dsm <= 16'd0; state <= S_OUT;
                    end else begin
                        dsm <= 16'd0; state <= S_RD;
                    end
                end
                S_RD: if (!req_valid) begin
                    if (rd_i == 2'd0) begin
                        if (!need0) rd_i <= 2'd1;
                        else if (!conf0) begin
                            req_valid <= 1'b1; req_write <= 1'b0; req_line <= line0; req_tag <= 8'h00;
                            rpend[0] <= 1'b1; rd_i <= 2'd1;
                        end
                    end else if (rd_i == 2'd1) begin
                        if (!need1 || same) rd_i <= 2'd2;
                        else if (!conf1) begin
                            req_valid <= 1'b1; req_write <= 1'b0; req_line <= line1; req_tag <= 8'h01;
                            rpend[1] <= 1'b1; rd_i <= 2'd2;
                        end
                    end else if (rpend == 2'b00 && !(rsp_valid && !rsp_write)) begin
                        state <= S_TST;
                    end
                end
                S_TST: begin
                    if (row_b) begin lb1 <= row_line; lbe1 <= row_lbe; end
                    else       begin lb0 <= row_line; lbe0 <= row_lbe; end
                    if (tr) dsm[15:8] <= row_pass; else dsm[7:0] <= row_pass;
                    tr <= 1'b1;
                    if (tr) state <= S_WR;
                end
                S_WR: if (!req_valid) begin
                    if (wr_i == 2'd0) begin
                        if (wv == 2'b00) begin
                            if (lbe0 != 0) begin
                                req_valid <= 1'b1; req_write <= 1'b1; req_line <= line0; req_tag <= 8'h02;
                                req_be <= lbe0; req_wdata <= lb0; wv[0] <= 1'b1; wl0 <= line0;
                            end
                            wr_i <= 2'd1;
                        end
                    end else if (wr_i == 2'd1) begin
                        if (lbe1 != 0) begin
                            req_valid <= 1'b1; req_write <= 1'b1; req_line <= line1; req_tag <= 8'h03;
                            req_be <= lbe1; req_wdata <= lb1; wv[1] <= 1'b1; wl1 <= line1;
                        end
                        wr_i <= 2'd2;
                    end else begin
                        state <= S_OUT;
                    end
                end
                S_OUT: if (dsm == 16'd0 || d_ready) begin
                    if (qbeat[0]) surv <= dsm;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
