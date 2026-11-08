// fv_ad_rop_cache -- protocol and data-integrity properties of ad_rop_cache.
// Reduction: LINE_BYTES = 4, SETS_LOG2 = 1 (2 sets), WAYS = 4; request addresses are
// assumed below 64 (16 lines, 8 per set: twice the capacity, so evictions happen).
// Reset only in the first cycle.  The DUT is read with -DAD_FV_CACHE (observation ports).
//
// Data integrity: A = (* anyconst *) line.  S = shadow of A's latest written value (writes
// merged with byte enables at acceptance).  M = the memory's copy of A (written by mem
// writes of A).  Both start equal to an arbitrary constant.  The memory model answers each
// refill read once, later; for line A with M, for other lines with anything.  Every read
// response of A must equal S at the read's acceptance (a_data).
// The h_* assertions are helper invariants (they make the property inductive; each one is
// itself proven).
module fv_ad_rop_cache #(
    parameter LBY = 4,
    parameter SL  = 1
) (
    input wire            clk,
    input wire            rst_n,
    input wire            req_valid,
    input wire            req_write,
    input wire [31:0]     req_addr,
    input wire [LBY-1:0]  req_be,
    input wire [LBY*8-1:0] req_wdata,
    input wire            mem_req_ready,
    input wire            mem_rsp_valid,
    input wire [LBY*8-1:0] mem_rsp_any,
    input wire            flush
);
    localparam LS = $clog2(LBY), LW = 32 - LS, TW = 32 - LS - SL, NE = (1 << SL) * 4, LB = LBY * 8;
    localparam EW = SL + 2;
    localparam [3:0] S_IDLE = 0, S_MISS = 1, S_EVICT = 2, S_RREQ = 3, S_RWAIT = 4, S_REPLAY = 5,
                     S_FSCAN = 6, S_FWB = 7;

    wire req_ready, rsp_valid, mem_req_valid, mem_req_write, busy;
    wire [LB-1:0] rsp_rdata, mem_req_wdata;
    wire [LW-1:0] mem_req_line;
    wire [LB-1:0] mem_rsp_rdata;
    wire [3:0] st; wire [NE-1:0] fv_valid, fv_dirty; wire [NE*TW-1:0] fv_tags; wire [NE*LB-1:0] fv_ram;
    wire [31:0] q_addr; wire q_write; wire [1:0] vway; wire [EW-1:0] fl_idx;
    wire [LBY-1:0] q_be; wire [LB-1:0] q_wdata;

    ad_rop_cache #(.LINE_BYTES(LBY), .WAYS(4), .SETS_LOG2(SL)) dut (.clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_addr(req_addr),
        .req_be(req_be), .req_wdata(req_wdata), .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready), .mem_req_write(mem_req_write),
        .mem_req_line(mem_req_line), .mem_req_wdata(mem_req_wdata),
        .mem_rsp_valid(mem_rsp_valid), .mem_rsp_rdata(mem_rsp_rdata), .flush(flush), .busy(busy),
        .fv_state(st), .fv_valid(fv_valid), .fv_dirty(fv_dirty), .fv_tags(fv_tags), .fv_ram(fv_ram),
        .fv_q_addr(q_addr), .fv_q_write(q_write), .fv_vway(vway), .fv_fl_idx(fl_idx),
        .fv_q_be(q_be), .fv_q_wdata(q_wdata));

    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) assume (rst_n == !init);
    always @(*) if (req_valid) assume (req_addr[31:6] == 26'd0);

    (* anyconst *) reg [LW-1:0] A;
    (* anyconst *) reg [LB-1:0] init_val;
    always @(*) assume (A[LW-1:6-LS] == 0);
    wire [SL-1:0] A_set = A[SL-1:0];
    wire [TW-1:0] A_tag = A[LW-1:SL];

    wire accept   = req_valid && req_ready;
    wire req_A    = (req_addr[31:LS] == A);
    wire mem_fire = mem_req_valid && mem_req_ready;

    reg [LB-1:0] S, S_old, M;
    reg pend, pend_rdA; reg [LB-1:0] pend_exp;
    reg rd_out, rd_A;
    integer b;
    always @(posedge clk) begin
        if (init) begin
            S <= init_val; M <= init_val; pend <= 1'b0; rd_out <= 1'b0; rd_A <= 1'b0; pend_rdA <= 1'b0;
        end else begin
            if (accept && req_write && req_A) begin
                S_old <= S;
                for (b = 0; b < LBY; b = b + 1) if (req_be[b]) S[8*b +: 8] <= req_wdata[8*b +: 8];
            end
            if (accept) begin pend <= 1'b1; pend_rdA <= !req_write && req_A; pend_exp <= S; end
            else if (rsp_valid) pend <= 1'b0;
            if (mem_fire && mem_req_write && mem_req_line == A) M <= mem_req_wdata;
            if (mem_fire && !mem_req_write) begin rd_out <= 1'b1; rd_A <= (mem_req_line == A); end
            else if (mem_rsp_valid) rd_out <= 1'b0;
        end
    end
    // memory model: one response per refill read, later; line A answers M
    assign mem_rsp_rdata = rd_A ? M : mem_rsp_any;
    always @(*) if (!rd_out || init) assume (!mem_rsp_valid);

    // ---------------- assertions ----------------
    wire [EW-1:0]  q_ent = {q_addr[LS +: SL], vway};
    wire [SL-1:0]  q_set = q_addr[LS +: SL];
    wire [TW-1:0]  q_tag = q_addr[31 -: TW];
    wire q_A     = (q_addr[31:LS] == A);
    wire missing = (st == S_MISS) || (st == S_EVICT) || (st == S_RREQ) || (st == S_RWAIT) || (st == S_REPLAY);
    wire wpend   = missing && q_write && q_A;
    wire [LB-1:0] cur = wpend ? S_old : S;      // value of A the cache+memory currently hold
    reg  [LB-1:0] merged;
    integer bb;
    always @(*) for (bb = 0; bb < LBY; bb = bb + 1) merged[8*bb +: 8] = q_be[bb] ? q_wdata[8*bb +: 8] : S_old[8*bb +: 8];

    wire [NE-1:0] inA;
    wire [TW-1:0] tg [0:NE-1];      // per-entry views (variable indexing without multiplies)
    wire [LB-1:0] rm [0:NE-1];
    genvar g;
    generate for (g = 0; g < NE; g = g + 1) begin : g_in
        assign tg[g]  = fv_tags[g*TW +: TW];
        assign rm[g]  = fv_ram[g*LB +: LB];
        assign inA[g] = fv_valid[g] && (g >> 2) == A_set && tg[g] == A_tag;
    end endgenerate

    integer e, f;
    always @(*) begin e = 0; f = 0; if (!init) begin
        // ---- data integrity ----
        if (rsp_valid) a_rsp_pend: assert (pend);
        if (rsp_valid && pend_rdA) a_data: assert (rsp_rdata == pend_exp);
        if (accept) a_one_req: assert (!pend || rsp_valid);
        // ---- protocol ----
        if (mem_req_valid) a_one_read: assert (!rd_out);
        if (mem_req_valid && !mem_req_write) a_refill_clean: assert (!(fv_valid[q_ent] && fv_dirty[q_ent]));
        if (!busy) begin
            a_idle_st:  assert (st == S_IDLE);
            a_idle_mem: assert (!mem_req_valid);
        end
        if (busy) a_busy_rdy: assert (!req_ready);

        // ---- helper invariants ----
        h_st: assert (st <= S_FWB);
        for (e = 0; e < NE; e = e + 1) begin
            for (f = e + 1; f < NE; f = f + 1)
                if ((e >> 2) == (f >> 2) && fv_valid[e] && fv_valid[f]) assert (fv_tags[e*TW +: TW] != fv_tags[f*TW +: TW]);
            if (inA[e]) assert (fv_ram[e*LB +: LB] == cur);
            if (inA[e] && !fv_dirty[e]) assert (M == cur);
            if (fv_dirty[e]) assert (fv_valid[e]);
            if ((st == S_FSCAN || st == S_FWB) && e < fl_idx) assert (!fv_dirty[e]);
            if ((st == S_MISS || st == S_EVICT || st == S_RREQ || st == S_RWAIT) && (e >> 2) == q_set)
                assert (!(fv_valid[e] && fv_tags[e*TW +: TW] == q_tag));
        end
        if (inA == 0) h_mem: assert (M == cur);
        if (st == S_EVICT) begin
            h_ev_d: assert (rsp_rdata == rm[q_ent]);
            h_ev_v: assert (fv_valid[q_ent] && fv_dirty[q_ent]);
        end
        if (st == S_FWB) begin
            h_fw_d: assert (rsp_rdata == rm[fl_idx]);
            h_fw_v: assert (fv_valid[fl_idx] && fv_dirty[fl_idx]);
        end
        if (st == S_REPLAY) h_rp: assert (fv_valid[q_ent] && tg[q_ent] == q_tag);
        if (st == S_RREQ || st == S_RWAIT) h_rf: assert (!(fv_valid[q_ent] && fv_dirty[q_ent]));
        if (pend && pend_rdA) h_pexp: assert (pend_exp == S);
        if (missing) begin
            h_m_p:  assert (pend && !rsp_valid);
            h_m_ra: assert (pend_rdA == (!q_write && q_A));
        end
        if (st == S_IDLE) h_i_p: assert (pend == rsp_valid);
        if (st == S_FSCAN || st == S_FWB) h_f_p: assert (!pend && !rsp_valid);
        h_rd: assert (rd_out == (st == S_RWAIT));
        if (st == S_RWAIT) h_rdA: assert (rd_A == q_A);
        if (wpend) h_wp: assert (S == merged);
    end end
    // hold-until-ready of the memory request; flush completion
    reg p_ok = 1'b0, p_v, p_r, p_w; reg [LW-1:0] p_l; reg [LB-1:0] p_d; reg [3:0] p_st;
    always @(posedge clk) begin
        p_ok <= !init; p_v <= mem_req_valid; p_r <= mem_req_ready; p_w <= mem_req_write;
        p_l <= mem_req_line; p_d <= mem_req_wdata; p_st <= st;
    end
    always @(*) if (p_ok) begin
        if (p_v && !p_r) begin
            a_hold_v: assert (mem_req_valid);
            a_hold_w: assert (mem_req_write == p_w);
            a_hold_l: assert (mem_req_line == p_l);
            if (p_w) a_hold_d: assert (mem_req_wdata == p_d);
        end
        if ((p_st == S_FSCAN || p_st == S_FWB) && st == S_IDLE) a_flush_clean: assert (fv_dirty == 0);
    end
    // reachability
    always @(*) if (!init) begin
        c_rdA_miss: cover (rsp_valid && pend_rdA && p_st == S_REPLAY);
        c_flwb:     cover (p_ok && p_st == S_FWB && st == S_FSCAN);   // a flush write-back
        c_fldone:   cover (p_ok && p_st == S_FSCAN && st == S_IDLE && fv_valid != 0);
    end
endmodule
