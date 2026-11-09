// fv_ad_vf_asm_lastuse -- prim_free against its definition (spec section 4): within a warp,
// primitive J's slot s is freed iff no later primitive of the warp names lane L_s and no lower
// slot of J names the same lane.  Driven as ad_vf_asm drives it: clr at warp start, then writes
// for primitives 0, 1, 2, ... (wj counts, at most 32), then reads (no write after a read until
// the next clr).  J is an arbitrary primitive number (anyconst); its lanes are recorded at its
// write, and every later write naming one of them is noted.
module fv_ad_vf_asm_lastuse (
    input wire       clk,
    input wire       rst_n,
    input wire       clr,
    input wire       we,
    input wire [4:0] wl0, wl1, wl2,
    input wire       rd,
    input wire [4:0] rj,
    input wire [4:0] rl0, rl1, rl2
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);

    reg [5:0] wcnt; reg rd_phase;
    wire [2:0] free;
    ad_vf_asm_lastuse dut (.clk(clk), .rst_n(rst_n), .clr(clr), .we(we), .wj(wcnt[4:0]),
        .wl0(wl0), .wl1(wl1), .wl2(wl2), .rj(rj), .rl0(rl0), .rl1(rl1), .rl2(rl2), .free(free));

    (* anyconst *) reg [4:0] J;
    reg recJ; reg [4:0] L0, L1, L2; reg [2:0] later;
    always @(*) begin
        assume (!(clr && we));
        if (we) assume (wcnt < 6'd32 && !rd_phase && !clr);
    end
    always @(posedge clk) begin
        if (!rst_n || clr) begin
            wcnt <= 6'd0; rd_phase <= 1'b0; recJ <= 1'b0; later <= 3'd0;
        end else begin
            if (rd) rd_phase <= 1'b1;
            if (we) begin
                wcnt <= wcnt + 6'd1;
                if (wcnt[4:0] == J) begin recJ <= 1'b1; L0 <= wl0; L1 <= wl1; L2 <= wl2; end
                if (recJ) later <= later | {(wl0 == L2 || wl1 == L2 || wl2 == L2),
                                            (wl0 == L1 || wl1 == L1 || wl2 == L1),
                                            (wl0 == L0 || wl1 == L0 || wl2 == L0)};
            end
        end
    end
    always @(*) if (rst_n && !init && rd && !we && recJ && rj == J && rl0 == L0 && rl1 == L1 && rl2 == L2) begin
        a_f0: assert (free[0] == !later[0]);
        a_f1: assert (free[1] == (!later[1] && L1 != L0));
        a_f2: assert (free[2] == (!later[2] && L2 != L0 && L2 != L1));
    end
endmodule
