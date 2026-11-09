// fv_ad_lane_srcl: the shfl source lane at full width (WARP 32, every 32-bit
// rs2): idx s = rs2, xor s = l ^ rs2, up s = l - rs2, down s = l + rs2 as
// integers (ok when 0 <= s < 32), rot s = (l + rs2) mod 32 (always ok);
// other sub values ok = 0.  When ok, s is that lane.
module fv_ad_lane_srcl;
    (* anyconst *) reg [4:0] l;
    (* anyconst *) reg [31:0] rs2;
    (* anyconst *) reg [4:0] sub;
    wire [4:0] s;
    wire ok;
    ad_lane_srcl #(.WARP(32), .LW(5)) dut (.l(l), .rs2(rs2), .sub(sub), .s(s), .ok(ok));
    wire signed [34:0] li = {30'd0, l};
    wire signed [34:0] ri = {3'd0, rs2};
    reg signed [34:0] sx;
    reg rok;
    always @(*) begin
        case (sub)
        5'd0: sx = ri;
        5'd1: sx = {3'd0, rs2 ^ {27'd0, l}};
        5'd2: sx = li - ri;
        5'd3: sx = li + ri;
        default: sx = (li + ri) & 35'sd31;
        endcase
        rok = (sub <= 5'd4) && sx >= 0 && sx < 32;
        assert (ok == rok);
        if (ok)
            assert (s == sx[4:0]);
    end
endmodule
