// ad_fmt_info -- VkFormat of a colour attachment -> its ROP properties
// (spec/gpu/rop/ad_rop_wpix.md §4).  Combinational.
//   o_sup   the format has the colour-attachment feature here (else the beat is dropped)
//   o_ps    pixel bytes: 1, 2, 4, 8 or 16 (0 when unsupported)
//   o_lps   log2(o_ps) (0 when unsupported)
//   o_path  0 ad_rop_blend (UNORM 8-bit path), 1 ad_rop_fblend, 2 packing only, 3 unsupported
//   o_chm   channels the format has, bit 0 R, 1 G, 2 B, 3 A
//   o_blendable  path 0 or 1 (Vulkan blends these; path 2 ignores BLEND's enable)
module ad_fmt_info (
    input  wire [7:0] i_fmt,
    output reg        o_sup,
    output reg  [4:0] o_ps,
    output reg  [2:0] o_lps,
    output reg  [1:0] o_path,
    output reg  [3:0] o_chm,
    output wire       o_blendable
);
    // {path, lps, chm}; path 3 = unsupported
    reg [8:0] t;
    always @(*) begin
        case (i_fmt)
            // ---- path 0: ad_rop_blend ----
            8'd37, 8'd44, 8'd51:       t = {2'd0, 3'd2, 4'b1111};  // RGBA8 / BGRA8 / ABGR8_PACK32
            8'd4:                      t = {2'd0, 3'd1, 4'b0111};  // R5G6B5
            8'd8:                      t = {2'd0, 3'd1, 4'b1111};  // A1R5G5B5
            8'd9:                      t = {2'd0, 3'd0, 4'b0001};  // R8
            8'd16:                     t = {2'd0, 3'd1, 4'b0011};  // R8G8
            // ---- path 1: ad_rop_fblend ----
            8'd43, 8'd50, 8'd57:       t = {2'd1, 3'd2, 4'b1111};  // sRGB
            8'd64:                     t = {2'd1, 3'd2, 4'b1111};  // A2B10G10R10_UNORM
            8'd76:                     t = {2'd1, 3'd1, 4'b0001};  // R16_SFLOAT
            8'd83:                     t = {2'd1, 3'd2, 4'b0011};  // R16G16_SFLOAT
            8'd97:                     t = {2'd1, 3'd3, 4'b1111};  // R16G16B16A16_SFLOAT
            // ---- path 2: packing only ----
            8'd13, 8'd14:              t = {2'd2, 3'd0, 4'b0001};  // R8_UINT/SINT
            8'd20, 8'd21:              t = {2'd2, 3'd1, 4'b0011};  // R8G8_UINT/SINT
            8'd41, 8'd42, 8'd55, 8'd56: t = {2'd2, 3'd2, 4'b1111}; // RGBA8 UINT/SINT (+PACK32)
            8'd68:                     t = {2'd2, 3'd2, 4'b1111};  // A2B10G10R10_UINT
            8'd74, 8'd75:              t = {2'd2, 3'd1, 4'b0001};  // R16_UINT/SINT
            8'd81, 8'd82:              t = {2'd2, 3'd2, 4'b0011};  // R16G16_UINT/SINT
            8'd95, 8'd96:              t = {2'd2, 3'd3, 4'b1111};  // R16G16B16A16_UINT/SINT
            8'd98, 8'd99, 8'd100:      t = {2'd2, 3'd2, 4'b0001};  // R32
            8'd101, 8'd102, 8'd103:    t = {2'd2, 3'd3, 4'b0011};  // R32G32
            8'd107, 8'd108, 8'd109:    t = {2'd2, 3'd4, 4'b1111};  // R32G32B32A32
            default:                   t = {2'd3, 3'd0, 4'b0000};
        endcase
        o_path = t[8:7];
        o_sup  = (t[8:7] != 2'd3);
        o_lps  = t[6:4];
        o_chm  = t[3:0];
        o_ps   = o_sup ? (5'd1 << t[6:4]) : 5'd0;
    end
    assign o_blendable = (o_path == 2'd0) || (o_path == 2'd1);
endmodule
