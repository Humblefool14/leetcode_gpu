// fv_ad_su_alu -- ad_su_alu (NPHYS 2, SHORT_LAT 6): s_* is exactly SHORT_LAT cycles
// after a taken ALU group with WRD, carrying its warp/grp/rd/EXEC lanes and per lane
// the reference result (expressions of gsi1model.alu(), the IMMB operand-b rule);
// fw4_*/fw5_* equal the result 2/1 cycles early, valid only for rd < 63; no result
// for other units or without WRD; x_ready is 1.
module fv_ad_su_alu (
    input wire clk,
    input wire x_valid,
    input wire [1:0] x_warp,
    input wire x_grp,
    input wire [107:0] x_uop,
    input wire [63:0] x_a, x_b, x_c,
    input wire [3:0] x_mask
);
`include "ad_su_uop.vh"
    localparam N = 2, L = 6;
    reg init = 1;
    always @(posedge clk) init <= 0;
    wire rst_n = !init;
    wire x_ready, s_valid, f4v, f5v; wire [1:0] s_warp, f4w, f5w; wire s_grp, f4g, f5g;
    wire [6:0] s_rd, f4r, f5r; wire [63:0] s_data, f4d, f5d; wire [1:0] s_lanes, f4l, f5l;
    ad_su_alu #(.NPHYS(N), .WARP_W(2), .GRP_W(1), .SHORT_LAT(L)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(1'b0),
        .x_sbe(3'd0), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
        .x_info(32'd0), .x_ready(x_ready), .s_valid(s_valid), .s_warp(s_warp), .s_grp(s_grp),
        .s_rd(s_rd), .s_data(s_data), .s_lanes(s_lanes),
        .fw4_valid(f4v), .fw4_warp(f4w), .fw4_grp(f4g), .fw4_rd(f4r), .fw4_data(f4d), .fw4_lanes(f4l),
        .fw5_valid(f5v), .fw5_warp(f5w), .fw5_grp(f5g), .fw5_rd(f5r), .fw5_data(f5d), .fw5_lanes(f5l));
    function [31:0] ref(input [7:0] op, input [31:0] a, input [31:0] b0, input [31:0] c, input [31:0] imm);
        reg [31:0] b; reg signed [32:0] sa, sb;
        begin
            b = op[7] ? imm : b0; sa = {a[31], a}; sb = {b[31], b};
            case (op[4:0])
            0: ref = a + b;  1: ref = a + ~b + 1;  2: ref = a << b[4:0];
            3: ref = (sa < sb) ? 32'hFFFFFFFF : 0;  4: ref = (a < b) ? 32'hFFFFFFFF : 0;
            5: ref = a ^ b;  6: ref = a >> b[4:0];  7: ref = ({{32{a[31]}}, a} >> b[4:0]);
            8: ref = a | b;  9: ref = a & b;
            10: ref = (sa < sb) ? a : b;  11: ref = (sa < sb) ? b : a;
            12: ref = (a < b) ? a : b;  13: ref = (a < b) ? b : a;
            14: ref = a & ~b; 15: ref = a | ~b; 16: ref = ~a ^ b; 17: ref = (a & b) | (~a & c);
            18: ref = imm; default: ref = 0;
            endcase
        end
    endfunction
    wire [7:0] op = x_uop[AD_UOP_OP +: 8]; wire [31:0] imm = x_uop[AD_UOP_IMM +: 32];
    wire [63:0] er = {ref(op, x_a[63:32], x_b[63:32], x_c[63:32], imm), ref(op, x_a[31:0], x_b[31:0], x_c[31:0], imm)};
    wire ev = x_valid && x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_ALU && x_uop[AD_UOP_WRD];
    // expected delay line (harness side)
    reg [L:1] hv; reg [1:0] hw [1:L]; reg hg [1:L]; reg [6:0] hr [1:L]; reg [63:0] hd [1:L]; reg [1:0] hl [1:L];
    integer k;
    always @(posedge clk) begin
        hv <= init ? 0 : {hv[L-1:1], ev};
        hw[1] <= x_warp; hg[1] <= x_grp; hr[1] <= x_uop[AD_UOP_RD +: 7]; hd[1] <= er; hl[1] <= x_mask[1:0];
        for (k = 2; k <= L; k = k + 1) begin hw[k] <= hw[k-1]; hg[k] <= hg[k-1]; hr[k] <= hr[k-1]; hd[k] <= hd[k-1]; hl[k] <= hl[k-1]; end
    end
    always @(*) if (!init) begin
        assert (x_ready);
        assert (s_valid == hv[L]);
        if (hv[L]) assert (s_warp == hw[L] && s_grp == hg[L] && s_rd == hr[L] && s_data == hd[L] && s_lanes == hl[L]);
        assert (f5v == (hv[L-1] && hr[L-1] < 63));
        if (f5v) assert (f5w == hw[L-1] && f5g == hg[L-1] && f5r == hr[L-1] && f5d == hd[L-1] && f5l == hl[L-1]);
        assert (f4v == (hv[L-2] && hr[L-2] < 63));
        if (f4v) assert (f4w == hw[L-2] && f4g == hg[L-2] && f4r == hr[L-2] && f4d == hd[L-2] && f4l == hl[L-2]);
    end
endmodule
