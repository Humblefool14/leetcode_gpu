// fv_ad_ctl_sb_sil -- the short-result interlock (bmc: NPHYS 16, G = 2,
// SHORT_LAT 4, OQ 4; prove: NPHYS 32, SHORT_LAT 2, OQ 2).  A tagged short writer (free pick) of warp W, rd R:
// while it is issued and its x_end has not come, or fewer than
// SHORT_LAT + 1 - (G + 1) cycles have passed since (its count is above
// G + 1), a query of warp W reading R must see hold_rd; a long writer whose
// range covers R must see hold_wr until SHORT_LAT + 1 cycles after x_end.
// Reduced to registers 0, 1, 62 (63 rq) and one source.  The list never overflows (push only when not full; x_end only for listed
// instructions).
module fv_ad_ctl_sb_sil #(parameter NPHYS = 16, parameter SL = 4, parameter OQ = 4) (input wire clk, input wire push, input wire [0:0] push_warp, input wire push_sw,
                         input wire [5:0] push_rd, input wire x_end, input wire pick,
                         input wire [0:0] q_warp, input wire [4:0] q_use, input wire [39:0] q_src,
                         input wire q_dst_use, input wire [5:0] q_dst, input wire q_dst_w4);
    reg init = 1'b1; always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    wire hold_rd, hold_wr, full, idle;
    ad_ctl_sb_sil #(.WARP_W(1), .NPHYS(NPHYS), .SHORT_LAT(SL), .OQ(OQ)) dut (.clk(clk), .rst_n(rst_n),
        .push(push), .push_warp(push_warp), .push_sw(push_sw), .push_rd(push_rd), .x_end(x_end),
        .q_warp(q_warp), .q_use(q_use), .q_src(q_src), .q_dst_use(q_dst_use), .q_dst(q_dst), .q_dst_w4(q_dst_w4),
        .hold_rd(hold_rd), .hold_wr(hold_wr), .full(full), .idle(idle));
    localparam G = 32 / NPHYS, C0 = SL + 1;
    reg [2:0] n;              // listed
    reg armed, ended; reg [2:0] ahead; reg [0:0] tw; reg [5:0] tr; reg [3:0] since;
    always @(*) if (rst_n) begin
        assume (!push || !full);
        assume (!push_sw || push_rd != 6'd63);     // a short writer has rd < 63
        // data reduction: registers 0-1 and 62-63, one source (the checks
        // are the same comparators for every operand)
        assume (push_rd[5:1] == 5'd0 || push_rd[5:1] == 5'd31);
        assume (q_use[4:1] == 4'd0 && (q_src[7:1] == 7'd0 || q_src[7:1] == 7'd31 || q_src[7:1] == 7'd63));
        assume (q_dst[5:1] == 5'd0 || q_dst[5:1] == 5'd31);
        assume (!x_end || n != 0);
    end else assume (!push && !x_end);
    always @(posedge clk) begin
        if (!rst_n) begin n <= 0; armed <= 0; end
        else begin
            n <= n + push - x_end;
            if (armed && !ended && x_end) begin
                if (ahead == 0) begin ended <= 1'b1; since <= 0; end else ahead <= ahead - 1'b1;
            end
            if (armed && ended && since != 4'hF) since <= since + 1'b1;
            if (armed && ended && since >= C0 + 1) armed <= 1'b0;
            if (push && push_sw && pick && !armed) begin
                armed <= 1'b1; ended <= 1'b0; tw <= push_warp; tr <= push_rd; ahead <= n - x_end;
            end
        end
    end
    // since counts cycles after x_end: 0 in the cycle after.  The tracker's
    // count there is C0 = SHORT_LAT+1, so it is above G+1 while
    // since < C0 - (G+1), and not 0 while since < C0.
    reg reads; integer s;
    always @(*) begin
        reads = 1'b0;
        for (s = 0; s < 5; s = s + 1) if (q_use[s] && q_src[8*s +: 8] == {2'b00, tr}) reads = 1'b1;
    end
    always @(*) if (rst_n) begin
        a_n: assert (n <= OQ && full == (n == OQ));
        if (armed && q_warp == tw && reads && (!ended || since < C0 - (G + 1))) a_hold_rd: assert (hold_rd);
        if (armed && q_warp == tw && q_dst_use && tr >= q_dst && tr < q_dst + (q_dst_w4 ? 4 : 1) && (!ended || since < C0))
            a_hold_wr: assert (hold_wr);
    end
endmodule
