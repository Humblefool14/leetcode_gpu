// ad_ds_row -- the depth/stencil test of one row of a quad on its line: the up to
// 8 entries e = 4 px + s (pixel px of the row, sample s) through ad_rop_dtest, and
// their writes merged into the line.  Combinational (the parent registers line_out).
// Entry e sits at byte off + (S px + s) ps of the line, the offset rounded down to a
// multiple of ps and taken modulo LINE_BYTES (aligned surfaces, ghci §8.5, never wrap).
module ad_ds_row #(
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5
) (
    input  wire [9:0]              depth,
    input  wire [26:0]             sfront,
    input  wire [26:0]             sback,
    input  wire [24:0]             sops,
    input  wire [31:0]             bmin,
    input  wire [31:0]             bmax,
    input  wire                    front,
    input  wire                    s4,        // four samples (S = 4), else S = 1
    input  wire                    ps2,       // 2-byte entries (D16), else 4
    input  wire [LINE_SHIFT-1:0]   off,       // byte offset of the row's first entry in the line
    input  wire [7:0]              cov,       // entry e covered (the parent masks s != 0 for S = 1)
    input  wire [255:0]            zf,        // entry e's depth at [32 e +: 32]
    input  wire [LINE_BYTES*8-1:0] line_in,
    input  wire [LINE_BYTES-1:0]   lbe_in,    // bytes of the line written so far
    output wire [7:0]              pass,
    output reg  [LINE_BYTES*8-1:0] line_out,
    output reg  [LINE_BYTES-1:0]   lbe_out
);
    // padded copy so a 32-bit read at the last entry never runs off the line
    wire [LINE_BYTES*8+31:0] lpad = {32'd0, line_in};
    wire [LINE_SHIFT-1:0] eoff [0:7];
    wire [31:0]           wword [0:7];
    wire [3:0]            wbe [0:7];
    genvar e;
    generate
        for (e = 0; e < 8; e = e + 1) begin : g_ent
            wire [4:0] idx = s4 ? (5'd4 * (e / 4) + (e % 4)) : (e / 4);    // S px + s
            wire [LINE_SHIFT+4:0] raw = {5'd0, off} + (ps2 ? {{LINE_SHIFT{1'b0}}, idx} << 1
                                                           : {{LINE_SHIFT{1'b0}}, idx} << 2);
            assign eoff[e] = ps2 ? {raw[LINE_SHIFT-1:1], 1'b0} : {raw[LINE_SHIFT-1:2], 2'b00};
            wire [31:0] w = lpad[8*eoff[e] +: 32];
            wire [31:0] stored = ps2 ? {16'd0, w[15:0]} : w;
            ad_rop_dtest u_dt (.depth(depth), .sfront(sfront), .sback(sback), .sops(sops),
                               .bmin(bmin), .bmax(bmax), .cov(cov[e]), .front(front),
                               .zf(zf[32*e +: 32]), .stored(stored),
                               .pass(pass[e]), .wword(wword[e]), .wbe(wbe[e]));
        end
    endgenerate
    // merge, decoded per byte of the line: byte j takes byte k of entry i when that
    // entry enables it and sits at j - k (the later entry wins; entries never overlap)
    integer i, j, k;
    always @(*) begin
        line_out = line_in;
        lbe_out  = lbe_in;
        for (j = 0; j < LINE_BYTES; j = j + 1)
            for (i = 0; i < 8; i = i + 1)
                for (k = 0; k < 4; k = k + 1)
                    if (wbe[i][k] && !(ps2 && k >= 2) &&
                        ({1'b0, eoff[i]} + k[LINE_SHIFT:0]) % LINE_BYTES == j) begin
                        line_out[8*j +: 8] = wword[i][8*k +: 8];
                        lbe_out[j] = 1'b1;
                    end
    end
endmodule
