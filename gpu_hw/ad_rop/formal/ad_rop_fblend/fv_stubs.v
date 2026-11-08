// Reduced datapath for the ad_rop_fblend handshake proof: the leaf IPs and
// ad_fp_mul are replaced by trivial stand-ins with the same ports.  The source
// colour flows unchanged clamp -> S1 -> S2 -> S3 -> combine (y = s) -> S4 -> pack
// (raw = channels R, G; keep = channels B, A), so a tag carried in i_src comes out
// on o_raw and data integrity through the pipeline registers can be checked.
module ad_fblend_unpack (input wire [63:0] raw, input wire [7:0] fmt, output wire [127:0] d,
                         output wire fixed, output wire supported);
    assign d = 128'd0; assign fixed = 1'b0; assign supported = 1'b0;
endmodule
module ad_fblend_clamp (input wire en, input wire [31:0] x, output wire [31:0] y);
    assign y = x;
endmodule
module ad_fblend_factor (input wire [3:0] sel, input wire is_alpha, input wire [31:0] s, input wire [31:0] sa,
                         input wire [31:0] d, input wire [31:0] da, input wire [31:0] c, input wire [31:0] ca,
                         output wire [31:0] f);
    assign f = 32'd0;
endmodule
module ad_fp_mul (input wire [31:0] a, input wire [31:0] b, output wire [31:0] y);
    assign y = 32'd0;
endmodule
module ad_fblend_combine (input wire en, input wire [2:0] op, input wire [31:0] s, input wire [31:0] d,
                          input wire [31:0] p, input wire [31:0] q, output wire [31:0] y);
    assign y = s;
endmodule
module ad_fblend_pack (input wire [127:0] r, input wire [7:0] fmt, input wire [3:0] wm, input wire active,
                       output wire [63:0] raw, output wire [63:0] keep);
    assign raw = r[63:0]; assign keep = r[127:64];
endmodule
