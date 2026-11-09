// fv_ad_su_wb -- ad_su_wb reduced (NPHYS 4, NS 2, NL 3, 2-bit lane words, input FIFOs
// of 4 words).  Asserts: at most one result a cycle (RF write or rq push) and at most
// one long beat taken (only valid ones); a short result is written (or pushed for rd
// 63) in its own cycle with its fields; a long beat with data never goes beside a
// short result, and when taken is written/pushed in that cycle with its fields; the
// count of long beats with data taken equals the count of their writes; a release
// exactly for each taken l_last beat with its warp/sbe/class; rd 63 never writes the
// RF; no input FIFO overflows; wb_stall = an input word waits or a long beat with
// data waited >= 4 cycles.
// Assumptions (the spec's): at most one short result a cycle; rd < 64; after wb_stall
// has been 1 for K = FDEPTH/2 cycles in a row no short result comes (the issue stage
// stops, K = SHORT_LAT + 2G + 2 for the spec's depth); at most one input word a cycle
// in total (ASSUMPTION of ad_su_wb.md §10: two sources at one word a cycle each would
// exceed the port).
module fv_ad_su_wb (
    input wire clk,
    input wire [1:0] s_valid, input wire [1:0] s_warp, input wire [5:0] s_grp, input wire [13:0] s_rd,
    input wire [15:0] s_data, input wire [7:0] s_lanes,
    input wire [2:0] l_valid, input wire [2:0] l_warp, input wire [8:0] l_grp, input wire [20:0] l_rd,
    input wire [23:0] l_data, input wire [11:0] l_lanes, input wire [2:0] l_wr, input wire [2:0] l_last,
    input wire [5:0] l_sbe, input wire [8:0] l_cls,
    input wire [1:0] in_we, input wire [1:0] in_warp, input wire [11:0] in_reg, input wire [9:0] in_lane,
    input wire [63:0] in_data
);
    localparam NPHYS = 4, LW = 2, NS = 2, NL = 3, FD = 4, K = FD / 2, DW = NPHYS * LW;
    reg init = 1;
    always @(posedge clk) init <= 0;
    wire rst_n = !init;
    wire [2:0] l_ready; wire w_en, rel_valid, rq_push, wb_stall; wire w_warp, rel_warp; wire [2:0] w_grp;
    wire [5:0] w_reg; wire [DW-1:0] w_data, rq_data; wire [3:0] w_lanes; wire [1:0] rel_sbe; wire [2:0] rel_cls;
    ad_su_wb #(.NPHYS(NPHYS), .WARP_W(1), .GRP_W(3), .SBE_W(1), .NS(NS), .NL(NL), .SHORT_LAT(6),
               .FDEPTH(FD), .LW(LW)) dut (
        .clk(clk), .rst_n(rst_n), .s_valid(s_valid), .s_warp(s_warp), .s_grp(s_grp), .s_rd(s_rd), .s_data(s_data),
        .s_lanes(s_lanes), .l_valid(l_valid), .l_ready(l_ready), .l_warp(l_warp), .l_grp(l_grp), .l_rd(l_rd),
        .l_data(l_data), .l_lanes(l_lanes), .l_wr(l_wr), .l_last(l_last), .l_sbe(l_sbe), .l_cls(l_cls),
        .in_we(in_we), .in_warp(in_warp), .in_reg(in_reg), .in_lane(in_lane), .in_data(in_data),
        .w_en(w_en), .w_warp(w_warp), .w_grp(w_grp), .w_reg(w_reg), .w_data(w_data), .w_lanes(w_lanes),
        .rel_valid(rel_valid), .rel_warp(rel_warp), .rel_sbe(rel_sbe), .rel_cls(rel_cls),
        .rq_push(rq_push), .rq_data(rq_data), .wb_stall(wb_stall));
    // ---- assumptions ----
    reg [3:0] stall_run = 0;
    always @(posedge clk) stall_run <= init ? 0 : (wb_stall ? ((stall_run == 15) ? 15 : stall_run + 1) : 0);
    always @(*) begin
        assume (s_valid != 2'b11);
        assume (s_rd[6] == 0 && s_rd[13] == 0 && l_rd[6] == 0 && l_rd[13] == 0 && l_rd[20] == 0);
        assume (in_we != 2'b11);
        if (stall_run >= K) assume (s_valid == 0);
    end
    // ---- harness model ----
    integer k;
    reg sv; reg [6:0] sr; reg sw; reg [2:0] sg; reg [DW-1:0] sd; reg [3:0] sl;
    reg lt, lw, ll; reg [6:0] lr; reg lwp; reg [2:0] lg; reg [DW-1:0] ld; reg [3:0] lln; reg [1:0] lsb; reg [2:0] lc;
    always @(*) begin
        sv = 0; sr = 0; sw = 0; sg = 0; sd = 0; sl = 0;
        for (k = 0; k < NS; k = k + 1) if (s_valid[k]) begin
            sv = 1; sr = s_rd[7*k +: 7]; sw = s_warp[k]; sg = s_grp[3*k +: 3]; sd = s_data[DW*k +: DW]; sl = s_lanes[4*k +: 4];
        end
        lt = 0; lw = 0; ll = 0; lr = 0; lwp = 0; lg = 0; ld = 0; lln = 0; lsb = 0; lc = 0;
        for (k = 0; k < NL; k = k + 1) if (l_ready[k]) begin
            lt = 1; lw = l_wr[k]; ll = l_last[k]; lr = l_rd[7*k +: 7]; lwp = l_warp[k]; lg = l_grp[3*k +: 3];
            ld = l_data[DW*k +: DW]; lln = l_lanes[4*k +: 4]; lsb = l_sbe[2*k +: 2]; lc = l_cls[3*k +: 3];
        end
    end
    // counts of long beats with data taken / written
    reg [7:0] n_lt = 0, n_lw = 0;
    always @(posedge clk) if (init) begin n_lt <= 0; n_lw <= 0; end else begin
        if (lt && lw) n_lt <= n_lt + 1;
        if (lt && lw && (w_en || rq_push) && !sv) n_lw <= n_lw + 1;
    end
    // input FIFO occupancy model
    reg [3:0] c0 = 0, c1 = 0;
    wire ip0 = !sv && c0 != 0, ip1 = !sv && c0 == 0 && c1 != 0;
    always @(posedge clk) if (init) begin c0 <= 0; c1 <= 0; end else begin
        c0 <= c0 + (in_we[0] && c0 != FD) - ip0;
        c1 <= c1 + (in_we[1] && c1 != FD) - ip1;
    end
    // wait counter model
    reg [2:0] wc = 0;
    always @(posedge clk) wc <= init ? 0 : (|(l_valid & l_wr) && !(lt && lw)) ? ((wc == 7) ? 7 : wc + 1) : 0;
    always @(*) if (!init) begin
        assert (!(w_en && rq_push));
        assert ((l_ready & (l_ready - 1)) == 0);
        assert ((l_ready & ~l_valid) == 0);
        if (sv) begin
            if (sr == 63) assert (rq_push && rq_data == sd);
            else assert (w_en && w_reg == sr[5:0] && w_warp == sw && w_grp == sg && w_data == sd && w_lanes == sl);
            assert (!(lt && lw));
        end
        if (lt && lw) begin
            if (lr == 63) assert (rq_push && rq_data == ld);
            else assert (w_en && w_reg == lr[5:0] && w_warp == lwp && w_grp == lg && w_data == ld && w_lanes == lln);
        end
        assert (n_lt == n_lw);
        assert (rel_valid == (lt && ll));
        if (rel_valid) assert (rel_warp == lwp && rel_sbe == lsb && rel_cls == lc);
        if (w_en) assert (w_reg != 63);
        assert (!(in_we[0] && c0 == FD) && !(in_we[1] && c1 == FD));
        assert (wb_stall == (c0 != 0 || c1 != 0 || wc >= 4));
        if (ip0 || ip1) assert (!(lt && lw));
    end
endmodule
