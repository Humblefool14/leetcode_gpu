// fv_ad_su_lda -- ad_su_lda (NP lanes: 32 in the bmc/prove tasks, 16 and 8 in bmc16/prove16,
// bmc8/prove8; NWARPS 2, PRIMS 2, VARY_WORDS 2, SHORT_LAT 6: the table reduced).  Every input is
// free each cycle.  Properties: x_ready is 0 exactly in the NR - 1 cycles after a group is taken
// (NR = NQ / NC: 4, 2, 1); s_valid exactly SHORT_LAT cycles after a taken group that writes rd,
// never otherwise, with that group's warp, group, rd and EXEC lanes.
module fv_ad_su_lda #(parameter NP = 32) (
    input wire clk,
    input wire rst_n,
    input wire x_valid,
    input wire x_warp,
    input wire [(NP == 32 ? 1 : $clog2(32 / NP))-1:0] x_grp,
    input wire [107:0] x_uop,
    input wire [2*NP-1:0] x_mask,
    input wire pw_we,
    input wire pw_warp,
    input wire [11:0] pw_addr,
    input wire [31:0] pw_data,
    input wire scrub
);
    `include "ad_su_uop.vh"
    localparam GRP_W = (NP == 32) ? 1 : $clog2(32 / NP);
    localparam NQ = NP / 4, NC = (NQ < 2) ? NQ : 2, NR = NQ / NC, L = 6;
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n); else assume (rst_n);

    wire x_ready, s_valid, scrub_busy;
    wire s_warp;
    wire [GRP_W-1:0] s_grp;
    wire [6:0] s_rd;
    wire [NP*32-1:0] s_data;
    wire [NP-1:0] s_lanes;
    ad_su_lda #(.NPHYS(NP), .NWARPS(2), .WARP_W(1), .GRP_W(GRP_W), .PRIMS(2), .VARY_WORDS(2),
                .SHORT_LAT(L)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
        .x_last(1'b0), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a({NP{32'd0}}),
        .x_b({NP{32'd0}}), .x_c({NP{32'd0}}), .x_mask(x_mask), .x_info(32'd0),
        .x_ready(x_ready), .s_valid(s_valid), .s_warp(s_warp), .s_grp(s_grp), .s_rd(s_rd),
        .s_data(s_data), .s_lanes(s_lanes), .pw_we(pw_we), .pw_warp(pw_warp), .pw_addr(pw_addr),
        .pw_data(pw_data), .scrub(scrub), .scrub_busy(scrub_busy));

    wire take = x_valid && x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_LDA && x_ready;
    reg [2:0] busy;
    reg [L-1:0] sv;
    reg sw [0:L-1];
    reg [GRP_W-1:0] sg [0:L-1];
    reg [6:0] sr [0:L-1];
    reg [NP-1:0] sl [0:L-1];
    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 3'd0;
            sv <= {L{1'b0}};
        end else begin
            busy <= take ? NR - 1 : (busy != 3'd0) ? busy - 3'd1 : 3'd0;
            sv <= {sv[L-2:0], take && x_uop[AD_UOP_WRD]};
        end
        sw[0] <= x_warp; sg[0] <= x_grp; sr[0] <= x_uop[AD_UOP_RD +: 7]; sl[0] <= x_mask[NP-1:0];
        for (k = 1; k < L; k = k + 1) begin
            sw[k] <= sw[k-1]; sg[k] <= sg[k-1]; sr[k] <= sr[k-1]; sl[k] <= sl[k-1];
        end
    end
    always @(*) if (rst_n && !init) begin
        assert (x_ready == (busy == 3'd0));
        assert (s_valid == sv[L-1]);
        if (s_valid) assert (s_warp == sw[L-1] && s_grp == sg[L-1] && s_rd == sr[L-1] &&
                             s_lanes == sl[L-1]);
    end
endmodule
