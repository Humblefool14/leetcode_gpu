// ad_vf_fetch_extract -- the 16 raw bytes of an attribute from its one or two lines (spec §4):
//   raw byte i = byte off + i of {hi, lo}  (lo = line of addr, hi = the next line)
// so byte 0 is the byte at addr, any byte alignment.  Bytes past the end of the format (or of
// hi) are unspecified for the consumer; here they are those of {hi, lo} or 0.  Combinational.
module ad_vf_fetch_extract #(
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5
) (
    input  wire [LINE_BYTES*8-1:0] lo,
    input  wire [LINE_BYTES*8-1:0] hi,
    input  wire [LINE_SHIFT-1:0]   off,
    output wire [127:0]            raw
);
    wire [2*LINE_BYTES*8-1:0] both = {hi, lo};
    wire [2*LINE_BYTES*8-1:0] sh   = both >> {off, 3'b000};
    assign raw = sh[127:0];
endmodule
