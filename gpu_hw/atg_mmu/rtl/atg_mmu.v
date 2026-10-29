// ============================================================================
// atg_mmu -- Amaterrace GPU MMU top (GHCI 1.0 sections 11.2 / 11.6)
// ----------------------------------------------------------------------------
//   NCL clients --> NCL x atg_tlb_l1 --> atg_mmu_arb --> atg_tlb_l2 --> atg_mmu_walker --> AXI read
//                                                                       (root table here)
//   atg_mmu_ifc : per-client, per-epoch in-flight occupancy (unmap drain)
//   atg_mmu_flt : first-fault capture for FAULT_INFO / FAULT_ADDR
//   flush sequencer: hold -> quiesce -> flush -> flip epoch -> release
//
// The MMU is a translation service: a client presents a GPU VA and gets back
// a PA (or a fault) and then issues the access itself, through the LLC.
// Contract with every client:
//   * on rsp_flt = 1 the access must be completed locally (read data 0,
//     write dropped) and never reach the interconnect;
//   * every successful translation is one transaction: when it completes
//     the client pulses cmp_vld with the rsp_epo it was given.
// Physical-address traffic (ring fetch, fences, page-table writes, display
// scan-out) does not pass through the MMU.
// ============================================================================
`include "atg_mmu_pkg.vh"
module atg_mmu #(
    parameter VAW = `AMU_VAW,
    parameter GVW = `AMU_GVW,
    parameter PAW = `AMU_PAW,
    parameter PGS = `AMU_PGS,
    parameter VPW = `AMU_VPW,
    parameter PFW = `AMU_PFW,
    parameter D0W = `AMU_D0W,
    parameter PTW = `AMU_PTW,
    parameter RTW = `AMU_RTW,
    parameter RAS = `AMU_RAS,
    parameter SIW = `AMU_SIW,
    parameter NSS = `AMU_NSS,
    parameter PRT = `AMU_PRT,
    parameter NCL = `AMU_NCL,
    parameter CIW = `AMU_CIW,
    parameter STW = `AMU_STW,
    parameter L1E = `AMU_L1E,
    parameter L2S = `AMU_L2S,
    parameter L2X = `AMU_L2X,
    parameter L2W = `AMU_L2W,
    parameter L2T = `AMU_L2T,
    parameter OSD = `AMU_OSD,
    parameter ATW = `AMU_ATW
) (
    input  wire                     clk,
    input  wire                     rst_n,
    // ---- client translation ports (client c at [c*W +: W])
    input  wire [NCL-1:0]           c_req_vld,
    output wire [NCL-1:0]           c_req_rdy,
    input  wire [NCL*GVW-1:0]       c_req_va,
    input  wire [NCL*`AMU_ACW-1:0]  c_req_acc,
    input  wire [NCL*SIW-1:0]       c_req_sid,
    input  wire [NCL*STW-1:0]       c_req_stg,
    output wire [NCL-1:0]           c_rsp_vld,
    output wire [NCL*PAW-1:0]       c_rsp_pa,
    output wire [NCL*ATW-1:0]       c_rsp_att,
    output wire [NCL-1:0]           c_rsp_flt,
    output wire [NCL-1:0]           c_rsp_epo,
    input  wire [NCL-1:0]           c_cmp_vld,
    input  wire [NCL-1:0]           c_cmp_epo,
    // ---- AXI4 read master for page-table walks (64-bit, single beat)
    output wire                     m_arvalid,
    input  wire                     m_arready,
    output wire [PAW-1:0]           m_araddr,
    output wire [7:0]               m_arlen,
    output wire [2:0]               m_arsize,
    output wire [1:0]               m_arburst,
    input  wire                     m_rvalid,
    output wire                     m_rready,
    input  wire [PTW-1:0]           m_rdata,
    input  wire [1:0]               m_rresp,
    // ---- CP private register port (MMU_REG_*)
    input  wire                     cfg_wen,
    input  wire [`AMU_RAW-1:0]      cfg_adr,
    input  wire [31:0]              cfg_wdt,
    output reg  [31:0]              cfg_rdt,
    output wire                     irq_flt
);
    localparam FKW = `AMU_FKW;
    localparam SYW = `AMU_SYW;

    // ------------------------------------------------------------ elaboration checks
    generate
        if (VPW != VAW - PGS || PFW != PAW - PGS || L2T != VPW - L2X ||
            (1 << L2X) != L2S || (1 << SIW) != NSS || RTW + RAS != `AMU_HPW ||
            RTW + VPW - D0W + 3 > PAW || D0W + 3 != PGS || NCL > (1 << CIW) ||
            PTW != 64 || L1E < 2 || L2W < 2 || OSD < 2) begin : g_bad_cfg
            initial begin
                $display("atg_mmu: inconsistent atg_mmu_pkg.vh configuration");
                $finish;
            end
        end
    endgenerate

    // ------------------------------------------------------------ registers
    reg [RTW-1:0] root_ptr [0:NSS-1];
    reg [NSS-1:0] root_ok;
    reg           epo;

    // flush request captured from the TLB_FLUSH write
    reg           f_all, f_rng;
    reg [SIW-1:0] f_sid;
    reg [VPW-1:0] f_vpn;

    // ------------------------------------------------------------ flush sequencer
    localparam [1:0] FS_IDL = 2'd0, FS_HLD = 2'd1, FS_FLU = 2'd2, FS_WT2 = 2'd3;
    reg  [1:0] fs;
    wire       hld = (fs != FS_IDL);
    wire       flu = (fs == FS_FLU);

    wire [NCL-1:0] l1_idl;
    wire           l2_idl, wk_idl, obz;
    wire           quiet = (&l1_idl) && l2_idl && wk_idl && !obz;
    wire           wr_flu = cfg_wen && cfg_adr == `AMU_RFL;
    wire           wr_fst = cfg_wen && cfg_adr == `AMU_RFS && cfg_wdt[`AMU_FVB];

    always @(posedge clk) begin
        if (!rst_n) begin
            fs    <= FS_IDL;
            epo   <= 1'b0;
            f_all <= 1'b0;
            f_rng <= 1'b0;
            f_sid <= {SIW{1'b0}};
            f_vpn <= {VPW{1'b0}};
        end else begin
            case (fs)
                FS_IDL: if (wr_flu) begin           // writes while busy are ignored
                    f_sid <= (PRT != 0) ? cfg_wdt[SIW-1:0] : {SIW{1'b0}};
                    f_all <= cfg_wdt[`AMU_FAB];
                    f_rng <= cfg_wdt[`AMU_FRB];
                    f_vpn <= cfg_wdt[PGS +: VPW];
                    fs    <= FS_HLD;
                end
                FS_HLD: if (quiet) fs <= FS_FLU;   // no L1 miss, no L2 op, no walk, old epoch drained
                FS_FLU: fs <= FS_WT2;               // flush pulse to every L1 and the L2
                FS_WT2: if (l2_idl) begin           // range flush needs the L2's second stage
                    epo <= ~epo;
                    fs  <= FS_IDL;
                end
            endcase
        end
    end

    // ------------------------------------------------------------ root table / register writes
    integer r;
    always @(posedge clk) begin
        if (!rst_n) begin
            root_ok <= {NSS{1'b0}};
            for (r = 0; r < NSS; r = r + 1) root_ptr[r] <= {RTW{1'b0}};
        end else if (cfg_wen && cfg_adr[`AMU_RAW-1:SIW] == {(`AMU_RAW-SIW){1'b0}}) begin
            root_ptr[cfg_adr[SIW-1:0]] <= cfg_wdt[RAS +: RTW];
            root_ok [cfg_adr[SIW-1:0]] <= cfg_wdt[0];
        end
    end

`ifdef FORMAL
    (* anyconst *) reg [SIW-1:0] f_ssid;          // the symbolic page used by the
    (* anyconst *) reg [VPW-1:0] f_svpn;          // stale-translation property
    wire [NCL-1:0] f_l1hit;
    wire           f_l2hit;
    wire [NCL-1:0] f_snt;
    wire [(1<<CIW)-1:0] f_l2pnd;
    wire           f_l2wbz, f_l2wot, f_l2s1k;
    wire [CIW-1:0] f_l2wci, f_l2s1c;
    wire [SIW-1:0] f_l2s1s;
    wire [VPW-1:0] f_l2s1v;
`endif
    // ------------------------------------------------------------ L1s
    wire [NCL-1:0]     ifc_ful, ifc_nzr;
    wire [NCL-1:0]     mrq_vld, mrq_rdy;
    wire [NCL*SIW-1:0] mrq_sid;
    wire [NCL*VPW-1:0] mrq_vpn;
    wire               lrs_vld, lrs_rty, lrs_flt;
    wire [CIW-1:0]     lrs_cid;
    wire [FKW-1:0]     lrs_fkd;
    wire [SYW-1:0]     lrs_syn;
    wire [PFW-1:0]     lrs_pfn;
    wire [ATW-1:0]     lrs_att;
    wire [NCL*FKW-1:0] r_fkd;
    wire [NCL*SYW-1:0] r_syn;
    wire [NCL*GVW-1:0] r_va;
    wire [NCL*SIW-1:0] r_sid;
    wire [NCL*STW-1:0] r_stg;

    genvar c;
    generate
        for (c = 0; c < NCL; c = c + 1) begin : g_l1
            wire [SIW-1:0] sid_in = (PRT != 0) ? c_req_sid[c*SIW +: SIW] : {SIW{1'b0}};
            atg_tlb_l1 #(
                .VAW(VAW), .GVW(GVW), .PAW(PAW), .PGS(PGS), .VPW(VPW), .PFW(PFW),
                .SIW(SIW), .STW(STW), .NEN(L1E), .ATW(ATW), .FKW(FKW), .SYW(SYW)
            ) u_l1 (
                .clk     (clk),
                .rst_n   (rst_n),
                .req_vld (c_req_vld[c]),
                .req_rdy (c_req_rdy[c]),
                .req_va  (c_req_va [c*GVW +: GVW]),
                .req_acc (c_req_acc[c*`AMU_ACW +: `AMU_ACW]),
                .req_sid (sid_in),
                .req_stg (c_req_stg[c*STW +: STW]),
                .rsp_vld (c_rsp_vld[c]),
                .rsp_pa  (c_rsp_pa [c*PAW +: PAW]),
                .rsp_att (c_rsp_att[c*ATW +: ATW]),
                .rsp_flt (c_rsp_flt[c]),
                .rsp_fkd (r_fkd[c*FKW +: FKW]),
                .rsp_syn (r_syn[c*SYW +: SYW]),
                .rsp_va  (r_va [c*GVW +: GVW]),
                .rsp_sid (r_sid[c*SIW +: SIW]),
                .rsp_stg (r_stg[c*STW +: STW]),
                .hld     (hld),
                .ful     (ifc_ful[c]),
                .idl     (l1_idl[c]),
                .flu_vld (flu),
                .flu_all (f_all),
                .flu_rng (f_rng),
                .flu_sid (f_sid),
                .flu_vpn (f_vpn),
                .mrq_vld (mrq_vld[c]),
                .mrq_rdy (mrq_rdy[c]),
                .mrq_sid (mrq_sid[c*SIW +: SIW]),
                .mrq_vpn (mrq_vpn[c*VPW +: VPW]),
                .mrs_vld (lrs_vld && lrs_cid == c),
                .mrs_rty (lrs_rty),
                .mrs_flt (lrs_flt),
                .mrs_fkd (lrs_fkd),
                .mrs_syn (lrs_syn),
                .mrs_pfn (lrs_pfn),
                .mrs_att (lrs_att)
`ifdef FORMAL
               ,.f_qsid  (f_ssid),
                .f_qvpn  (f_svpn),
                .f_qhit  (f_l1hit[c]),
                .f_snt   (f_snt[c])
`endif
            );
            assign c_rsp_epo[c] = epo;
        end
    endgenerate

    // ------------------------------------------------------------ arbiter + request mux
    wire [NCL-1:0] gnt;
    wire           lrq_rdy;
    atg_mmu_arb #(.N(NCL)) u_arb (
        .clk(clk), .rst_n(rst_n), .req(mrq_vld), .rdy(lrq_rdy), .gnt(gnt)
    );
    assign mrq_rdy = gnt & {NCL{lrq_rdy}};

    reg [CIW-1:0] a_cid;
    reg [SIW-1:0] a_sid;
    reg [VPW-1:0] a_vpn;
    integer k;
    always @(*) begin
        a_cid = {CIW{1'b0}};
        a_sid = {SIW{1'b0}};
        a_vpn = {VPW{1'b0}};
        for (k = 0; k < NCL; k = k + 1)
            if (gnt[k]) begin
                a_cid = k;
                a_sid = mrq_sid[k*SIW +: SIW];
                a_vpn = mrq_vpn[k*VPW +: VPW];
            end
    end

    // ------------------------------------------------------------ L2
    wire           wrq_vld;
    wire [SIW-1:0] wrq_sid;
    wire [VPW-1:0] wrq_vpn;
    wire           wrs_vld, wrs_flt;
    wire [FKW-1:0] wrs_fkd;
    wire [SYW-1:0] wrs_syn;
    wire [PFW-1:0] wrs_pfn;
    wire [ATW-1:0] wrs_att;

    atg_tlb_l2 #(
        .VPW(VPW), .PFW(PFW), .SIW(SIW), .CIW(CIW), .NST(L2S), .SXW(L2X),
        .NWY(L2W), .TGW(L2T), .ATW(ATW), .FKW(FKW), .SYW(SYW)
    ) u_l2 (
        .clk(clk), .rst_n(rst_n),
        .lrq_vld(|gnt), .lrq_rdy(lrq_rdy), .lrq_cid(a_cid), .lrq_sid(a_sid), .lrq_vpn(a_vpn),
        .lrs_vld(lrs_vld), .lrs_cid(lrs_cid), .lrs_rty(lrs_rty), .lrs_flt(lrs_flt),
        .lrs_fkd(lrs_fkd), .lrs_syn(lrs_syn), .lrs_pfn(lrs_pfn), .lrs_att(lrs_att),
        .wrq_vld(wrq_vld), .wrq_sid(wrq_sid), .wrq_vpn(wrq_vpn),
        .wrs_vld(wrs_vld), .wrs_flt(wrs_flt), .wrs_fkd(wrs_fkd), .wrs_syn(wrs_syn),
        .wrs_pfn(wrs_pfn), .wrs_att(wrs_att),
        .flu_vld(flu), .flu_all(f_all), .flu_rng(f_rng), .flu_sid(f_sid), .flu_vpn(f_vpn),
        .idl(l2_idl)
`ifdef FORMAL
       ,.f_qsid(f_ssid), .f_qvpn(f_svpn), .f_qhit(f_l2hit), .f_pnd_o(f_l2pnd), .f_wbz(f_l2wbz), .f_wot(f_l2wot),
        .f_wci(f_l2wci), .f_s1k(f_l2s1k), .f_s1c(f_l2s1c), .f_s1s(f_l2s1s), .f_s1v(f_l2s1v)
`endif
    );

    // ------------------------------------------------------------ walker
    wire [SIW-1:0] rot_sid;
    atg_mmu_walker #(
        .PAW(PAW), .PTW(PTW), .PGS(PGS), .VPW(VPW), .PFW(PFW), .D0W(D0W), .RTW(RTW),
        .SIW(SIW), .ATW(ATW), .FKW(FKW), .SYW(SYW)
    ) u_wk (
        .clk(clk), .rst_n(rst_n),
        .wrq_vld(wrq_vld), .wrq_sid(wrq_sid), .wrq_vpn(wrq_vpn), .idl(wk_idl),
        .rot_sid(rot_sid), .rot_ptr(root_ptr[rot_sid]), .rot_ok(root_ok[rot_sid]),
        .ar_vld(m_arvalid), .ar_rdy(m_arready), .ar_adr(m_araddr),
        .r_vld(m_rvalid), .r_rdy(m_rready), .r_dat(m_rdata), .r_rsp(m_rresp),
        .wrs_vld(wrs_vld), .wrs_flt(wrs_flt), .wrs_fkd(wrs_fkd), .wrs_syn(wrs_syn),
        .wrs_pfn(wrs_pfn), .wrs_att(wrs_att)
    );
    assign m_arlen   = 8'd0;          // one beat
    assign m_arsize  = 3'd3;          // 8 bytes
    assign m_arburst = 2'b01;         // INCR

    // ------------------------------------------------------------ in-flight tracker
`ifdef FORMAL
    wire [NCL-1:0] f_ifull;
`endif
    atg_mmu_ifc #(.NCL(NCL), .OSD(OSD)) u_ifc (
        .clk(clk), .rst_n(rst_n), .epo(epo),
        .inc(c_rsp_vld & ~c_rsp_flt), .cmp(c_cmp_vld), .cmp_epo(c_cmp_epo),
        .ful(ifc_ful), .nzr(ifc_nzr), .obz(obz)
`ifdef FORMAL
       ,.f_top(f_ifull)
`endif
    );

    // ------------------------------------------------------------ fault capture
    wire           fl_vld, fl_ovf;
    wire [FKW-1:0] fl_knd;
    wire [3:0]     fl_unt;
    wire [SIW-1:0] fl_sid;
    wire [STW-1:0] fl_stg;
    wire [SYW-1:0] fl_syn;
    wire [GVW-1:0] fl_va;
    atg_mmu_flt #(.NCL(NCL), .GVW(GVW), .SIW(SIW), .STW(STW), .FKW(FKW), .SYW(SYW)) u_flt (
        .clk(clk), .rst_n(rst_n),
        .f_vld(c_rsp_vld & c_rsp_flt), .f_knd(r_fkd), .f_syn(r_syn), .f_sid(r_sid),
        .f_stg(r_stg), .f_va(r_va), .clr(wr_fst),
        .vld(fl_vld), .ovf(fl_ovf), .knd(fl_knd), .unt(fl_unt), .sid(fl_sid),
        .stg(fl_stg), .syn(fl_syn), .va(fl_va)
    );
    assign irq_flt = fl_vld;

    // ------------------------------------------------------------ register read
    always @(*) begin
        cfg_rdt = 32'h0;
        if (cfg_adr[`AMU_RAW-1:SIW] == {(`AMU_RAW-SIW){1'b0}}) begin
            cfg_rdt[RAS +: RTW] = root_ptr[cfg_adr[SIW-1:0]];
            cfg_rdt[0]          = root_ok [cfg_adr[SIW-1:0]];
        end else case (cfg_adr)
            `AMU_RFL: begin
                cfg_rdt[SIW-1:0]    = f_sid;
                cfg_rdt[`AMU_FAB]   = f_all;
                cfg_rdt[`AMU_FRB]   = f_rng;
                cfg_rdt[PGS +: VPW] = f_vpn;
            end
            `AMU_RST: begin
                cfg_rdt[0]          = hld;        // flush sequence running
                cfg_rdt[1]          = obz;        // previous epoch still draining
                cfg_rdt[2]          = !wk_idl;
                cfg_rdt[3]          = !l2_idl;
                cfg_rdt[4]          = epo;
                cfg_rdt[8 +: NCL]   = ifc_nzr;    // per-client: something in flight
            end
            `AMU_RFS: begin
                cfg_rdt[FKW-1:0]    = fl_knd;
                cfg_rdt[7:4]        = fl_unt;
                cfg_rdt[8 +: SIW]   = fl_sid;
                cfg_rdt[12 +: STW]  = fl_stg;
                cfg_rdt[`AMU_FOB]   = fl_ovf;
                cfg_rdt[`AMU_FVB]   = fl_vld;
                cfg_rdt[16 +: SYW]  = fl_syn;
            end
            `AMU_RFA: cfg_rdt = fl_va[31:0];
            `AMU_RFH: cfg_rdt = fl_va[GVW-1:32];
            default:  cfg_rdt = 32'h0;
        endcase
    end

`ifdef FORMAL
    reg f_pv = 1'b0;
    always @(posedge clk) f_pv <= 1'b1;

    // flush happens only on a quiet machine, and stays quiet until the epoch flips
    always @(*) if (f_pv && rst_n && fs != FS_IDL && fs != FS_HLD) begin
        assert (&l1_idl);
        assert (wk_idl);
        assert (!wrq_vld);
    end

    // the L2's view of who has a miss inside matches the L1s', and its view
    // of the walk matches the walker's
    always @(*) if (f_pv && rst_n) begin
        assert (f_l2pnd == f_snt);
        assert (wk_idl == !f_l2wot);
    end
    // the walk / the S1 lookup is for exactly the page its client is missing
    integer fm;
    always @(*)
        for (fm = 0; fm < NCL; fm = fm + 1)
            if (f_pv && rst_n) begin
                if (f_l2wbz && f_l2wci == fm)
                    assert (mrq_sid[fm*SIW +: SIW] == wrq_sid && mrq_vpn[fm*VPW +: VPW] == wrq_vpn);
                if (f_l2s1k && f_l2s1c == fm)
                    assert (mrq_sid[fm*SIW +: SIW] == f_l2s1s && mrq_vpn[fm*VPW +: VPW] == f_l2s1v);
            end

    // a client with a request in progress always has a free in-flight slot
    integer fk;
    always @(*)
        for (fk = 0; fk < NCL; fk = fk + 1)
            if (f_pv && rst_n && !l1_idl[fk]) assert (!f_ifull[fk]);

    // ---- no stale translation after a flush --------------------------------
    // Pick any {session, vpn}.  Once a flush covering it has executed, no
    // client may receive a successful translation for it until the walker
    // has re-read its page table entry.
    reg f_stl;
    wire f_fmatch = (f_all || f_sid == f_ssid) && (!f_rng || f_vpn == f_svpn);
    always @(posedge clk) begin
        if (!rst_n)
            f_stl <= 1'b0;
        else if (flu && f_fmatch)
            f_stl <= 1'b1;
        else if (wrs_vld && wrq_sid == f_ssid && wrq_vpn == f_svpn)
            f_stl <= 1'b0;
    end
    // invariant behind it: while stale, no TLB level holds the page
    // (the L2 may still hold it in the one cycle a one-VPN flush is in S1)
    always @(*) if (f_pv && rst_n && f_stl) begin
        assert (f_l1hit == {NCL{1'b0}});
        assert (!f_l2hit || fs == FS_WT2);
        // a finished walk for the page clears f_stl, so its INS is never still in flight
        assert (!(f_l2wbz && !f_l2wot && wrq_sid == f_ssid && wrq_vpn == f_svpn));
    end
    integer fc;
    always @(*)
        for (fc = 0; fc < NCL; fc = fc + 1)
            if (f_pv && rst_n && c_rsp_vld[fc] && !c_rsp_flt[fc]
             && r_sid[fc*SIW +: SIW] == f_ssid
             && r_va[fc*GVW + PGS +: VPW] == f_svpn)
                assert (!f_stl);
`endif
endmodule
