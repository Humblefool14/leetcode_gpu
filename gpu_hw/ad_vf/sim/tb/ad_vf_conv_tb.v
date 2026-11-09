// ad_vf_conv_tb -- self-checking testbench of ad_vf_conv against tools/fmtmodel.py
// (vectors from tools/gen_conv_vectors.py: sim/vec/vf_conv.txt, vf_conv_vk.txt, vf_conv_<leaf>.hex).
//
// 1. Leaves, exhaustively against fmtmodel: h2f (65536), UNORM2/8/10/16, SNORM8/16 (every code).
// 2. Batches of afs (STATE written between batches only), back to back with random af_valid gaps.
//    A scoreboard checks every vl word (data, register, lane and the exact cycle: words of an af
//    taken in cycle T are in cycles T+1 .. T+n), af_ready in every cycle (high iff idle or in the
//    last slot of the current af), and conv_done: exactly one pulse per af_last, in cycle
//    T + max(n, 1) + 1, never elsewhere.
`timescale 1ns/1ps
module ad_vf_conv_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg st_we = 0; reg [8:0] st_idx = 0; reg [31:0] st_wdata = 0;
    reg af_valid = 0; reg [3:0] af_attr = 0; reg [4:0] af_lane = 0; reg [127:0] af_raw = 0;
    reg af_oob = 0, af_last = 0;
    wire af_ready, vl_we, conv_done; wire [5:0] vl_reg; wire [4:0] vl_lane; wire [31:0] vl_data;

    ad_vf_conv dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .af_valid(af_valid), .af_ready(af_ready), .af_attr(af_attr), .af_lane(af_lane), .af_raw(af_raw),
        .af_oob(af_oob), .af_last(af_last), .vl_we(vl_we), .vl_reg(vl_reg), .vl_lane(vl_lane),
        .vl_data(vl_data), .conv_done(conv_done));

    // ---------------- leaves (exhaustive) ----------------
    reg [15:0] l16; reg [9:0] l10; reg [7:0] l8; reg [1:0] l2;
    wire [31:0] o_h2f, o_un16, o_sn16, o_un10, o_un8, o_sn8, o_un2;
    ad_vf_fmt_h2f            t_h2f  (.h(l16), .f(o_h2f));
    ad_vf_fmt_unorm #(.N(16)) t_un16 (.c(l16), .f(o_un16));
    ad_vf_fmt_snorm #(.N(16)) t_sn16 (.c(l16), .f(o_sn16));
    ad_vf_fmt_unorm #(.N(10)) t_un10 (.c(l10), .f(o_un10));
    ad_vf_fmt_unorm #(.N(8))  t_un8  (.c(l8),  .f(o_un8));
    ad_vf_fmt_snorm #(.N(8))  t_sn8  (.c(l8),  .f(o_sn8));
    ad_vf_fmt_unorm #(.N(2))  t_un2  (.c(l2),  .f(o_un2));
    reg [31:0] r_h2f [0:65535]; reg [31:0] r_un16 [0:65535]; reg [31:0] r_sn16 [0:65535];
    reg [31:0] r_un10 [0:1023]; reg [31:0] r_un8 [0:255]; reg [31:0] r_sn8 [0:255]; reg [31:0] r_un2 [0:3];
    integer leaf_err = 0, leaf_n = 0, v;

    task leaf_chk(input [8*5-1:0] nm, input integer x, input [31:0] got, input [31:0] exp);
        begin
            leaf_n = leaf_n + 1;
            if (got !== exp) begin
                leaf_err = leaf_err + 1;
                if (leaf_err < 10) $display("FAIL ad_vf_conv.formats leaf %0s(%h) = %h, expected %h", nm, x, got, exp);
            end
        end
    endtask

    // ---------------- scoreboard ----------------
    localparam QN = 4096;
    reg [31:0] q_data [0:QN-1]; reg [5:0] q_reg [0:QN-1]; reg [4:0] q_lane [0:QN-1];
    integer    q_cyc [0:QN-1], q_grp [0:QN-1];
    integer    qh = 0, qt = 0;
    integer    d_cyc [0:QN-1], d_grp [0:QN-1]; integer dh = 0, dt = 0;
    integer    err [0:3]; integer nw [0:3]; integer naf [0:3];
    integer    cyc = 0, slot_end = 0, n_done = 0, n_gapcyc = 0, n_b2b = 0, last_take = -10;
    reg [31:0] e_w [0:3]; integer e_n, e_grp; reg [5:0] e_reg;  // expectation of the af on the inputs
    reg        mon_on = 0;

    task bad(input integer g, input [8*48-1:0] msg);
        begin
            err[g] = err[g] + 1;
            if (err[g] < 12) $display("FAIL %0s (group %0d, cycle %0d)", msg, g, cyc);
        end
    endtask

    integer i, m;
    always @(posedge clk) if (mon_on) begin
        // af_ready timing
        if (af_ready !== (cyc >= slot_end)) bad(0, "ad_vf_conv af_ready timing");
        // words
        if (vl_we === 1'b1) begin
            if (qh == qt) bad(0, "ad_vf_conv unexpected vl_we");
            else begin
                i = qh % QN;
                if (q_cyc[i] != cyc) bad(q_grp[i], "ad_vf_conv word cycle");
                if (vl_data !== q_data[i] || vl_reg !== q_reg[i] || vl_lane !== q_lane[i]) begin
                    bad(q_grp[i], "ad_vf_conv word value");
                    if (err[q_grp[i]] < 12) $display("     got reg %0d lane %0d data %h, expected reg %0d lane %0d data %h",
                        vl_reg, vl_lane, vl_data, q_reg[i], q_lane[i], q_data[i]);
                end
                nw[q_grp[i]] = nw[q_grp[i]] + 1;
                qh = qh + 1;
            end
        end else if (vl_we !== 1'b0) bad(0, "ad_vf_conv vl_we X");
        else if (qh != qt && q_cyc[qh % QN] <= cyc) begin bad(q_grp[qh % QN], "ad_vf_conv missing word"); qh = qh + 1; end
        // conv_done
        if (conv_done === 1'b1) begin
            if (dh == dt || d_cyc[dh % QN] != cyc) bad(0, "ad_vf_conv conv_done unexpected");
            else begin dh = dh + 1; n_done = n_done + 1; end
        end else if (conv_done !== 1'b0) bad(0, "ad_vf_conv conv_done X");
        else if (dh != dt && d_cyc[dh % QN] <= cyc) begin bad(d_grp[dh % QN], "ad_vf_conv conv_done missing"); dh = dh + 1; end
        // take
        if (af_valid && af_ready) begin
            if (last_take == cyc - 1 || (e_n > 1 && cyc == slot_end)) n_b2b = n_b2b + 1;
            for (m = 0; m < e_n; m = m + 1) begin
                i = qt % QN;
                q_data[i] = e_w[m]; q_reg[i] = e_reg + m; q_lane[i] = af_lane; q_cyc[i] = cyc + 1 + m; q_grp[i] = e_grp;
                qt = qt + 1;
            end
            slot_end = cyc + (e_n > 0 ? e_n : 1);
            if (af_last) begin d_cyc[dt % QN] = slot_end + 1; d_grp[dt % QN] = e_grp; dt = dt + 1; end
            naf[e_grp] = naf[e_grp] + 1;
            last_take = cyc;
        end
        if (!af_valid) n_gapcyc = n_gapcyc + 1;
        cyc = cyc + 1;
    end

    // ---------------- driver ----------------
    integer fd, r, k, lane, oob, last, gap, grp, n; reg [8*2-1:0] cmd; reg [127:0] raw; reg [8:0] sidx; reg [31:0] sdat;
    reg [5:0] rg; reg [31:0] w0, w1, w2, w3;
    integer total_af = 0;

    task run_file(input [8*40-1:0] fname);
        begin
            fd = $fopen(fname, "r");
            if (fd == 0) begin $display("FAIL ad_vf_conv cannot open %0s (run tools/gen_conv_vectors.py)", fname); $finish; end
            while (!$feof(fd)) begin
                r = $fscanf(fd, "%s", cmd);
                if (r == 1 && cmd == "S") begin
                    r = $fscanf(fd, "%h %h", sidx, sdat);
                    @(negedge clk); st_we = 1; st_idx = sidx; st_wdata = sdat;
                    @(negedge clk); st_we = 0;
                end else if (r == 1 && cmd == "A") begin
                    r = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h", grp, k, lane, oob, last, gap, raw, n, rg, w0, w1, w2, w3);
                    repeat (gap) begin @(negedge clk); af_valid = 0; end
                    @(negedge clk);
                    af_valid = 1; af_attr = k; af_lane = lane; af_raw = raw; af_oob = oob; af_last = last;
                    e_w[0] = w0; e_w[1] = w1; e_w[2] = w2; e_w[3] = w3; e_n = n; e_grp = grp; e_reg = rg;
                    @(posedge clk); while (!af_ready) @(posedge clk);
                    #1 af_valid = 0; af_raw = {4{$random}}; af_attr = $random; af_last = $random; af_oob = $random;
                    total_af = total_af + 1;
                end else if (r == 1 && cmd == "W") begin
                    @(negedge clk);
                    while (qh != qt || dh != dt || !af_ready) @(negedge clk);
                    repeat (2) @(negedge clk);
                end
            end
            $fclose(fd);
        end
    endtask

    initial begin
        for (i = 0; i < 4; i = i + 1) begin err[i] = 0; nw[i] = 0; naf[i] = 0; end
        e_n = 0; e_grp = 0; e_reg = 0;
        // 1. leaves
        $readmemh("sim/vec/vf_conv_h2f.hex", r_h2f);   $readmemh("sim/vec/vf_conv_un16.hex", r_un16);
        $readmemh("sim/vec/vf_conv_sn16.hex", r_sn16); $readmemh("sim/vec/vf_conv_un10.hex", r_un10);
        $readmemh("sim/vec/vf_conv_un8.hex", r_un8);   $readmemh("sim/vec/vf_conv_sn8.hex", r_sn8);
        $readmemh("sim/vec/vf_conv_un2.hex", r_un2);
        for (v = 0; v < 65536; v = v + 1) begin
            l16 = v; l10 = v; l8 = v; l2 = v; #1;
            leaf_chk("h2f", v, o_h2f, r_h2f[v]); leaf_chk("un16", v, o_un16, r_un16[v]); leaf_chk("sn16", v, o_sn16, r_sn16[v]);
            if (v < 1024) leaf_chk("un10", v, o_un10, r_un10[v]);
            if (v < 256) begin leaf_chk("un8", v, o_un8, r_un8[v]); leaf_chk("sn8", v, o_sn8, r_sn8[v]); end
            if (v < 4) leaf_chk("un2", v, o_un2, r_un2[v]);
        end
        $display("ad_vf_conv leaves: %0d exhaustive values checked, %0d errors", leaf_n, leaf_err);
        err[0] = err[0] + leaf_err;
        // 2. block
        repeat (3) @(negedge clk); rst_n = 1;
        @(negedge clk); mon_on = 1;
        run_file("sim/vec/vf_conv.txt");
        run_file("sim/vec/vf_conv_vk.txt");
        repeat (5) @(negedge clk);
        if (qh != qt || dh != dt) bad(0, "ad_vf_conv words or conv_done left over");
        $display("ad_vf_conv: %0d afs (formats %0d, fill %0d, vk %0d, oob %0d), words %0d/%0d/%0d/%0d, conv_done %0d, back-to-back takes %0d, idle-input cycles %0d",
            total_af, naf[0], naf[1], naf[2], naf[3], nw[0], nw[1], nw[2], nw[3], n_done, n_b2b, n_gapcyc);
        if (err[0] == 0 && naf[0] > 0) $display("PASS ad_vf_conv.formats");   else $display("FAIL ad_vf_conv.formats");
        if (err[1] == 0 && naf[1] > 0) $display("PASS ad_vf_conv.fill");      else $display("FAIL ad_vf_conv.fill");
        if (err[2] == 0 && naf[2] > 0) $display("PASS ad_vf_conv.vkformats"); else $display("FAIL ad_vf_conv.vkformats");
        if (err[3] == 0 && naf[3] > 0) $display("PASS ad_vf_conv.oob");       else $display("FAIL ad_vf_conv.oob");
        if (err[0] + err[1] + err[2] + err[3] == 0) $display("PASS ad_vf_conv"); else $display("FAIL ad_vf_conv");
        $finish;
    end
endmodule
