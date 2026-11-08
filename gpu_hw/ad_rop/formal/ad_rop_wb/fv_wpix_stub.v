// ad_rop_wpix formal stand-in for the ad_rop_wb harness: same 35 ports.
//   * per attachment a free constant configuration: path, drop, read, log2(ps) <= 4; S free
//     constant (MS_CTRL); the slots (o_mask, o_ent, o_soff, o_lw, o_multi, o_nl, o_np) from the
//     real leaf ad_wpix_place, so they follow i_r / i_j / i_g / i_smask like the real block;
//   * o_addr and o_res free every cycle (any line, any pixel bytes): hits, misses and merged
//     data are arbitrary;
//   * path 1: f_done 5 cycles after f_go, held until f_take (ad_rop_fblend's handshake).
module ad_rop_wpix #(
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    st_we,
    input  wire [8:0]              st_idx,
    input  wire [31:0]             st_wdata,
    input  wire [31:0]             i_xy,
    input  wire [1:0]              i_rt,
    input  wire [15:0]             i_smask,
    input  wire [511:0]            i_color,
    input  wire                    i_r,
    input  wire [1:0]              i_j,
    input  wire [1:0]              i_g,
    input  wire [LINE_BYTES*8-1:0] i_line0,
    input  wire [LINE_BYTES*8-1:0] i_line1,
    input  wire [LINE_SHIFT-1:0]   i_off0,
    input  wire [LINE_SHIFT-1:0]   i_off1,
    input  wire [127:0]            b_pix,
    input  wire                    f_go,
    output wire                    f_done,
    input  wire                    f_take,
    output wire [31:0]             o_addr,
    output wire [1:0]              o_nl,
    output wire [1:0]              o_np,
    output wire                    o_multi,
    output wire                    o_drop,
    output wire                    o_read,
    output wire [1:0]              o_path,
    output wire                    o_lw,
    output wire [3:0]              o_mask,
    output wire [511:0]            o_bsrc,
    output wire [127:0]            o_bdst,
    output wire [511:0]            o_res,
    output wire [3:0]              o_ent,
    output wire [4*LINE_SHIFT-1:0] o_soff,
    output wire [4:0]              o_ps
);
    (* anyconst *) reg [7:0]  c_path;
    (* anyconst *) reg [3:0]  c_drop, c_read;
    (* anyconst *) reg [11:0] c_lps;
    (* anyconst *) reg        c_s4;
    (* anyseq *)   reg [31:0]  f_addr;
    (* anyseq *)   reg [511:0] f_res;
    wire [2:0] lps = (i_rt == 2'd0) ? c_lps[2:0] : (i_rt == 2'd1) ? c_lps[5:3] :
                     (i_rt == 2'd2) ? c_lps[8:6] : c_lps[11:9];
    always @(*) begin
        assume (c_lps[2:0] <= 3'd4); assume (c_lps[5:3] <= 3'd4);
        assume (c_lps[8:6] <= 3'd4); assume (c_lps[11:9] <= 3'd4);
        // the format table: path 0 pixels of at most 4 bytes, path 1 of at most 8
        if (o_path == 2'd0) assume (lps <= 3'd2);
        if (o_path == 2'd1) assume (lps <= 3'd3);
`ifdef LIVE2
        assume (!c_s4);               // short beats for the flush bound
`endif
    end
    assign o_path = (i_rt == 2'd0) ? c_path[1:0] : (i_rt == 2'd1) ? c_path[3:2] :
                    (i_rt == 2'd2) ? c_path[5:4] : c_path[7:6];
    assign o_drop = c_drop[i_rt];
    assign o_read = c_read[i_rt];
    assign o_ps   = 5'd1 << lps;
    assign o_addr = f_addr;
    `ifdef LIVE1
    assign o_res  = 512'd0;           // progress only: pixel bytes do not matter
`else
    assign o_res  = f_res;
`endif
    assign o_bsrc = 512'd0;
    assign o_bdst = 128'd0;
    wire [31:0] unused_addr;
    wire [7:0]  unused_lane;
    ad_wpix_place #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_place (
        .i_base(32'd0), .i_stride(32'd0), .i_xy(i_xy), .i_smask(i_smask), .i_lps(lps), .i_s4(c_s4),
        .i_r(i_r), .i_j(i_j), .i_g(i_g), .i_off0(i_off0), .i_off1(i_off1),
        .o_addr(unused_addr), .o_nl(o_nl), .o_np(o_np), .o_multi(o_multi), .o_lw(o_lw),
        .o_mask(o_mask), .o_ent(o_ent), .o_soff(o_soff), .o_lane(unused_lane));
    // fblend handshake
    reg       fpend;
    reg [2:0] fcnt;
    always @(posedge clk) begin
        if (!rst_n) begin fpend <= 1'b0; fcnt <= 3'd0; end
        else if (f_go && !fpend) begin fpend <= 1'b1; fcnt <= 3'd0; end
        else if (fpend && fcnt != 3'd4) fcnt <= fcnt + 3'd1;
        else if (f_done && f_take) fpend <= 1'b0;
    end
    assign f_done = fpend && (fcnt == 3'd4);
endmodule
