// fv_ad_rop_wb -- formal harness of ad_rop_wb (ad_rop_wpix replaced by fv_wpix_stub.v; the
// embedded `ifdef FORMAL properties of ad_rop_wb.v are checked with these):
//   AMB client (formal/common/ad_amb_client_props.sv): requests held until taken;
//   embedded: a write's byte enables are exactly the entry's dirty bytes and not empty (never
//     a byte that is not dirty), writes only from valid entries, dirty only in valid entries,
//     b_valid only in BLEND, d_ready only in IDLE, busy low => nothing dirty, no entry, nothing
//     outstanding;
//   here: busy low => no outstanding request (the props' counter); d_ready handshake (a beat
//     offered with d_valid is held until taken);
//   LIVE (fair memory: ready within 2 cycles, a response at most 2 cycles apart while any is
//     outstanding): a beat offered is taken within NB cycles (no deadlock), busy falls within
//     NI cycles of the last beat (the flush after 16 idle cycles is bounded).
module fv_ad_rop_wb #(
    parameter ADDR_W     = 12,
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5,
    parameter NB         = 160,
    parameter NI         = 40,
    parameter NB1        = 70,
    parameter NI1        = 28
) (
    input wire                    clk,
    input wire                    rst_n,
    input wire                    d_valid,
    input wire [31:0]             d_xy,
    input wire [15:0]             d_smask,
    input wire [1:0]              d_rt,
    input wire                    d_nocol,
    input wire                    req_ready,
    input wire                    rsp_valid,
    input wire                    rsp_write,
    input wire [7:0]              rsp_tag,
    input wire [LINE_BYTES*8-1:0] rsp_rdata,
    input wire                    rsp_error
);
    localparam LW = ADDR_W - LINE_SHIFT, LB = LINE_BYTES;
    // reset held two cycles: ad_amb_client_props samples req_valid during the first reset
    // cycle (registers not yet reset) and checks the hold rule right after it
    reg init = 1'b1, init2 = 1'b1;
    always @(posedge clk) begin init <= 1'b0; init2 <= init; end
    always @(*) begin
        if (init || init2) assume (!rst_n);
        else               assume (rst_n);
    end

    wire d_ready, b_valid, busy, req_valid, req_write;
    wire [511:0] b_src; wire [127:0] b_dst; wire [3:0] b_mask; wire [1:0] b_rt;
    wire [LW-1:0] req_line; wire [LB-1:0] req_be; wire [LB*8-1:0] req_wdata; wire [7:0] req_tag;
    // ad_rop_blend: b_rvalid 3 cycles after b_valid
    reg [2:0] bpipe;
    always @(posedge clk) if (!rst_n) bpipe <= 3'd0; else bpipe <= {bpipe[1:0], b_valid};
    (* anyseq *) reg [127:0] b_pix;

    ad_rop_wb #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) dut (
        .clk(clk), .rst_n(rst_n), .st_we(1'b0), .st_idx(9'd0), .st_wdata(32'd0),
        .d_valid(d_valid), .d_ready(d_ready), .d_xy(d_xy), .d_smask(d_smask), .d_color(512'd0),
        .d_rt(d_rt), .d_nocol(d_nocol),
        .b_valid(b_valid), .b_src(b_src), .b_dst(b_dst), .b_mask(b_mask), .b_rt(b_rt),
`ifdef LIVE1
        .b_rvalid(bpipe[2]), .b_pix(128'd0), .busy(busy),
`else
        .b_rvalid(bpipe[2]), .b_pix(b_pix), .busy(busy),
`endif
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line),
        .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
`ifdef LIVE1
        .rsp_rdata({LB*8{1'b0}}),
`else
        .rsp_rdata(rsp_rdata),
`endif
        .rsp_error(rsp_error));

    wire [4:0] outstanding;
    ad_amb_client_props #(.LINE_BYTES(LB), .LINE_W(LW), .CNT_W(5)) u_amb (
        .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
        .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .outstanding(outstanding));

    // memory side: a read's response only for an outstanding read, a write's for a write
    reg [4:0] rd_out, wr_out;
    always @(posedge clk) begin
        if (!rst_n) begin rd_out <= 0; wr_out <= 0; end
        else begin
            rd_out <= rd_out + (req_valid && req_ready && !req_write) - (rsp_valid && !rsp_write);
            wr_out <= wr_out + (req_valid && req_ready &&  req_write) - (rsp_valid &&  rsp_write);
        end
    end
    always @(*) if (!init) begin
        if (rsp_valid && !rsp_write) assume (rd_out != 0);
        if (rsp_valid &&  rsp_write) assume (wr_out != 0);
    end

    // the producer holds a beat until taken
    reg p_dv = 1'b0, p_dr; reg [31:0] p_xy; reg [15:0] p_sm; reg [1:0] p_rt; reg p_nc;
    always @(posedge clk) begin
        p_dv <= d_valid && rst_n; p_dr <= d_ready; p_xy <= d_xy; p_sm <= d_smask; p_rt <= d_rt; p_nc <= d_nocol;
    end
    always @(*) if (!init && p_dv && !p_dr)
        assume (d_valid && d_xy == p_xy && d_smask == p_sm && d_rt == p_rt && d_nocol == p_nc);

    always @(*) if (!init) begin
        a_busy_out: assert (busy || outstanding == 5'd0);
        a_out_max:  assert (outstanding <= 5'd15);
    end

`ifdef LIVE
    // fair memory
    reg p_rv = 1'b0, p_rr = 1'b0;
    reg [2:0] wcnt;
    always @(posedge clk) begin
        p_rv <= req_valid; p_rr <= req_ready;
        if (!rst_n || rsp_valid || outstanding == 0) wcnt <= 3'd0; else wcnt <= wcnt + 3'd1;
    end
    always @(*) if (!init) begin
        if (p_rv && !p_rr && req_valid) assume (req_ready);
        if (wcnt >= 3'd2 && outstanding != 0) assume (rsp_valid);
    end
    // bounded progress
    reg [9:0] cb, ci;
    always @(posedge clk) begin
        if (!rst_n || !d_valid || d_ready) cb <= 10'd0; else if (cb != 10'h3FF) cb <= cb + 10'd1;
        if (!rst_n || d_valid) ci <= 10'd0; else if (ci != 10'h3FF) ci <= ci + 10'd1;
    end
    always @(*) if (!init) begin
        a_take:  assert (cb < NB);
        a_flush: assert (ci < NI + NB || !busy);
    end
`endif
`ifdef LIVE1
    // one beat from reset through a fast memory (always ready, a response at most 2 cycles
    // apart): the beat completes (d_ready again) within NB1 cycles of being taken (a_done1),
    // and busy falls within NI1 cycles of that (16 idle cycles, the flush writes and their
    // responses; a_flush1)
    reg taken, back; reg [7:0] ct, cf;
    reg [2:0] wc1;
    always @(posedge clk) begin
        if (!rst_n) begin taken <= 1'b0; back <= 1'b0; ct <= 8'd0; cf <= 8'd0; end
        else begin
            if (d_valid && d_ready) taken <= 1'b1;
            if (taken && d_ready) back <= 1'b1;
            if (taken && ct != 8'hFF) ct <= ct + 8'd1;
            if (back && cf != 8'hFF) cf <= cf + 8'd1;
        end
        if (!rst_n || rsp_valid || outstanding == 0) wc1 <= 3'd0; else wc1 <= wc1 + 3'd1;
    end
    always @(*) if (!init && !init2) begin
        if (taken) assume (!d_valid);
        assume (req_ready);
        if (wc1 >= 3'd1 && outstanding != 0) assume (rsp_valid);
    end
    always @(*) if (!init && !init2) begin
        if (taken && ct >= NB1) a_done1:  assert (back || d_ready);
        if (back && cf >= NI1)  a_flush1: assert (!busy);
    end
`endif
    // reachability (more covers are embedded in ad_rop_wb.v)
    always @(posedge clk) if (!init) begin
        c_take:  cover (d_valid && d_ready && !d_nocol);
        c_idle:  cover (p_dv && !busy && outstanding == 0 && wr_out == 0 && rd_out == 0 && !d_valid && init == 1'b0);
    end
endmodule
