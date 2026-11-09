// fv_ad_vf_vc_penc -- ad_vf_vc_penc (N 32): any == |req; when any, req[idx] is set and no lower
// bit is set (req & ((1 << idx) - 1) == 0); idx == 0 when req == 0.  Combinational, req anyconst.
module fv_ad_vf_vc_penc #(parameter N = 32, parameter W = 5) (input wire clk);
    (* anyconst *) reg [N-1:0] req;
    wire [W-1:0] idx; wire any;
    ad_vf_vc_penc #(.N(N), .IDX_W(W)) dut (.req(req), .idx(idx), .any(any));
    wire [N-1:0] below = ({{(N-1){1'b0}}, 1'b1} << idx) - 1'b1;
    always @(*) begin
        a_any: assert (any == (req != 0));
        if (any) begin
            a_set:    assert (idx < N && ((req >> idx) & 1'b1));
            a_lowest: assert ((req & below) == 0);
        end else a_zero: assert (idx == 0);
    end
endmodule
