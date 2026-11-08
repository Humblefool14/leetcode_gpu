// ad_rop_order properties, narrowed: SEQ_W 4, COLOR_W 8, DEPTH_W 8, AUX_W 16,
// FIFO of 4.  Harness shadow FIFO of the issued numbers (independent of the
// DUT's) and a shadow of the quad in the output register.
// Assumption: the rasterizer never has more than 4 numbers outstanding
// (issued and not retired), counting a retirement in the same cycle.
//  - a quad is taken only when the FIFO is non-empty and its number equals
//    ex_next, which equals the shadow head (so retirement follows issue order)
//  - the FIFO never overflows (ovf stays 0) nor underflows (a pop only when
//    the shadow holds an entry); busy == o_valid || numbers outstanding
//  - the output register holds the last forwarded quad (its seq, fields),
//    direct quads with colour 0, o_dbg 1, the fixed beat; mask-0 quads never
//  - o_* hold while o_valid && !o_ready
module fv_ad_rop_order (
    input wire        clk,
    input wire        ex_valid,
    input wire [3:0]  ex_seq,
    input wire [31:0] ex_xy,
    input wire [3:0]  ex_mask,
    input wire [7:0]  ex_color,
    input wire [7:0]  ex_depth,
    input wire        ex_last,
    input wire [15:0] ex_aux,
    input wire        dx_valid,
    input wire [3:0]  dx_seq,
    input wire [31:0] dx_xy,
    input wire [3:0]  dx_mask,
    input wire [7:0]  dx_depth,
    input wire        dx_last,
    input wire        ord_valid,
    input wire [3:0]  ord_seq,
    input wire        o_ready
);
    localparam N = 4;
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;

    wire ex_ready, dx_ready, o_valid, o_dbg, busy, ovf;
    wire [3:0] ex_next, o_mask; wire [31:0] o_xy; wire [7:0] o_color, o_depth; wire [15:0] o_aux;
    ad_rop_order #(.SEQ_W(4), .COLOR_W(8), .DEPTH_W(8), .AUX_W(16), .FIFO_LG(2)) dut (
        .clk(clk), .rst_n(rst_n),
        .ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy), .ex_mask(ex_mask),
        .ex_color(ex_color), .ex_depth(ex_depth), .ex_last(ex_last), .ex_aux(ex_aux), .ex_next(ex_next),
        .dx_valid(dx_valid), .dx_ready(dx_ready), .dx_seq(dx_seq), .dx_xy(dx_xy), .dx_mask(dx_mask),
        .dx_depth(dx_depth), .dx_last(dx_last), .ord_valid(ord_valid), .ord_seq(ord_seq),
        .o_valid(o_valid), .o_ready(o_ready), .o_xy(o_xy), .o_mask(o_mask), .o_color(o_color),
        .o_depth(o_depth), .o_dbg(o_dbg), .o_aux(o_aux), .busy(busy), .ovf(ovf));

    wire ex_fire = ex_valid && ex_ready;
    wire dx_fire = dx_valid && dx_ready;
    wire pop = (ex_fire && ex_last) || (dx_fire && dx_last);

    // ---- shadow FIFO of issued numbers ----
    reg [3:0] sh [0:N-1];
    reg [1:0] srd, swr;
    reg [2:0] scnt;
    wire [3:0] shead = sh[srd];
    always @(*) if (rst_n) assume (!ord_valid || scnt < N || pop);
    always @(posedge clk) begin
        if (!rst_n) begin srd <= 0; swr <= 0; scnt <= 0; end
        else begin
            if (ord_valid) begin sh[swr] <= ord_seq; swr <= swr + 1'b1; end
            if (pop) srd <= srd + 1'b1;
            scnt <= scnt + ord_valid - pop;
        end
    end

    // ---- shadow of the output register ----
    reg        h_ov, h_dbg;
    reg [3:0]  h_seq, h_mask;
    reg [31:0] h_xy;
    reg [7:0]  h_col, h_dep;
    reg [15:0] h_aux;
    always @(posedge clk) begin
        if (!rst_n) h_ov <= 1'b0;
        else begin
            if (o_valid && o_ready) h_ov <= 1'b0;
            if (ex_fire && ex_mask != 0) begin
                h_ov <= 1'b1; h_dbg <= 1'b0; h_seq <= ex_seq; h_mask <= ex_mask; h_xy <= ex_xy;
                h_col <= ex_color; h_dep <= ex_depth; h_aux <= ex_aux;
            end else if (dx_fire && dx_mask != 0) begin
                h_ov <= 1'b1; h_dbg <= 1'b1; h_seq <= dx_seq; h_mask <= dx_mask; h_xy <= dx_xy;
                h_col <= 8'd0; h_dep <= dx_depth; h_aux <= 16'h1111;
            end
        end
    end
    // sequence number of the quad held at output, at the time it was taken
    reg [3:0] h_seqhead;
    always @(posedge clk) if ((ex_fire && ex_mask != 0) || (dx_fire && dx_mask != 0)) h_seqhead <= shead;

    // ---- properties ----
    always @(*) if (rst_n) begin
        a_ovf:    assert (!ovf);
        a_busy:   assert (busy == (o_valid || scnt != 0));
        if (scnt != 0) a_next: assert (ex_next == shead);
        if (ex_fire) begin
            a_ex_seq: assert (ex_seq == ex_next && scnt != 0);
        end
        if (dx_fire) begin
            a_dx_seq: assert (dx_seq == ex_next && scnt != 0);
            a_dx_pri: assert (!(ex_valid && ex_ready));
        end
        a_ov:     assert (o_valid == h_ov);
        if (o_valid) begin
            a_oseq:  assert (h_seq == h_seqhead);
            a_odata: assert (o_xy == h_xy && o_mask == h_mask && o_color == h_col &&
                             o_depth == h_dep && o_dbg == h_dbg && o_aux == h_aux);
            a_omask: assert (o_mask != 0);
        end
    end
    reg past_ok = 1'b0;
    reg p_valid, p_ready, p_dbg; reg [3:0] p_mask; reg [31:0] p_xy; reg [7:0] p_col, p_dep; reg [15:0] p_aux;
    always @(posedge clk) begin
        past_ok <= rst_n;
        p_valid <= o_valid; p_ready <= o_ready; p_dbg <= o_dbg; p_mask <= o_mask; p_xy <= o_xy;
        p_col <= o_color; p_dep <= o_depth; p_aux <= o_aux;
    end
    always @(posedge clk) if (rst_n && past_ok && p_valid && !p_ready) begin
        a_hold_v: assert (o_valid);
        a_hold_d: assert (o_xy == p_xy && o_mask == p_mask && o_color == p_col && o_depth == p_dep &&
                          o_dbg == p_dbg && o_aux == p_aux);
    end
    always @(posedge clk) if (rst_n) begin
        c_full: cover (scnt == N && o_valid && o_dbg);
        c_pop:  cover (ex_fire && ex_last && scnt == 3'd1);
    end
endmodule
