// ad_blend_unpack8 -- one 32-bit destination lane + VkFormat -> RGBA8 (spec ad_rop_blend.md §4).
// Missing alpha (R8, R8G8, R5G6B5) reads 255; missing G/B of R8/R8G8 read 0; 5/6-bit fields
// expand by bit replication; A1 reads 0 or 255.  ok = 0 for a format outside the 8-bit list
// (then r/g/b/a = 0).
`include "ad_rop_state.vh"
module ad_blend_unpack8 (
    input  wire [31:0] lane,
    input  wire [7:0]  fmt,
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b,
    output reg  [7:0]  a,
    output reg         ok
);
    always @(*) begin
        r = 8'd0; g = 8'd0; b = 8'd0; a = 8'hFF; ok = 1'b1;
        case (fmt)
            `AD_VK_RGBA8, `AD_VK_ABGR8: begin
                r = lane[7:0]; g = lane[15:8]; b = lane[23:16]; a = lane[31:24];
            end
            `AD_VK_BGRA8: begin
                b = lane[7:0]; g = lane[15:8]; r = lane[23:16]; a = lane[31:24];
            end
            `AD_VK_R8: begin
                r = lane[7:0];
            end
            `AD_VK_R8G8: begin
                r = lane[7:0]; g = lane[15:8];
            end
            `AD_VK_R5G6B5: begin
                r = {lane[15:11], lane[15:13]};
                g = {lane[10:5],  lane[10:9]};
                b = {lane[4:0],   lane[4:2]};
            end
            `AD_VK_A1R5G5B5: begin
                a = {8{lane[15]}};
                r = {lane[14:10], lane[14:12]};
                g = {lane[9:5],   lane[9:7]};
                b = {lane[4:0],   lane[4:2]};
            end
            default: begin
                a = 8'd0; ok = 1'b0;
            end
        endcase
    end
endmodule
