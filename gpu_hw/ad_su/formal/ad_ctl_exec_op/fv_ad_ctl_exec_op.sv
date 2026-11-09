// fv_ad_ctl_exec_op -- the whole-warp EXEC operation equals a per-lane
// reference written from tools/gsi1model.py (unit EXEC ops 0-5, 8-14).
module fv_ad_ctl_exec_op (input wire clk);
    (* anyconst *) reg [7:0]  op;
    (* anyconst *) reg [31:0] bt, ex, kd;
    wire [31:0] exo, kdo; wire taken, wc; wire [1:0] wc_op;
    ad_ctl_exec_op dut (.op(op), .bt(bt), .exec_i(ex), .killed_i(kd), .exec_o(exo), .killed_o(kdo),
                        .taken(taken), .wc(wc), .wc_op(wc_op));
    reg any_b, none_b, all_b, any_e; reg [31:0] rx, rk; reg rt, rwc; reg [1:0] rop;
    integer l;
    always @(*) begin
        any_b = 0; none_b = 1; all_b = 1; any_e = 0;
        for (l = 0; l < 32; l = l + 1) begin
            if (ex[l] && bt[l]) begin any_b = 1; none_b = 0; end
            if (ex[l] && !bt[l]) all_b = 0;
            if (ex[l]) any_e = 1;
        end
        rx = ex; rk = kd; rt = 0; rwc = (op <= 5) || op == 13 || op == 14; rop = (op == 13) ? 1 : (op == 14) ? 2 : 0;
        case (op)
        0: rt = any_b; 1: rt = none_b; 2: rt = all_b; 3: rt = 1; 4: rt = any_e; 5: rt = !any_e;
        default: rt = 0;
        endcase
        for (l = 0; l < 32; l = l + 1) begin
            if (op == 8) rx[l] = bt[l];
            if (op == 9) rx[l] = ex[l] && bt[l];
            if (op == 10) rx[l] = ex[l] || bt[l];
            if (op == 12) rk[l] = kd[l] || (bt[l] && ex[l]);
        end
        a_exec: assert (exo == rx);
        a_kill: assert (kdo == rk);
        a_take: assert (!rwc || rop != 0 || taken == rt);
        a_wc:   assert (wc == rwc && (!wc || wc_op == rop));
    end
endmodule
