// ad_rop_dtest_tb -- ad_rop_dtest against tools/ds_model.py dtest()
// (sim/vec/dtest_vec.hex from tools/gen_ds_vectors.py).  Compares pass, wbe and the
// bytes of wword under wbe.  Sections: 0 stencil, 1 d16, 2 bounds, 3 order.
`timescale 1ns/1ps
module ad_rop_dtest_tb;
    reg  [9:0]  depth;
    reg  [26:0] sfront, sback;
    reg  [24:0] sops;
    reg  [31:0] bmin, bmax, zf, stored;
    reg         cov, front;
    wire        pass;
    wire [31:0] wword;
    wire [3:0]  wbe;
    ad_rop_dtest dut (.depth(depth), .sfront(sfront), .sback(sback), .sops(sops), .bmin(bmin),
                      .bmax(bmax), .cov(cov), .front(front), .zf(zf), .stored(stored),
                      .pass(pass), .wword(wword), .wbe(wbe));

    localparam NV = 20000;
    reg [447:0] v [0:NV-1];
    integer i, n, sec, cur, err, tot, cnt, k;
    reg [31:0] f [0:13];
    reg bad;

    task sec_done(input integer s, input integer e, input integer c);
        begin
            case (s)
                0: if (e == 0 && c > 0) $display("PASS ad_rop_dtest.stencil (%0d vectors)", c); else $display("FAIL ad_rop_dtest.stencil (%0d of %0d)", e, c);
                1: if (e == 0 && c > 0) $display("PASS ad_rop_dtest.d16 (%0d vectors)", c);     else $display("FAIL ad_rop_dtest.d16 (%0d of %0d)", e, c);
                2: if (e == 0 && c > 0) $display("PASS ad_rop_dtest.bounds (%0d vectors)", c);  else $display("FAIL ad_rop_dtest.bounds (%0d of %0d)", e, c);
                default: if (e == 0 && c > 0) $display("PASS ad_rop_dtest.order (%0d vectors)", c); else $display("FAIL ad_rop_dtest.order (%0d of %0d)", e, c);
            endcase
        end
    endtask

    initial begin
        for (i = 0; i < NV; i = i + 1) v[i] = {448{1'bx}};
        $readmemh("sim/vec/dtest_vec.hex", v);
        tot = 0; err = 0; cnt = 0; cur = 0; n = 0;
        while (n < NV && v[n] !== {448{1'bx}}) begin
            for (k = 0; k < 14; k = k + 1) f[k] = v[n][447 - 32*k -: 32];
            sec = f[0];
            if (sec != cur) begin
                sec_done(cur, err, cnt); tot = tot + err + (cnt == 0);
                err = 0; cnt = 0; cur = sec;
            end
            depth = f[1]; sfront = f[2]; sback = f[3]; sops = f[4]; bmin = f[5]; bmax = f[6];
            cov = f[7][0]; front = f[7][1]; zf = f[8]; stored = f[9];
            #1;
            bad = (pass !== f[10][0]) || (wbe !== f[12][3:0]);
            for (k = 0; k < 4; k = k + 1)
                if (f[12][k] && wword[8*k +: 8] !== f[11][8*k +: 8]) bad = 1;
            if (bad) begin
                if (err < 6) $display("  mismatch sec %0d #%0d depth=%h sf=%h sb=%h ops=%h bmin=%h bmax=%h cov=%b front=%b zf=%h st=%h : pass %b wword %h wbe %b, exp %b %h %b",
                                      sec, n, depth, sfront, sback, sops, bmin, bmax, cov, front, zf, stored,
                                      pass, wword, wbe, f[10][0], f[11], f[12][3:0]);
                err = err + 1;
            end
            cnt = cnt + 1; n = n + 1;
        end
        sec_done(cur, err, cnt); tot = tot + err + (cnt == 0);
        if (tot == 0 && cur == 3) $display("PASS ad_rop_dtest");
        else $display("FAIL ad_rop_dtest (%0d)", tot);
        $finish;
    end
endmodule
