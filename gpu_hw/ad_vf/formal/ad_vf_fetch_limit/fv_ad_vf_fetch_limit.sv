// fv_ad_vf_fetch_limit -- the ATTR_LIMIT compare against a direct 49-bit reference:
//   oob == limit[31] && (end49 > {18'b0, limit[30:0]})   for every end49 and limit word.
// Built with -DMUT_ATTR_LIMIT_GE the check must fail (task mut).
module fv_ad_vf_fetch_limit (input wire clk);
    (* anyconst *) reg [48:0] end49;
    (* anyconst *) reg [31:0] limit;
    wire oob;
    ad_vf_fetch_limit dut (.end49(end49), .limit(limit), .oob(oob));
    wire ref_oob = limit[31] && (end49 > {18'd0, limit[30:0]});
    always @(*) begin
        a_ref: assert (oob == ref_oob);
        c_eq:  cover (limit[31] && end49 == {18'd0, limit[30:0]});
    end
endmodule
