// fv_ad_rop_wpix -- combinational properties of ad_rop_wpix over every reachable STATE
// (ad_rop_fblend black-boxed, colours and lines tied to 0: not in these properties' cone).
//   a_drop:  an attachment whose format (shadow decode of RT_FORMATS / RT_FORMAT, independent
//            list) is not a supported colour format is dropped
//   a_ps:    ps in {1,2,4,8,16}
//   a_multi: several lines exactly when 2 S ps > LINE_BYTES; o_np = S - 1
//   a_soff*: every slot in o_mask has an offset that is a multiple of ps with the pixel inside
//            the line (given the alignment of ghci §8.5: the row's first byte a multiple of 2 S ps)
//   a_mask*: o_mask is a subset of i_smask's samples (one line: lane k, sample g; several:
//            lane 2 r + n / 4, sample n mod 4, n = E j + k)
//   a_ent:   entries (one line: k >> 1, several: r)
//   one line: a slot inside its quad row [off, off + 2 S ps); slots of a pass in one entry distinct
`include "ad_rop_state.vh"
module fv_ad_rop_wpix #(
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5
) (
    input wire        clk,
    input wire        rst_n,
    input wire        st_we,
    input wire [8:0]  st_idx,
    input wire [31:0] st_wdata,
    input wire [31:0] i_xy,
    input wire [1:0]  i_rt,
    input wire [15:0] i_smask,
    input wire        i_r,
    input wire [1:0]  i_j,
    input wire [1:0]  i_g,
    input wire [LINE_SHIFT-1:0] i_off0,
    input wire [LINE_SHIFT-1:0] i_off1
);
    localparam LS = LINE_SHIFT, LB = LINE_BYTES;
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);

    wire f_done; wire [31:0] o_addr; wire [1:0] o_nl, o_np, o_path; wire o_multi, o_drop, o_read, o_lw;
    wire [3:0] o_mask, o_ent; wire [511:0] o_bsrc, o_res; wire [127:0] o_bdst; wire [4*LS-1:0] o_soff;
    wire [4:0] o_ps;
    ad_rop_wpix #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) dut (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .i_xy(i_xy), .i_rt(i_rt), .i_smask(i_smask), .i_color(512'd0), .i_r(i_r), .i_j(i_j), .i_g(i_g),
        .i_line0({LB*8{1'b0}}), .i_line1({LB*8{1'b0}}), .i_off0(i_off0), .i_off1(i_off1), .b_pix(128'd0),
        .f_go(1'b0), .f_done(f_done), .f_take(1'b0),
        .o_addr(o_addr), .o_nl(o_nl), .o_np(o_np), .o_multi(o_multi), .o_drop(o_drop), .o_read(o_read),
        .o_path(o_path), .o_lw(o_lw), .o_mask(o_mask), .o_bsrc(o_bsrc), .o_bdst(o_bdst), .o_res(o_res),
        .o_ent(o_ent), .o_soff(o_soff), .o_ps(o_ps));

    // ---- shadow STATE and the attachment's format
    reg [31:0] fmts, rtfmt; reg [3:0] ms;
    always @(posedge clk) begin
        if (!rst_n) begin fmts <= 0; rtfmt <= 0; ms <= 0; end
        else if (st_we) begin
            if (st_idx == `AD_S_RT_FORMATS) fmts <= st_wdata;
            if (st_idx == `AD_S_RT_FORMAT)  rtfmt <= st_wdata;
            if (st_idx == `AD_S_MS_CTRL)    ms <= st_wdata[3:0];
        end
    end
    wire [7:0] fb  = fmts >> (8 * i_rt);
    wire [7:0] fmt = (i_rt == 0 && fb == 0) ? ((rtfmt == 0) ? 8'd44 : (rtfmt == 1) ? 8'd37 :
                                               (rtfmt == 2 || rtfmt == 3) ? 8'd4 : 8'd0) : fb;
    wire supported = (fmt == 4) || (fmt == 8) || (fmt == 9) || (fmt == 13) || (fmt == 14) || (fmt == 16) ||
                     (fmt == 20) || (fmt == 21) || (fmt == 37) || (fmt == 41) || (fmt == 42) || (fmt == 43) ||
                     (fmt == 44) || (fmt == 50) || (fmt == 51) || (fmt == 55) || (fmt == 56) || (fmt == 57) ||
                     (fmt == 64) || (fmt == 68) || (fmt == 74) || (fmt == 75) || (fmt == 76) || (fmt == 81) ||
                     (fmt == 82) || (fmt == 83) || (fmt == 95) || (fmt == 96) || (fmt == 97) ||
                     (fmt >= 98 && fmt <= 103) || (fmt >= 107 && fmt <= 109);
    wire       s4   = (ms == 4'd2);
    wire [8:0] rowb = {4'd0, o_ps} << (s4 ? 3 : 1);              // 2 S ps
    wire [8:0] ebytes = LB;
    wire [4:0] e    = (o_ps == 0) ? 5'd0 : (ebytes / o_ps);        // slots a line (several lines)
    // place inputs within range, rows aligned (ghci §8.5)
    always @(*) if (!init) begin
        if (!s4) assume (i_g == 2'd0);
        assume (i_j <= o_nl);
        if (!o_multi && rowb != 0) begin
            assume ({4'd0, i_off0} % rowb == 0);
            assume ({4'd0, i_off1} % rowb == 0);
        end
    end
    always @(*) if (!init && rst_n) begin
        if (!supported) a_drop: assert (o_drop);
        if (supported)  a_ps:   assert (o_ps == 1 || o_ps == 2 || o_ps == 4 || o_ps == 8 || o_ps == 16);
        if (supported)  a_multi: assert (o_multi == (rowb > LB));
        a_np: assert (o_np == (s4 ? 2'd3 : 2'd0));
        if (supported && o_multi) a_e: assert (e == 2 || e == 4);
        if (i_smask == 16'd0) a_mask0: assert (o_mask == 4'd0 && !o_lw);
    end
    genvar k;
    generate for (k = 0; k < 4; k = k + 1) begin : g_slot
        wire [8:0] so   = o_soff[k*LS +: LS];
        wire [3:0] sbit = {i_r, 3'b000} + (i_j * e[3:0]) + k;
        always @(*) if (!init && rst_n && supported && o_mask[k]) begin
            assert (so % o_ps == 0);
            assert (so + o_ps <= LB);
            if (!o_multi) begin
                // inside the quad's row of its entry: [off, off + 2 S ps)
                assert (so >= {4'd0, (k[1] ? i_off1 : i_off0)});
                assert (so + o_ps <= {4'd0, (k[1] ? i_off1 : i_off0)} + rowb);
                assert (i_smask[4*k + i_g]);
                assert (o_ent[k] == k[1]);
                if (!s4) assert (i_g == 0);
            end else begin
                assert (k < e && i_smask[sbit]);
                assert (o_ent[k] == i_r);
            end
        end
    end endgenerate
    // two slots of a pass never share an entry's unit
    genvar k1, k2;
    generate for (k1 = 0; k1 < 4; k1 = k1 + 1) begin : g_p1
        for (k2 = k1 + 1; k2 < 4; k2 = k2 + 1) begin : g_p2
            always @(*) if (!init && rst_n && supported && o_mask[k1] && o_mask[k2] && o_ent[k1] == o_ent[k2])
                assert (o_soff[k1*LS +: LS] != o_soff[k2*LS +: LS]);
        end
    end endgenerate
endmodule
