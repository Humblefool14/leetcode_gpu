// fv_ad_hazard_prienc -- any = |req; idx is a set bit and every lower bit is clear.
module fv_ad_hazard_prienc;
    (* anyconst *) reg [15:0] req;
    wire any; wire [3:0] idx;
    ad_hazard_prienc #(.N(16), .IDX_W(4)) dut (.req(req), .any(any), .idx(idx));
    wire [15:0] below = (16'd1 << idx) - 16'd1;
    always @(*) begin
        a_any: assert (any == (|req));
        if (any) begin
            a_set: assert (req[idx]);
            a_low: assert ((req & below) == 16'd0);
        end else a_zero: assert (idx == 4'd0);
    end
endmodule
