// ad_dtest_depth -- format-specific depth compare of the new depth zf against the
// stored word, and the depth bits to write.  Combinational.
//   D32F: ad_fp_cmp(zf, stored) (fp32 order, -0 = +0, NaN unordered); writes zf.
//   D24 : ad_f2unorm #(24)(zf) against stored[23:0], unsigned; writes {8'h0, u24}.
//   D16 : ad_f2unorm #(16)(zf) against stored[15:0], unsigned; writes {16'h0, u16}.
// A NaN zf makes the D16/D24 comparison unordered as well (ad_cmp_op: only
// NOT_EQUAL and ALWAYS pass).  fmt is one-hot {d16, d32f, d24}; with another
// value the outputs are don't-care (the parent ignores them).
module ad_dtest_depth (
    input  wire [2:0]  fmt,      // {D16, D32F, D24S8} = DEPTH[7:5]
    input  wire [2:0]  op,       // VkCompareOp, DEPTH[4:2]
    input  wire [31:0] zf,
    input  wire [31:0] stored,
    output wire        dpass,
    output wire [31:0] zword
);
    wire [23:0] u24;
    wire [15:0] u16;
    ad_f2unorm #(.N(24)) u_f24 (.f(zf), .u(u24));
    ad_f2unorm #(.N(16)) u_f16 (.f(zf), .u(u16));
    wire flt, feq, fun;
    ad_fp_cmp u_fcmp (.a(zf), .b(stored), .lt(flt), .eq(feq), .un(fun));
    wire znan = (zf[30:23] == 8'hFF) && (zf[22:0] != 23'd0);
    reg lt, eq, un;
    always @(*) begin
        if (fmt[1]) begin
            lt = flt; eq = feq; un = fun;
        end else if (fmt[2]) begin
            lt = !znan && (u16 <  stored[15:0]);
            eq = !znan && (u16 == stored[15:0]);
            un = znan;
        end else begin
            lt = !znan && (u24 <  stored[23:0]);
            eq = !znan && (u24 == stored[23:0]);
            un = znan;
        end
    end
    ad_cmp_op u_op (.op(op), .lt(lt), .eq(eq), .un(un), .pass(dpass));
    assign zword = fmt[1] ? zf : fmt[2] ? {16'h0, u16} : {8'h0, u24};
endmodule
