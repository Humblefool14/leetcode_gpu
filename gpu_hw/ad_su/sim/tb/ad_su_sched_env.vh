// ad_su_sched_env.vh -- the environment of ad_su_sched for its two TBs
// (sim/tb/ad_su_sched_tb.v, sim/tb/ad_su_sched_gto_tb.v), included in a
// harness module with parameters NPHYS, NWARPS, WARP_W, NSU, SU_INDEX,
// FRAG_RESERVE, GTO.  The TB plays fetch (random f_ready), ad_su_sb (feedback
// per a per-warp program table, wake after replays, warp_ready), ad_su_exec
// (wc_* after feedback 1), ad_su_exp (xr after end, when xr_auto), the VF and
// the RX.  Always-on checks: f_pc follows the program (pc+1, branch targets,
// barrier continuation, replays repeat the pc), f_addr = base(kind) + 8 pc,
// a warp is fetched only when runnable (no fetch outstanding, not waiting),
// at least G = 32/NPHYS cycles between two fetches of a warp, the selected
// warp had warp_ready, and (GTO = 0) round-robin / (GTO = 1) greedy-then-
// oldest against the candidates (dut.cand) and the TB's own age model.
    localparam G = 32 / NPHYS;
    `include "ad_su_uop.vh"
    reg st_we = 0; reg [8:0] st_idx = 0; reg [31:0] st_wdata = 0;
    reg cs_kick = 0, vl_req = 0, vl_go = 0, fl_req = 0, fl_go = 0, pt_ok = 1;
    reg [31:0] vl_mask = 0, fl_mask = 0; reg [63:0] fl_info = 0;
    wire vl_gnt, fl_gnt, f_valid, init_valid, busy;
    wire [WARP_W-1:0] vl_slot, fl_slot, f_warp, init_warp;
    wire [15:0] f_pc; wire [31:0] f_addr, init_mask;
    reg f_ready = 1;
    reg fb_valid = 0; reg [WARP_W-1:0] fb_warp = 0; reg [1:0] fb_kind = 0;
    reg [NWARPS-1:0] wake = 0, warp_ready = {NWARPS{1'b1}};
    reg wc_valid = 0; reg [WARP_W-1:0] wc_warp = 0; reg [1:0] wc_op = 0; reg [15:0] wc_pc = 0;
    reg [WARP_W-1:0] q_warp = 0; wire [159:0] q_info;
    reg xr_valid = 0; reg [WARP_W-1:0] xr_warp = 0;

    ad_su_sched #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .NSU(NSU), .SU_INDEX(SU_INDEX),
                  .FRAG_RESERVE(FRAG_RESERVE), .GTO(GTO)) dut (.*);

    integer errors = 0, cyc = 0, seed = SEED;
    reg [NWARPS-1:0] wr_low = 0;
    integer n_rp = 0;
    integer frdy_pct = 100, fbd_min = 2, fbd_max = 5, xr_auto = 1, wr_rand = 0, long_pct = 0;
    // program table: per warp and pc: {kind[1:0], wcop[1:0], target[15:0]}; kind 3 = long (fb 0, then pending)
    reg [19:0] prog [0:NWARPS*64-1];
    // model per warp
    reg [15:0] m_pc [0:NWARPS-1];
    reg [1:0]  m_kind [0:NWARPS-1];     // warp kind for f_addr
    integer    m_st [0:NWARPS-1];       // 0 free, 1 runnable, 2 fetch out, 3 replay, 4 wait wc, 5 bar, 6 ended
    integer    m_last [0:NWARPS-1];     // cycle of the last take
    integer    m_age [0:NWARPS-1];
    integer    m_pend [0:NWARPS-1];     // long pending until this cycle (warp_ready 0)
    integer    n_take [0:NWARPS-1];
    integer    n_replay = 0, n_sel = 0, n_greedy = 0, n_bar_viol = 0;
    reg [NWARPS-1:0] m_wgm [0:NWARPS-1];
    // event queues: feedback (by due cycle), wc, wake, xr
    integer fq_due [0:63]; reg [WARP_W-1:0] fq_w [0:63]; reg [15:0] fq_pc [0:63]; integer fqh = 0, fqt = 0;
    integer wq_due [0:63]; reg [WARP_W+2+16-1:0] wq_d [0:63]; integer wqh = 0, wqt = 0;
    integer kq_due [0:63]; reg [WARP_W-1:0] kq_w [0:63]; integer kqh = 0, kqt = 0;
    integer xq_due [0:63]; reg [WARP_W-1:0] xq_w [0:63]; integer xqh = 0, xqt = 0;

    function integer rnd(input integer lo, input integer hi);
        rnd = lo + ($unsigned($random(seed)) % (hi - lo + 1));
    endfunction
    function [31:0] base_of(input [1:0] k);
        base_of = (k == 0) ? 32'h0001_0000 : (k == 1) ? 32'h0002_0000 : 32'h0004_0000;
    endfunction

    task setst(input [8:0] idx, input [31:0] v);
        begin @(negedge clk); st_we = 1; st_idx = idx; st_wdata = v; @(negedge clk); st_we = 0; end
    endtask

    integer i, w, k, t;
    reg p_fv, p_take, p_sel; reg [NWARPS-1:0] p_wr, p_cand; reg [WARP_W-1:0] p_gw, p_rr; reg p_gv;
    integer p_age [0:NWARPS-1];
    reg [WARP_W-1:0] exp_sel;
    integer best;
    initial begin
        for (i = 0; i < NWARPS; i = i + 1) begin
            m_st[i] = 0; m_pc[i] = 0; m_last[i] = -1000; m_age[i] = 0; m_pend[i] = 0; n_take[i] = 0; m_kind[i] = 0;
            m_wgm[i] = 0;
        end
        for (i = 0; i < NWARPS * 64; i = i + 1) prog[i] = 0;
        p_fv = 0; p_take = 0;
    end

    // ---------------- the environment, at negedge (inputs), checks at posedge
    always @(negedge clk) if (rst_n) begin
        f_ready = ($unsigned($random(seed)) % 100) < frdy_pct;
        fb_valid = 0; wc_valid = 0; wake = 0; xr_valid = 0;
        if (fqh != fqt && fq_due[fqh % 64] <= cyc) begin
            w = fq_w[fqh % 64];
            t = prog[w * 64 + (fq_pc[fqh % 64] % 64)];
            fb_valid = 1; fb_warp = w;
            if (m_pend[w] > cyc && t[19:18] != 2'd0) begin
                // a dependent instruction while a long one is pending: replay
                fb_kind = 2; n_replay = n_replay + 1;
                kq_due[kqt % 64] = m_pend[w]; kq_w[kqt % 64] = w; kqt = kqt + 1;
                m_st[w] = 3;
            end else begin
                case (t[19:18])
                2'd0, 2'd3: begin
                    fb_kind = 0; m_pc[w] = m_pc[w] + 1; m_st[w] = 1;
                    if (t[19:18] == 3 || (long_pct > 0 && rnd(0, 99) < long_pct)) m_pend[w] = cyc + rnd(3, 20);
                end
                2'd1: begin
                    fb_kind = 1; m_st[w] = 4;
                    wq_due[wqt % 64] = cyc + rnd(2, 6); wq_d[wqt % 64] = {w[WARP_W-1:0], t[17:16], t[15:0]}; wqt = wqt + 1;
                end
                default: begin
                    fb_kind = 2; m_st[w] = 3; n_rp = n_rp + 1;
                    prog[w * 64 + (fq_pc[fqh % 64] % 64)] = 0;          // replays once
                    kq_due[kqt % 64] = cyc + rnd(1, 8); kq_w[kqt % 64] = w; kqt = kqt + 1;
                end
                endcase
            end
            fqh = fqh + 1;
        end
        if (wqh != wqt && wq_due[wqh % 64] <= cyc) begin
            {wc_warp, wc_op, wc_pc} = wq_d[wqh % 64]; wc_valid = 1; w = wc_warp;
            if (wc_op == 0) begin m_pc[w] = wc_pc; m_st[w] = 1; end
            else if (wc_op == 2) begin m_pc[w] = wc_pc; m_st[w] = 5; end
            else begin
                m_st[w] = 6;
                if (xr_auto) begin xq_due[xqt % 64] = cyc + rnd(1, 10); xq_w[xqt % 64] = w; xqt = xqt + 1; end
            end
            wqh = wqh + 1;
        end
        if (kqh != kqt && kq_due[kqh % 64] <= cyc) begin
            wake[kq_w[kqh % 64]] = 1;
            if (m_st[kq_w[kqh % 64]] == 3) m_st[kq_w[kqh % 64]] = 1;
            kqh = kqh + 1;
        end
        if (xqh != xqt && xq_due[xqh % 64] <= cyc) begin
            xr_valid = 1; xr_warp = xq_w[xqh % 64]; m_st[xr_warp] = 0; xqh = xqh + 1;
            for (i = 0; i < NWARPS; i = i + 1) m_wgm[i][xr_warp] = 1'b0;
        end
        // barrier release in the model: all members of a group at bar or ended
        for (w = 0; w < NWARPS; w = w + 1) if (m_st[w] == 5) begin
            k = 1;
            for (i = 0; i < NWARPS; i = i + 1) if (m_wgm[w][i] && m_st[i] != 5 && m_st[i] != 6) k = 0;
            if (k) for (i = 0; i < NWARPS; i = i + 1) if (m_wgm[w][i] && m_st[i] == 5) m_st[i] = 7; // releasing
        end
        for (w = 0; w < NWARPS; w = w + 1) begin
            if (m_st[w] == 7) m_st[w] = 1;
            warp_ready[w] = (m_pend[w] <= cyc) && !wr_low[w] && (wr_rand == 0 || rnd(0, 99) < 70);
        end
    end

    always @(posedge clk) if (rst_n) begin
        cyc <= cyc + 1;
        // start of a warp
        if (init_valid) begin
            m_pc[init_warp] = 0; m_st[init_warp] = 1; m_age[init_warp] = -1;
        end
        // selection reference (the selection is made in this cycle when f_* is empty or taken)
        if ((!f_valid || f_ready) && |dut.cand) begin
            n_sel = n_sel + 1;
            if (GTO == 0) begin
                exp_sel = dut.rr_last;
                for (i = NWARPS; i >= 1; i = i - 1) if (dut.cand[(dut.rr_last + i) % NWARPS]) exp_sel = (dut.rr_last + i) % NWARPS;
            end else if (dut.gv && dut.cand[dut.gw]) begin
                exp_sel = dut.gw; n_greedy = n_greedy + 1;
            end else begin
                best = -1;
                for (i = 0; i < NWARPS; i = i + 1) if (dut.cand[i] && m_age[i] > best) begin best = m_age[i]; exp_sel = i; end
            end
            if (dut.sel_w !== exp_sel) begin
                $display("FAIL %m: selection %0d expected %0d (cand %b) at %0d", dut.sel_w, exp_sel, dut.cand, cyc);
                errors = errors + 1;
            end
            if (!warp_ready[dut.sel_w]) begin $display("FAIL %m: selected a warp without warp_ready"); errors = errors + 1; end
            for (i = 0; i < NWARPS; i = i + 1)
                if (dut.cand[i] && (m_st[i] != 1 || !warp_ready[i])) begin
                    $display("FAIL %m: warp %0d candidate in model state %0d at %0d", i, m_st[i], cyc); errors = errors + 1;
                end
        end
        // take
        if (f_valid && f_ready) begin
            w = f_warp;
            if (m_st[w] != 1) begin $display("FAIL %m: warp %0d fetched in model state %0d at %0d", w, m_st[w], cyc); errors = errors + 1; end
            if (f_pc !== m_pc[w]) begin $display("FAIL %m: warp %0d pc %0d expected %0d", w, f_pc, m_pc[w]); errors = errors + 1; end
            if (f_addr !== base_of(m_kind[w]) + 8 * f_pc) begin $display("FAIL %m: f_addr %h", f_addr); errors = errors + 1; end
            if (cyc - m_last[w] < G) begin $display("FAIL %m: warp %0d fetched %0d cycles apart (G %0d)", w, cyc - m_last[w], G); errors = errors + 1; end
            m_last[w] = cyc; m_st[w] = 2; m_age[w] = -1; n_take[w] = n_take[w] + 1;
            fq_due[fqt % 64] = cyc + rnd(fbd_min, fbd_max);
            if (fqt != fqh && fq_due[fqt % 64] <= fq_due[(fqt + 63) % 64]) fq_due[fqt % 64] = fq_due[(fqt + 63) % 64] + 1;
            fq_w[fqt % 64] = w; fq_pc[fqt % 64] = f_pc; fqt = fqt + 1;
        end
        for (i = 0; i < NWARPS; i = i + 1) if (m_age[i] < 255) m_age[i] = m_age[i] + 1;
    end

    // ---- helpers for the tests
    task wait_idle(input integer maxc);
        integer c;
        begin
            c = 0;
            while ((busy || fqh != fqt || wqh != wqt || xqh != xqt) && c < maxc) begin @(negedge clk); c = c + 1; end
            if (c >= maxc) begin $display("FAIL %m: not idle after %0d cycles", maxc); errors = errors + 1; end
        end
    endtask
    // a compute grid
    task grid(input [31:0] wgs, input [15:0] x, input [15:0] y, input [15:0] z);
        begin
            setst(`AD_S_WG_SIZE, wgs); setst(`AD_S_GRID_X, x); setst(`AD_S_GRID_Y, y); setst(`AD_S_GRID_Z, z);
            @(negedge clk); cs_kick = 1; @(negedge clk); cs_kick = 0;
        end
    endtask
    // programs: every warp straight code to pc n-1, end at n
    task prog_straight(input integer n);
        begin
            for (i = 0; i < NWARPS * 64; i = i + 1) prog[i] = 0;
            for (w = 0; w < NWARPS; w = w + 1) prog[w * 64 + n] = {2'd1, 2'd1, 16'd0};
        end
    endtask
    task bases;
        begin
            setst(`AD_S_VS_BASE, base_of(0)); setst(`AD_S_FS_BASE, base_of(1)); setst(`AD_S_CS_BASE, base_of(2));
        end
    endtask
    // record compute starts for the model's kind and workgroup masks
    reg [NWARPS-1:0] cur_wg;
    always @(posedge clk) if (rst_n && init_valid) begin
        m_kind[init_warp] = dut.s_frag ? 1 : dut.s_vert ? 0 : 2;
        m_wgm[init_warp] = dut.s_comp ? dut.l_all : (1 << init_warp);
    end
