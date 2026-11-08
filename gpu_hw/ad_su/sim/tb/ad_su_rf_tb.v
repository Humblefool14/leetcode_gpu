// ad_su_rf_tb -- ad_su_rf against a model register file (32 lanes per register) for
// NPHYS 4, 8, 16, 32, NPHYS 16 with NREGS 64 and NWARPS 8, NPHYS 4 with NREGS 64:
// a fill pass, then random lane-masked writes and dual-port reads (random r_en;
// r_data must hold while r_en is 0); a read of the register written in the same
// cycle must return the old value (counted for the .same line).
`timescale 1ns/1ps
module rf_h #(parameter NPHYS = 8, parameter NWARPS = 4, parameter NREGS = 32, parameter SEED = 1,
              parameter NOPS = 6000) (
    input wire clk, input wire rst_n,
    output reg done, output reg [31:0] err, output reg [31:0] same_n, output reg [31:0] same_err
);
    localparam G = 32 / NPHYS, GRP_W = (G > 1) ? $clog2(G) : 1, WARP_W = $clog2(NWARPS);
    reg w_en = 0, r_en = 0; reg [WARP_W-1:0] w_warp = 0, r_warp = 0; reg [GRP_W-1:0] w_grp = 0, r_grp = 0;
    reg [5:0] w_reg = 0, r_reg1 = 0, r_reg2 = 0; reg [NPHYS*32-1:0] w_data = 0; reg [NPHYS-1:0] w_lanes = 0;
    wire [NPHYS*32-1:0] r_data1, r_data2; wire busy;
    ad_su_rf #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .NREGS(NREGS)) dut (
        .clk(clk), .rst_n(rst_n), .w_en(w_en), .w_warp(w_warp), .w_grp(w_grp), .w_reg(w_reg),
        .w_data(w_data), .w_lanes(w_lanes), .r_en(r_en), .r_warp(r_warp), .r_grp(r_grp),
        .r_reg1(r_reg1), .r_reg2(r_reg2), .r_data1(r_data1), .r_data2(r_data2), .scrub(1'b0),
        .scrub_busy(busy));
    reg [31:0] m [0:NWARPS*NREGS*32-1];
    reg [NPHYS*32-1:0] e1, e2, f1, f2;   // expected r_data (f: issued this cycle, e: checked)
    reg chk = 0, same_pend = 0, fchk = 0, fsame = 0;
    integer seed, n, i, fill, ln;
    initial begin seed = SEED; done = 0; err = 0; same_n = 0; same_err = 0; n = 0; fill = 0; end
    function integer mi(input integer w, input integer r, input integer lane);
        mi = (w * NREGS + r) * 32 + lane;
    endfunction
    reg [NPHYS*32-1:0] t_d; reg [NPHYS-1:0] t_l; integer tw, tg, tr, rw, rg, r1, r2; reg twe, tre;
    always @(posedge clk) if (rst_n && !done) begin
        // check the read issued last cycle (or the held data)
        if (chk) begin
            if (r_data1 !== e1 || r_data2 !== e2) begin
                err = err + 1;
                if (err < 5) $display("ERROR rf%0d/%0d/%0d n %0d data %h exp %h", NPHYS, NREGS, NWARPS, n, r_data1, e1);
                if (same_pend) same_err = same_err + 1;
            end
        end
        e1 = f1; e2 = f2; chk = fchk; same_pend = fsame; fsame = 0;
        // next operation
        if (fill < NWARPS * NREGS * G) begin
            twe = 1; tw = fill / (NREGS * G); tr = (fill / G) % NREGS; tg = fill % G; t_l = {NPHYS{1'b1}};
            fill = fill + 1; tre = 0;
        end else begin
            twe = $random(seed) % 3 != 0;
            tw = {$random(seed)} % NWARPS; tr = {$random(seed)} % NREGS; tg = {$random(seed)} % G;
            t_l = $random(seed);
            tre = $random(seed) % 4 != 0;
            n = n + 1;
        end
        for (i = 0; i < NPHYS; i = i + 1) t_d[32*i +: 32] = $random(seed);
        rw = {$random(seed)} % NWARPS; rg = {$random(seed)} % G; r1 = {$random(seed)} % NREGS; r2 = {$random(seed)} % NREGS;
        if ($random(seed) % 4 == 0) begin rw = tw; rg = tg; r1 = tr; end
        if ($random(seed) % 4 == 0) begin rw = tw; rg = tg; r2 = tr; end
        // expected read data: the model before this cycle's write
        if (tre) begin
            for (i = 0; i < NPHYS; i = i + 1) begin
                ln = rg * NPHYS + i;
                f1[32*i +: 32] = m[mi(rw, r1, ln)]; f2[32*i +: 32] = m[mi(rw, r2, ln)];
            end
            fchk = 1;
            if (twe && rw == tw && rg == tg && (r1 == tr || r2 == tr) && t_l != 0) begin
                fsame = 1; same_n = same_n + 1;
            end
        end
        if (twe) for (i = 0; i < NPHYS; i = i + 1) if (t_l[i]) m[mi(tw, tr, tg * NPHYS + i)] = t_d[32*i +: 32];
        w_en <= twe; w_warp <= tw; w_grp <= tg; w_reg <= tr; w_data <= t_d; w_lanes <= t_l;
        r_en <= tre; r_warp <= rw; r_grp <= rg; r_reg1 <= r1; r_reg2 <= r2;
        if (n >= NOPS) done <= 1;
    end
endmodule

module ad_su_rf_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    wire [5:0] d; wire [31:0] e [0:5]; wire [31:0] sn [0:5]; wire [31:0] se [0:5];
    rf_h #(.NPHYS(4),  .SEED(1)) h0 (clk, rst_n, d[0], e[0], sn[0], se[0]);
    rf_h #(.NPHYS(8),  .SEED(2)) h1 (clk, rst_n, d[1], e[1], sn[1], se[1]);
    rf_h #(.NPHYS(16), .SEED(3)) h2 (clk, rst_n, d[2], e[2], sn[2], se[2]);
    rf_h #(.NPHYS(32), .SEED(4)) h3 (clk, rst_n, d[3], e[3], sn[3], se[3]);
    rf_h #(.NPHYS(16), .NREGS(64), .NWARPS(8), .SEED(5)) h4 (clk, rst_n, d[4], e[4], sn[4], se[4]);
    rf_h #(.NPHYS(4),  .NREGS(64), .SEED(6)) h5 (clk, rst_n, d[5], e[5], sn[5], se[5]);
    integer k, te, tsn, tse;
    initial begin
        repeat (3) @(posedge clk); rst_n <= 1;
        wait (&d); @(posedge clk);
        te = 0; tsn = 0; tse = 0;
        for (k = 0; k < 6; k = k + 1) begin te = te + e[k]; tsn = tsn + sn[k]; tse = tse + se[k]; end
        $display("rf: %0d errors, %0d same-cycle read/write cases", te, tsn);
        if (te == 0) $display("PASS ad_su_rf.rw"); else $display("FAIL ad_su_rf.rw");
        if (tse == 0 && tsn > 100) $display("PASS ad_su_rf.same"); else $display("FAIL ad_su_rf.same");
        if (te == 0 && tse == 0 && tsn > 100) $display("PASS ad_su_rf");
        $finish;
    end
endmodule
