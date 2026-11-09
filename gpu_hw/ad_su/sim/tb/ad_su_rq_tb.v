// ad_su_rq_tb -- ad_su_rq with HAS_SA 0 (spec §8): empty and full are 1 and
// every other output is 0 whatever the inputs do (random stimulus, NPHYS 4
// and 8).
`timescale 1ns/1ps
module ad_su_rq_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg pop = 0, push = 0, ctl_valid = 0, sa_push_ready = 0, sa_pop_valid = 0;
    reg [255:0] push_data = 0, sa_pop_data = 0;
    reg [31:0] ctl_data = 0, sa_qstat = 0, sa_stat = 0, sa_qtag = 0;
    wire [255:0] pop_data8, sa_push_data8; wire [127:0] pop_data4, sa_push_data4;
    wire e8, f8, spv8, spr8, scv8, e4, f4, spv4, spr4, scv4;
    wire [31:0] scd8, scd4;
    ad_su_rq #(.NPHYS(8), .HAS_SA(0)) r8 (.clk(clk), .rst_n(rst_n), .pop(pop), .pop_data(pop_data8), .push(push),
        .push_data(push_data), .empty(e8), .full(f8), .ctl_valid(ctl_valid), .ctl_data(ctl_data),
        .sa_push_valid(spv8), .sa_push_ready(sa_push_ready), .sa_push_data(sa_push_data8), .sa_pop_valid(sa_pop_valid),
        .sa_pop_ready(spr8), .sa_pop_data(sa_pop_data), .sa_ctl_valid(scv8), .sa_ctl_data(scd8),
        .sa_qstat(sa_qstat), .sa_stat(sa_stat), .sa_qtag(sa_qtag));
    ad_su_rq #(.NPHYS(4), .HAS_SA(0)) r4 (.clk(clk), .rst_n(rst_n), .pop(pop), .pop_data(pop_data4), .push(push),
        .push_data(push_data[127:0]), .empty(e4), .full(f4), .ctl_valid(ctl_valid), .ctl_data(ctl_data),
        .sa_push_valid(spv4), .sa_push_ready(sa_push_ready), .sa_push_data(sa_push_data4), .sa_pop_valid(sa_pop_valid),
        .sa_pop_ready(spr4), .sa_pop_data(sa_pop_data[127:0]), .sa_ctl_valid(scv4), .sa_ctl_data(scd4),
        .sa_qstat(sa_qstat), .sa_stat(sa_stat), .sa_qtag(sa_qtag));
    integer i, errors = 0, seed = 9;
    initial begin
        for (i = 0; i < 2000; i = i + 1) begin
            @(negedge clk);
            rst_n = i > 2;
            {pop, push, ctl_valid, sa_push_ready, sa_pop_valid} = $random(seed);
            push_data = {8{$random(seed)}}; sa_pop_data = {8{$random(seed)}};
            ctl_data = $random(seed); sa_qstat = $random(seed); sa_stat = $random(seed); sa_qtag = $random(seed);
            #1;
            if ({e8, f8, e4, f4} !== 4'hF || {spv8, spr8, scv8, spv4, spr4, scv4} !== 0 || pop_data8 !== 0 ||
                sa_push_data8 !== 0 || pop_data4 !== 0 || sa_push_data4 !== 0 || scd8 !== 0 || scd4 !== 0) begin
                $display("FAIL ad_su_rq.v1: outputs at step %0d", i); errors = errors + 1;
            end
        end
        if (errors == 0) $display("PASS ad_su_rq.v1");
        if (errors == 0) $display("PASS ad_su_rq"); else $display("FAIL ad_su_rq: %0d errors", errors);
        $finish;
    end
endmodule
