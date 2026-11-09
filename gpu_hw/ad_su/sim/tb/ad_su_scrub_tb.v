// ad_su_scrub_tb -- ad_su_scrub alone (DEPTH 16 and 12: the address sequence, a
// start while on begins again, rst_n stops it) and inside ad_su_rf (NPHYS 8 and 4,
// default shape): every word filled with non-zero data, scrub, scrub_busy lasts
// exactly NWARPS x NREGS x 32/NPHYS cycles, then every word of every lane and both
// read ports reads 0.  (The spec's whole-SU check, every scrubbed memory of ad_su,
// belongs to the ad_su testbench.)
`timescale 1ns/1ps
module scrub_rf_h #(parameter NPHYS = 8) (input wire clk, input wire go, output reg done, output reg [31:0] err);
    localparam G = 32 / NPHYS, GRP_W = (G > 1) ? $clog2(G) : 1, NREGS = 32, NWARPS = 4, DEPTH = NWARPS * NREGS * G;
    reg rst_n = 0, w_en = 0, r_en = 0, scrub = 0; reg [1:0] w_warp = 0, r_warp = 0;
    reg [GRP_W-1:0] w_grp = 0, r_grp = 0; reg [5:0] w_reg = 0, r_reg1 = 0, r_reg2 = 0;
    reg [NPHYS*32-1:0] w_data = 0; wire [NPHYS*32-1:0] d1, d2; wire busy;
    ad_su_rf #(.NPHYS(NPHYS), .GRP_W(GRP_W)) dut (.clk(clk), .rst_n(rst_n), .w_en(w_en), .w_warp(w_warp),
        .w_grp(w_grp), .w_reg(w_reg), .w_data(w_data), .w_lanes({NPHYS{1'b1}}), .r_en(r_en), .r_warp(r_warp),
        .r_grp(r_grp), .r_reg1(r_reg1), .r_reg2(r_reg2), .r_data1(d1), .r_data2(d2), .scrub(scrub), .scrub_busy(busy));
    integer i, k, nb;
    initial begin
        done = 0; err = 0;
        wait (go); @(posedge clk); rst_n <= 1;
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge clk); w_en <= 1; w_warp <= i / (NREGS * G); w_reg <= (i / G) % NREGS; w_grp <= i % G;
            for (k = 0; k < NPHYS; k = k + 1) w_data[32*k +: 32] <= 32'h80000000 | (i << 8) | k;
        end
        @(posedge clk); w_en <= 0; r_en <= 1; r_warp <= 1; r_reg1 <= 3; r_reg2 <= 4; r_grp <= 0;
        @(posedge clk); r_en <= 0; @(posedge clk);
        if (d1 == 0 || d2 == 0) err = err + 1;            // filled
        scrub <= 1; @(posedge clk); scrub <= 0; nb = 0;
        // ad_su_wb would keep writing; a write while busy must be ignored
        w_en <= 1; w_warp <= 0; w_reg <= 0; w_grp <= 0;
        @(posedge clk); w_en <= 0;
        while (busy) begin nb = nb + 1; @(posedge clk); end
        if (nb != DEPTH) begin err = err + 1; $display("ERROR scrub rf%0d busy %0d cycles, exp %0d", NPHYS, nb, DEPTH); end
        for (i = 0; i < DEPTH; i = i + 1) begin
            r_en <= 1; r_warp <= i / (NREGS * G); r_reg1 <= (i / G) % NREGS; r_reg2 <= (i / G) % NREGS; r_grp <= i % G;
            @(posedge clk); r_en <= 0; @(posedge clk); #1;
            if (d1 !== 0 || d2 !== 0) begin err = err + 1; if (err < 4) $display("ERROR scrub rf%0d word %0d not 0", NPHYS, i); end
        end
        done = 1;
    end
endmodule

module ad_su_scrub_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    // ---- the counter alone ----
    reg rst_n = 0, start = 0; wire on16, on12; wire [3:0] a16, a12;
    ad_su_scrub #(.DEPTH(16)) s16 (.clk(clk), .rst_n(rst_n), .start(start), .on(on16), .a(a16));
    ad_su_scrub #(.DEPTH(12)) s12 (.clk(clk), .rst_n(rst_n), .start(start), .on(on12), .a(a12));
    integer cerr = 0, n, rst_at;
    task run_seq(input integer restart_at, input integer reset_at);
        integer t, exp16, exp12;
        begin
            @(posedge clk); start <= 1; @(posedge clk); start <= 0;
            exp16 = 0; exp12 = 0;
            for (t = 0; t < 40; t = t + 1) begin
                #1;
                if (on16 !== (exp16 < 16) || (on16 && a16 !== exp16)) begin cerr = cerr + 1; $display("ERROR scrub16 t %0d on %b a %0d exp %0d", t, on16, a16, exp16); end
                if (on12 !== (exp12 < 12) || (on12 && a12 !== exp12)) begin cerr = cerr + 1; $display("ERROR scrub12 t %0d on %b a %0d exp %0d", t, on12, a12, exp12); end
                if (t == restart_at) start <= 1; else start <= 0;
                if (t == reset_at) rst_n <= 0; else rst_n <= 1;
                @(posedge clk);
                if (t == restart_at) begin exp16 = 0; exp12 = 0; end
                else if (t == reset_at) begin exp16 = 99; exp12 = 99; end
                else begin if (exp16 < 16) exp16 = exp16 + 1; if (exp12 < 12) exp12 = exp12 + 1; end
            end
        end
    endtask
    wire d8, d4; wire [31:0] e8, e4; reg go = 0;
    scrub_rf_h #(.NPHYS(8)) r8 (.clk(clk), .go(go), .done(d8), .err(e8));
    scrub_rf_h #(.NPHYS(4)) r4 (.clk(clk), .go(go), .done(d4), .err(e4));
    initial begin
        repeat (2) @(posedge clk); rst_n <= 1;
        run_seq(-1, -1);       // plain
        run_seq(5, -1);        // restart while on
        run_seq(-1, 7);        // reset stops it
        if (cerr == 0) $display("PASS ad_su_scrub.counter"); else $display("FAIL ad_su_scrub.counter");
        go = 1;
        wait (d8 && d4);
        if (e8 == 0 && e4 == 0) $display("PASS ad_su_scrub.rf"); else $display("FAIL ad_su_scrub.rf");
        if (cerr == 0 && e8 == 0 && e4 == 0) $display("PASS ad_su_scrub");
        $finish;
    end
endmodule
