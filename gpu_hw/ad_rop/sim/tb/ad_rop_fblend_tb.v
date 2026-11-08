// ad_rop_fblend_tb -- self-checking testbench of ad_rop_fblend against tools/fblend_model.py
// (vectors from tools/gen_fblend_vectors.py).
// Sections: leaf (h2f exhaustive, f2h, sRGB encode thresholds), ops, srgb, burst.
`timescale 1ns/1ps
module ad_rop_fblend_tb;
    // ================================================================ leaves
    reg  [15:0] lh;  wire [31:0] lh2f;
    reg  [31:0] lf;  wire [15:0] lf2h; wire [7:0] lenc;
    ad_fblend_h2f      u_h2f (.h(lh), .f(lh2f));
    ad_fblend_f2h      u_f2h (.f(lf), .h(lf2h));
    ad_fblend_srgb_enc u_enc (.f(lf), .c(lenc));
    wire [15:0] lrt;                                    // h2f -> f2h round trip
    ad_fblend_f2h      u_rt  (.f(lh2f), .h(lrt));

    reg [31:0] vh2f [0:65535];
    reg [47:0] vf2h [0:299999];
    reg [39:0] venc [0:1999];

    // ================================================================ DUT
    reg          clk = 0, rst_n = 0;
    reg          i_valid = 0, o_ready = 0;
    reg  [3:0]   i_lanes = 0, i_wm = 0;
    reg  [511:0] i_src = 0;
    reg  [255:0] i_dst = 0;
    reg  [7:0]   i_fmt = 0;
    reg  [22:0]  i_blend = 0;
    reg  [127:0] i_const = 0;
    wire         i_ready, o_valid;
    wire [255:0] o_raw, o_keep;
    ad_rop_fblend dut (
        .clk(clk), .rst_n(rst_n), .i_valid(i_valid), .i_ready(i_ready), .i_lanes(i_lanes),
        .i_src(i_src), .i_dst(i_dst), .i_fmt(i_fmt), .i_blend(i_blend), .i_const(i_const),
        .i_wm(i_wm), .o_valid(o_valid), .o_ready(o_ready), .o_raw(o_raw), .o_keep(o_keep));
    always #5 clk = !clk;

    localparam NV = 4500;
    reg [1447:0] vm [0:NV-1];
    integer nvec;
    integer sent, recv, err, total_err, cyc, i, n, lerr, seed;
    integer acc_cyc [0:NV-1];
    integer out_cyc [0:NV-1];
    integer vprob, rprob;           // per-mille probabilities of i_valid / o_ready
    reg          stalled_prev;
    reg  [255:0] raw_prev, keep_prev;
    reg          chk_stable;

    // vector fields
    function [3:0]   v_lanes; input [1447:0] v; v_lanes = v[1447:1444]; endfunction
    function [7:0]   v_fmt;   input [1447:0] v; v_fmt   = v[1443:1436]; endfunction
    function [22:0]  v_blend; input [1447:0] v; v_blend = v[1434:1412]; endfunction
    function [3:0]   v_wm;    input [1447:0] v; v_wm    = v[1411:1408]; endfunction
    function [127:0] v_const; input [1447:0] v; v_const = v[1407:1280]; endfunction
    function [511:0] v_src;   input [1447:0] v; v_src   = v[1279:768];  endfunction
    function [255:0] v_dst;   input [1447:0] v; v_dst   = v[767:512];   endfunction
    function [255:0] v_raw;   input [1447:0] v; v_raw   = v[511:256];   endfunction
    function [255:0] v_keep;  input [1447:0] v; v_keep  = v[255:0];     endfunction

    task load(input [8*64-1:0] fname);
        begin
            for (i = 0; i < NV; i = i + 1) vm[i] = {1448{1'bx}};
            $readmemh(fname, vm);
            nvec = 0;
            while (nvec < NV && vm[nvec] !== {1448{1'bx}}) nvec = nvec + 1;
        end
    endtask

    task drive_beat(input integer idx);
        begin
            i_lanes = v_lanes(vm[idx]); i_fmt = v_fmt(vm[idx]); i_blend = v_blend(vm[idx]);
            i_wm = v_wm(vm[idx]); i_const = v_const(vm[idx]); i_src = v_src(vm[idx]);
            i_dst = v_dst(vm[idx]);
        end
    endtask

    // Stream vectors [0, cnt) with random i_valid (vprob) and o_ready (rprob), checking
    // every result in order, o_valid/o_raw/o_keep stability under stall, i_ready == !stall,
    // and that nothing extra comes out after the last beat.
    task run_stream(input integer cnt);
        integer k, idle;
        reg [255:0] er, ek;
        begin
            sent = 0; recv = 0; err = 0; stalled_prev = 0; idle = 0;
            @(negedge clk);
            while (recv < cnt && idle < 200) begin
                // drive (negedge)
                if (sent < cnt && (($random(seed) & 1023) < vprob || (vprob >= 1000))) begin
                    i_valid = 1; drive_beat(sent);
                end else begin
                    i_valid = 0; i_src = {16{32'hDEAD_BEEF}};
                end
                o_ready = (rprob >= 1000) || (($random(seed) & 1023) < rprob);
                k = recv;
                @(posedge clk); #0.1;
                cyc = cyc + 1;
                @(negedge clk);
                idle = (recv != k) ? 0 : idle + 1;
            end
            if (recv != cnt || sent != cnt) begin
                $display("FAIL stream: sent %0d recv %0d of %0d", sent, recv, cnt);
                err = err + 1;
            end
            // drain: nothing more may come out
            i_valid = 0; o_ready = 1;
            repeat (10) begin
                @(posedge clk);
                if (o_valid) begin
                    $display("FAIL stream: extra beat after the last one");
                    err = err + 1;
                end
            end
            @(negedge clk);
        end
    endtask

    // ---------------- monitor (samples just before each posedge)
    always @(posedge clk) begin
        if (rst_n) begin
            if (i_ready !== !(o_valid && !o_ready)) begin
                $display("FAIL i_ready=%b with o_valid=%b o_ready=%b", i_ready, o_valid, o_ready);
                err = err + 1;
            end
            if (chk_stable && stalled_prev && (o_valid !== 1'b1 || o_raw !== raw_prev || o_keep !== keep_prev)) begin
                $display("FAIL output changed while stalled (beat %0d)", recv);
                err = err + 1;
            end
            stalled_prev = o_valid && !o_ready;
            raw_prev = o_raw; keep_prev = o_keep;
            if (i_valid && i_ready) begin
                acc_cyc[sent] = cyc;
                sent = sent + 1;
            end
            if (o_valid && o_ready) begin
                out_cyc[recv] = cyc;
                if (o_raw !== v_raw(vm[recv]) || o_keep !== v_keep(vm[recv])) begin
                    if (err < 6) begin
                        $display("FAIL beat %0d fmt=%0d blend=%h lanes=%b wm=%b", recv, v_fmt(vm[recv]),
                                 v_blend(vm[recv]), v_lanes(vm[recv]), v_wm(vm[recv]));
                        $display("  raw  got %h", o_raw);
                        $display("  raw  exp %h", v_raw(vm[recv]));
                        $display("  keep got %h", o_keep);
                        $display("  keep exp %h", v_keep(vm[recv]));
                    end
                    err = err + 1;
                end
                recv = recv + 1;
            end
        end
    end

    initial begin
        total_err = 0; cyc = 0; seed = 32'h1234_5678; chk_stable = 1;
        // ------------------------------------------------ leaf: h2f exhaustive + round trip
        $readmemh("sim/vec/fblend_h2f.hex", vh2f);
        lerr = 0;
        for (i = 0; i < 65536; i = i + 1) begin
            lh = i; #1;
            if (lh2f !== vh2f[i]) begin
                if (lerr < 5) $display("h2f h=%h got %h exp %h", lh, lh2f, vh2f[i]);
                lerr = lerr + 1;
            end
            if (!(lh[14:10] == 5'h1F && lh[9:0] != 0) && lrt !== lh) begin
                if (lerr < 5) $display("h2f->f2h h=%h got %h", lh, lrt);
                lerr = lerr + 1;
            end
        end
        if (lerr == 0) $display("PASS ad_rop_fblend.leaf_h2f (65536 exhaustive, h2f->f2h identity)");
        else $display("FAIL ad_rop_fblend.leaf_h2f (%0d)", lerr);
        total_err = total_err + lerr;
        // ------------------------------------------------ leaf: f2h
        for (i = 0; i < 300000; i = i + 1) vf2h[i] = {48{1'bx}};
        $readmemh("sim/vec/fblend_f2h.hex", vf2h);
        lerr = 0; n = 0;
        while (n < 300000 && vf2h[n] !== {48{1'bx}}) begin
            lf = vf2h[n][47:16]; #1;
            if (lf2h !== vf2h[n][15:0]) begin
                if (lerr < 5) $display("f2h f=%h got %h exp %h", lf, lf2h, vf2h[n][15:0]);
                lerr = lerr + 1;
            end
            n = n + 1;
        end
        if (lerr == 0 && n > 200000) $display("PASS ad_rop_fblend.leaf_f2h (%0d vectors)", n);
        else $display("FAIL ad_rop_fblend.leaf_f2h (%0d of %0d)", lerr, n);
        total_err = total_err + lerr + (n <= 200000);
        // ------------------------------------------------ leaf: sRGB encode
        for (i = 0; i < 2000; i = i + 1) venc[i] = {40{1'bx}};
        $readmemh("sim/vec/fblend_senc.hex", venc);
        lerr = 0; n = 0;
        while (n < 2000 && venc[n] !== {40{1'bx}}) begin
            lf = venc[n][39:8]; #1;
            if (lenc !== venc[n][7:0]) begin
                if (lerr < 5) $display("srgb_enc f=%h got %0d exp %0d", lf, lenc, venc[n][7:0]);
                lerr = lerr + 1;
            end
            n = n + 1;
        end
        if (lerr == 0 && n > 1000) $display("PASS ad_rop_fblend.leaf_srgb_enc (%0d vectors: T[k] +-1 ulp, LUT, specials)", n);
        else $display("FAIL ad_rop_fblend.leaf_srgb_enc (%0d of %0d)", lerr, n);
        total_err = total_err + lerr + (n <= 1000);

        // ------------------------------------------------ reset
        rst_n = 0; i_valid = 0; o_ready = 1;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;

        // ------------------------------------------------ ops
        load("sim/vec/fblend_ops.hex");
        vprob = 850; rprob = 800;
        run_stream(nvec);
        if (err == 0 && nvec > 3000) $display("PASS ad_rop_fblend.ops (%0d beats: 7 formats x 8 ops x 16 factors x 4 slots, unsupported formats, random blend words)", nvec);
        else $display("FAIL ad_rop_fblend.ops (%0d errors, %0d beats)", err, nvec);
        total_err = total_err + err + (nvec <= 3000);

        // ------------------------------------------------ srgb
        load("sim/vec/fblend_srgb.hex");
        vprob = 1000; rprob = 1000;
        run_stream(nvec);
        if (err == 0 && nvec > 1000) $display("PASS ad_rop_fblend.srgb (%0d beats: every code round-trips decode+encode, MIN/MAX, blend off, UNORM10 all codes, alpha-blend accuracy)", nvec);
        else $display("FAIL ad_rop_fblend.srgb (%0d errors, %0d beats)", err, nvec);
        total_err = total_err + err + (nvec <= 1000);

        // ------------------------------------------------ burst
        load("sim/vec/fblend_ops.hex");
        lerr = 0;
        // (a) 16 back-to-back beats, o_ready high: 1 beat/cycle, latency 5
        vprob = 1000; rprob = 1000;
        run_stream(16);
        lerr = lerr + err;
        for (i = 0; i < 16; i = i + 1) begin
            if (out_cyc[i] - acc_cyc[i] != 5) begin
                $display("FAIL burst latency beat %0d: %0d", i, out_cyc[i] - acc_cyc[i]);
                lerr = lerr + 1;
            end
            if (i > 0 && (acc_cyc[i] != acc_cyc[i-1] + 1 || out_cyc[i] != out_cyc[i-1] + 1)) begin
                $display("FAIL burst throughput beat %0d", i);
                lerr = lerr + 1;
            end
        end
        // (b) 600 beats with random o_ready back-pressure and random i_valid gaps
        vprob = 900; rprob = 450;
        run_stream(600);
        lerr = lerr + err;
        // (c) heavy back-pressure, saturated input
        vprob = 1000; rprob = 150;
        run_stream(200);
        lerr = lerr + err;
        if (lerr == 0) $display("PASS ad_rop_fblend.burst (16 back-to-back at 1 beat/cycle, latency 5; 800 beats under random back-pressure, in order, no loss/duplication)");
        else $display("FAIL ad_rop_fblend.burst (%0d)", lerr);
        total_err = total_err + lerr;

        if (total_err == 0) $display("PASS ad_rop_fblend");
        else $display("FAIL ad_rop_fblend (%0d)", total_err);
        $finish;
    end
endmodule
