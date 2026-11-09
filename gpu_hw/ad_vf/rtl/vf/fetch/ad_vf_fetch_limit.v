// ad_vf_fetch_limit -- ATTR_LIMIT check of ad_vf_fetch (spec §4, CAPS[30]):
//   oob = ATTR_LIMIT[31] && (offset + size > ATTR_LIMIT[30:0])
// with end49 = offset + size computed in 49 bits (no wrap).  Written as "a bit above 30 is set,
// or the low 31 bits exceed the limit" (the formal harness compares with a direct 49-bit >).
// MUT_ATTR_LIMIT_GE (mutation, spec §10): the compare as >= (an attribute ending exactly at the
// limit becomes out of bounds); ad_vf_fetch_tb.limit and the formal check must fail.
module ad_vf_fetch_limit (
    input  wire [48:0] end49,
    input  wire [31:0] limit,
    output wire        oob
);
    wire hi = |end49[48:31];
`ifdef MUT_ATTR_LIMIT_GE
    wire lo = (end49[30:0] >= limit[30:0]);
`else
    wire lo = (end49[30:0] >  limit[30:0]);
`endif
    assign oob = limit[31] && (hi || lo);
endmodule
