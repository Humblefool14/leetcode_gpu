// fv_ad_su_rq -- ad_su_rq with HAS_SA 0: for every input sequence empty and
// full are 1 and every other output is 0.
module fv_ad_su_rq (input wire clk, input wire rst_n, input wire pop, push, ctl_valid, sa_push_ready, sa_pop_valid,
                    input wire [127:0] push_data, sa_pop_data, input wire [31:0] ctl_data, sa_qstat, sa_stat, sa_qtag);
    wire [127:0] pd, spd; wire e, f, spv, spr, scv; wire [31:0] scd;
    ad_su_rq #(.NPHYS(4), .HAS_SA(0)) dut (.clk(clk), .rst_n(rst_n), .pop(pop), .pop_data(pd), .push(push),
        .push_data(push_data), .empty(e), .full(f), .ctl_valid(ctl_valid), .ctl_data(ctl_data),
        .sa_push_valid(spv), .sa_push_ready(sa_push_ready), .sa_push_data(spd), .sa_pop_valid(sa_pop_valid),
        .sa_pop_ready(spr), .sa_pop_data(sa_pop_data), .sa_ctl_valid(scv), .sa_ctl_data(scd),
        .sa_qstat(sa_qstat), .sa_stat(sa_stat), .sa_qtag(sa_qtag));
    always @(*) begin
        a_flags: assert (e && f);
        a_zero:  assert (pd == 0 && spd == 0 && !spv && !spr && !scv && scd == 0);
    end
endmodule
