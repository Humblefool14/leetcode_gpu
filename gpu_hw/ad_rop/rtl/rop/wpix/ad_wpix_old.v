// ad_wpix_old -- the old pixel of each slot, read from its entry's line
// (spec/gpu/rop/ad_rop_wpix.md §10 "area"): the 16-byte block of the slot's offset,
// then its ps bytes at the offset rounded down to a multiple of ps; bytes above ps 0.
// Combinational.
module ad_wpix_old #(
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5
) (
    input  wire [LINE_BYTES*8-1:0] i_line0,
    input  wire [LINE_BYTES*8-1:0] i_line1,
    input  wire [3:0]              i_ent,
    input  wire [4*LINE_SHIFT-1:0] i_soff,
    input  wire [2:0]              i_lps,
    output wire [511:0]            o_old     // slot k at [128 k +: 128]
);
    localparam LS = LINE_SHIFT;
    localparam NB = LINE_BYTES / 16;          // 16-byte blocks in a line
    wire [3:0]   pm   = (4'd1 << i_lps) - 4'd1;
    wire [127:0] keep = ~({128{1'b1}} << ({4'd0, 4'd1 << i_lps} << 3));   // low ps bytes (ps = 16: all)
    genvar k;
    generate for (k = 0; k < 4; k = k + 1) begin : g_slot
        wire [LINE_BYTES*8-1:0] ln  = i_ent[k] ? i_line1 : i_line0;
        wire [LS-1:0]           so  = i_soff[k*LS +: LS];
        wire [LS-5:0]           bi  = so[LS-1:4];
        wire [127:0]            blk = ln[128*bi +: 128];
        wire [3:0]              bo  = so[3:0] & ~pm;
        wire [127:0]            pix = blk >> {bo, 3'b000};
        assign o_old[128*k +: 128] = (i_lps >= 3'd4) ? blk : (pix & keep);
    end endgenerate
endmodule
