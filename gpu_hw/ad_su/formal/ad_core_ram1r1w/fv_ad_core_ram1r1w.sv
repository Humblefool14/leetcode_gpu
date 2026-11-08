// fv_ad_core_ram1r1w -- ad_su_ram1r1w (DW 2, AW 3): for a symbolic address, a read
// returns the next cycle the last word written there before the read's cycle (old word
// on a same-cycle write); rq holds while re is 0.
module fv_ad_core_ram1r1w (input wire clk, input wire we, input wire [2:0] wa, input wire [1:0] wd,
                           input wire re, input wire [2:0] ra);
    reg init = 1; always @(posedge clk) init <= 0;
    wire [1:0] rq;
    ad_su_ram1r1w #(.DW(2), .AW(3)) dut (.clk(clk), .we(we), .wa(wa), .wd(wd), .re(re), .ra(ra), .rq(rq));
    (* anyconst *) reg [2:0] A;
    reg [1:0] sh; reg kn = 0, p_hit = 0, p_re = 0, p_kn = 0, p_ok = 0; reg [1:0] p_sh, p_rq;
    always @(posedge clk) begin
        if (we && wa == A) begin sh <= wd; kn <= 1; end
        p_hit <= re && ra == A; p_re <= re; p_sh <= sh; p_kn <= kn; p_rq <= rq; p_ok <= !init;
    end
    always @(*) if (p_ok) begin
        if (p_hit && p_kn) assert (rq == p_sh);
        if (!p_re) assert (rq == p_rq);
    end
endmodule
