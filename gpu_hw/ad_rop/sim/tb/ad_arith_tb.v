// ad_arith_tb -- the shared arithmetic IPs against tools/admodel.py
// (vectors from tools/gen_arith_vectors.py) plus the exhaustive div255 check.
`timescale 1ns/1ps
module ad_arith_tb;
    // ---------------- div255: exhaustive 0..65025 ----------------
    reg  [17:0] dx;  wire [8:0] dq;
    ad_rop_div255 u_div (.x(dx), .q(dq));

    // ---------------- f2u8 / f2unorm ----------------
    reg  [31:0] ff;  wire [7:0] fu8, fu8g; wire [15:0] fu16; wire [23:0] fu24;
    ad_rop_f2u8          u_f2u8 (.f(ff), .u(fu8));
    ad_f2unorm #(.N(8))  u_g8   (.f(ff), .u(fu8g));
    ad_f2unorm #(.N(16)) u_g16  (.f(ff), .u(fu16));
    ad_f2unorm #(.N(24)) u_g24  (.f(ff), .u(fu24));

    // ---------------- fp add / mul / cmp ----------------
    reg  [31:0] fa, fb; reg fs;
    wire [31:0] fsum, fprod; wire clt, ceq, cun;
    ad_fp_add u_add (.a(fa), .b(fb), .sub(fs), .y(fsum));
    ad_fp_mul u_mul (.a(fa), .b(fb), .y(fprod));
    ad_fp_cmp u_cmp (.a(fa), .b(fb), .lt(clt), .eq(ceq), .un(cun));

    // ---------------- unorm2f ----------------
    reg  [15:0] ux16; reg [23:0] ux24; wire [31:0] uf16, uf24;
    ad_unorm2f #(.N(16)) u_u16 (.x(ux16), .f(uf16));
    ad_unorm2f #(.N(24)) u_u24 (.x(ux24), .f(uf24));

    // ---------------- cmp_op: exhaustive over op x flags ----------------
    reg [2:0] cop; reg ilt, ieq, iun; wire cpass;
    ad_cmp_op u_cop (.op(cop), .lt(ilt), .eq(ieq), .un(iun), .pass(cpass));

    reg [79:0]  vf [0:299999];
    reg [135:0] vp [0:299999];
    reg [55:0]  v16 [0:65535];
    reg [55:0]  v24 [0:199999];
    integer i, n, err, total_err;
    reg exp_pass; reg gt;

    initial begin
        total_err = 0;
        // div255
        err = 0;
        for (i = 0; i <= 65025; i = i + 1) begin
            dx = i; #1;
            if (dq !== (i + 127) / 255) begin
                if (err < 5) $display("div255 x=%0d q=%0d exp=%0d", i, dq, (i + 127) / 255);
                err = err + 1;
            end
        end
        if (err == 0) $display("PASS ad_arith.div255 (65026 inputs, exhaustive)");
        else $display("FAIL ad_arith.div255 (%0d)", err);
        total_err = total_err + err;

        // f2unorm
        for (i = 0; i < 300000; i = i + 1) vf[i] = {80{1'bx}};
        $readmemh("sim/vec/arith_f2unorm.hex", vf);
        err = 0; n = 0;
        while (vf[n] !== {80{1'bx}} && n < 300000) begin
            ff = vf[n][79:48]; #1;
            if (fu8 !== vf[n][47:40] || fu8g !== vf[n][47:40] || fu16 !== vf[n][39:24] || fu24 !== vf[n][23:0]) begin
                if (err < 8) $display("f2unorm f=%h got %h/%h/%h/%h exp %h/%h/%h", ff, fu8, fu8g, fu16, fu24,
                                      vf[n][47:40], vf[n][39:24], vf[n][23:0]);
                err = err + 1;
            end
            n = n + 1;
        end
        if (err == 0 && n > 0) $display("PASS ad_arith.f2unorm (%0d vectors: f2u8, N=8/16/24)", n);
        else $display("FAIL ad_arith.f2unorm (%0d of %0d)", err, n);
        total_err = total_err + err + (n == 0);

        // fp add / mul / cmp
        for (i = 0; i < 300000; i = i + 1) vp[i] = {136{1'bx}};
        $readmemh("sim/vec/arith_fp.hex", vp);
        err = 0; n = 0;
        while (vp[n] !== {136{1'bx}} && n < 300000) begin
            fa = vp[n][135:104]; fb = vp[n][103:72]; fs = vp[n][68]; #1;
            if (fsum !== vp[n][67:36]) begin
                if (err < 8) $display("fp_add a=%h b=%h sub=%0d got %h exp %h", fa, fb, fs, fsum, vp[n][67:36]);
                err = err + 1;
            end
            if (fprod !== vp[n][35:4]) begin
                if (err < 8) $display("fp_mul a=%h b=%h got %h exp %h", fa, fb, fprod, vp[n][35:4]);
                err = err + 1;
            end
            if ({clt, ceq, cun} !== vp[n][2:0]) begin
                if (err < 8) $display("fp_cmp a=%h b=%h got %b exp %b", fa, fb, {clt, ceq, cun}, vp[n][2:0]);
                err = err + 1;
            end
            n = n + 1;
        end
        if (err == 0 && n > 0) $display("PASS ad_arith.fp (%0d vectors: add/sub, mul, cmp)", n);
        else $display("FAIL ad_arith.fp (%0d mismatches in %0d)", err, n);
        total_err = total_err + err + (n == 0);

        // unorm2f
        $readmemh("sim/vec/arith_u2f16.hex", v16);
        err = 0;
        for (i = 0; i < 65536; i = i + 1) begin
            ux16 = v16[i][47:32]; #1;
            if (uf16 !== v16[i][31:0]) begin
                if (err < 5) $display("unorm2f16 x=%h got %h exp %h", ux16, uf16, v16[i][31:0]);
                err = err + 1;
            end
        end
        for (i = 0; i < 200000; i = i + 1) v24[i] = {56{1'bx}};
        $readmemh("sim/vec/arith_u2f24.hex", v24);
        n = 0;
        while (v24[n] !== {56{1'bx}} && n < 200000) begin
            ux24 = v24[n][55:32]; #1;
            if (uf24 !== v24[n][31:0]) begin
                if (err < 10) $display("unorm2f24 x=%h got %h exp %h", ux24, uf24, v24[n][31:0]);
                err = err + 1;
            end
            n = n + 1;
        end
        if (err == 0) $display("PASS ad_arith.unorm2f (N=16 exhaustive, N=24 %0d random)", n);
        else $display("FAIL ad_arith.unorm2f (%0d)", err);
        total_err = total_err + err;

        // cmp_op exhaustive
        err = 0;
        for (i = 0; i < 64; i = i + 1) begin
            {cop, ilt, ieq, iun} = i[5:0];
            if (!((ilt & ieq) | (iun & (ilt | ieq)))) begin   // legal flag combinations only
                #1;
                gt = !ilt & !ieq & !iun;
                case (cop)
                    0: exp_pass = 0; 1: exp_pass = ilt; 2: exp_pass = ieq; 3: exp_pass = ilt | ieq;
                    4: exp_pass = gt; 5: exp_pass = !ieq; 6: exp_pass = gt | ieq; default: exp_pass = 1;
                endcase
                if (cpass !== exp_pass) err = err + 1;
            end
        end
        if (err == 0) $display("PASS ad_arith.cmp_op (exhaustive)");
        else $display("FAIL ad_arith.cmp_op (%0d)", err);
        total_err = total_err + err;

        if (total_err == 0) $display("PASS ad_arith");
        else $display("FAIL ad_arith (%0d)", total_err);
        $finish;
    end
endmodule
