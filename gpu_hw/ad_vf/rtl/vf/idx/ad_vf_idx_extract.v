// ad_vf_idx_extract -- one index out of an index-buffer line (spec/gpu/vf/ad_vf_index.md section 4).
// off is the byte offset of the index in the line; INDEX_BASE is aligned to the index size, so a
// u16 sits at an even offset and a u32 at a multiple of 4 (the low offset bits are ignored).
// u16 is zero-extended.  Line byte 0 is rdata[7:0].
module ad_vf_idx_extract #(
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5
) (
    input  wire [LINE_BYTES*8-1:0] line,
    input  wire [LINE_SHIFT-1:0]   off,
    input  wire                    u32,
    output wire [31:0]             idx
);
    wire [LINE_SHIFT-1:0] m1 = 1, m3 = 3;
    wire [LINE_SHIFT-1:0] o2 = off & ~m1;       // (any LINE_SHIFT >= 2)
    wire [LINE_SHIFT-1:0] o4 = off & ~m3;
    wire [15:0] w16 = line[{o2, 3'b000} +: 16];
    wire [31:0] w32 = line[{o4, 3'b000} +: 32];
    assign idx = u32 ? w32 : {16'd0, w16};
endmodule
