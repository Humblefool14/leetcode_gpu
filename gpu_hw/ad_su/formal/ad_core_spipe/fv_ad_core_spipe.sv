// fv_ad_core_spipe -- ad_su_spipe (NPHYS 1, N 4, 4-bit data via the low lane bits):
// s_* = the input N cycles earlier, fw5 = N-1, fw4 = N-2 cycles earlier, fw valid only
// for rd < 63; valid bits reset.
module fv_ad_core_spipe (input wire clk, input wire iv, input wire [1:0] iw, input wire ig, input wire [6:0] ir,
                         input wire [31:0] id, input wire il);
    localparam N = 4;
    reg init = 1; always @(posedge clk) init <= 0;
    wire sv, f4v, f5v; wire [1:0] sw, f4w, f5w; wire sg, f4g, f5g; wire [6:0] sr, f4r, f5r; wire [31:0] sd, f4d, f5d; wire sl, f4l, f5l;
    ad_su_spipe #(.NPHYS(1), .WARP_W(2), .GRP_W(1), .N(N)) dut (.clk(clk), .rst_n(!init), .in_valid(iv), .in_warp(iw),
        .in_grp(ig), .in_rd(ir), .in_data(id), .in_lanes(il), .s_valid(sv), .s_warp(sw), .s_grp(sg), .s_rd(sr), .s_data(sd),
        .s_lanes(sl), .fw4_valid(f4v), .fw4_warp(f4w), .fw4_grp(f4g), .fw4_rd(f4r), .fw4_data(f4d), .fw4_lanes(f4l),
        .fw5_valid(f5v), .fw5_warp(f5w), .fw5_grp(f5g), .fw5_rd(f5r), .fw5_data(f5d), .fw5_lanes(f5l));
    reg [N:1] hv; reg [42:0] hp [1:N]; integer k;
    always @(posedge clk) begin
        hv <= init ? 0 : {hv[N-1:1], iv}; hp[1] <= {iw, ig, ir, id, il};
        for (k = 2; k <= N; k = k + 1) hp[k] <= hp[k-1];
    end
    always @(*) if (!init) begin
        assert (sv == hv[N]); if (sv) assert ({sw, sg, sr, sd, sl} == hp[N]);
        assert (f5v == (hv[N-1] && hp[N-1][39:33] < 63)); if (f5v) assert ({f5w, f5g, f5r, f5d, f5l} == hp[N-1]);
        assert (f4v == (hv[N-2] && hp[N-2][39:33] < 63)); if (f4v) assert ({f4w, f4g, f4r, f4d, f4l} == hp[N-2]);
    end
endmodule
