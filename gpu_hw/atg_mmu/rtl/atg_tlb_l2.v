// ============================================================================
// atg_tlb_l2 -- shared L2 TLB (set associative, 2-stage pipeline)
// ----------------------------------------------------------------------------
//   S0  pick one op: INS (walker result) > FLR (flush one VPN) > LKP (lookup)
//       read the set from RAM, write RAM for INS
//   S1  compare tags, answer the requesting L1 (or launch / retry a walk)
//
// Storage split:  valid + sid  in flops (single-cycle flush-all / by-session),
//                 vpn tag + pfn + attr in one 1R1W RAM per way (block RAM).
// Misses: one walk at a time.  A miss while the walker is busy answers
// "retry" and the L1 asks again later; this gives hit-under-miss and merges
// misses to the same page (the retry hits once the walk has installed).
// wbz stays set until the walker's INS has passed S1, so a page is never
// walked twice and the L2 never holds two entries for one {sid, vpn}.
// Faults are answered but never installed.
// ============================================================================
`include "atg_mmu_pkg.vh"
module atg_tlb_l2 #(
    parameter VPW = `AMU_VPW,
    parameter PFW = `AMU_PFW,
    parameter SIW = `AMU_SIW,
    parameter CIW = `AMU_CIW,
    parameter NST = `AMU_L2S,
    parameter SXW = `AMU_L2X,
    parameter NWY = `AMU_L2W,
    parameter TGW = `AMU_L2T,
    parameter ATW = `AMU_ATW,
    parameter FKW = `AMU_FKW,
    parameter SYW = `AMU_SYW
) (
    input  wire            clk,
    input  wire            rst_n,
    // ---- lookup from the arbiter
    input  wire            lrq_vld,
    output wire            lrq_rdy,
    input  wire [CIW-1:0]  lrq_cid,
    input  wire [SIW-1:0]  lrq_sid,
    input  wire [VPW-1:0]  lrq_vpn,
    // ---- answer to the L1s (cid selects the L1)
    output reg             lrs_vld,
    output reg  [CIW-1:0]  lrs_cid,
    output reg             lrs_rty,
    output reg             lrs_flt,
    output reg  [FKW-1:0]  lrs_fkd,
    output reg  [SYW-1:0]  lrs_syn,
    output reg  [PFW-1:0]  lrs_pfn,
    output reg  [ATW-1:0]  lrs_att,
    // ---- walker
    output reg             wrq_vld,     // one-cycle launch
    output reg  [SIW-1:0]  wrq_sid,
    output reg  [VPW-1:0]  wrq_vpn,
    input  wire            wrs_vld,     // one-cycle result, always accepted
    input  wire            wrs_flt,
    input  wire [FKW-1:0]  wrs_fkd,
    input  wire [SYW-1:0]  wrs_syn,
    input  wire [PFW-1:0]  wrs_pfn,
    input  wire [ATW-1:0]  wrs_att,
    // ---- flush (only while the L2 is idle: see atg_mmu flush sequencer)
    input  wire            flu_vld,
    input  wire            flu_all,
    input  wire            flu_rng,
    input  wire [SIW-1:0]  flu_sid,
    input  wire [VPW-1:0]  flu_vpn,
    output wire            idl
`ifdef FORMAL
   ,input  wire [SIW-1:0]  f_qsid,      // formal-only: "is this page cached?"
    input  wire [VPW-1:0]  f_qvpn,
    output reg             f_qhit,
    output wire [(1<<CIW)-1:0] f_pnd_o, // formal-only: clients with a miss inside
    output wire            f_wbz,       // formal-only: a walk (or its INS) is outstanding
    output wire            f_wot,       // formal-only: the walker owes a result
    output wire [CIW-1:0]  f_wci,       // formal-only: who the walk is for
    output wire            f_s1k,       // formal-only: a lookup is in S1 ...
    output wire [CIW-1:0]  f_s1c,       //              ... from this client
    output wire [SIW-1:0]  f_s1s,
    output wire [VPW-1:0]  f_s1v
`endif
);
    localparam RDW = TGW + PFW + ATW;               // RAM word: {tag, pfn, attr}
    localparam OLK = 2'd0, OIN = 2'd1, OFR = 2'd2;  // S0/S1 op codes

    // ------------------------------------------------------------ state
    reg [NWY-1:0] v_vld [0:NST-1];
    reg [NWY*SIW-1:0] v_sid [0:NST-1];            // sid of way w at [w*SIW +: SIW]
    reg [NWY-1:0] v_rr  [0:NST-1];                  // one-hot victim pointer per set
    reg           wbz;                              // a walk (or its INS) is outstanding
    reg [CIW-1:0] wcid;                             // who asked for the walk

    // ------------------------------------------------------------ S0
    wire s0_ins = wrs_vld;
    wire s0_flr = !s0_ins && flu_vld && flu_rng;
    wire s0_lkp = !s0_ins && !s0_flr && lrq_vld;
    assign lrq_rdy = !s0_ins && !s0_flr;

    wire [VPW-1:0] s0_vpn = s0_ins ? wrq_vpn : (s0_flr ? flu_vpn : lrq_vpn);
    wire [SXW-1:0] s0_idx = s0_vpn[SXW-1:0];

    // victim for INS: first invalid way, else round-robin
    reg [NWY-1:0] vic;
    reg           v_fnd;
    integer w, s, h;
    always @(*) begin
        vic   = {NWY{1'b0}};
        v_fnd = 1'b0;
        for (w = 0; w < NWY; w = w + 1)
            if (!v_vld[s0_idx][w] && !v_fnd) begin
                vic[w] = 1'b1;
                v_fnd  = 1'b1;
            end
        if (!v_fnd) vic = v_rr[s0_idx];
    end

    wire           ram_we = s0_ins && !wrs_flt;
    wire [RDW-1:0] ram_wd = {wrq_vpn[VPW-1:SXW], wrs_pfn, wrs_att};
    wire [RDW-1:0] ram_rd [0:NWY-1];
`ifdef FORMAL
    wire [NST*RDW-1:0] f_mem [0:NWY-1];
`endif

    genvar g;
    generate
        for (g = 0; g < NWY; g = g + 1) begin : g_way
            atg_mmu_ram #(.DW(RDW), .AW(SXW), .DEP(NST)) u_ram (
                .clk (clk),
                .we  (ram_we && vic[g]),
                .wa  (s0_idx),
                .wd  (ram_wd),
                .ra  (s0_idx),
                .rd  (ram_rd[g])
`ifdef FORMAL
               ,.f_mem(f_mem[g])
`endif
            );
        end
    endgenerate

    // ------------------------------------------------------------ S1 registers
    reg           s1_vld;
    reg [1:0]     s1_op;
    reg [CIW-1:0] s1_cid;
    reg [SIW-1:0] s1_sid;
    reg [VPW-1:0] s1_vpn;
    reg           s1_all;                           // FLR: ignore sid
    reg           s1_flt;                           // INS payload
    reg [FKW-1:0] s1_fkd;
    reg [SYW-1:0] s1_syn;
    reg [PFW-1:0] s1_pfn;
    reg [ATW-1:0] s1_att;

    assign idl = !s1_vld && !wbz;

    // ------------------------------------------------------------ S1 compare
    wire [SXW-1:0] s1_idx = s1_vpn[SXW-1:0];
    wire [TGW-1:0] s1_tag = s1_vpn[VPW-1:SXW];
    reg  [NWY-1:0] hv;
    reg  [PFW-1:0] h_pfn;
    reg  [ATW-1:0] h_att;
    always @(*) begin
        h_pfn = {PFW{1'b0}};
        h_att = {ATW{1'b0}};
        for (h = 0; h < NWY; h = h + 1) begin
            hv[h] = v_vld[s1_idx][h]
                 && (s1_all || v_sid[s1_idx][h*SIW +: SIW] == s1_sid)
                 && (ram_rd[h][RDW-1 -: TGW] == s1_tag);
            h_pfn = h_pfn | ({PFW{hv[h]}} & ram_rd[h][ATW +: PFW]);
            h_att = h_att | ({ATW{hv[h]}} & ram_rd[h][0 +: ATW]);
        end
    end
    wire hit = |hv;

    // ------------------------------------------------------------ outputs (S1, combinational)
    always @(*) begin
        lrs_vld = 1'b0; lrs_cid = s1_cid; lrs_rty = 1'b0; lrs_flt = 1'b0;
        lrs_fkd = `AMU_FKN; lrs_syn = {SYW{1'b0}}; lrs_pfn = {PFW{1'b0}}; lrs_att = {ATW{1'b0}};
        wrq_vld = 1'b0;
        if (s1_vld && s1_op == OLK) begin
            if (hit) begin
                lrs_vld = 1'b1;
                lrs_pfn = h_pfn;
                lrs_att = h_att;
            end else if (wbz) begin
                lrs_vld = 1'b1;
                lrs_rty = 1'b1;
            end else begin
                wrq_vld = 1'b1;
            end
        end
        if (s1_vld && s1_op == OIN) begin
            lrs_vld = 1'b1;
            lrs_cid = wcid;
            lrs_flt = s1_flt;
            lrs_fkd = s1_fkd;
            lrs_syn = s1_syn;
            lrs_pfn = s1_flt ? {PFW{1'b0}} : s1_pfn;
            lrs_att = s1_flt ? {ATW{1'b0}} : s1_att;
        end
    end

    // ------------------------------------------------------------ sequential
    integer wj, sj;
    always @(posedge clk) begin
        if (!rst_n) begin
            s1_vld  <= 1'b0;
            s1_op   <= OLK;
            wbz     <= 1'b0;
            wcid    <= {CIW{1'b0}};
            wrq_sid <= {SIW{1'b0}};
            wrq_vpn <= {VPW{1'b0}};
            for (sj = 0; sj < NST; sj = sj + 1) begin
                v_vld[sj] <= {NWY{1'b0}};
                v_rr[sj]  <= {{(NWY-1){1'b0}}, 1'b1};
            end
        end else begin
            // ---- S0 -> S1
            s1_vld <= s0_ins || s0_flr || s0_lkp;
            s1_op  <= s0_ins ? OIN : (s0_flr ? OFR : OLK);
            s1_cid <= lrq_cid;
            s1_sid <= s0_flr ? flu_sid : lrq_sid;
            s1_vpn <= s0_vpn;
            s1_all <= s0_flr && flu_all;
            s1_flt <= wrs_flt;
            s1_fkd <= wrs_fkd;
            s1_syn <= wrs_syn;
            s1_pfn <= wrs_pfn;
            s1_att <= wrs_att;

            // ---- INS: valid/sid flops (RAM written by the ram instance)
            if (ram_we) begin
                for (wj = 0; wj < NWY; wj = wj + 1)
                    if (vic[wj]) begin
                        v_vld[s0_idx][wj] <= 1'b1;
                        v_sid[s0_idx][wj*SIW +: SIW] <= wrq_sid;
                    end
                v_rr[s0_idx] <= {v_rr[s0_idx][NWY-2:0], v_rr[s0_idx][NWY-1]};
            end

            // ---- S1: launch a walk / retire the INS
            if (wrq_vld) begin
                wbz     <= 1'b1;
                wcid    <= s1_cid;
                wrq_sid <= s1_sid;
                wrq_vpn <= s1_vpn;
            end
            if (s1_vld && s1_op == OIN)
                wbz <= 1'b0;

            // ---- S1: flush one VPN
            if (s1_vld && s1_op == OFR)
                for (wj = 0; wj < NWY; wj = wj + 1)
                    if (hv[wj]) v_vld[s1_idx][wj] <= 1'b0;

            // ---- flush all / by session: valid flops only, one cycle
            if (flu_vld && !flu_rng)
                for (sj = 0; sj < NST; sj = sj + 1)
                    for (wj = 0; wj < NWY; wj = wj + 1)
                        if (flu_all || v_sid[sj][wj*SIW +: SIW] == flu_sid)
                            v_vld[sj][wj] <= 1'b0;
        end
    end

`ifdef FORMAL
    // Shadow of the tag RAMs, written exactly like them.  Used to state
    // invariants over the stored tags (the RAM array itself is not visible).
    reg f_pv = 1'b0;
    always @(posedge clk) f_pv <= 1'b1;
    integer fw, fs, fa, fb, fx, fy, fz, gs, gw;

    // {sid, vpn} of the walk in progress is present in the L2?
    reg f_wpr;
    always @(*) begin
        f_wpr = 1'b0;
        for (fy = 0; fy < NWY; fy = fy + 1)
            if (v_vld[wrq_vpn[SXW-1:0]][fy]
             && v_sid[wrq_vpn[SXW-1:0]][fy*SIW +: SIW] == wrq_sid
             && f_mem[fy][wrq_vpn[SXW-1:0]*RDW + RDW - TGW +: TGW] == wrq_vpn[VPW-1:SXW])
                f_wpr = 1'b1;
    end

    always @(*) begin
      fw = 0; fs = 0; fa = 0; fb = 0;
      if (f_pv && rst_n) begin
        assert (!(wrq_vld && wbz));                        // one walk at a time
        assert (!(lrs_vld && lrs_rty && lrs_flt));
        // the RAM returns what was written for every valid way
        if (s1_vld && s1_op != OIN)
            for (fw = 0; fw < NWY; fw = fw + 1)
                if (v_vld[s1_idx][fw])
                    assert (ram_rd[fw] == f_mem[fw][s1_idx*RDW +: RDW]);
        // the page being walked is not cached until its INS has been written
        if (wbz && !(s1_vld && s1_op == OIN))
            assert (!f_wpr);
        // no set holds two entries for one {sid, vpn}
        for (fs = 0; fs < NST; fs = fs + 1)
            for (fa = 0; fa < NWY; fa = fa + 1)
                for (fb = fa + 1; fb < NWY; fb = fb + 1)
                    assert (!(v_vld[fs][fa] && v_vld[fs][fb]
                           && v_sid[fs][fa*SIW +: SIW] == v_sid[fs][fb*SIW +: SIW]
                           && f_mem[fa][fs*RDW + RDW - TGW +: TGW] == f_mem[fb][fs*RDW + RDW - TGW +: TGW]));
        for (fs = 0; fs < NST; fs = fs + 1)
            assert (v_rr[fs] != 0 && (v_rr[fs] & (v_rr[fs] - 1)) == 0);
      end
    end
    // flush all / by session leaves no matching entry
    always @(posedge clk)
        for (gs = 0; gs < NST; gs = gs + 1)
            for (gw = 0; gw < NWY; gw = gw + 1)
                if (f_pv && rst_n && $past(rst_n) && $past(flu_vld) && !$past(flu_rng))
                    assert (!(v_vld[gs][gw] && ($past(flu_all) || v_sid[gs][gw*SIW +: SIW] == $past(flu_sid))));
    // ---- data integrity for one arbitrary {sid, vpn}
    (* anyconst *) reg [SIW-1:0] f_ssid;
    (* anyconst *) reg [VPW-1:0] f_svpn;
    reg           f_sv;
    reg [PFW-1:0] f_spfn;
    reg [ATW-1:0] f_satt;
    always @(posedge clk) begin
        if (!rst_n) f_sv <= 1'b0;
        else begin
            if (ram_we && wrq_sid == f_ssid && wrq_vpn == f_svpn) begin
                f_sv <= 1'b1; f_spfn <= wrs_pfn; f_satt <= wrs_att;
            end
            if (flu_vld && !flu_rng && (flu_all || flu_sid == f_ssid)) f_sv <= 1'b0;
            if (s1_vld && s1_op == OFR && (s1_all || s1_sid == f_ssid) && s1_vpn == f_svpn) f_sv <= 1'b0;
        end
    end
    integer fq;
    always @(*) begin
        f_qhit = 1'b0;
        for (fq = 0; fq < NWY; fq = fq + 1)
            if (v_vld[f_qvpn[SXW-1:0]][fq] && v_sid[f_qvpn[SXW-1:0]][fq*SIW +: SIW] == f_qsid
             && f_mem[fq][f_qvpn[SXW-1:0]*RDW + RDW - TGW +: TGW] == f_qvpn[VPW-1:SXW]) f_qhit = 1'b1;
    end
    integer fe;
    always @(*) begin
        fe = 0;
        for (fe = 0; fe < NWY; fe = fe + 1)
            if (f_pv && rst_n && v_vld[f_svpn[SXW-1:0]][fe]
             && v_sid[f_svpn[SXW-1:0]][fe*SIW +: SIW] == f_ssid
             && f_mem[fe][f_svpn[SXW-1:0]*RDW + RDW - TGW +: TGW] == f_svpn[VPW-1:SXW])
                assert (f_sv && f_mem[fe][f_svpn[SXW-1:0]*RDW +: RDW] == {f_svpn[VPW-1:SXW], f_spfn, f_satt});
        // what the L1 receives for that page is what the walker installed
        if (f_pv && rst_n && lrs_vld && !lrs_rty && !lrs_flt && s1_op == OLK && s1_sid == f_ssid && s1_vpn == f_svpn)
            assert (f_sv && lrs_pfn == f_spfn && lrs_att == f_satt);
        // a pending range flush (S1) has not yet removed the page; nothing else may be in S1 then
        if (f_pv && rst_n && s1_vld && s1_op == OFR) assert (!wbz);
    end

    // ---- the walker answers only a launched walk (environment standalone)
    reg f_wout;
    assign f_wot = f_wout;
    assign f_wci = wcid;
    assign f_s1k = s1_vld && s1_op == OLK;
    assign f_s1c = s1_cid;
    assign f_s1s = s1_sid;
    assign f_s1v = s1_vpn;
    always @(posedge clk)
        if (!rst_n) f_wout <= 1'b0;
        else if (wrq_vld) f_wout <= 1'b1;
        else if (wrs_vld) f_wout <= 1'b0;
    always @(*) if (f_pv && rst_n) begin
`ifdef AMU_FV2
        assume (!wrs_vld || f_wout);
`else
        assert (!wrs_vld || f_wout);
`endif
        if (f_wout) assert (wbz && !(s1_vld && s1_op == OIN));
        if (wbz && !f_wout) assert (s1_vld && s1_op == OIN);
    end
    // ---- one miss per client: an L1 asks again only after its answer
    localparam NCI = 1 << CIW;
    reg [NCI-1:0] f_pnd;
    assign f_pnd_o = f_pnd;
    assign f_wbz   = wbz;
    always @(posedge clk)
        if (!rst_n) f_pnd <= {NCI{1'b0}};
        else f_pnd <= (f_pnd | ((lrq_vld && lrq_rdy) ? ({{(NCI-1){1'b0}}, 1'b1} << lrq_cid) : {NCI{1'b0}}))
                            & ~(lrs_vld ? ({{(NCI-1){1'b0}}, 1'b1} << lrs_cid) : {NCI{1'b0}});
    always @(*) if (f_pv && rst_n) begin
`ifdef AMU_FV2
        assume (!lrq_vld || !f_pnd[lrq_cid]);
`else
        assert (!lrq_vld || !f_pnd[lrq_cid]);
`endif
        assert (!lrs_vld || f_pnd[lrs_cid]);                 // answers go to a waiting client
        if (s1_vld && s1_op == OLK) assert (f_pnd[s1_cid]);
        if (wbz) assert (f_pnd[wcid]);
        if (s1_vld && s1_op == OLK && wbz) assert (s1_cid != wcid);
    end
`endif
endmodule
