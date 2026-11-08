// ad_su_exec_tb -- self-checking TB of ad_su_exec (spec §8) on NPHYS 4 and 8.
// Vectors from tools/gen_ad_su_exec_vectors.py (the EXEC-unit semantics of
// tools/gsi1model.py).  Each instruction goes on the bus as 32/NPHYS groups
// with random gaps (ALU groups in some gaps, which must be ignored); the TB
// checks EXEC/KILLED (q_exec/q_killed) after it, wc_* exactly the cycle after
// the last group of a branch/end/bar (and no wc_* otherwise), and exec.save's
// short result SHORT_LAT cycles after each group (every lane, all-ones/0 per
// the lane's EXEC bit).
`timescale 1ns/1ps
module ad_su_exec_h #(parameter NPHYS = 8, parameter SEED = 1) (input wire clk, input wire rst_n);
    localparam NWARPS = 4, WARP_W = 2, GRP_W = (NPHYS == 32) ? 1 : $clog2(32 / NPHYS), SBE_W = 2;
    localparam G = 32 / NPHYS, SHORT_LAT = 6;
    `include "ad_su_uop.vh"
    reg                 x_valid = 0, x_last = 0;
    reg  [WARP_W-1:0]   x_warp = 0;
    reg  [GRP_W-1:0]    x_grp = 0;
    reg  [15:0]         x_pc = 0;
    reg  [AD_UOP_W-1:0] x_uop = 0;
    reg  [NPHYS*32-1:0] x_a = 0;
    reg                 init_valid = 0;
    reg  [WARP_W-1:0]   init_warp = 0, q_warp = 0;
    reg  [31:0]         init_mask = 0;
    wire x_ready, s_valid, wc_valid;
    wire [WARP_W-1:0] s_warp, wc_warp;
    wire [GRP_W-1:0] s_grp;
    wire [6:0] s_rd;
    wire [NPHYS*32-1:0] s_data;
    wire [NPHYS-1:0] s_lanes;
    wire [1:0] wc_op;
    wire [15:0] wc_pc;
    wire [31:0] q_exec, q_killed;

    ad_su_exec #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W),
                 .UOP_W(AD_UOP_W), .SHORT_LAT(SHORT_LAT)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last),
        .x_sbe(3'b111), .x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b({NPHYS*32{1'b1}}),
        .x_c({NPHYS*32{1'b1}}), .x_mask({2*NPHYS{1'b1}}), .x_info(32'd0), .x_ready(x_ready),
        .s_valid(s_valid), .s_warp(s_warp), .s_grp(s_grp), .s_rd(s_rd), .s_data(s_data),
        .s_lanes(s_lanes), .wc_valid(wc_valid), .wc_warp(wc_warp), .wc_op(wc_op), .wc_pc(wc_pc),
        .q_warp(q_warp), .q_exec(q_exec), .q_killed(q_killed), .init_valid(init_valid),
        .init_warp(init_warp), .init_mask(init_mask));

    integer errors = 0, cyc = 0, seed = SEED;
    // expected short results
    integer sq_due [0:63];
    reg [WARP_W+GRP_W+7+NPHYS*32-1:0] sq_d [0:63];
    integer sqh = 0, sqt = 0;
    // expected wc
    integer wc_due = -1;
    reg [WARP_W+2+16-1:0] wc_exp;
    always @(posedge clk) if (rst_n) begin
        cyc <= cyc + 1;
        #1;
        if (s_valid) begin
            if (sqh == sqt || sq_due[sqh % 64] != cyc || {s_warp, s_grp, s_rd, s_data} !== sq_d[sqh % 64]
                || s_lanes !== {NPHYS{1'b1}}) begin
                $display("FAIL ad_su_exec: NPHYS %0d unexpected/wrong short result at %0d", NPHYS, cyc);
                errors = errors + 1;
            end
            if (sqh != sqt) sqh = sqh + 1;
        end else if (sqh != sqt && sq_due[sqh % 64] <= cyc) begin
            $display("FAIL ad_su_exec: NPHYS %0d missing short result", NPHYS); errors = errors + 1; sqh = sqh + 1;
        end
        if (wc_valid !== (wc_due == cyc)) begin
            $display("FAIL ad_su_exec: NPHYS %0d wc_valid %0d at %0d (due %0d)", NPHYS, wc_valid, cyc, wc_due);
            errors = errors + 1;
        end else if (wc_valid && {wc_warp, wc_op, wc_pc} !== wc_exp) begin
            $display("FAIL ad_su_exec: NPHYS %0d wc %h exp %h", NPHYS, {wc_warp, wc_op, wc_pc}, wc_exp);
            errors = errors + 1;
        end
    end

    task gap;
        integer n, k;
        begin
            n = (($random(seed) & 3) == 0) ? ($random(seed) & 3) : 0;
            for (k = 0; k < n; k = k + 1) begin
                x_valid = ($random(seed) & 1);             // another unit's group
                x_uop = 0; x_uop[AD_UOP_UNIT +: 4] = AD_UNIT_ALU; x_uop[AD_UOP_OP +: 8] = 8'd14;
                x_last = 1; x_a = {NPHYS{32'h1}};
                @(posedge clk); #2;
            end
            x_valid = 0;
        end
    endtask

    // record r of vec (46 words from index 1 + 46 r)
    task do_rec(input integer r);
        integer b, gidx, ln;
        reg [31:0] v [0:45];
        reg [31:0] ex_before;
        begin
            for (b = 0; b < 46; b = b + 1) v[b] = ad_su_exec_tb.vec[1 + 46 * r + b];
            if (v[0] == 0) begin
                init_valid = 1; init_warp = v[1]; init_mask = v[6];
                @(posedge clk); #2; init_valid = 0;
            end else begin
                ex_before = v[45];
                for (gidx = 0; gidx < G; gidx = gidx + 1) begin
                    gap;
                    x_valid = 1; x_warp = v[1]; x_grp = gidx; x_last = (gidx == G - 1); x_pc = v[4];
                    x_uop = 0; x_uop[AD_UOP_UNIT +: 4] = AD_UNIT_EXEC; x_uop[AD_UOP_OP +: 8] = v[2];
                    x_uop[AD_UOP_USE1] = v[3]; x_uop[AD_UOP_IMM +: 32] = v[5];
                    x_uop[AD_UOP_WRD] = v[44]; x_uop[AD_UOP_RD +: 7] = (v[2] * 3) % 63;
                    x_uop[AD_UOP_CLS +: 3] = AD_CLS_A;
                    for (ln = 0; ln < NPHYS; ln = ln + 1) x_a[32*ln +: 32] = v[7 + gidx * NPHYS + ln];
                    if (v[44]) begin
                        sq_due[sqt % 64] = cyc + SHORT_LAT;
                        sq_d[sqt % 64][NPHYS*32 +: WARP_W+GRP_W+7] = {x_warp, x_grp, x_uop[AD_UOP_RD +: 7]};
                        for (ln = 0; ln < NPHYS; ln = ln + 1)
                            sq_d[sqt % 64][32*ln +: 32] = ex_before[gidx * NPHYS + ln] ? 32'hFFFFFFFF : 0;
                        sqt = sqt + 1;
                    end
                    if (x_last && v[41]) begin wc_due = cyc + 1; wc_exp = {v[1][WARP_W-1:0], v[42][1:0], v[43][15:0]}; end
                    @(posedge clk); #2;
                    x_valid = 0;
                end
            end
            q_warp = v[1]; #1;
            if (q_exec !== v[39] || q_killed !== v[40]) begin
                $display("FAIL ad_su_exec: NPHYS %0d rec %0d op %0d exec %h/%h killed %h/%h", NPHYS, r, v[2],
                         q_exec, v[39], q_killed, v[40]);
                errors = errors + 1;
            end
        end
    endtask
endmodule

module ad_su_exec_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg [31:0] vec [0:200000];
    ad_su_exec_h #(.NPHYS(4), .SEED(3)) h4 (.clk(clk), .rst_n(rst_n));
    ad_su_exec_h #(.NPHYS(8), .SEED(4)) h8 (.clk(clk), .rst_n(rst_n));
    integer r, e0, errs = 0;

    task run(input [8*64-1:0] file, input [8*16-1:0] name);
        begin
            e0 = h4.errors + h8.errors;
            $readmemh(file, vec);
            for (r = 0; r < vec[0]; r = r + 1) h4.do_rec(r);
            repeat (10) @(posedge clk);
            for (r = 0; r < vec[0]; r = r + 1) h8.do_rec(r);
            repeat (10) @(posedge clk);
            if (h4.errors + h8.errors == e0) $display("PASS ad_su_exec.%0s", name);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk); #2;
        run("sim/vec/ad_su_exec_branch.hex", "branch");
        run("sim/vec/ad_su_exec_exec.hex", "exec");
        run("sim/vec/ad_su_exec_endbar.hex", "endbar");
        e0 = h4.errors + h8.errors;
        $readmemh("sim/vec/ad_su_exec_mix.hex", vec);
        for (r = 0; r < vec[0]; r = r + 1) h4.do_rec(r);
        for (r = 0; r < vec[0]; r = r + 1) h8.do_rec(r);
        repeat (10) @(posedge clk);
        if (h4.errors + h8.errors == 0) $display("PASS ad_su_exec");
        else $display("FAIL ad_su_exec: %0d errors", h4.errors + h8.errors);
        $finish;
    end
endmodule
