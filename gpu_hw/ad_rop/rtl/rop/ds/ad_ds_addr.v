// ad_ds_addr -- byte address of the first entry of each row of a quad and its line:
//   row r: base + (y + r) stride + S x ps   (modulo 2^ADDR_W)
// line_r = address >> LINE_SHIFT, off_r = its low LINE_SHIFT bits.  Combinational.
module ad_ds_addr #(
    parameter ADDR_W     = 32,
    parameter LINE_SHIFT = 5
) (
    input  wire [31:0]                  base,
    input  wire [31:0]                  stride,
    input  wire [15:0]                  x,
    input  wire [15:0]                  y,
    input  wire                         s4,     // S = 4
    input  wire                         ps2,    // ps = 2
    output wire [ADDR_W-LINE_SHIFT-1:0] line0,
    output wire [ADDR_W-LINE_SHIFT-1:0] line1,
    output wire [LINE_SHIFT-1:0]        off0,
    output wire [LINE_SHIFT-1:0]        off1
);
    wire [ADDR_W-1:0] b  = base[ADDR_W-1:0];
    wire [ADDR_W-1:0] st = stride[ADDR_W-1:0];
    // x * S * ps = x << log2(S ps): 1 (S1, D16), 2 (S1, 4 B), 3 (S4, D16), 4 (S4, 4 B)
    wire [2:0]  sh = (s4 ? 3'd3 : 3'd1) + (ps2 ? 3'd0 : 3'd1);
    wire [ADDR_W+19:0] xo = {{ADDR_W{1'b0}}, 4'd0, x} << sh;
    wire [ADDR_W+15:0] yo = {{ADDR_W{1'b0}}, y} * {16'd0, st};
    wire [ADDR_W-1:0] a0 = b + yo[ADDR_W-1:0] + xo[ADDR_W-1:0];
    wire [ADDR_W-1:0] a1 = a0 + st;
    assign line0 = a0[ADDR_W-1:LINE_SHIFT];
    assign line1 = a1[ADDR_W-1:LINE_SHIFT];
    assign off0  = a0[LINE_SHIFT-1:0];
    assign off1  = a1[LINE_SHIFT-1:0];
endmodule
