// ad_su_wb_tb -- ad_su_wb (NPHYS 8 and 4, NS 6, NL 6) with random traffic:
// a short pipeline model (an issue stage that stops the cycle after wb_stall, groups
// arriving SHORT_LAT + 2G cycles later from a random short source, rd 63 sometimes),
// six long sources (queues of beats with random l_wr / l_last / rd 63, held until
// l_ready), and VF/RX lane writes (random, sometimes both in one cycle, combined
// rate below one a cycle).  Checks:
//  .prio    every short result goes out the cycle it comes (RF or rq) with its fields;
//           a long beat with data never goes in a cycle with a short result or a
//           waiting input word; wb_stall equals (input waiting or a beat with data
//           waited >= 4 cycles); every long beat is taken in the end.
//  .release exactly one release per taken l_last beat, with its warp/sbe/class, also
//           for l_wr 0 beats (some taken in cycles of short results).
//  .input   every VF/RX word becomes one lane-masked write of its group, in order per
//           source (source 0 first), and no input FIFO overflows.
`timescale 1ns/1ps
module wb_h #(parameter NPHYS = 8, parameter SEED = 1, parameter NCYC = 20000) (
    input wire clk, input wire rst_n, output reg done,
    output reg [31:0] e_prio, output reg [31:0] e_rel, output reg [31:0] e_in,
    output reg [31:0] n_short, output reg [31:0] n_long, output reg [31:0] n_rel, output reg [31:0] n_in,
    output reg [31:0] n_stall, output reg [31:0] n_nodata_busy
);
    localparam NS = 6, NL = 6, L = 6, G = 32 / NPHYS, GRP_W = (G > 1) ? $clog2(G) : 1, WARP_W = 2, SBE_W = 2;
    localparam D = L + 2 * G;   // issue to short result
    localparam DW = NPHYS * 32;
    // DUT signals
    reg [NS-1:0] s_valid; reg [NS*WARP_W-1:0] s_warp; reg [NS*GRP_W-1:0] s_grp; reg [NS*7-1:0] s_rd;
    reg [NS*DW-1:0] s_data; reg [NS*NPHYS-1:0] s_lanes;
    reg [NL-1:0] l_valid; wire [NL-1:0] l_ready; reg [NL*WARP_W-1:0] l_warp; reg [NL*GRP_W-1:0] l_grp;
    reg [NL*7-1:0] l_rd; reg [NL*DW-1:0] l_data; reg [NL*NPHYS-1:0] l_lanes; reg [NL-1:0] l_wr, l_last;
    reg [NL*(SBE_W+1)-1:0] l_sbe; reg [NL*3-1:0] l_cls;
    reg [1:0] in_we; reg [2*WARP_W-1:0] in_warp; reg [11:0] in_reg; reg [9:0] in_lane; reg [63:0] in_data;
    reg [NS-1:0] d_s_valid = 0; reg [NS*WARP_W-1:0] d_s_warp; reg [NS*GRP_W-1:0] d_s_grp; reg [NS*7-1:0] d_s_rd;
    reg [NS*DW-1:0] d_s_data; reg [NS*NPHYS-1:0] d_s_lanes;
    reg [NL-1:0] d_l_valid = 0; reg [NL*WARP_W-1:0] d_l_warp; reg [NL*GRP_W-1:0] d_l_grp;
    reg [NL*7-1:0] d_l_rd; reg [NL*DW-1:0] d_l_data; reg [NL*NPHYS-1:0] d_l_lanes; reg [NL-1:0] d_l_wr, d_l_last;
    reg [NL*(SBE_W+1)-1:0] d_l_sbe; reg [NL*3-1:0] d_l_cls;
    reg [1:0] d_in_we = 0; reg [2*WARP_W-1:0] d_in_warp; reg [11:0] d_in_reg; reg [9:0] d_in_lane; reg [63:0] d_in_data;
    wire w_en, rel_valid, rq_push, wb_stall; wire [WARP_W-1:0] w_warp, rel_warp; wire [GRP_W-1:0] w_grp;
    wire [5:0] w_reg; wire [DW-1:0] w_data, rq_data; wire [NPHYS-1:0] w_lanes; wire [SBE_W:0] rel_sbe; wire [2:0] rel_cls;
    ad_su_wb #(.NPHYS(NPHYS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .NS(NS), .NL(NL), .SHORT_LAT(L)) dut (
        .clk(clk), .rst_n(rst_n), .s_valid(d_s_valid), .s_warp(d_s_warp), .s_grp(d_s_grp), .s_rd(d_s_rd), .s_data(d_s_data),
        .s_lanes(d_s_lanes), .l_valid(d_l_valid), .l_ready(l_ready), .l_warp(d_l_warp), .l_grp(d_l_grp), .l_rd(d_l_rd),
        .l_data(d_l_data), .l_lanes(d_l_lanes), .l_wr(d_l_wr), .l_last(d_l_last), .l_sbe(d_l_sbe), .l_cls(d_l_cls),
        .in_we(d_in_we), .in_warp(d_in_warp), .in_reg(d_in_reg), .in_lane(d_in_lane), .in_data(d_in_data),
        .w_en(w_en), .w_warp(w_warp), .w_grp(w_grp), .w_reg(w_reg), .w_data(w_data), .w_lanes(w_lanes),
        .rel_valid(rel_valid), .rel_warp(rel_warp), .rel_sbe(rel_sbe), .rel_cls(rel_cls),
        .rq_push(rq_push), .rq_data(rq_data), .wb_stall(wb_stall));
    // short pipeline model: issue slots delayed by D
    reg [D-1:0] pv; reg [2:0] psrc [0:D-1]; reg [6:0] prd [0:D-1]; reg [DW-1:0] pdat [0:D-1];
    reg [WARP_W+GRP_W+NPHYS-1:0] ptag [0:D-1];
    // input queues (TB side), with the cycle of the push
    reg [WARP_W+6+5+32-1:0] iq [0:1][0:32767]; integer iqh [0:1]; integer iqt [0:1]; integer iqc [0:1][0:32767];
    integer cyc, seed, k, j, wcnt, pend_long, burst;
    reg [DW-1:0] t; reg any_wr_wait, short_now, lwr_taken; reg [31:0] r;
    initial begin
        seed = SEED; done = 0; e_prio = 0; e_rel = 0; e_in = 0; n_short = 0; n_long = 0; n_rel = 0; n_in = 0;
        n_stall = 0; n_nodata_busy = 0; cyc = 0; wcnt = 0; pv = 0; pend_long = 0; burst = 0;
        s_valid = 0; l_valid = 0; in_we = 0; iqh[0] = 0; iqh[1] = 0; iqt[0] = 0; iqt[1] = 0;
        s_warp = 0; s_grp = 0; s_rd = 0; s_data = 0; s_lanes = 0; l_warp = 0; l_grp = 0; l_rd = 0; l_data = 0;
        l_lanes = 0; l_wr = 0; l_last = 0; l_sbe = 0; l_cls = 0; in_warp = 0; in_reg = 0; in_lane = 0; in_data = 0;
    end
    function [DW-1:0] rnd(input integer dummy); integer q; begin for (q = 0; q < NPHYS; q = q + 1) rnd[32*q +: 32] = $random(seed); end endfunction
    // ---- checks at the clock edge (outputs of the current cycle), then drive the next cycle ----
    always @(posedge clk) if (rst_n && !done) begin
        short_now = |d_s_valid;
        lwr_taken = |(l_ready & d_l_valid & d_l_wr);
        any_wr_wait = |(d_l_valid & d_l_wr) && !lwr_taken;
        // wb_stall model
        if (wb_stall !== ((iqh[0] != iqt[0] && iqc[0][iqh[0]] < cyc) || (iqh[1] != iqt[1] && iqc[1][iqh[1]] < cyc) || wcnt >= 4))
            begin e_prio = e_prio + 1; if (e_prio < 5) $display("ERROR wb%0d cyc %0d wb_stall %b wcnt %0d", NPHYS, cyc, wb_stall, wcnt); end
        if (wb_stall) n_stall = n_stall + 1;
        wcnt = any_wr_wait ? wcnt + 1 : 0;
        if (short_now) begin
            n_short = n_short + 1;
            for (k = 0; k < NS; k = k + 1) if (d_s_valid[k]) begin
                if (d_s_rd[7*k +: 7] == 63) begin
                    if (!rq_push || w_en || rq_data !== d_s_data[DW*k +: DW]) e_prio = e_prio + 1;
                end else if (!w_en || rq_push || w_warp !== d_s_warp[WARP_W*k +: WARP_W] || w_grp !== d_s_grp[GRP_W*k +: GRP_W] ||
                             w_reg !== d_s_rd[7*k +: 6] || w_data !== d_s_data[DW*k +: DW] || w_lanes !== d_s_lanes[NPHYS*k +: NPHYS])
                    begin e_prio = e_prio + 1; if (e_prio < 5) $display("ERROR wb%0d cyc %0d short not written", NPHYS, cyc); end
            end
            if (lwr_taken) e_prio = e_prio + 1;
            if (|(l_ready & d_l_valid & ~d_l_wr)) n_nodata_busy = n_nodata_busy + 1;
        end else if (lwr_taken) begin
            // a waiting input word goes first
            if ((iqh[0] != iqt[0] && iqc[0][iqh[0]] < cyc) || (iqh[1] != iqt[1] && iqc[1][iqh[1]] < cyc)) e_prio = e_prio + 1;
            for (k = 0; k < NL; k = k + 1) if (l_ready[k] && d_l_valid[k] && d_l_wr[k]) begin
                n_long = n_long + 1;
                if (d_l_rd[7*k +: 7] == 63) begin
                    if (!rq_push || w_en || rq_data !== d_l_data[DW*k +: DW]) e_prio = e_prio + 1;
                end else if (!w_en || rq_push || w_warp !== d_l_warp[WARP_W*k +: WARP_W] || w_grp !== d_l_grp[GRP_W*k +: GRP_W] ||
                             w_reg !== d_l_rd[7*k +: 6] || w_data !== d_l_data[DW*k +: DW] || w_lanes !== d_l_lanes[NPHYS*k +: NPHYS])
                    begin e_prio = e_prio + 1; $display("ERROR wb%0d cyc %0d long beat not written", NPHYS, cyc); end
            end
        end else if (w_en || rq_push) begin
            // an input word
            k = (iqh[0] != iqt[0] && iqc[0][iqh[0]] < cyc) ? 0 : 1;
            if (iqh[k] == iqt[k] || iqc[k][iqh[k]] >= cyc || rq_push) begin e_in = e_in + 1; $display("ERROR wb%0d cyc %0d unexpected write", NPHYS, cyc); end
            else begin
                r = iq[k][iqh[k]][31:0];
                j = iq[k][iqh[k]][36:32];   // lane
                if (w_warp !== iq[k][iqh[k]][43 +: WARP_W] || w_reg !== iq[k][iqh[k]][42:37] ||
                    w_grp !== j / NPHYS || w_lanes !== (1 << (j % NPHYS)) || w_data[32*(j % NPHYS) +: 32] !== r)
                    begin e_in = e_in + 1; if (e_in < 5) $display("ERROR wb%0d cyc %0d input word %0d of %0d: w %h/%h g %h/%0d r %h/%h l %b/%0d d %h/%h", NPHYS, cyc, iqh[k], k,
                    w_warp, iq[k][iqh[k]][43 +: WARP_W], w_grp, j / NPHYS, w_reg, iq[k][iqh[k]][42:37], w_lanes, j, w_data[32*(j % NPHYS) +: 32], r); end
                iqh[k] = iqh[k] + 1; n_in = n_in + 1;
            end
        end
        // releases
        if (rel_valid !== |(l_ready & d_l_valid & d_l_last)) e_rel = e_rel + 1;
        for (k = 0; k < NL; k = k + 1) if (l_ready[k] && d_l_valid[k] && d_l_last[k]) begin
            n_rel = n_rel + 1;
            if (rel_warp !== d_l_warp[WARP_W*k +: WARP_W] || rel_sbe !== d_l_sbe[(SBE_W+1)*k +: SBE_W+1] || rel_cls !== d_l_cls[3*k +: 3]) e_rel = e_rel + 1;
        end
        if ($countones(l_ready) > 1 || (l_ready & ~d_l_valid) != 0) e_rel = e_rel + 1;
        // input FIFO overflow
        if ((d_in_we[0] && dut.f0_full) || (d_in_we[1] && dut.f1_full)) begin e_in = e_in + 1; $display("ERROR wb%0d input FIFO overflow", NPHYS); end

        // ---- next cycle ----
        // long sources: taken beats leave; new beats appear
        for (k = 0; k < NL; k = k + 1) begin
            if (l_valid[k] && l_ready[k]) begin l_valid[k] = 0; pend_long = pend_long - 1; end
            if (!l_valid[k] && cyc < NCYC && $random(seed) % 14 == 0) begin
                l_valid[k] = 1; pend_long = pend_long + 1;
                l_wr[k] = $random(seed) % 4 != 0; l_last[k] = $random(seed) % 3 == 0;
                l_rd[7*k +: 7] = ($random(seed) % 12 == 0) ? 63 : {$random(seed)} % 63;
                l_warp[WARP_W*k +: WARP_W] = $random(seed); l_grp[GRP_W*k +: GRP_W] = $random(seed);
                l_data[DW*k +: DW] = rnd(0); l_lanes[NPHYS*k +: NPHYS] = $random(seed);
                l_sbe[(SBE_W+1)*k +: SBE_W+1] = $random(seed); l_cls[3*k +: 3] = 2 + {$random(seed)} % 3;
            end
        end
        // short pipeline: issue (not the cycle after wb_stall), arrival D cycles later
        s_valid = 0;
        if (pv[D-1]) begin
            k = psrc[D-1];
            s_valid[k] = 1; s_rd[7*k +: 7] = prd[D-1]; s_data[DW*k +: DW] = pdat[D-1];
            {s_warp[WARP_W*k +: WARP_W], s_grp[GRP_W*k +: GRP_W], s_lanes[NPHYS*k +: NPHYS]} = ptag[D-1];
        end
        for (j = D - 1; j > 0; j = j - 1) begin pv[j] = pv[j-1]; psrc[j] = psrc[j-1]; prd[j] = prd[j-1]; pdat[j] = pdat[j-1]; ptag[j] = ptag[j-1]; end
        if (burst == 0 && $random(seed) % 50 == 0) burst = 20 + {$random(seed)} % 60;
        pv[0] = !wb_stall && cyc < NCYC && (burst > 0 || $random(seed) % 3 == 0);
        if (burst > 0) burst = burst - 1;
        psrc[0] = {$random(seed)} % NS; prd[0] = ($random(seed) % 10 == 0) ? 63 : {$random(seed)} % 63;
        pdat[0] = rnd(0); ptag[0] = {$random(seed)};
        // input writes
        in_we = 0;
        if (cyc < NCYC) begin
            r = {$random(seed)} % 100;
            if (r < 14) in_we = 2'b01; else if (r < 26) in_we = 2'b10; else if (r < 29) in_we = 2'b11;
        end
        for (k = 0; k < 2; k = k + 1) if (in_we[k]) begin
            in_warp[WARP_W*k +: WARP_W] = $random(seed); in_reg[6*k +: 6] = {$random(seed)} % 63;
            in_lane[5*k +: 5] = $random(seed); in_data[32*k +: 32] = $random(seed);
            iq[k][iqt[k]] = {in_warp[WARP_W*k +: WARP_W], in_reg[6*k +: 6], in_lane[5*k +: 5], in_data[32*k +: 32]};
            iqc[k][iqt[k]] = cyc + 1; iqt[k] = iqt[k] + 1;
        end
        d_s_valid <= s_valid; d_s_warp <= s_warp; d_s_grp <= s_grp; d_s_rd <= s_rd; d_s_data <= s_data; d_s_lanes <= s_lanes; d_l_valid <= l_valid; d_l_warp <= l_warp; d_l_grp <= l_grp; d_l_rd <= l_rd; d_l_data <= l_data; d_l_lanes <= l_lanes; d_l_wr <= l_wr; d_l_last <= l_last; d_l_sbe <= l_sbe; d_l_cls <= l_cls; d_in_we <= in_we; d_in_warp <= in_warp; d_in_reg <= in_reg; d_in_lane <= in_lane; d_in_data <= in_data;
        cyc = cyc + 1;
        if (cyc > NCYC + 200 && pend_long == 0 && iqh[0] == iqt[0] && iqh[1] == iqt[1]) done <= 1;
        if (cyc > NCYC + 5000) begin e_prio = e_prio + 1; $display("ERROR wb%0d did not drain (%0d long)", NPHYS, pend_long); done <= 1; end
    end
endmodule

module ad_su_wb_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    wire d8, d4; wire [31:0] p8, r8, i8, s8, l8, n8, in8, st8, nb8, p4, r4, i4, s4, l4, n4, in4, st4, nb4;
    wb_h #(.NPHYS(8), .SEED(7)) h8 (clk, rst_n, d8, p8, r8, i8, s8, l8, n8, in8, st8, nb8);
    wb_h #(.NPHYS(4), .SEED(9)) h4 (clk, rst_n, d4, p4, r4, i4, s4, l4, n4, in4, st4, nb4);
    initial begin
        repeat (3) @(posedge clk); rst_n <= 1;
        wait (d8 && d4); @(posedge clk);
        $display("wb NPHYS 8: %0d short, %0d long, %0d releases, %0d input, %0d stall cycles, %0d no-data beats beside a short", s8, l8, n8, in8, st8, nb8);
        $display("wb NPHYS 4: %0d short, %0d long, %0d releases, %0d input, %0d stall cycles, %0d no-data beats beside a short", s4, l4, n4, in4, st4, nb4);
        if (p8 == 0 && p4 == 0 && s8 > 1000 && l8 > 1000 && st8 > 100) $display("PASS ad_su_wb.prio"); else $display("FAIL ad_su_wb.prio (%0d %0d)", p8, p4);
        if (r8 == 0 && r4 == 0 && n8 > 500 && nb8 > 10) $display("PASS ad_su_wb.release"); else $display("FAIL ad_su_wb.release (%0d %0d)", r8, r4);
        if (i8 == 0 && i4 == 0 && in8 > 1000 && in4 > 1000) $display("PASS ad_su_wb.input"); else $display("FAIL ad_su_wb.input (%0d %0d)", i8, i4);
        if (p8 + p4 + r8 + r4 + i8 + i4 == 0) $display("PASS ad_su_wb");
        $finish;
    end
endmodule
