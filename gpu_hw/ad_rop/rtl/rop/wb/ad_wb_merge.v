// ad_wb_merge -- byte enables and data to merge a pass's pixels into the two line
// entries (spec/gpu/rop/ad_rop_wb.md §4, §10 "area").  Combinational.
// Slot k (i_mask[k]) writes the whole ps-byte unit that holds its offset i_soff[k] in
// entry i_ent[k]: line byte b of that unit takes byte (b mod ps) of the slot's pixel
// (i_res[128 k], its low ps bytes).  The lowest slot wins if two slots hit one unit.
module ad_wb_merge #(
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5
) (
    input  wire                    i_en,
    input  wire [511:0]            i_res,
    input  wire [3:0]              i_mask,
    input  wire [3:0]              i_ent,
    input  wire [4*LINE_SHIFT-1:0] i_soff,
    input  wire [2:0]              i_lps,
    output reg  [LINE_BYTES-1:0]   o_we0,
    output reg  [LINE_BYTES-1:0]   o_we1,
    output reg  [LINE_BYTES*8-1:0] o_wd0,
    output reg  [LINE_BYTES*8-1:0] o_wd1
);
    localparam LS = LINE_SHIFT;
    wire [LS-1:0] um = ~(({{(LS-1){1'b0}}, 1'b1} << i_lps) - 1'b1);   // unit mask (~(ps-1))
    wire [3:0]    pm = (4'd1 << i_lps) - 4'd1;
    integer b, k;
    reg [LS-1:0] bb;
    reg [3:0]    bi;
    reg          h0, h1;
    always @(*) begin
        o_we0 = {LINE_BYTES{1'b0}}; o_we1 = {LINE_BYTES{1'b0}};
        o_wd0 = {LINE_BYTES*8{1'b0}}; o_wd1 = {LINE_BYTES*8{1'b0}};
        for (b = 0; b < LINE_BYTES; b = b + 1) begin
            bb = b[LS-1:0];
            bi = bb[3:0] & pm;                       // byte within the pixel
            h0 = 1'b0; h1 = 1'b0;
            for (k = 3; k >= 0; k = k - 1) begin     // descending: slot 0 wins last
                if (i_en && i_mask[k] && ((bb & um) == (i_soff[k*LS +: LS] & um))) begin
                    if (!i_ent[k]) begin h0 = 1'b1; o_wd0[8*b +: 8] = i_res[128*k + 8*bi +: 8]; end
                    else           begin h1 = 1'b1; o_wd1[8*b +: 8] = i_res[128*k + 8*bi +: 8]; end
                end
            end
            o_we0[b] = h0; o_we1[b] = h1;
        end
    end
endmodule
