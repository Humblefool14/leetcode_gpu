// ad_su_lda_tb -- ad_su_lda against an in-TB scoreboard (the semantics of tools/gsi1model.py's
// lda with --prims: PT word imm[8:2], vertex imm[1:0]; 0 for vertex 3, words 0-3 and past
// 4 + VARY_WORDS), in the shapes NPHYS 8 / 16 varying words, NPHYS 16 / 64 (two read cycles),
// NPHYS 32 / 32 (four read cycles) and NPHYS 4 / 64.  RX-style writes (every warp's map and table
// words, also words past VARY_WORDS, vertex 3 and primitives' words that must not land), then
// random lda groups (any warp, group, rd, imm, with and without WRD, back to back, held while
// x_ready is 0) mixed with other units' groups, also in the later read cycles.  Checks s_*
// exactly SHORT_LAT cycles after each take, x_ready 0 exactly in the later read cycles of a
// group, and the d_s words 0xFF8-0xFFB (multisampling) touching neither the table nor the map.
`timescale 1ns/1ps
module lda_h #(parameter NPHYS = 8, parameter VW = 16, parameter SEED = 1) (
    input  wire clk,
    input  wire rst_n,
    input  wire run,
    output reg  done,
    output reg [31:0] e_rw,
    output reg [31:0] e_ms,
    output reg [31:0] e_rdy,
    output reg [31:0] nres
);
`include "ad_su_uop.vh"
    localparam WARP_W = 2, GRP_W = (NPHYS == 32) ? 1 : $clog2(32 / NPHYS), GPW = 32 / NPHYS;
    localparam NQ = NPHYS / 4, NC = (NQ < 2) ? NQ : 2, NR = NQ / NC, L = 6, PRIMS = 8;
    localparam DEPTH = 4 * PRIMS * 3 * VW;
    reg x_valid; reg [WARP_W-1:0] x_warp; reg [GRP_W-1:0] x_grp; reg [107:0] x_uop;
    reg [2*NPHYS-1:0] x_mask;
    wire x_ready, s_valid; wire [WARP_W-1:0] s_warp; wire [GRP_W-1:0] s_grp; wire [6:0] s_rd;
    wire [NPHYS*32-1:0] s_data; wire [NPHYS-1:0] s_lanes;
    reg pw_we; reg [WARP_W-1:0] pw_warp; reg [11:0] pw_addr; reg [31:0] pw_data;
    reg scrub; wire scrub_busy;
    ad_su_lda #(.NPHYS(NPHYS), .NWARPS(4), .WARP_W(WARP_W), .GRP_W(GRP_W), .PRIMS(PRIMS),
                .VARY_WORDS(VW), .SHORT_LAT(L)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
        .x_last(1'b0), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a({NPHYS{32'h1}}),
        .x_b({NPHYS{32'h2}}), .x_c({NPHYS{32'h3}}), .x_mask(x_mask), .x_info(32'h0001_0000),
        .x_ready(x_ready), .s_valid(s_valid), .s_warp(s_warp), .s_grp(s_grp), .s_rd(s_rd),
        .s_data(s_data), .s_lanes(s_lanes), .pw_we(pw_we), .pw_warp(pw_warp),
        .pw_addr(pw_addr), .pw_data(pw_data), .scrub(scrub), .scrub_busy(scrub_busy));

    integer seed;
    initial seed = SEED;
    reg [31:0] tab [0:DEPTH-1];          // [warp][prim][vtx][w]
    reg [23:0] map [0:3];

    // expected results by cycle
    integer cyc;
    localparam NE = 64;
    reg ev [0:NE-1];
    reg [WARP_W-1:0] ew [0:NE-1]; reg [GRP_W-1:0] eg [0:NE-1]; reg [6:0] erd [0:NE-1];
    reg [NPHYS*32-1:0] ed [0:NE-1]; reg [NPHYS-1:0] el [0:NE-1];
    integer rdy_until;                   // x_ready must be 0 up to this cycle
    integer i, l, qw, pr, wd, vx;
    reg [NPHYS*32-1:0] dv;
    always @(posedge clk) begin
        if (!rst_n) begin
            cyc = 0;
            for (i = 0; i < NE; i = i + 1) ev[i] = 0;
            rdy_until = -1;
            e_rw = 0; e_rdy = 0; nres = 0;
        end else begin
            // x_ready this cycle
            if (x_ready !== (cyc > rdy_until)) begin
                e_rdy = e_rdy + 1;
                $display("FAIL lda%0d: x_ready %b at cycle %0d (busy until %0d)", NPHYS, x_ready,
                         cyc, rdy_until);
            end
            // the result due this cycle
            if (s_valid !== ev[cyc % NE] || (ev[cyc % NE] && (s_warp !== ew[cyc % NE] ||
                s_grp !== eg[cyc % NE] || s_rd !== erd[cyc % NE] || s_data !== ed[cyc % NE] ||
                s_lanes !== el[cyc % NE]))) begin
                e_rw = e_rw + 1;
                if (e_rw < 10)
                    $display("FAIL lda%0d: cycle %0d s_valid %b/%b rd %0d data %h exp %h", NPHYS,
                             cyc, s_valid, ev[cyc % NE], s_rd, s_data, ed[cyc % NE]);
            end
            if (ev[cyc % NE]) nres = nres + 1;
            ev[cyc % NE] = 0;
            // a take this cycle
            if (x_valid && x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_LDA && x_ready) begin
                vx = x_uop[AD_UOP_IMM +: 2];
                wd = x_uop[AD_UOP_IMM + 2 +: 7];
                for (l = 0; l < NPHYS; l = l + 1) begin
                    qw = x_grp * NQ + l / 4;
                    pr = map[x_warp][3*qw +: 3];
                    dv[32*l +: 32] = (vx == 3 || wd < 4 || wd >= 4 + VW) ? 32'd0 :
                                     tab[((x_warp * PRIMS + pr) * 3 + vx) * VW + wd - 4];
                end
                ev[(cyc + L) % NE] = x_uop[AD_UOP_WRD];
                ew[(cyc + L) % NE] = x_warp; eg[(cyc + L) % NE] = x_grp;
                erd[(cyc + L) % NE] = x_uop[AD_UOP_RD +: 7]; ed[(cyc + L) % NE] = dv;
                el[(cyc + L) % NE] = x_mask[NPHYS-1:0];
                rdy_until = cyc + NR - 1;
            end
            cyc = cyc + 1;
        end
    end

    integer w, p, v, k, n, it, a;
    reg [31:0] d;
    task pw(input [1:0] ww, input [11:0] aa, input [31:0] dd);
        begin
            @(negedge clk);
            pw_we = 1; pw_warp = ww; pw_addr = aa; pw_data = dd;
            @(negedge clk);
            pw_we = 0;
        end
    endtask
    task fill;
        begin
            for (w = 0; w < 4; w = w + 1) begin
                d = $random(seed);
                map[w] = d[23:0];
                pw(w, 12'hFFF, d);
                for (p = 0; p < PRIMS; p = p + 1)
                    for (v = 0; v < 4; v = v + 1)
                        for (k = 0; k < 64; k = k + 1)
                            if ((v < 3 && k < VW) || ($random(seed) & 15) == 0) begin
                                d = $random(seed);
                                if (v < 3 && k < VW) tab[((w * PRIMS + p) * 3 + v) * VW + k] = d;
                                pw(w, {1'b0, p[2:0], v[1:0], k[5:0]}, d);
                            end
            end
        end
    endtask
    task reads(input integer cnt);
        begin
            for (it = 0; it < cnt; it = it + 1) begin
                @(negedge clk);
                x_valid = 0;
                n = $random(seed) & 7;
                if (n < 5) begin
                    x_valid = 1;
                    x_uop = 108'd0;
                    x_uop[AD_UOP_UNIT +: 4] = AD_UNIT_LDA;
                    x_uop[AD_UOP_WRD] = (n != 0);
                    x_uop[AD_UOP_RD +: 7] = $random(seed);
                    a = $random(seed);
                    x_uop[AD_UOP_IMM +: 32] = ((a & 7) == 0) ? a : (a & 32'h1FF) | (32'h7 << 9);
                    if ((a & 3) == 1) x_uop[AD_UOP_IMM + 2 +: 7] = 4 + (($random(seed) & 63) % VW);
                    x_warp = $random(seed);
                    x_grp = $random(seed) % GPW;
                    x_mask = $random(seed);
                    @(posedge clk);
                    while (!x_ready) @(posedge clk);  // held until taken
                    #1;
                end else if (n < 7) begin
                    x_valid = 1;               // another unit's group, also in the read cycles
                    x_uop = 108'd0;
                    x_uop[AD_UOP_UNIT +: 4] = AD_UNIT_ALU;
                    x_uop[AD_UOP_WRD] = 1;
                    x_warp = $random(seed);
                    x_grp = $random(seed) % GPW;
                end
            end
            @(negedge clk);
            x_valid = 0;
            repeat (L + 2) @(posedge clk);
        end
    endtask

    integer t, mmis;
    initial begin
        done = 0; e_ms = 0;
        x_valid = 0; x_warp = 0; x_grp = 0; x_uop = 0; x_mask = 0;
        pw_we = 0; pw_warp = 0; pw_addr = 0; pw_data = 0; scrub = 0;
        @(posedge run);
        @(negedge clk);
        scrub = 1;
        @(negedge clk);
        scrub = 0;
        t = 0;
        while (scrub_busy) begin
            @(negedge clk);
            t = t + 1;
        end
        if (t != DEPTH) begin
            e_rw = e_rw + 1;
            $display("FAIL lda%0d: scrub %0d cycles", NPHYS, t);
        end
        fill;
        reads(1500);
        // .ms: the d_s words of every warp: neither the table nor the map change
        for (w = 0; w < 4; w = w + 1)
            for (k = 0; k < 4; k = k + 1) pw(w, 12'hFF8 + k, $random(seed));
        mmis = 0;
        for (w = 0; w < 4; w = w + 1) if (dut.pmap[w] !== map[w]) mmis = mmis + 1;
        for (k = 0; k < DEPTH; k = k + 1) begin
            if (dut.cp[0].mem[k] !== tab[k]) mmis = mmis + 1;
            if (dut.cp[NC-1].mem[k] !== tab[k]) mmis = mmis + 1;
        end
        if (mmis != 0) begin
            e_ms = e_ms + 1;
            $display("FAIL lda%0d: %0d words changed by the d_s writes", NPHYS, mmis);
        end
        fill;
        reads(1500);
        done = 1;
    end
endmodule

module ad_su_lda_tb;
    reg clk = 0, rst_n = 0, run = 0;
    always #5 clk = ~clk;
    wire d8, d16, d32, d4;
    wire [31:0] r8, m8, y8, n8, r16, m16, y16, n16, r32, m32, y32, n32, r4, m4, y4, n4;
    lda_h #(.NPHYS(8), .VW(16), .SEED(1)) h8 (.clk(clk), .rst_n(rst_n), .run(run), .done(d8),
        .e_rw(r8), .e_ms(m8), .e_rdy(y8), .nres(n8));
    lda_h #(.NPHYS(16), .VW(64), .SEED(2)) h16 (.clk(clk), .rst_n(rst_n), .run(run), .done(d16),
        .e_rw(r16), .e_ms(m16), .e_rdy(y16), .nres(n16));
    lda_h #(.NPHYS(32), .VW(32), .SEED(3)) h32 (.clk(clk), .rst_n(rst_n), .run(run), .done(d32),
        .e_rw(r32), .e_ms(m32), .e_rdy(y32), .nres(n32));
    lda_h #(.NPHYS(4), .VW(64), .SEED(4)) h4 (.clk(clk), .rst_n(rst_n), .run(run), .done(d4),
        .e_rw(r4), .e_ms(m4), .e_rdy(y4), .nres(n4));
    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        run = 1;
        wait (d8 && d16 && d32 && d4);
        if (r8 == 0 && r16 == 0 && r32 == 0 && r4 == 0 && n8 > 1000 && n32 > 500)
            $display("PASS ad_su_lda.rw");
        else $display("FAIL ad_su_lda.rw (%0d %0d %0d %0d errors; %0d %0d %0d %0d results)",
                      r8, r16, r32, r4, n8, n16, n32, n4);
        if (m8 == 0 && m16 == 0 && m32 == 0 && m4 == 0) $display("PASS ad_su_lda.ms");
        else $display("FAIL ad_su_lda.ms");
        if (y8 == 0 && y16 == 0 && y32 == 0 && y4 == 0) $display("PASS ad_su_lda.ready");
        else $display("FAIL ad_su_lda.ready (%0d %0d %0d %0d)", y8, y16, y32, y4);
        if (r8 == 0 && r16 == 0 && r32 == 0 && r4 == 0 && m8 == 0 && m16 == 0 && m32 == 0 &&
            m4 == 0 && y8 == 0 && y16 == 0 && y32 == 0 && y4 == 0)
            $display("PASS ad_su_lda");
        $finish;
    end
endmodule
