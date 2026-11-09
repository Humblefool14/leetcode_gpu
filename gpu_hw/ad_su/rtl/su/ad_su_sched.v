// ad_su_sched -- the SU's warp scheduler (spec ad_su_sched.md).
// Warp slots (ad_ctl_slot each: state and pc), allocation for vertex (vl_*),
// fragment (fl_*) and compute (cs_kick) warps, the fetch selector
// (ad_ctl_wsel: GTO or round-robin), the issue gap, barriers and the
// warp-info word.
//
// Allocation, one per cycle, fragment > vertex > compute:
//  - fragment grant: fl_req, a FREE slot, no fragment slot granted and not
//    yet started; vertex grant: vl_req, pt_ok, more than FRAG_RESERVE FREE
//    slots, no vertex slot granted and not yet started.  The lowest FREE slot
//    goes to ALLOC; vl_gnt/fl_gnt (registered pulses) and vl_slot/fl_slot
//    (held until the next grant) the next cycle.  vl_go/fl_go make the
//    start pending (init mask, and for q_info vl_mask / fl_info).
//  - compute: cs_kick snapshots WG_SIZE and GRID_X/Y/Z (a kick while a grid is
//    still being launched waits until that grid is launched, then snapshots
//    STATE).  Workgroup ids in x, y, z order (linear id = x + X(y + Yz)); ids
//    with id % NSU != SU_INDEX are skipped (one per cycle).  A workgroup of
//    nw = ceil(WG_SIZE/32) warps (1..NWARPS, clamped) reserves the lowest nw
//    FREE slots at once (ALLOC) when that many are free, then starts one warp
//    per cycle: warp k gets EXEC = the lanes below WG_SIZE - 32k, LID 32k.
//  - starts (init_valid, one per cycle): fragment > vertex > compute.
// Fetch: f_* registered; a slot is a candidate when READY, its issue gap has
// counted out (two fetches of one warp are at least 32/NPHYS cycles apart)
// and warp_ready (ad_su_sb: no pending long destination).  Selection when
// f_* is empty or taken this cycle.  f_addr = base(kind) + 8 x pc.
// GTO = 1: the greedy warp is selected whenever it is a candidate; it stays
// the greedy warp while it has warp_ready and is READY, fetching or waiting
// for its feedback (an instruction of a warp is fetched only after the
// feedback of the previous one, so other warps fill those cycles).  When it
// stalls (warp_ready 0, replay, warp control, barrier, end) the next
// selection, the oldest candidate (largest age = cycles since its last fetch
// or start), becomes the greedy warp.  GTO = 0: round-robin after the last selected warp.
// Barrier: a warp in BAR is released when every slot of its workgroup is in
// BAR or ENDED (members are recorded at the start; a freed slot leaves).
// q_info: per-slot AD_WI_* fields, combinational on q_warp.
module ad_su_sched #(
    parameter NPHYS        = 8,
    parameter NWARPS       = 4,
    parameter WARP_W       = 2,
    parameter NSU          = 1,
    parameter SU_INDEX     = 0,
    parameter FRAG_RESERVE = 1,
    parameter GTO          = 1
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              st_we,
    input  wire [8:0]        st_idx,
    input  wire [31:0]       st_wdata,
    input  wire              cs_kick,
    input  wire              vl_req,
    output reg               vl_gnt,
    output reg  [WARP_W-1:0] vl_slot,
    input  wire              vl_go,
    input  wire [31:0]       vl_mask,
    input  wire              fl_req,
    output reg               fl_gnt,
    output reg  [WARP_W-1:0] fl_slot,
    input  wire              fl_go,
    input  wire [31:0]       fl_mask,
    input  wire [63:0]       fl_info,
    output reg               f_valid,
    input  wire              f_ready,
    output reg  [WARP_W-1:0] f_warp,
    output reg  [15:0]       f_pc,
    output reg  [31:0]       f_addr,
    input  wire              fb_valid,
    input  wire [WARP_W-1:0] fb_warp,
    input  wire [1:0]        fb_kind,
    input  wire [NWARPS-1:0] wake,
    input  wire [NWARPS-1:0] warp_ready,
    input  wire              wc_valid,
    input  wire [WARP_W-1:0] wc_warp,
    input  wire [1:0]        wc_op,
    input  wire [15:0]       wc_pc,
    input  wire [WARP_W-1:0] q_warp,
    output wire [159:0]      q_info,
    output wire              init_valid,
    output wire [WARP_W-1:0] init_warp,
    output wire [31:0]       init_mask,
    input  wire              pt_ok,
    input  wire              xr_valid,
    input  wire [WARP_W-1:0] xr_warp,
    output wire              busy
);
    `include "ad_su_uop.vh"
    `include "ad_su_state.vh"
    localparam G     = 32 / NPHYS;
    localparam GW    = $clog2(G + 1);
    localparam AGE_W = 8;
    localparam CW    = $clog2(NWARPS + 1);
    localparam [3:0] FREE = 4'd0, ALLOC = 4'd1, READY = 4'd2, FETCH = 4'd3, WAIT_FB = 4'd4,
                     WAIT_WC = 4'd5, REPLAY = 4'd6, BAR = 4'd7, ENDED = 4'd8;

    // ---- STATE
    reg [31:0] s_vs, s_fs, s_cs, s_wgs, s_gx, s_gy, s_gz;
    always @(posedge clk) begin
        if (!rst_n) begin
            s_vs <= 0; s_fs <= 0; s_cs <= 0; s_wgs <= 0; s_gx <= 0; s_gy <= 0; s_gz <= 0;
        end else if (st_we) begin
            case (st_idx)
            `AD_S_VS_BASE: s_vs  <= st_wdata;
            `AD_S_FS_BASE: s_fs  <= st_wdata;
            `AD_S_CS_BASE: s_cs  <= st_wdata;
            `AD_S_WG_SIZE: s_wgs <= st_wdata;
            `AD_S_GRID_X:  s_gx  <= st_wdata;
            `AD_S_GRID_Y:  s_gy  <= st_wdata;
            `AD_S_GRID_Z:  s_gz  <= st_wdata;
            default: ;
            endcase
        end
    end

    // ---- per-slot state
    wire [3:0]  st [0:NWARPS-1];
    wire [15:0] pc [0:NWARPS-1];
    reg  [1:0]  kind [0:NWARPS-1];
    reg  [GW-1:0] gap [0:NWARPS-1];
    reg  [AGE_W-1:0] age [0:NWARPS-1];
    reg  [NWARPS-1:0] wgm [0:NWARPS-1];
    reg  [159:0] info [0:NWARPS-1];

    reg  [NWARPS-1:0] is_free, cand;
    reg  [CW-1:0]     nfree;
    integer i, j;
    always @(*) begin
        nfree = 0;
        for (i = 0; i < NWARPS; i = i + 1) begin
            is_free[i] = st[i] == FREE;
`ifdef MUT_SCHED_NO_WREADY
            cand[i]    = st[i] == READY && gap[i] <= 1;
