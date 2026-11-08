// ad_rop_mrt_tb -- four colour attachments (CAPS[30]) through ad_rop_wb + ad_rop_wpix + blend
// (TB model, or -DAD_REAL_BLEND) + ad_rop_fblend (see the .f) + ad_amb_mem, LINE_BYTES 32 and
// 64, against tools/wb_model.py (sim/vec/wb_mrt_cmd_<LB>.hex / wb_mrt_exp_<LB>.hex from
// tools/gen_wb_vectors.py): 12 runs with one sample and 12 with four per line size; each run
// four attachments of different formats (paths 0, 1, 2; absent and unsupported ones;
// attachment 0 by RT_FORMAT's code), random write masks and blends, 24 beats (15 % without
// colour); the four targets' region compared byte for byte after the drain.
// Skeleton of spec ad_rop_wb.md §8: the integrator reruns it with the real blend/fblend
// (formats outside the TB models' lists then need the real models in tools/wb_model.py).
// -DMUT_WPIX_LINE and -DMUT_WPIX_KEEP (spec §7) make it fail.
`timescale 1ns/1ps
`include "sim/tb/ad_rop_wb_tb.vh"

module ad_rop_mrt_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    ad_rop_wb_bench #(.LINE_BYTES(32), .LINE_SHIFT(5), .CMDF("sim/vec/wb_mrt_cmd_32.hex"),
                      .EXPF("sim/vec/wb_mrt_exp_32.hex"), .SEED(7)) b32 (.clk(clk));
    ad_rop_wb_bench #(.LINE_BYTES(64), .LINE_SHIFT(6), .CMDF("sim/vec/wb_mrt_cmd_64.hex"),
                      .EXPF("sim/vec/wb_mrt_exp_64.hex"), .SEED(9)) b64 (.clk(clk));
    integer e1, e4, ed;
    initial begin
        wait (b32.done && b64.done);
        e1 = b32.err_sec[0] + b64.err_sec[0];
        e4 = b32.err_sec[1] + b64.err_sec[1];
        ed = b32.err_drain + b64.err_drain;
        if (b32.n_runs != 24 || b64.n_runs != 24) begin ed = ed + 1; $display("FAIL ad_rop_mrt coverage"); end
        if (ed != 0) $display("FAIL ad_rop_mrt drain/AMB errors %0d", ed);
        if (e1 == 0 && ed == 0) $display("PASS ad_rop_mrt.one");
        if (e4 == 0 && ed == 0) $display("PASS ad_rop_mrt.four");
        if (e1 + e4 + ed == 0) $display("PASS ad_rop_mrt");
        $finish;
    end
    initial begin #200000000; $display("FAIL ad_rop_mrt timeout"); $finish; end
endmodule
