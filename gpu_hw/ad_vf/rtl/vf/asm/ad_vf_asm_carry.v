// ad_vf_asm_carry -- which run vertices are re-sent into the next warp's lanes 0 and 1
// (spec section 4).  Run slots: r0 / r1 (strip: older / newer of the last two; fan: first / last;
// line strip: r1 the last; line list: r0 the started vertex; triangle list: r0 A, r1 B).
//   strip: n>=2 -> r0, r1; n==1 -> r1          fan: n>=2 -> r0, r1; n==1 -> r0
//   triangle list: pos 2 -> r0, r1; pos 1 -> r0  line list: pos 1 -> r0
//   line strip: n>=1 -> r1                      point: none
// Outputs: cnt (0..2), c0_r1 (lane 0 gets r1, else r0; lane 1 always gets r1) and the run's
// new lanes: r0_l0 (r0 moves to lane 0), r1_l (r1's new lane, when r1 is carried).
module ad_vf_asm_carry (
    input  wire [2:0] cls,
    input  wire [1:0] n,
    output reg  [1:0] cnt,
    output reg        c0_r1,
    output reg        r0_mv,    // r0 is carried (to lane 0)
    output reg        r1_mv,    // r1 is carried (to lane r1_l)
    output reg        r1_l      // r1's new lane (0 or 1)
);
    always @(*) begin
        cnt = 2'd0; c0_r1 = 1'b0;
        if (n != 2'd0) case (cls)
            3'd1:       cnt = 2'd1;
            3'd2:       begin cnt = 2'd1; c0_r1 = 1'b1; end
            3'd3, 3'd5: cnt = (n >= 2'd2) ? 2'd2 : 2'd1;
            3'd4:       begin cnt = (n >= 2'd2) ? 2'd2 : 2'd1; c0_r1 = (n == 2'd1); end
            default:    cnt = 2'd0;
        endcase
        r0_mv = (cnt != 2'd0) && !c0_r1;
        r1_mv = (cnt == 2'd2) || c0_r1;
        r1_l  = (cnt == 2'd2);
    end
endmodule
