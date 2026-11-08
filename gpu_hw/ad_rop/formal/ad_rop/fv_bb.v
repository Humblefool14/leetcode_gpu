// Blackbox stand-ins for the arithmetic datapaths in the top-level harness: same
// ports, outputs unconstrained each cycle except the handshake signals that must
// follow the real block's protocol.
module ad_fp_add (input [31:0] a, input [31:0] b, input sub, output [31:0] y);
    (* anyseq *) reg [31:0] r; assign y = r;
endmodule
module ad_rop_dtest (input [9:0] depth, input [26:0] sfront, input [26:0] sback,
    input [24:0] sops, input [31:0] bmin, input [31:0] bmax, input cov, input front, input [31:0] zf,
    input [31:0] stored, output pass, output [31:0] wword, output [3:0] wbe);
    (* anyseq *) reg p; (* anyseq *) reg [31:0] w; (* anyseq *) reg [3:0] b;
    assign pass = p & cov; assign wword = w; assign wbe = cov ? b : 4'd0;
endmodule
// blend: b_rvalid = b_valid delayed by 3 (proven in formal/ad_rop_blend); b_pix free
module ad_rop_blend #(parameter LAT = 3) (input clk, input rst_n, input st_we, input [8:0] st_idx,
    input [31:0] st_wdata, input b_valid, input [511:0] b_src, input [511:0] b_src1, input b_has_src1,
    input [127:0] b_dst, input [3:0] b_mask, input [1:0] b_rt, output b_rvalid, output [127:0] b_pix);
    reg [2:0] v;
    always @(posedge clk) v <= rst_n ? {v[1:0], b_valid} : 3'd0;
    assign b_rvalid = v[2];
    (* anyseq *) reg [127:0] pix; assign b_pix = pix;
endmodule
// fblend: a 1-deep valid/ready stage with free data (handshake proven in formal/ad_rop_fblend)
module ad_rop_fblend (input clk, input rst_n, input i_valid, output i_ready, input [3:0] i_lanes,
    input [511:0] i_src, input [255:0] i_dst, input [7:0] i_fmt, input [22:0] i_blend, input [127:0] i_const,
    input [3:0] i_wm, output reg o_valid, input o_ready, output [255:0] o_raw, output [255:0] o_keep);
    assign i_ready = !(o_valid && !o_ready);
    always @(posedge clk) if (!rst_n) o_valid <= 1'b0; else if (i_ready) o_valid <= i_valid;
    (* anyseq *) reg [255:0] r, k; assign o_raw = r; assign o_keep = k;
endmodule
