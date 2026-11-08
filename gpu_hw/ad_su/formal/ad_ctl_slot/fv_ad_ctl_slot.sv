// fv_ad_ctl_slot -- the slot state machine against a reference of its
// transition table (free events every cycle): state and pc after each cycle
// equal the reference; the state is always one of the nine.
module fv_ad_ctl_slot (input wire clk, input wire alloc, start, sel, take, fb, wake, wc, bar_rel, xr,
                       input wire [1:0] fb_kind, wc_op, input wire [15:0] wc_pc);
    reg init = 1'b1; always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    wire [3:0] st; wire [15:0] pc;
    ad_ctl_slot dut (.clk(clk), .rst_n(rst_n), .alloc(alloc), .start(start), .sel(sel), .take(take), .fb(fb),
        .fb_kind(fb_kind), .wake(wake), .wc(wc), .wc_op(wc_op), .wc_pc(wc_pc), .bar_rel(bar_rel), .xr(xr),
        .st(st), .pc(pc));
    reg [3:0] rs; reg [15:0] rp;
    always @(posedge clk) begin
        if (!rst_n) begin rs <= 0; rp <= 0; end
        else begin
            if (rs == 0 && alloc) rs <= 1;
            if (rs == 1 && start) begin rs <= 2; rp <= 0; end
            if (rs == 2 && sel) rs <= 3;
            if (rs == 3 && take) rs <= 4;
            if (rs == 4 && fb && fb_kind == 0) begin rs <= 2; rp <= rp + 1; end
            if (rs == 4 && fb && fb_kind == 1) rs <= 5;
            if (rs == 4 && fb && fb_kind == 2) rs <= wake ? 2 : 6;
            if (rs == 4 && fb && fb_kind == 3) rs <= 2;
            if (rs == 6 && wake) rs <= 2;
            if (rs == 5 && wc && wc_op == 1) rs <= 8;
            if (rs == 5 && wc && wc_op == 2) begin rs <= 7; rp <= wc_pc; end
            if (rs == 5 && wc && (wc_op == 0 || wc_op == 3)) begin rs <= 2; rp <= wc_pc; end
            if (rs == 7 && bar_rel) rs <= 2;
            if (rs == 8 && xr) rs <= 0;
        end
    end
    always @(*) if (rst_n) begin
        a_st: assert (st == rs && st <= 8);
        a_pc: assert (pc == rp);
    end
endmodule
