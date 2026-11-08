// ad_su_sched_tb -- self-checking TB of ad_su_sched (spec §8) with GTO = 0
// (round-robin), on NPHYS 4 and 8 (NWARPS 4, FRAG_RESERVE 1, NSU 2 with
// SU_INDEX 1 and 0).  The environment and its always-on checks are in
// sim/tb/ad_su_sched_env.vh.
`timescale 1ns/1ps
module ad_su_sched_h #(
    parameter NPHYS = 8, parameter NWARPS = 4, parameter WARP_W = 2, parameter NSU = 2,
    parameter SU_INDEX = 0, parameter FRAG_RESERVE = 1, parameter GTO = 0, parameter SEED = 1
) (input wire clk, input wire rst_n);
    `include "ad_su_state.vh"
    `include "sim/tb/ad_su_sched_env.vh"

    integer e0, n, nv, c, id, kk, ex;
    reg [NWARPS-1:0] seen;
    reg [31:0] im;

    task t_rr;
        begin
            bases; prog_straight(30); frdy_pct = 75; fbd_min = 2; fbd_max = 6;
            for (i = 0; i < NWARPS; i = i + 1) n_take[i] = 0;
            grid(128, NSU, 1, 1);
            wait_idle(5000);
            for (i = 0; i < NWARPS; i = i + 1)
                if (n_take[i] != 31) begin $display("FAIL %m: warp %0d took %0d fetches", i, n_take[i]); errors = errors + 1; end
        end
    endtask

    task t_alloc;
        begin
            prog_straight(40);
            for (w = 0; w < NWARPS; w = w + 1) prog[w * 64 + 10] = {2'd1, 2'd0, 16'd0};  // loop
            // pt_ok 0: no vertex grant
            @(negedge clk); pt_ok = 0; vl_req = 1;
            repeat (20) begin @(negedge clk); if (vl_gnt) begin $display("FAIL %m: vertex grant without pt_ok"); errors = errors + 1; end end
            pt_ok = 1; nv = 0;
            for (n = 0; n < NWARPS; n = n + 1) begin
                c = 0; vl_req = 1;
                while (!vl_gnt && c < 40) begin @(negedge clk); c = c + 1; end
                if (vl_gnt) begin
                    nv = nv + 1; vl_req = 0; kk = vl_slot;
                    repeat (rnd(0, 5)) @(negedge clk);
                    vl_mask = $random(seed); vl_go = 1; @(negedge clk); vl_go = 0;
                    c = 0; while (!(init_valid && init_warp == kk) && c < 10) begin #1; if (!(init_valid && init_warp == kk)) @(negedge clk); c = c + 1; end
                    if (init_mask !== vl_mask) begin $display("FAIL %m: vertex init mask"); errors = errors + 1; end
                    @(posedge clk); #1; q_warp = kk; #1;
                    if (q_info[AD_WI_KIND +: 2] !== 0 || q_info[AD_WI_MASK +: 32] !== vl_mask || q_info[AD_WI_LID +: 8] !== 0) begin
                        $display("FAIL %m: vertex q_info %h", q_info); errors = errors + 1; end
                end
            end
            vl_req = 0;
            if (nv != NWARPS - FRAG_RESERVE) begin $display("FAIL %m: %0d vertex grants (NWARPS %0d FRAG_RESERVE %0d)", nv, NWARPS, FRAG_RESERVE); errors = errors + 1; end
            // fragment: takes the reserved slot
            @(negedge clk); fl_req = 1; c = 0;
            while (!fl_gnt && c < 40) begin @(negedge clk); c = c + 1; end
            if (!fl_gnt) begin $display("FAIL %m: no fragment grant"); errors = errors + 1; end
            fl_req = 0; kk = fl_slot;
            repeat (3) @(negedge clk);
            fl_mask = 32'h0F0F_00FF; fl_info = {15'h1234, 1'b1, 16'hBEEF, 32'h0303_0011}; fl_go = 1;
            @(negedge clk); fl_go = 0;
            repeat (3) @(negedge clk);
            q_warp = kk; #1;
            if (q_info[AD_WI_KIND +: 2] !== 1 || q_info[AD_WI_SEQ +: 16] !== 16'hBEEF || q_info[AD_WI_FRONT] !== 1'b1 ||
                q_info[AD_WI_MASK +: 32] !== 32'h0303_0011) begin $display("FAIL %m: fragment q_info %h", q_info); errors = errors + 1; end
            // full: no further grant of either kind
            fl_req = 1; vl_req = 1;
            repeat (30) begin @(negedge clk); if (fl_gnt || vl_gnt) begin $display("FAIL %m: grant with no free slot"); errors = errors + 1; end end
            fl_req = 0; vl_req = 0;
            for (w = 0; w < NWARPS; w = w + 1) prog[w * 64 + 10] = {2'd1, 2'd1, 16'd0};   // end
            wait_idle(3000);
        end
    endtask

    task t_feedback;
        begin
            for (i = 0; i < NWARPS * 64; i = i + 1) prog[i] = (rnd(0, 99) < 15) ? {2'd2, 18'd0} : 0;
            for (w = 0; w < NWARPS; w = w + 1) begin
                prog[w * 64 + 5]  = {2'd1, 2'd0, 16'd20};      // branch to 20
                prog[w * 64 + 21] = {2'd1, 2'd0, 16'd22 + w[15:0]};  // to 22 + w
                prog[w * 64 + 30] = {2'd1, 2'd1, 16'd0};       // end
            end
            for (i = 0; i < NWARPS; i = i + 1) n_take[i] = 0;
            n_rp = 0; frdy_pct = 60; fbd_max = 9;
            grid(128, NSU, 1, 1);
            wait_idle(5000);
            // fetches: pcs 0..5, 20, 21, then 22+w .. 30, plus replays
            n = 0; for (i = 0; i < NWARPS; i = i + 1) n = n + n_take[i];
            ex = n_rp; for (w = 0; w < NWARPS; w = w + 1) ex = ex + 8 + (30 - (22 + w) + 1);
            if (n != ex) begin $display("FAIL %m: %0d fetches, expected %0d (%0d replays)", n, ex, n_rp); errors = errors + 1; end
            if (n_rp == 0) begin $display("FAIL %m: no replay exercised"); errors = errors + 1; end
        end
    endtask

    task t_compute(input [31:0] wgs);
        begin
            prog_straight(4); frdy_pct = 90;
            grid(wgs, 2, 2, 1);
            n = 0; c = 0;
            while (c < 3000 && (busy || n == 0)) begin
                @(posedge clk);
                if (init_valid) begin
                    kk = init_warp; im = init_mask;
                    #1; q_warp = kk; #1;
                    id = q_info[AD_WI_WGX +: 16] + 2 * q_info[AD_WI_WGX + 16 +: 16];
                    ex = q_info[AD_WI_LID +: 8] / 32;
                    if (id % NSU != SU_INDEX || q_info[AD_WI_WGX + 32 +: 16] !== 0 || q_info[AD_WI_KIND +: 2] !== 2 ||
                        q_info[AD_WI_NWGX +: 48] !== {16'd1, 16'd2, 16'd2} || q_info[AD_WI_LID +: 8] % 32 != 0 ||
                        q_info[AD_WI_MASK +: 32] !== ((wgs - 32 * ex >= 32) ? 32'hFFFFFFFF : (32'd1 << (wgs - 32 * ex)) - 1) ||
                        q_info[AD_WI_MASK +: 32] !== im) begin
                        $display("FAIL %m: compute q_info %h (id %0d k %0d) init_mask %h", q_info, id, ex, im); errors = errors + 1;
                    end
                    if (n != 2 * (id / NSU) + ex) begin $display("FAIL %m: start %0d is id %0d warp %0d", n, id, ex); errors = errors + 1; end
                    n = n + 1;
                end
                c = c + 1;
            end
            if (n != 4) begin $display("FAIL %m: %0d compute warps started", n); errors = errors + 1; end
            wait_idle(2000);
        end
    endtask

    task t_barrier;
        begin
            for (i = 0; i < NWARPS * 64; i = i + 1) prog[i] = 0;
            for (w = 0; w < NWARPS; w = w + 1) begin
                prog[w * 64 + 3] = {2'd1, 2'd2, 16'd4};
                prog[w * 64 + 6] = {2'd1, 2'd2, 16'd7};
                prog[w * 64 + 9] = {2'd1, 2'd1, 16'd0};
            end
            fbd_max = 15; frdy_pct = 80;
            for (i = 0; i < NWARPS; i = i + 1) n_take[i] = 0;
            grid(128, NSU, 1, 1);
            wait_idle(5000);
            for (i = 0; i < NWARPS; i = i + 1) if (n_take[i] != 10) begin $display("FAIL %m: barrier: warp %0d %0d fetches", i, n_take[i]); errors = errors + 1; end
            // one warp ends before the second barrier: the others still continue
            prog[3 * 64 + 5] = {2'd1, 2'd1, 16'd0};
            grid(128, NSU, 1, 1);
            wait_idle(5000);
        end
    endtask

    task t_end;
        begin
            xr_auto = 0; prog_straight(2); frdy_pct = 100;
            for (n = 0; n < NWARPS; n = n + 1) begin
                @(negedge clk); fl_req = 1;
                while (!fl_gnt) @(negedge clk);
                fl_req = 0; kk = fl_slot;
                fl_mask = 32'hFFFF; fl_info = n; fl_go = 1; @(negedge clk); fl_go = 0;
            end
            // all end; no slot is freed without xr
            c = 0; while (c < 200 && (fqh != fqt || wqh != wqt)) begin @(negedge clk); c = c + 1; end
            repeat (5) @(negedge clk);
            for (w = 0; w < NWARPS; w = w + 1) if (m_st[w] != 6) begin $display("FAIL %m: warp %0d not ended", w); errors = errors + 1; end
            fl_req = 1;
            repeat (30) begin @(negedge clk); if (fl_gnt) begin $display("FAIL %m: grant before xr_valid"); errors = errors + 1; end end
            fl_req = 0;
            if (!busy) begin $display("FAIL %m: not busy with ended warps"); errors = errors + 1; end
            xq_due[xqt % 64] = cyc; xq_w[xqt % 64] = 2; xqt = xqt + 1;
            @(negedge clk); @(negedge clk); fl_req = 1; c = 0;
            while (!fl_gnt && c < 10) begin @(negedge clk); c = c + 1; end
            if (!fl_gnt || fl_slot !== 2) begin $display("FAIL %m: no grant of the freed slot"); errors = errors + 1; end
            fl_req = 0; fl_go = 1; @(negedge clk); fl_go = 0;
            xr_auto = 1;
            for (w = 0; w < NWARPS; w = w + 1) if (w != 2) begin xq_due[xqt % 64] = cyc + w; xq_w[xqt % 64] = w; xqt = xqt + 1; end
            wait_idle(2000);
        end
    endtask
endmodule

module ad_su_sched_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    ad_su_sched_h #(.NPHYS(4), .SU_INDEX(1), .SEED(5)) h4 (.clk(clk), .rst_n(rst_n));
    ad_su_sched_h #(.NPHYS(8), .SU_INDEX(0), .SEED(6)) h8 (.clk(clk), .rst_n(rst_n));
    integer e0;
    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1;
        e0 = h4.errors + h8.errors;
        fork h4.t_rr; h8.t_rr; join
        if (h4.errors + h8.errors == e0) $display("PASS ad_su_sched.rr");
        e0 = h4.errors + h8.errors;
        fork h4.t_alloc; h8.t_alloc; join
        if (h4.errors + h8.errors == e0) $display("PASS ad_su_sched.alloc");
        e0 = h4.errors + h8.errors;
        fork h4.t_feedback; h8.t_feedback; join
        if (h4.errors + h8.errors == e0) $display("PASS ad_su_sched.feedback");
        e0 = h4.errors + h8.errors;
        fork h4.t_compute(64); h8.t_compute(64); join
        fork h4.t_compute(40); h8.t_compute(40); join
        if (h4.errors + h8.errors == e0) $display("PASS ad_su_sched.compute");
        e0 = h4.errors + h8.errors;
        fork h4.t_barrier; h8.t_barrier; join
        if (h4.errors + h8.errors == e0) $display("PASS ad_su_sched.barrier");
        e0 = h4.errors + h8.errors;
        fork h4.t_end; h8.t_end; join
        if (h4.errors + h8.errors == e0) $display("PASS ad_su_sched.end");
        if (h4.errors + h8.errors == 0) $display("PASS ad_su_sched");
        else $display("FAIL ad_su_sched: %0d errors", h4.errors + h8.errors);
        $finish;
    end
endmodule
