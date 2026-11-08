// ad_wpix_place -- places of a beat's pixels in the render-target lines
// (spec/gpu/rop/ad_rop_wpix.md §4 "Places").  Combinational.
// S = 4 (i_s4) or 1 samples; sample s of pixel x at (S x + s) ps of the row, the row
// at base + y stride (y = quad y + i_r).  A quad's row is 2 S ps bytes:
//   one line  (2 S ps <= LINE_BYTES): pass g's slot k = lane k, sample g, entry k >> 1,
//             byte i_off(k>>1) + (S (k & 1) + g) ps;
//   several   (o_multi): line j of row r holds slots n = E j + k, k < E = LINE_BYTES / ps
//             (lane 2 r + n / 4, sample n mod 4) at byte k ps of entry r; one pass.
// Lane l, sample s survives when i_smask[4 l + s] (with one sample only bit 4 l counts).
module ad_wpix_place #(
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5
) (
    input  wire [31:0]             i_base,
    input  wire [31:0]             i_stride,
    input  wire [31:0]             i_xy,      // {y, x}
    input  wire [15:0]             i_smask,
    input  wire [2:0]              i_lps,     // log2(ps)
    input  wire                    i_s4,      // four samples
    input  wire                    i_r,
    input  wire [1:0]              i_j,
    input  wire [1:0]              i_g,
    input  wire [LINE_SHIFT-1:0]   i_off0,
    input  wire [LINE_SHIFT-1:0]   i_off1,
    output wire [31:0]             o_addr,
    output wire [1:0]              o_nl,
    output wire [1:0]              o_np,
    output wire                    o_multi,
    output wire                    o_lw,
    output reg  [3:0]              o_mask,
    output reg  [3:0]              o_ent,
    output reg  [4*LINE_SHIFT-1:0] o_soff,
    output reg  [7:0]              o_lane     // slot k's source lane at [2k +: 2]
);
    localparam [31:0] LS = LINE_SHIFT;
    wire [15:0] x = i_xy[15:0];
    wire [15:0] y = i_xy[31:16];
    wire [15:0] sm = i_s4 ? i_smask : (i_smask & 16'h1111);

    // log2 of the quad row's bytes: 1 + 2 s4 + lps
    wire [3:0] rowl  = 4'd1 + {2'd0, i_s4, 1'b0} + {1'b0, i_lps};
    assign o_multi = ({28'd0, rowl} > LS);
    wire [3:0] dl    = rowl - LS[3:0];                        // log2(lines of a row), 1 or 2
    assign o_nl    = o_multi ? ((dl == 4'd1) ? 2'd1 : 2'd3) : 2'd0;
    assign o_np    = i_s4 ? 2'd3 : 2'd0;

    wire [16:0] yr    = {1'b0, y} + {16'd0, i_r};
    wire [31:0] yoff  = {15'd0, yr} * i_stride;
    wire [31:0] xoff  = {16'd0, x} << (i_lps + {i_s4, 1'b0});
`ifdef MUT_WPIX_LINE
    wire [31:0] joff  = 32'd0;                            // mutation: the line index left out
`else
    wire [31:0] joff  = o_multi ? ({30'd0, i_j} << LS) : 32'd0;
`endif
    assign o_addr = i_base + yoff + xoff + joff;

    // several lines: E = LINE_BYTES / ps slots a line (2 or 4)
    wire [3:0] le = LS[3:0] - {1'b0, i_lps};                          // log2(E) (<= 2 when o_multi)
    wire [7:0] rbits = i_r ? sm[15:8] : sm[7:0];          // lanes 2r, 2r+1, every sample (index n)
    integer k;
    reg [3:0] n;
    reg       one_lw;
    always @(*) begin
        o_mask = 4'd0; o_ent = 4'd0; o_soff = {4*LS{1'b0}}; o_lane = 8'd0;
        n = 4'd0;
        for (k = 0; k < 4; k = k + 1) begin
            if (o_multi) begin
                n = ({2'd0, i_j} << le) + k[3:0];
                o_ent[k]  = i_r;
                o_lane[2*k +: 2] = {i_r, n[2]};
                if (k < (1 << le)) begin
                    o_mask[k] = rbits[n[2:0]];
                    o_soff[k*LS +: LS] = k[LS-1:0] << i_lps;
                end
            end else begin
                o_ent[k]  = k[1];
                o_lane[2*k +: 2] = k[1:0];
                o_mask[k] = sm[4*k + {30'd0, i_g}];
                o_soff[k*LS +: LS] = (k[1] ? i_off1 : i_off0) +
                                     (({{(LS-3){1'b0}}, (i_s4 ? {k[0], 2'b00} : {2'b00, k[0]})} + {{(LS-2){1'b0}}, i_g}) << i_lps);
            end
        end
    end
    assign o_lw = o_multi ? (|o_mask) : (|rbits);
endmodule
