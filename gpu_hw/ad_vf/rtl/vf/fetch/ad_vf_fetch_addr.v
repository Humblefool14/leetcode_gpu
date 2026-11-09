// ad_vf_fetch_addr -- address of one attribute of one vertex (spec §4):
//   offset = stride * element                (48 bits, exact)
//   addr   = ATTR_BASE + offset mod 2^32
//   end49  = offset + size                   (49 bits, cannot wrap; for the ATTR_LIMIT check)
// and the lines it touches: line0 = addr >> LINE_SHIFT, line1 = (addr + size - 1) >> LINE_SHIFT
// (mod 2^ADDR_W), two = the attribute crosses into a second line, off = byte offset in line0.
// size is 1..16, LINE_BYTES >= 16, so at most two lines.  Combinational.
module ad_vf_fetch_addr #(
    parameter ADDR_W     = 32,
    parameter LINE_SHIFT = 5
) (
    input  wire [31:0]                  base,
    input  wire [15:0]                  stride,
    input  wire [31:0]                  elem,
    input  wire [4:0]                   size,
    output wire [31:0]                  addr,
    output wire [48:0]                  end49,
    output wire [ADDR_W-LINE_SHIFT-1:0] line0,
    output wire [ADDR_W-LINE_SHIFT-1:0] line1,
    output wire                         two,
    output wire [LINE_SHIFT-1:0]        off
);
    wire [47:0] offset = stride * elem;
    wire [31:0] lastb;
    assign addr  = base + offset[31:0];
    assign end49 = {1'b0, offset} + {44'd0, size};
    assign lastb = addr + {27'd0, size} - 32'd1;
    assign line0 = addr[ADDR_W-1:LINE_SHIFT];
    assign line1 = lastb[ADDR_W-1:LINE_SHIFT];
    assign two   = (line0 != line1);
    assign off   = addr[LINE_SHIFT-1:0];
endmodule
