// fv_props.vh -- shared property block of fv_ad_rop_blend / fv_ad_blend_pipe.
// Needs: clk, rst_n, init, b_valid, b_src, b_dst, b_mask, b_rvalid, b_pix, NL (lanes checked
// for the datapath properties) and the beat's selected state c_blend, c_fmt, c_wm, c_lo, c_lop.
    // expected values computed at the beat's input
    wire [127:0] e_dis, e_copy;
    genvar fl, fc;
    generate for (fl = 0; fl < 4; fl = fl + 1) begin : g_e
        wire [31:0] sb;
        for (fc = 0; fc < 4; fc = fc + 1) begin : g_c
            ad_rop_f2u8 u_f (.f(b_src[128*fl + 32*fc +: 32]), .u(sb[8*fc +: 8]));
        end
        wire [31:0] pk, kp;
        ad_blend_pack8 u_pk (.r(sb[7:0]), .g(sb[15:8]), .b(sb[23:16]), .a(sb[31:24]),
            .fmt(c_fmt), .wm(4'hF), .bits(pk), .keep(kp));
        assign e_dis [32*fl +: 32] = sb;
        assign e_copy[32*fl +: 32] = (kp & b_dst[32*fl +: 32]) | (~kp & pk);
    end endgenerate
    wire fmt_ok = c_fmt == 8'd37 || c_fmt == 8'd51 || c_fmt == 8'd44 || c_fmt == 8'd9 ||
                  c_fmt == 8'd16 || c_fmt == 8'd4  || c_fmt == 8'd8;
    wire c_dis  = !c_blend[0] && !c_lo && c_fmt == 8'd37 && c_wm == 4'hF;   // blend off, RGBA8
    wire c_wm0  = c_wm == 4'h0;
    wire c_copy = c_lo && c_lop == 4'd3 && c_wm == 4'hF;                    // logic op COPY
    wire c_bad  = !fmt_ok;

    // shadow pipeline (3 deep), valid with reset exactly as b_rvalid must be
    reg h1, h2, h3;
    reg [3:0]   k1, k2, k3;    // {c_dis, c_wm0, c_copy, c_bad}
    reg [3:0]   m1, m2, m3;
    reg [127:0] d1, d2, d3, x1, x2, x3, y1, y2, y3;
    always @(posedge clk) begin
        h1 <= rst_n & b_valid; h2 <= rst_n & h1; h3 <= rst_n & h2;
        k1 <= {c_dis, c_wm0, c_copy, c_bad}; k2 <= k1; k3 <= k2;
        m1 <= b_mask; m2 <= m1; m3 <= m2;
        d1 <= b_dst; d2 <= d1; d3 <= d2;
        x1 <= e_dis; x2 <= x1; x3 <= x2;
        y1 <= e_copy; y2 <= y1; y3 <= y2;
    end
    // h* start at 0 only through the reset of the first cycle
    reg pv1 = 1'b0, pv2 = 1'b0, pv3 = 1'b0;   // the first cycles have no defined history
    always @(posedge clk) begin pv1 <= !init; pv2 <= pv1; pv3 <= pv2; end
    always @(*) begin
        if (pv1) a_lat: assert (b_rvalid == h3);
        if (pv3 && b_rvalid && k3[2]) a_wm0: assert (b_pix == d3);
        if (pv3 && b_rvalid && k3[0]) a_bad: assert (b_pix == d3);
    end
    // per lane: masked lane = b_dst; a_dis; a_copy (unlabelled: yosys labels are not scoped)
    generate for (fl = 0; fl < 4; fl = fl + 1) begin : g_chk
        always @(*) begin
            if (pv3 && b_rvalid && !m3[fl]) assert (b_pix[32*fl +: 32] == d3[32*fl +: 32]);
            if (fl < NL && pv3 && b_rvalid && m3[fl] && k3[3]) assert (b_pix[32*fl +: 32] == x3[32*fl +: 32]);
            if (fl < NL && pv3 && b_rvalid && m3[fl] && k3[1]) assert (b_pix[32*fl +: 32] == y3[32*fl +: 32]);
        end
    end endgenerate
