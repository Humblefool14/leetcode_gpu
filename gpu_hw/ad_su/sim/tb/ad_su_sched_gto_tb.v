// ad_su_sched_gto_tb -- GTO scheduling of ad_su_sched (spec §8, Phase 012),
// GTO = 1 on NPHYS 8 and 32 (NWARPS 4).  The environment and its always-on
// checks (every selection against the greedy-then-oldest reference: the
// greedy warp when it is a candidate, else the candidate with the largest
// age, ages from the TB's own model) are in sim/tb/ad_su_sched_env.vh.
`timescale 1ns/1ps
module ad_su_sched_gto_h #(
    parameter NPHYS = 8, parameter NWARPS = 4, parameter WARP_W = 2, parameter NSU = 1,
    parameter SU_INDEX = 0, parameter FRAG_RESERVE = 1, parameter GTO = 1, parameter SEED = 1
) (input wire clk, input wire rst_n);
    `include "ad_su_state.vh"
    `include "sim/tb/ad_su_sched_env.vh"

    integer c, n, run, maxrun, g0, nsw, nold;
    reg [WARP_W-1:0] lastw, oldgw;

    // greedy: the greedy warp is fetched again as soon as it can be (its
    // feedback turnaround, or the issue gap), so it runs to its end first
    integer lastt, first_end, iv, maxiv;
    task t_greedy;
        begin
            bases; prog_straight(60); frdy_pct = 100; fbd_min = 1; fbd_max = 1;
            n_sel = 0; n_greedy = 0;
            for (i = 0; i < NWARPS; i = i + 1) n_take[i] = 0;
            grid(128, 1, 1, 1);
            c = 0; g0 = -1; lastt = -1; maxiv = 0; first_end = -1;
            while (c < 4000 && busy) begin
                @(posedge clk);
                if (f_valid && f_ready) begin
                    if (g0 < 0) g0 = f_warp;
                    if (f_warp == g0) begin
                        if (lastt >= 0 && cyc - lastt > maxiv) maxiv = cyc - lastt;
                        lastt = cyc;
                    end
                end
                if (wc_valid && wc_op == 1 && first_end < 0) first_end = wc_warp;
                c = c + 1;
            end
            wait_idle(2000);
            for (i = 0; i < NWARPS; i = i + 1) if (n_take[i] != 61) begin
                $display("FAIL %m: warp %0d %0d fetches", i, n_take[i]); errors = errors + 1; end
            iv = (G > 3) ? G : 3;      // take, feedback a cycle later, READY, selected, taken
            if (maxiv > iv) begin $display("FAIL %m: greedy warp fetched %0d cycles apart (best %0d)", maxiv, iv); errors = errors + 1; end
            if (first_end != g0) begin $display("FAIL %m: warp %0d ended first, greedy was %0d", first_end, g0); errors = errors + 1; end
        end
    endtask

    // stall_switch: warp_ready of the greedy warp falls: the next selection is another warp,
    // which becomes the greedy one
    task t_stall;
        begin
            prog_straight(60); frdy_pct = 100; fbd_min = 1; fbd_max = 3;
            grid(128, 1, 1, 1);
            nsw = 0; c = 0;
            while (c < 3000 && busy) begin
                @(negedge clk);
                if (dut.gv && warp_ready[dut.gw] && nsw < 20 && ($random(seed) & 3) == 0) begin
                    oldgw = dut.gw;
                    wr_low = 1 << oldgw; warp_ready[oldgw] = 0; #1;
                    if (|dut.cand && (!f_valid || f_ready)) begin
                        if (dut.sel_w == oldgw) begin $display("FAIL %m: stalled greedy warp selected"); errors = errors + 1; end
                        @(posedge clk); #1;
                        if (dut.gw !== dut.f_warp || dut.gw == oldgw) begin $display("FAIL %m: no switch of the greedy warp"); errors = errors + 1; end
                        nsw = nsw + 1;
                    end
                    repeat ($random(seed) & 7) @(negedge clk);
                    wr_low = 0;
                end
                c = c + 1;
            end
            wait_idle(3000);
            if (nsw < 5) begin $display("FAIL %m: only %0d switches", nsw); errors = errors + 1; end
        end
    endtask

    // oldest: with random warp_ready many selections are not greedy; each must be the oldest
    task t_oldest;
        begin
            prog_straight(50); frdy_pct = 70; fbd_min = 1; fbd_max = 6; wr_rand = 1;
            n_sel = 0; n_greedy = 0;
            grid(128, 1, 1, 1);
            wait_idle(8000);
            wr_rand = 0;
            nold = n_sel - n_greedy;
            if (nold < 20) begin $display("FAIL %m: only %0d oldest selections", nold); errors = errors + 1; end
        end
    endtask

    // no_replay: the TB's scoreboard model replays an instruction of a warp with a pending
    // long result; warp_ready is 0 while one is pending, so no replay may happen
    task t_noreplay;
        begin
            prog_straight(60); frdy_pct = 80; fbd_min = 1; fbd_max = 5; long_pct = 30;
            n_replay = 0; n_rp = 0;
            grid(128, 1, 1, 1); grid(96, 1, 1, 1);
            wait_idle(20000);
            long_pct = 0;
            if (n_replay != 0 || n_rp != 0) begin $display("FAIL %m: %0d replays", n_replay + n_rp); errors = errors + 1; end
        end
    endtask
endmodule

module ad_su_sched_gto_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    ad_su_sched_gto_h #(.NPHYS(8), .SEED(7)) h8 (.clk(clk), .rst_n(rst_n));
    ad_su_sched_gto_h #(.NPHYS(32), .SEED(8)) h32 (.clk(clk), .rst_n(rst_n));
    integer e0;
    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1;
        e0 = h8.errors + h32.errors;
        fork h8.t_greedy; h32.t_greedy; join
        if (h8.errors + h32.errors == e0) $display("PASS ad_su_sched_gto.greedy");
        e0 = h8.errors + h32.errors;
        fork h8.t_stall; h32.t_stall; join
        if (h8.errors + h32.errors == e0) $display("PASS ad_su_sched_gto.stall_switch");
        e0 = h8.errors + h32.errors;
        fork h8.t_oldest; h32.t_oldest; join
        if (h8.errors + h32.errors == e0) $display("PASS ad_su_sched_gto.oldest");
        e0 = h8.errors + h32.errors;
        fork h8.t_noreplay; h32.t_noreplay; join
        if (h8.errors + h32.errors == e0) $display("PASS ad_su_sched_gto.no_replay");
        if (h8.errors + h32.errors == 0) $display("PASS ad_su_sched_gto");
        else $display("FAIL ad_su_sched_gto: %0d errors", h8.errors + h32.errors);
        $finish;
    end
endmodule
