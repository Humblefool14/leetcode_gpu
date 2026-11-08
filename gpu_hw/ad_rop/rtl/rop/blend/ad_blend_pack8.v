// ad_blend_pack8 -- RGBA8 -> lane bits of a VkFormat, plus the per-bit keep mask
// (spec ad_rop_blend.md §4).  8-bit fields direct, 5-bit = div255(v*31), 6-bit = div255(v*63),
// A1 = (a >= 128).  keep[i] = 1: bit i of the lane keeps the destination (channel not in the
// write mask wm = {A,B,G,R}, bit above the pixel size, or a format outside the list).
// bits is 0 wherever the format has no field.
`include "ad_rop_state.vh"
module ad_blend_pack8 (
    input  wire [7:0]  r,
    input  wire [7:0]  g,
    input  wire [7:0]  b,
    input  wire [7:0]  a,
    input  wire [7:0]  fmt,
    input  wire [3:0]  wm,
    output reg  [31:0] bits,
    output wire [31:0] keep
);
    // v * 31 = (v << 5) - v, v * 63 = (v << 6) - v
    wire [8:0] r5, g5, b5, g6;
    ad_rop_div255 u_r5 (.x({5'd0, r, 5'd0} - {10'd0, r}), .q(r5));
    ad_rop_div255 u_g5 (.x({5'd0, g, 5'd0} - {10'd0, g}), .q(g5));
    ad_rop_div255 u_b5 (.x({5'd0, b, 5'd0} - {10'd0, b}), .q(b5));
    ad_rop_div255 u_g6 (.x({4'd0, g, 6'd0} - {10'd0, g}), .q(g6));

    reg [31:0] wr;   // bits written
    always @(*) begin
        bits = 32'd0; wr = 32'd0;
        case (fmt)
            `AD_VK_RGBA8, `AD_VK_ABGR8: begin
                bits = {a, b, g, r};
                wr   = {{8{wm[3]}}, {8{wm[2]}}, {8{wm[1]}}, {8{wm[0]}}};
            end
            `AD_VK_BGRA8: begin
                bits = {a, r, g, b};
                wr   = {{8{wm[3]}}, {8{wm[0]}}, {8{wm[1]}}, {8{wm[2]}}};
            end
            `AD_VK_R8: begin
                bits = {24'd0, r};
                wr   = {24'd0, {8{wm[0]}}};
            end
            `AD_VK_R8G8: begin
                bits = {16'd0, g, r};
                wr   = {16'd0, {8{wm[1]}}, {8{wm[0]}}};
            end
            `AD_VK_R5G6B5: begin
                bits = {16'd0, r5[4:0], g6[5:0], b5[4:0]};
                wr   = {16'd0, {5{wm[0]}}, {6{wm[1]}}, {5{wm[2]}}};
            end
            `AD_VK_A1R5G5B5: begin
                bits = {16'd0, a[7], r5[4:0], g5[4:0], b5[4:0]};
                wr   = {16'd0, wm[3], {5{wm[0]}}, {5{wm[1]}}, {5{wm[2]}}};
            end
            default: ;
        endcase
    end
    assign keep = ~wr;
endmodule