`else
            cand[i]    = st[i] == READY && gap[i] <= 1 && warp_ready[i];
`endif
            nfree      = nfree + is_free[i];
        end
    end
    // lowest FREE slot
    reg [WARP_W-1:0] ffree;
    always @(*) begin
        ffree = 0;
        for (i = NWARPS - 1; i >= 0; i = i - 1) if (is_free[i]) ffree = i;
    end

    // ---- vertex / fragment grants
    reg v_busy, f_busy;            // granted, not started yet
    reg pv, pf;                    // start pending
    reg [31:0] pv_mask, pf_mask;
    reg [63:0] pf_info;
    wire g_frag = fl_req && !f_busy && nfree != 0;
`ifdef MUT_SCHED_RESERVE
    wire g_vert = !g_frag && vl_req && !v_busy && pt_ok && nfree != 0;
`else
    wire g_vert = !g_frag && vl_req && !v_busy && pt_ok && nfree > FRAG_RESERVE;
`endif

    // ---- compute grid walk
    reg        c_run, c_kpend;
    reg [15:0] cx, cy, cz, gx, gy, gz;
    reg [31:0] c_wgs;
    reg [$clog2(NSU+1)-1:0] c_mod;
    reg        l_act;              // a workgroup is being started
    reg [NWARPS-1:0] l_rem, l_all;
    reg [3:0]  l_k;
    reg [15:0] l_x, l_y, l_z;
    wire [31:0] nw_raw = (c_wgs + 32'd31) >> 5;
    wire [CW-1:0] c_nw = (nw_raw == 0) ? 1 : (nw_raw > NWARPS) ? NWARPS : nw_raw[CW-1:0];
    wire c_mine = c_mod == SU_INDEX;
    wire g_comp = c_run && !l_act && c_mine && !g_frag && !g_vert && nfree >= c_nw;
    wire c_step = c_run && !l_act && (!c_mine || g_comp);
    wire c_lastid = cx + 16'd1 == gx && cy + 16'd1 == gy && cz + 16'd1 == gz;
    // the lowest c_nw FREE slots
    reg [NWARPS-1:0] c_pick;
    reg [CW-1:0] cnt;
    always @(*) begin
        c_pick = 0; cnt = 0;
        for (i = 0; i < NWARPS; i = i + 1)
            if (is_free[i] && cnt < c_nw) begin c_pick[i] = 1'b1; cnt = cnt + 1'b1; end
    end
    reg [WARP_W-1:0] l_slot;
    always @(*) begin
        l_slot = 0;
        for (i = NWARPS - 1; i >= 0; i = i - 1) if (l_rem[i]) l_slot = i;
    end

    // ---- starts
    wire s_frag = pf;
    wire s_vert = !pf && pv;
    wire s_comp = !pf && !pv && l_act;
    assign init_valid = s_frag || s_vert || s_comp;
    assign init_warp  = s_frag ? fl_slot : s_vert ? vl_slot : l_slot;
    wire [31:0] c_left = c_wgs - {l_k, 5'd0};
    wire [31:0] c_exec = (c_wgs <= {l_k, 5'd0}) ? 32'd0 :
                         (c_left >= 32) ? 32'hFFFF_FFFF : ((32'd1 << c_left[4:0]) - 32'd1);
    assign init_mask  = s_frag ? pf_mask : s_vert ? pv_mask : c_exec;

    // ---- barrier release
    reg [NWARPS-1:0] bar_rel;
    always @(*) begin
        for (i = 0; i < NWARPS; i = i + 1) begin
            bar_rel[i] = st[i] == BAR;
            for (j = 0; j < NWARPS; j = j + 1)
                if (wgm[i][j] && !(st[j] == BAR || st[j] == ENDED)) bar_rel[i] = 1'b0;
        end
    end

    // ---- fetch selection
    wire take   = f_valid && f_ready;
    wire can_sel = !f_valid || f_ready;
    reg  gv;
    reg  [WARP_W-1:0] gw, rr_last;
    wire sel_v;
    wire [WARP_W-1:0] sel_w;
    reg  [NWARPS*AGE_W-1:0] age_flat;
    always @(*) for (i = 0; i < NWARPS; i = i + 1) age_flat[AGE_W*i +: AGE_W] = age[i];
    ad_ctl_wsel #(.NWARPS(NWARPS), .WARP_W(WARP_W), .AGE_W(AGE_W), .GTO(GTO)) u_sel (
        .cand(cand), .gv(gv), .gw(gw), .age(age_flat), .last(rr_last), .sel_v(sel_v), .sel_w(sel_w));
    wire do_sel = can_sel && sel_v;
    wire gw_live = warp_ready[gw] && (st[gw] == FETCH || st[gw] == WAIT_FB || st[gw] == READY);
    wire [31:0] base_sel = (kind[sel_w] == 2'd0) ? s_vs : (kind[sel_w] == 2'd1) ? s_fs : s_cs;

    // ---- slot FSMs
    genvar g;
    generate for (g = 0; g < NWARPS; g = g + 1) begin : g_slot
        wire alloc = is_free[g] && ((g_frag || g_vert) ? ffree == g : g_comp && c_pick[g]);
        wire start = init_valid && init_warp == g;
        ad_ctl_slot u_slot (
            .clk(clk), .rst_n(rst_n), .alloc(alloc), .start(start),
            .sel(do_sel && sel_w == g), .take(take && f_warp == g),
            .fb(fb_valid && fb_warp == g), .fb_kind(fb_kind), .wake(wake[g]),
            .wc(wc_valid && wc_warp == g), .wc_op(wc_op), .wc_pc(wc_pc),
            .bar_rel(bar_rel[g]), .xr(xr_valid && xr_warp == g),
            .st(st[g]), .pc(pc[g]));
    end endgenerate

    // ---- registers
    always @(posedge clk) begin
        if (!rst_n) begin
            vl_gnt <= 1'b0; fl_gnt <= 1'b0; vl_slot <= 0; fl_slot <= 0;
            v_busy <= 1'b0; f_busy <= 1'b0; pv <= 1'b0; pf <= 1'b0;
            c_run <= 1'b0; c_kpend <= 1'b0; l_act <= 1'b0; l_rem <= 0; l_all <= 0; l_k <= 0;
            cx <= 0; cy <= 0; cz <= 0; gx <= 0; gy <= 0; gz <= 0; c_wgs <= 0; c_mod <= 0;
            f_valid <= 1'b0; f_warp <= 0; f_pc <= 0; f_addr <= 0;
            gv <= 1'b0; gw <= 0; rr_last <= {WARP_W{1'b1}};
            for (i = 0; i < NWARPS; i = i + 1) begin
                kind[i] <= 2'd0; gap[i] <= 0; age[i] <= 0; wgm[i] <= 0; info[i] <= 160'd0;
            end
        end else begin
            // grants
            vl_gnt <= g_vert;
            fl_gnt <= g_frag;
            if (g_vert) begin vl_slot <= ffree; v_busy <= 1'b1; end
            if (g_frag) begin fl_slot <= ffree; f_busy <= 1'b1; end
            if (vl_go && v_busy) begin pv <= 1'b1; pv_mask <= vl_mask; end
            if (fl_go && f_busy) begin pf <= 1'b1; pf_mask <= fl_mask; pf_info <= fl_info; end
            // starts
            if (s_frag) begin
                pf <= 1'b0; f_busy <= 1'b0;
                kind[fl_slot] <= 2'd1; wgm[fl_slot] <= {{(NWARPS-1){1'b0}}, 1'b1} << fl_slot;
                info[fl_slot] <= 160'd0;
                info[fl_slot][AD_WI_KIND +: 2] <= 2'd1;
                info[fl_slot][AD_WI_FRONT]     <= pf_info[48];
                info[fl_slot][AD_WI_SEQ +: 16] <= pf_info[47:32];
                info[fl_slot][AD_WI_MASK +: 32] <= pf_info[31:0];
            end
            if (s_vert) begin
                pv <= 1'b0; v_busy <= 1'b0;
                kind[vl_slot] <= 2'd0; wgm[vl_slot] <= {{(NWARPS-1){1'b0}}, 1'b1} << vl_slot;
                info[vl_slot] <= 160'd0;
                info[vl_slot][AD_WI_MASK +: 32] <= pv_mask;
            end
            if (s_comp) begin
                kind[l_slot] <= 2'd2; wgm[l_slot] <= l_all;
                info[l_slot] <= 160'd0;
                info[l_slot][AD_WI_WGX +: 16]      <= l_x;
                info[l_slot][AD_WI_WGX + 16 +: 16] <= l_y;
                info[l_slot][AD_WI_WGX + 32 +: 16] <= l_z;
                info[l_slot][AD_WI_NWGX +: 16]      <= gx;
                info[l_slot][AD_WI_NWGX + 16 +: 16] <= gy;
                info[l_slot][AD_WI_NWGX + 32 +: 16] <= gz;
                info[l_slot][AD_WI_LID +: 8]        <= {l_k[2:0], 5'd0};
                info[l_slot][AD_WI_KIND +: 2]       <= 2'd2;
                info[l_slot][AD_WI_MASK +: 32]      <= c_exec;
                l_rem <= l_rem & ~({{(NWARPS-1){1'b0}}, 1'b1} << l_slot);
                l_k   <= l_k + 1'b1;
                if ((l_rem & ~({{(NWARPS-1){1'b0}}, 1'b1} << l_slot)) == 0) l_act <= 1'b0;
            end
            // a freed slot leaves every workgroup mask
            for (i = 0; i < NWARPS; i = i + 1)
                if (xr_valid && st[xr_warp] == ENDED) wgm[i][xr_warp] <= 1'b0;
            // grid
            if (cs_kick) begin
                if (c_run) c_kpend <= 1'b1;
                else begin
                    c_run <= s_gx != 0 && s_gy != 0 && s_gz != 0;
                    gx <= s_gx[15:0]; gy <= s_gy[15:0]; gz <= s_gz[15:0]; c_wgs <= s_wgs;
                    cx <= 0; cy <= 0; cz <= 0; c_mod <= 0;
                end
            end
            if (g_comp) begin
                l_act <= 1'b1; l_rem <= c_pick; l_all <= c_pick; l_k <= 0;
                l_x <= cx; l_y <= cy; l_z <= cz;
            end
            if (c_step) begin
                c_mod <= (c_mod + 1'b1 == NSU) ? 0 : c_mod + 1'b1;
                if (c_lastid) begin
                    c_run <= (c_kpend || cs_kick) && s_gx != 0 && s_gy != 0 && s_gz != 0;
                    c_kpend <= 1'b0;
                    gx <= s_gx[15:0]; gy <= s_gy[15:0]; gz <= s_gz[15:0]; c_wgs <= s_wgs;
                    cx <= 0; cy <= 0; cz <= 0; c_mod <= 0;
                end else if (cx + 16'd1 != gx) cx <= cx + 16'd1;
                else begin
                    cx <= 0;
                    if (cy + 16'd1 != gy) cy <= cy + 16'd1;
                    else begin cy <= 0; cz <= cz + 16'd1; end
                end
            end
            // fetch
            if (can_sel) begin
                f_valid <= sel_v;
                if (sel_v) begin
                    f_warp <= sel_w; f_pc <= pc[sel_w];
                    f_addr <= base_sel + {13'd0, pc[sel_w], 3'b000};
                end
            end
            if (do_sel) begin
                rr_last <= sel_w;
                if (!gv || !gw_live || gw == sel_w) begin gv <= 1'b1; gw <= sel_w; end
            end
            for (i = 0; i < NWARPS; i = i + 1) begin
                if (take && f_warp == i) gap[i] <= G - 1;
                else if (gap[i] != 0) gap[i] <= gap[i] - 1'b1;
                if ((take && f_warp == i) || (init_valid && init_warp == i)) age[i] <= 0;
                else if (age[i] != {AGE_W{1'b1}}) age[i] <= age[i] + 1'b1;
            end
        end
    end


`ifdef AD_SCHED_FV
    // ---- formal properties (formal/ad_su_sched; enabled by AD_SCHED_FV only)
    reg fv_past = 1'b0;
    reg [3:0] fv_pst [0:NWARPS-1];
    reg [NWARPS-1:0] fv_parr;            // all members arrived (last cycle)
    reg [7:0] fv_since [0:NWARPS-1];     // cycles since the last take
    reg fv_pdo; reg [WARP_W-1:0] fv_pw; reg [NWARPS-1:0] fv_pwr;
    reg [NWARPS-1:0] fv_arr;
    always @(*) begin
        for (i = 0; i < NWARPS; i = i + 1) begin
            fv_arr[i] = 1'b1;
            for (j = 0; j < NWARPS; j = j + 1)
                if (wgm[i][j] && !(st[j] == BAR || st[j] == ENDED)) fv_arr[i] = 1'b0;
        end
    end
    always @(posedge clk) begin
        fv_past <= rst_n;
        fv_parr <= fv_arr;
        fv_pdo  <= do_sel; fv_pw <= sel_w; fv_pwr <= warp_ready;
        for (i = 0; i < NWARPS; i = i + 1) begin
            fv_pst[i] <= st[i];
            if (!rst_n) fv_since[i] <= 8'hFF;
            else if (take && f_warp == i) fv_since[i] <= 8'd1;
            else if (fv_since[i] != 8'hFF) fv_since[i] <= fv_since[i] + 1'b1;
        end
    end
    always @(*) if (rst_n) begin
        // a slot is granted only when FREE, one grant per cycle
        if (g_frag || g_vert) a_grant_free: assert (is_free[ffree]);
        a_one_grant: assert (!(g_frag && g_vert) && !((g_frag || g_vert) && g_comp));
        if (g_comp) a_comp_free: assert ((c_pick & ~is_free) == 0);
        // FRAG_RESERVE: a vertex grant leaves at least FRAG_RESERVE FREE slots
        if (g_vert) a_reserve: assert (nfree > FRAG_RESERVE);
        // the selector picks a candidate: READY, gap counted out, warp_ready
        if (do_sel) a_sel_cand: assert (cand[sel_w] && st[sel_w] == READY && warp_ready[sel_w]);
        // issue gap: two takes of one warp at least G cycles apart
        if (take) a_gap: assert (fv_since[f_warp] >= G);
        // f_* holds a warp in FETCH
        if (f_valid) a_fetch: assert (st[f_warp] == FETCH);
    end
    always @(posedge clk) if (fv_past && rst_n) begin
        for (i = 0; i < NWARPS; i = i + 1)
            if (fv_pst[i] == BAR && st[i] != BAR) assert (fv_parr[i]);   // a_bar
    end
`endif

    assign q_info = info[q_warp];

    reg any;
    always @(*) begin
        any = c_run || c_kpend || l_act || pv || pf || v_busy || f_busy;
        for (i = 0; i < NWARPS; i = i + 1) if (st[i] != FREE) any = 1'b1;
    end
    assign busy = any;
endmodule
