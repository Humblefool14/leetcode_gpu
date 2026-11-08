// ad_ds_row merge: a byte of the line changes only where its byte enable is set
// (lbe_out covers every changed byte), lbe only grows, an uncovered row changes
// nothing, pass only for covered entries.  ad_rop_dtest abstracted (fv_dtest_stub).
module fv_ad_ds_row;
    localparam LB = 32, LS = 5;
    (* anyconst *) reg [9:0]  depth;
    (* anyconst *) reg        s4, ps2, front;
    (* anyconst *) reg [LS-1:0] off;
    (* anyconst *) reg [7:0]  cov;
    (* anyconst *) reg [255:0] zf;
    (* anyconst *) reg [LB*8-1:0] line_in;
    (* anyconst *) reg [LB-1:0] lbe_in;
    wire [7:0] pass; wire [LB*8-1:0] line_out; wire [LB-1:0] lbe_out;
    ad_ds_row #(.LINE_BYTES(LB), .LINE_SHIFT(LS)) dut (
        .depth(depth), .sfront(27'd0), .sback(27'd0), .sops(25'd0), .bmin(32'd0), .bmax(32'd0),
        .front(front), .s4(s4), .ps2(ps2), .off(off), .cov(cov), .zf(zf),
        .line_in(line_in), .lbe_in(lbe_in), .pass(pass), .line_out(line_out), .lbe_out(lbe_out));
    reg be_ok; integer j;
    always @(*) begin
        be_ok = 1'b1;
        for (j = 0; j < LB; j = j + 1)
            if (line_out[8*j +: 8] != line_in[8*j +: 8] && !lbe_out[j]) be_ok = 1'b0;
    end
    always @(*) begin
        a_grow: assert ((lbe_out & lbe_in) == lbe_in);
        a_pass: assert ((pass & ~cov) == 8'd0);
        if (cov == 8'd0) a_nocov: assert (line_out == line_in && lbe_out == lbe_in);
        a_be: assert (be_ok);
    end
endmodule
