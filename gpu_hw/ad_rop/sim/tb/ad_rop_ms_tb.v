// ad_rop_ms_tb -- ad_rop_ms alone against tools/ms_model.py
// (sim/vec/ms_in.hex, ms_exp.hex from tools/gen_ms_vectors.py), random input
// gaps and random o_ready back-pressure; outputs compared in order, every field.
`timescale 1ns/1ps
module ad_rop_ms_tb;
    localparam NIN = 4096, NEXP = 4096;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg          st_we = 0; reg [8:0] st_idx = 0; reg [31:0] st_wdata = 0;
    reg          i_valid = 0; wire i_ready;
    reg  [31:0]  i_xy = 0; reg [3:0] i_mask = 0; reg [511:0] i_color = 0;
    reg  [127:0] i_depth = 0; reg i_dbg = 0; reg [153:0] i_aux = 0;
    wire         o_valid; reg o_ready = 0;
    wire [31:0]  o_xy; wire [15:0] o_smask; wire [511:0] o_color, o_sdepth;
    wire         o_dbg, o_front, busy; wire [3:0] o_beat;

    ad_rop_ms dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .i_valid(i_valid), .i_ready(i_ready), .i_xy(i_xy), .i_mask(i_mask), .i_color(i_color),
        .i_depth(i_depth), .i_dbg(i_dbg), .i_aux(i_aux), .o_valid(o_valid), .o_ready(o_ready),
        .o_xy(o_xy), .o_smask(o_smask), .o_color(o_color), .o_sdepth(o_sdepth), .o_dbg(o_dbg),
        .o_front(o_front), .o_beat(o_beat), .busy(busy));

    reg [895:0]  vin  [0:NIN-1];
    reg [1087:0] vexp [0:NEXP-1];
    integer nin, nexp, ii, ei, sec, s, seed, hold_err, cyc;
    integer err [0:3]; integer cnt [0:3];
    reg [1087:0] e, got;
    reg [895:0] r;
    reg done_in;

    // ---------------- driver ----------------
    initial begin
        for (ii = 0; ii < NIN; ii = ii + 1) vin[ii] = {896{1'bx}};
        for (ii = 0; ii < NEXP; ii = ii + 1) vexp[ii] = {1088{1'bx}};
        $readmemh("sim/vec/ms_in.hex", vin);
        $readmemh("sim/vec/ms_exp.hex", vexp);
        nin = 0;  while (nin < NIN && vin[nin] !== {896{1'bx}}) nin = nin + 1;
        nexp = 0; while (nexp < NEXP && vexp[nexp] !== {1088{1'bx}}) nexp = nexp + 1;
        seed = 7; done_in = 0;
        repeat (3) @(posedge clk);
        rst_n <= 1;
        @(posedge clk);
        for (ii = 0; ii < nin; ii = ii + 1) begin
            r = vin[ii];
            if (r[895:892] == 4'd1) begin
                // STATE writes come while the module is idle (spec §4)
                @(negedge clk);
                while (busy) @(negedge clk);
                @(posedge clk);
                st_we <= 1; st_idx <= r[887:879]; st_wdata <= r[878:847];
                @(posedge clk);
                st_we <= 0;
                repeat (2) @(posedge clk);
            end else begin
                while (($random(seed) & 3) == 0) @(posedge clk);
                i_valid <= 1; i_xy <= r[846:815]; i_mask <= r[814:811]; i_color <= r[810:299];
                i_depth <= r[298:171]; i_dbg <= r[170]; i_aux <= r[169:16];
                @(negedge clk);
                while (!i_ready) @(negedge clk);
                @(posedge clk);                 // taken at this edge
                i_valid <= 0;
            end
        end
        done_in = 1;
    end

    // ---------------- back-pressure and checker ----------------
    reg          p_v, p_r; reg [1087:0] p_o;
    always @(posedge clk) begin
        o_ready <= (($random(seed) & 3) != 0);
    end
    initial begin
        for (s = 0; s < 4; s = s + 1) begin err[s] = 0; cnt[s] = 0; end
        ei = 0; hold_err = 0; p_v = 0; p_r = 0; cyc = 0;
    end
    always @(posedge clk) if (rst_n) begin
        cyc = cyc + 1;
        got = {4'd0, o_xy, o_smask, o_color, o_sdepth, o_dbg, o_front, o_beat, 6'd0};
        if (p_v && !p_r && (!o_valid || got !== p_o)) begin
            if (hold_err < 5) $display("FAIL ad_rop_ms hold: output changed under back-pressure");
            hold_err = hold_err + 1;
        end
        p_v = o_valid; p_r = o_ready; p_o = got;
        if (o_valid && o_ready) begin
            if (ei >= nexp) begin
                $display("FAIL ad_rop_ms: unexpected output %0d", ei);
                err[0] = err[0] + 1;
            end else begin
                e = vexp[ei]; sec = e[1087:1084];
                got[1087:1084] = sec[3:0];
                cnt[sec] = cnt[sec] + 1;
                if (got !== e) begin
                    if (err[sec] < 6)
                        $display("FAIL ad_rop_ms out %0d sec %0d: xy %h/%h smask %h/%h beat %h/%h dbg %b/%b front %b/%b color %0s sdepth %0s",
                            ei, sec, o_xy, e[1083:1052], o_smask, e[1051:1036], o_beat, e[9:6],
                            o_dbg, e[11], o_front, e[10],
                            (o_color === e[1035:524]) ? "ok" : "BAD", (o_sdepth === e[523:12]) ? "ok" : "BAD");
                    if (err[sec] < 2 && o_sdepth !== e[523:12])
                        $display("     sdepth got %h\n     sdepth exp %h", o_sdepth, e[523:12]);
                    err[sec] = err[sec] + 1;
                end
            end
            ei = ei + 1;
        end
    end

    initial begin
        wait (done_in);
        repeat (40) @(posedge clk);
        if (ei != nexp) begin
            $display("FAIL ad_rop_ms: %0d outputs, %0d expected", ei, nexp);
            err[2] = err[2] + 1;
        end
        if (err[0] == 0 && cnt[0] > 0 && hold_err == 0) $display("PASS ad_rop_ms.depth (%0d beats)", cnt[0]);
        else $display("FAIL ad_rop_ms.depth (%0d errors)", err[0]);
        if (err[1] == 0 && cnt[1] > 0) $display("PASS ad_rop_ms.a2c (%0d beats)", cnt[1]);
        else $display("FAIL ad_rop_ms.a2c (%0d errors)", err[1]);
        if (err[2] == 0 && cnt[2] > 0) $display("PASS ad_rop_ms.beats (%0d beats)", cnt[2]);
        else $display("FAIL ad_rop_ms.beats (%0d errors)", err[2]);
        if (err[3] == 0 && cnt[3] > 0) $display("PASS ad_rop_ms.bypass1x (%0d beats)", cnt[3]);
        else $display("FAIL ad_rop_ms.bypass1x (%0d errors)", err[3]);
        if (err[0] + err[1] + err[2] + err[3] + hold_err == 0) $display("PASS ad_rop_ms");
        else $display("FAIL ad_rop_ms");
        $finish;
    end
    initial begin
        #20000000;
        $display("FAIL ad_rop_ms: timeout");
        $finish;
    end
endmodule
