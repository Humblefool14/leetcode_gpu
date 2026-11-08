// ad_su_tex_tb -- ad_su_tex (send half) and ad_su_tex_ret (return half) for NPHYS 4, 8, 16 and
// 32: 300 random texture instructions each (texl/texb/texf/texsz, the .c and .3 forms' two
// passes, gather and query modifiers, every slot, rd, scoreboard entry, offsets, vertex and
// fragment warps; EXEC full, partial or empty per quad and whole empty groups) mixed with other
// units' groups, a model TU (random tx_ready, a queue with random return delays, texels a
// function of the request), random l_ready.  An in-TB scoreboard checks every request (op,
// slot, tx_vs, mask, the five coordinate words per lane, offsets, tag, tx_last) and every beat
// (warp, group, rd..rd+3 or rd for texsz, the texels of the EXEC lanes, l_lanes, l_last,
// l_sbe, l_cls t, l_wr), in order.
`timescale 1ns/1ps
module tex_h #(parameter NPHYS = 8, parameter SEED = 1) (
    input  wire clk,
    input  wire rst_n,
    input  wire run,
    output reg  done,
    output reg [31:0] e_send,
    output reg [31:0] e_ret,
    output reg [31:0] ntx,
    output reg [31:0] nbeat
);
`include "ad_su_uop.vh"
    localparam WARP_W = 2, GRP_W = (NPHYS == 32) ? 1 : $clog2(32 / NPHYS), GPW = 32 / NPHYS;
    localparam NQ = NPHYS / 4, SBE_W = 2, NI = 300;
    reg x_valid, x_last; reg [WARP_W-1:0] x_warp; reg [GRP_W-1:0] x_grp; reg [SBE_W:0] x_sbe;
    reg [107:0] x_uop; reg [NPHYS*32-1:0] x_a, x_b, x_c; reg [2*NPHYS-1:0] x_mask;
    reg [31:0] x_info; wire x_ready;
    wire l_valid, l_wr, l_last; reg l_ready; wire [WARP_W-1:0] l_warp; wire [GRP_W-1:0] l_grp;
    wire [6:0] l_rd; wire [NPHYS*32-1:0] l_data; wire [NPHYS-1:0] l_lanes; wire [SBE_W:0] l_sbe;
    wire [2:0] l_cls;
    wire tx_valid, tx_vs, tx_last; reg tx_ready; wire [7:0] tx_op; wire [3:0] tx_slot, tx_mask;
    wire [639:0] tx_coord; wire [11:0] tx_off; wire [15:0] tx_tag;
    reg tr_valid; wire tr_ready; reg [15:0] tr_tag; reg [511:0] tr_data; reg tr_last;
    ad_su_tex #(.NPHYS(NPHYS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
        .x_last(x_last), .x_sbe(x_sbe), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b),
        .x_c(x_c), .x_mask(x_mask), .x_info(x_info), .x_ready(x_ready), .l_valid(l_valid),
        .l_ready(l_ready), .l_warp(l_warp), .l_grp(l_grp), .l_rd(l_rd), .l_data(l_data),
        .l_lanes(l_lanes), .l_wr(l_wr), .l_last(l_last), .l_sbe(l_sbe), .l_cls(l_cls),
        .tx_valid(tx_valid), .tx_ready(tx_ready), .tx_op(tx_op), .tx_slot(tx_slot),
        .tx_vs(tx_vs), .tx_mask(tx_mask), .tx_coord(tx_coord), .tx_off(tx_off),
        .tx_tag(tx_tag), .tx_last(tx_last), .tr_valid(tr_valid), .tr_ready(tr_ready),
        .tr_tag(tr_tag), .tr_data(tr_data), .tr_last(tr_last));

    integer seed;
    initial seed = SEED;

    // the TU's texels: a function of the request
    function [511:0] tu;
        input [639:0] c;
        input [7:0] op;
        integer i, k;
        reg [31:0] s;
        begin
            for (i = 0; i < 4; i = i + 1) begin
                s = c[160*i +: 32] + 3 * c[160*i + 32 +: 32] + 5 * c[160*i + 64 +: 32] +
                    7 * c[160*i + 96 +: 32] + 11 * c[160*i + 128 +: 32] + op;
                for (k = 0; k < 4; k = k + 1) tu[128*i + 32*k +: 32] = s ^ (32'h01010101 * (k + 1));
            end
        end
    endfunction

    // expected requests and beats
    localparam NX = 8192;
    reg [7:0] xo [0:NX-1]; reg [3:0] xs [0:NX-1]; reg xv [0:NX-1]; reg [3:0] xm [0:NX-1];
    reg [639:0] xc [0:NX-1]; reg [11:0] xf [0:NX-1]; reg [15:0] xt [0:NX-1]; reg xl [0:NX-1];
    integer xw, xr;
    reg [WARP_W-1:0] bw [0:NX-1]; reg [GRP_W-1:0] bg [0:NX-1]; reg [6:0] brd [0:NX-1];
    reg [NPHYS*32-1:0] bd [0:NX-1]; reg [NPHYS-1:0] bl [0:NX-1]; reg blast [0:NX-1];
    reg [SBE_W:0] bs [0:NX-1];
    integer bwp, brp;

    // the TU model: a queue of accepted requests, returned in order after a delay
    reg [511:0] tq [0:63]; reg [15:0] tqt [0:63]; reg tql [0:63]; integer tqtime [0:63];
    integer tqw, tqr, cyc;
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            tqw = 0; tqr = 0; cyc = 0; xr = 0; brp = 0;
            tx_ready <= 0; tr_valid <= 0; l_ready <= 0;
            e_send = 0; e_ret = 0; ntx = 0; nbeat = 0;
        end else begin
            cyc = cyc + 1;
            if (tx_valid && tx_ready) begin
                if (xr >= xw || tx_op !== xo[xr] || tx_slot !== xs[xr] || tx_vs !== xv[xr] ||
                    tx_mask !== xm[xr] || tx_coord !== xc[xr] || tx_off !== xf[xr] ||
                    tx_tag !== xt[xr] || tx_last !== xl[xr]) begin
                    e_send = e_send + 1;
                    if (e_send < 6)
                        $display("FAIL tex%0d: request %0d op %h/%h slot %h/%h vs %b/%b mask %h/%h off %h/%h tag %h/%h last %b/%b coord %0d",
                                 NPHYS, xr, tx_op, xo[xr], tx_slot, xs[xr], tx_vs, xv[xr], tx_mask,
                                 xm[xr], tx_off, xf[xr], tx_tag, xt[xr], tx_last, xl[xr],
                                 tx_coord === xc[xr]);
                end
                xr = xr + 1;
                ntx = ntx + 1;
                tq[tqw % 64] = tu(tx_coord, tx_op);
                tqt[tqw % 64] = tx_tag;
                tql[tqw % 64] = tx_last;
                tqtime[tqw % 64] = cyc + ($random(seed) & 15);
                tqw = tqw + 1;
            end
            if (tr_valid && tr_ready) tqr = tqr + 1;
            if (tqr < tqw && tqtime[tqr % 64] <= cyc) begin
                tr_valid <= 1;
                tr_data <= tq[tqr % 64];
                tr_tag <= tqt[tqr % 64];
                tr_last <= tql[tqr % 64];
            end else tr_valid <= 0;
            tx_ready <= ($random(seed) & 3) != 0 && (tqw - tqr) < 60;
            // beats
            if (l_valid && l_ready) begin
                if (brp >= bwp || l_warp !== bw[brp] || l_grp !== bg[brp] || l_rd !== brd[brp] ||
                    l_lanes !== bl[brp] || l_last !== blast[brp] || l_sbe !== bs[brp] ||
                    l_cls !== AD_CLS_T || l_wr !== 1'b1) begin
                    e_ret = e_ret + 1;
                    if (e_ret < 6)
                        $display("FAIL tex%0d: beat %0d warp %0d grp %0d rd %0d lanes %h last %b",
                                 NPHYS, brp, l_warp, l_grp, l_rd, l_lanes, l_last);
                end
                for (i = 0; i < NPHYS; i = i + 1)
                    if (bl[brp][i] && l_data[32*i +: 32] !== bd[brp][32*i +: 32]) begin
                        e_ret = e_ret + 1;
                        if (e_ret < 6)
                            $display("FAIL tex%0d: beat %0d lane %0d %h expected %h", NPHYS, brp,
                                     i, l_data[32*i +: 32], bd[brp][32*i +: 32]);
                    end
                brp = brp + 1;
                nbeat = nbeat + 1;
            end
            l_ready <= ($random(seed) & 3) != 0;
        end
    end

    // the driver
    integer n, g, q, l, c, nb, two, three_f, cf, last_sent;
    reg [7:0] op; reg [4:0] sub; reg [6:0] rd; reg [SBE_W:0] sbe; reg [11:0] off;
    reg [1:0] warp; reg vs; reg [NPHYS-1:0] ex;
    reg [NPHYS*32-1:0] a1, b1, c1, a2, c2;
    reg [639:0] qc;
    reg [NPHYS*128-1:0] tex;
    task other;
        begin
            @(negedge clk);
            x_valid = 1;
            x_uop = 108'd0;
            x_uop[AD_UOP_UNIT +: 4] = AD_UNIT_LSU;
            x_mask = {2*NPHYS{1'b1}};
            @(negedge clk);
            x_valid = 0;
        end
    endtask
    task issue(input [7:0] o, input lst, input [NPHYS*32-1:0] a, input [NPHYS*32-1:0] b,
               input [NPHYS*32-1:0] cc, input integer grp);
        begin
            @(negedge clk);
            while ($random(seed) & 1) @(negedge clk);
            x_valid = 1;
            x_uop = 108'd0;
            x_uop[AD_UOP_UNIT +: 4] = AD_UNIT_TEX;
            x_uop[AD_UOP_OP +: 8] = o;
            x_uop[AD_UOP_SUB +: 5] = sub;
            x_uop[AD_UOP_RD +: 7] = rd;
            x_uop[AD_UOP_IMM +: 32] = {20'hABCDE, off};
            x_uop[AD_UOP_SAMP_SLOT +: 4] = $random(seed);
            x_uop[AD_UOP_CLS +: 3] = AD_CLS_T;
            x_warp = warp; x_grp = grp; x_sbe = sbe; x_last = lst;
            x_info = vs ? 32'd0 : 32'h0001_0000;
            x_a = a; x_b = b; x_c = cc;
            x_mask = {{NPHYS{1'b1}}, ex};
            @(posedge clk);
            while (!x_ready) @(posedge clk);
            #1;
            @(negedge clk);
            x_valid = 0;
        end
    endtask
    function [NPHYS*32-1:0] rnd_ops;
        input integer dummy;
        integer k;
        begin
            for (k = 0; k < NPHYS; k = k + 1) rnd_ops[32*k +: 32] = $random(seed);
        end
    endfunction

    initial begin
        done = 0; xw = 0; bwp = 0;
        x_valid = 0; x_last = 0; x_warp = 0; x_grp = 0; x_sbe = 0; x_uop = 0; x_a = 0; x_b = 0;
        x_c = 0; x_mask = 0; x_info = 0;
        @(posedge run);
        for (n = 0; n < NI; n = n + 1) begin
            op = $random(seed) & 3;
            c = $random(seed) & 15;
            if (op != 3 && c < 5) op[2] = 1;                         // .c
            if (op == 0 && c >= 5 && c < 8) op[5:3] = {$random(seed), 1'b1} ;  // gather
            if ((op == 1 || op == 3) && c == 9) op[6] = 1;          // query
            sub = $random(seed);
            if (op[1:0] == 3) sub[4] = 0;
            rd = $random(seed); sbe = $random(seed); off = $random(seed);
            warp = $random(seed); vs = $random(seed);
            two = op[2] || sub[4];
            nb = (op[1:0] == 3) ? 1 : 4;
            for (g = 0; g < GPW; g = g + 1) begin
                // EXEC: full, partial, empty per quad, or an empty group
                c = $random(seed) & 7;
                for (q = 0; q < NQ; q = q + 1) begin
                    l = $random(seed) & 3;
                    ex[4*q +: 4] = (c == 0) ? 4'h0 : (l == 0) ? 4'h0 : (l == 1) ? $random(seed) : 4'hF;
                end
                a1 = rnd_ops(0); b1 = rnd_ops(0); c1 = rnd_ops(0); a2 = rnd_ops(0); c2 = rnd_ops(0);
                // the expected requests and texels
                last_sent = -1;
                for (q = 0; q < NQ; q = q + 1) if (ex[4*q +: 4] != 0) last_sent = q;
                for (q = 0; q < NQ; q = q + 1) begin
                    for (l = 0; l < 4; l = l + 1) begin
                        qc[160*l +: 32] = a1[32*(4*q+l) +: 32];
                        qc[160*l + 32 +: 32] = c1[32*(4*q+l) +: 32];
                        qc[160*l + 64 +: 32] = b1[32*(4*q+l) +: 32];
                        qc[160*l + 96 +: 32] = !op[2] ? 32'd0 : sub[4] ? c2[32*(4*q+l) +: 32] :
                                                a2[32*(4*q+l) +: 32];
                        qc[160*l + 128 +: 32] = sub[4] ? a2[32*(4*q+l) +: 32] : 32'd0;
                    end
                    tex[512*q +: 512] = tu(qc, {1'b0, op[6:0]});
                    if (ex[4*q +: 4] != 0) begin
                        xo[xw] = {1'b0, op[6:0]}; xs[xw] = sub[3:0]; xv[xw] = vs;
                        xm[xw] = ex[4*q +: 4]; xc[xw] = qc; xf[xw] = off;
                        xt[xw] = {3'b0, 1'b0, warp, 3'(g * NQ + q), rd};
                        xl[xw] = (g == GPW - 1) && q == last_sent;
                        xw = xw + 1;
                    end
                end
                for (c = 0; c < nb; c = c + 1) begin
                    bw[bwp] = warp; bg[bwp] = g; brd[bwp] = rd + c; bl[bwp] = ex; bs[bwp] = sbe;
                    blast[bwp] = (g == GPW - 1) && c == nb - 1;
                    for (l = 0; l < NPHYS; l = l + 1) bd[bwp][32*l +: 32] = tex[128*l + 32*c +: 32];
                    bwp = bwp + 1;
                end
                if (($random(seed) & 7) == 0) other;
                if (two) begin
                    issue(op, 1'b0, a1, b1, c1, g);
                    if (($random(seed) & 7) == 0) other;
                    issue(op | 8'h80, g == GPW - 1, a2, b1, c2, g);
                end else begin
                    issue(op, g == GPW - 1, a1, b1, c1, g);
                end
            end
        end
        n = 0;
        while ((brp < bwp || xr < xw) && n < 20000) begin
            @(posedge clk);
            n = n + 1;
        end
        if (n >= 20000) begin
            e_ret = e_ret + 1;
            $display("FAIL tex%0d: stuck (%0d of %0d requests, %0d of %0d beats)", NPHYS, xr, xw,
                     brp, bwp);
        end
        done = 1;
    end
endmodule

module ad_su_tex_tb;
    reg clk = 0, rst_n = 0, run = 0;
    always #5 clk = ~clk;
    wire d4, d8, d16, d32;
    wire [31:0] s4, r4, t4, b4, s8, r8, t8, b8, s16, r16, t16, b16, s32, r32, t32, b32;
    tex_h #(.NPHYS(4), .SEED(1)) h4 (.clk(clk), .rst_n(rst_n), .run(run), .done(d4),
        .e_send(s4), .e_ret(r4), .ntx(t4), .nbeat(b4));
    tex_h #(.NPHYS(8), .SEED(2)) h8 (.clk(clk), .rst_n(rst_n), .run(run), .done(d8),
        .e_send(s8), .e_ret(r8), .ntx(t8), .nbeat(b8));
    tex_h #(.NPHYS(16), .SEED(3)) h16 (.clk(clk), .rst_n(rst_n), .run(run), .done(d16),
        .e_send(s16), .e_ret(r16), .ntx(t16), .nbeat(b16));
    tex_h #(.NPHYS(32), .SEED(4)) h32 (.clk(clk), .rst_n(rst_n), .run(run), .done(d32),
        .e_send(s32), .e_ret(r32), .ntx(t32), .nbeat(b32));
    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        run = 1;
        wait (d4 && d8 && d16 && d32);
        if (s4 == 0 && s8 == 0 && s16 == 0 && s32 == 0 && t8 > 1000) $display("PASS ad_su_tex.send");
        else $display("FAIL ad_su_tex.send (%0d %0d %0d %0d)", s4, s8, s16, s32);
        if (r4 == 0 && r8 == 0 && r16 == 0 && r32 == 0 && b8 > 1000) $display("PASS ad_su_tex.ret");
        else $display("FAIL ad_su_tex.ret (%0d %0d %0d %0d)", r4, r8, r16, r32);
        if (s4 == 0 && s8 == 0 && s16 == 0 && s32 == 0 && r4 == 0 && r8 == 0 && r16 == 0 && r32 == 0)
            $display("PASS ad_su_tex");
        $display("ad_su_tex_tb: requests %0d %0d %0d %0d, beats %0d %0d %0d %0d", t4, t8, t16, t32,
                 b4, b8, b16, b32);
        $finish;
    end
endmodule
