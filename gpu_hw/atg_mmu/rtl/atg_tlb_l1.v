// ============================================================================
// atg_tlb_l1 -- per-client L1 TLB (fully associative, 1-cycle hit)
// ----------------------------------------------------------------------------
// Request accepted in cycle t  ->  response registered in cycle t+1 on a hit
// (or on a VA-range fault).  On a miss the request parks (pnd) and a refill
// is requested from the shared L2 through the arbiter; the client is stalled
// (req_rdy = 0) until the refill answers.  One request in flight at a time.
//
//   tag  = {sid, vpn}       data = {pfn, attr}
//   * permission check (R/W/X) is done here, on hits and on refills
//   * fault responses carry flt = 1 and pa = 0: the client must complete the
//     access locally and never issue it to the bus
//   * faults are never cached (no negative entries)
//   * replacement: first invalid entry, else round-robin (one-hot rotate)
//   * flush: all / by session / by {session, vpn}; single cycle
// ============================================================================
`include "atg_mmu_pkg.vh"
module atg_tlb_l1 #(
    parameter VAW = `AMU_VAW,
    parameter GVW = `AMU_GVW,
    parameter PAW = `AMU_PAW,
    parameter PGS = `AMU_PGS,
    parameter VPW = `AMU_VPW,
    parameter PFW = `AMU_PFW,
    parameter SIW = `AMU_SIW,
    parameter STW = `AMU_STW,
    parameter NEN = `AMU_L1E,
    parameter ATW = `AMU_ATW,
    parameter FKW = `AMU_FKW,
    parameter SYW = `AMU_SYW
) (
    input  wire                clk,
    input  wire                rst_n,
    // ---- client request
    input  wire                req_vld,
    output wire                req_rdy,
    input  wire [GVW-1:0]      req_va,
    input  wire [`AMU_ACW-1:0] req_acc,
    input  wire [SIW-1:0]      req_sid,
    input  wire [STW-1:0]      req_stg,
    // ---- client response (no back-pressure)
    output reg                 rsp_vld,
    output wire [PAW-1:0]      rsp_pa,
    output reg  [ATW-1:0]      rsp_att,
    output reg                 rsp_flt,
    output reg  [FKW-1:0]      rsp_fkd,
    output reg  [SYW-1:0]      rsp_syn,
    output wire [GVW-1:0]      rsp_va,     // request echo (fault capture)
    output wire [SIW-1:0]      rsp_sid,
    output wire [STW-1:0]      rsp_stg,
    // ---- control
    input  wire                hld,        // flush sequencer: accept nothing new
    input  wire                ful,        // in-flight tracker full for this client
    output wire                idl,        // nothing pending, nothing being answered
    input  wire                flu_vld,
    input  wire                flu_all,
    input  wire                flu_rng,
    input  wire [SIW-1:0]      flu_sid,
    input  wire [VPW-1:0]      flu_vpn,
    // ---- miss request to L2 (valid held until rdy)
    output wire                mrq_vld,
    input  wire                mrq_rdy,
    output wire [SIW-1:0]      mrq_sid,
    output wire [VPW-1:0]      mrq_vpn,
    // ---- L2 answer for this client
    input  wire                mrs_vld,
    input  wire                mrs_rty,    // L2 busy with another walk: ask again
    input  wire                mrs_flt,
    input  wire [FKW-1:0]      mrs_fkd,
    input  wire [SYW-1:0]      mrs_syn,
    input  wire [PFW-1:0]      mrs_pfn,
    input  wire [ATW-1:0]      mrs_att
`ifdef FORMAL
   ,input  wire [SIW-1:0]      f_qsid,     // formal-only: "is this page cached?"
    input  wire [VPW-1:0]      f_qvpn,
    output reg                 f_qhit,
    output wire                f_snt       // formal-only: miss is inside the L2
`endif
);
    // ------------------------------------------------------------ storage
    reg [NEN-1:0] e_vld;
    reg [SIW-1:0] e_sid [0:NEN-1];
    reg [VPW-1:0] e_vpn [0:NEN-1];
    reg [PFW-1:0] e_pfn [0:NEN-1];
    reg [ATW-1:0] e_att [0:NEN-1];
    reg [NEN-1:0] rr;                       // one-hot round-robin victim pointer

    // ------------------------------------------------------------ request state
    reg [GVW-1:0]      q_va;
    reg [`AMU_ACW-1:0] q_acc;
    reg [SIW-1:0]      q_sid;
    reg [STW-1:0]      q_stg;
    reg                pnd;                 // miss parked, waiting for L2
    reg                snt;                 // miss request accepted by L2
    reg [PFW-1:0]      r_pfn;

    assign req_rdy = !pnd && !hld && !ful;
    wire   acc     = req_vld && req_rdy;
    assign idl     = !pnd && !rsp_vld;

    assign rsp_va  = q_va;
    assign rsp_sid = q_sid;
    assign rsp_stg = q_stg;
    assign rsp_pa  = rsp_flt ? {PAW{1'b0}} : {r_pfn, q_va[PGS-1:0]};

    assign mrq_vld = pnd && !snt;
    assign mrq_sid = q_sid;
    assign mrq_vpn = q_va[VAW-1:PGS];

    // ------------------------------------------------------------ lookup (cycle t)
    wire [VPW-1:0] l_vpn = req_va[VAW-1:PGS];
    wire           l_oor = |req_va[GVW-1:VAW];
    reg  [NEN-1:0] l_hv;
    reg  [PFW-1:0] l_pfn;
    reg  [ATW-1:0] l_att;
    integer i;
    always @(*) begin
        l_pfn = {PFW{1'b0}};
        l_att = {ATW{1'b0}};
        for (i = 0; i < NEN; i = i + 1) begin
            l_hv[i] = e_vld[i] && (e_sid[i] == req_sid) && (e_vpn[i] == l_vpn);
            l_pfn   = l_pfn | ({PFW{l_hv[i]}} & e_pfn[i]);   // one-hot: OR-mux
            l_att   = l_att | ({ATW{l_hv[i]}} & e_att[i]);
        end
    end
    wire l_hit = |l_hv;

    // permission check
    function prm_ok;
        input [`AMU_ACW-1:0] a;
        input [ATW-1:0]      t;
        begin
            case (a)
                `AMU_AKW: prm_ok = t[`AMU_AWR];
                `AMU_AKX: prm_ok = t[`AMU_AEX];
                default:  prm_ok = t[`AMU_ARD];
            endcase
        end
    endfunction

    // access-kind syndrome bits
    function [SYW-1:0] acc_syn;
        input [`AMU_ACW-1:0] a;
        begin
            acc_syn = {SYW{1'b0}};
            acc_syn[`AMU_SWR] = (a == `AMU_AKW);
            acc_syn[`AMU_SEX] = (a == `AMU_AKX);
        end
    endfunction

    // ------------------------------------------------------------ victim select
    integer m;
    reg [NEN-1:0] vic;
    reg           v_fnd;
    always @(*) begin
        vic   = {NEN{1'b0}};
        v_fnd = 1'b0;
        for (m = 0; m < NEN; m = m + 1)
            if (!e_vld[m] && !v_fnd) begin
                vic[m] = 1'b1;
                v_fnd  = 1'b1;
            end
        if (!v_fnd) vic = rr;
    end

    wire fin = mrs_vld && !mrs_rty;          // refill finished
    wire ins = fin && !mrs_flt;              // install the translation

    // ------------------------------------------------------------ sequential
    integer j;
    always @(posedge clk) begin
        if (!rst_n) begin
            pnd     <= 1'b0;
            snt     <= 1'b0;
            rsp_vld <= 1'b0;
            rsp_flt <= 1'b0;
            rsp_fkd <= `AMU_FKN;
            rsp_syn <= {SYW{1'b0}};
            rsp_att <= {ATW{1'b0}};
            r_pfn   <= {PFW{1'b0}};
            q_va    <= {GVW{1'b0}};
            q_acc   <= `AMU_AKR;
            q_sid   <= {SIW{1'b0}};
            q_stg   <= {STW{1'b0}};
            e_vld   <= {NEN{1'b0}};
            rr      <= {{(NEN-1){1'b0}}, 1'b1};
        end else begin
            rsp_vld <= 1'b0;

            // -------- new request
            if (acc) begin
                q_va  <= req_va;
                q_acc <= req_acc;
                q_sid <= req_sid;
                q_stg <= req_stg;
                if (l_oor) begin
                    rsp_vld <= 1'b1;
                    rsp_flt <= 1'b1;
                    rsp_fkd <= `AMU_FKP;
                    rsp_syn <= acc_syn(req_acc) | ({{(SYW-1){1'b0}}, 1'b1} << `AMU_SOR);
                    rsp_att <= {ATW{1'b0}};
                    r_pfn   <= {PFW{1'b0}};
                end else if (l_hit) begin
                    rsp_vld <= 1'b1;
                    rsp_att <= l_att;
                    r_pfn   <= l_pfn;
                    if (prm_ok(req_acc, l_att)) begin
                        rsp_flt <= 1'b0;
                        rsp_fkd <= `AMU_FKN;
                        rsp_syn <= {SYW{1'b0}};
                    end else begin
                        rsp_flt <= 1'b1;
                        rsp_fkd <= `AMU_FKM;
                        rsp_syn <= acc_syn(req_acc) | ({{(SYW-1){1'b0}}, 1'b1} << `AMU_SPM);
                    end
                end else begin
                    pnd <= 1'b1;
                    snt <= 1'b0;
                end
            end

            // -------- miss request handshake
            if (mrq_vld && mrq_rdy)
                snt <= 1'b1;

            // -------- L2 answer
            if (mrs_vld && mrs_rty)
                snt <= 1'b0;                 // re-arbitrate
            if (fin) begin
                pnd     <= 1'b0;
                snt     <= 1'b0;
                rsp_vld <= 1'b1;
                rsp_att <= mrs_flt ? {ATW{1'b0}} : mrs_att;
                r_pfn   <= mrs_flt ? {PFW{1'b0}} : mrs_pfn;
                if (mrs_flt) begin
                    rsp_flt <= 1'b1;
                    rsp_fkd <= mrs_fkd;
                    rsp_syn <= mrs_syn | acc_syn(q_acc);
                end else if (prm_ok(q_acc, mrs_att)) begin
                    rsp_flt <= 1'b0;
                    rsp_fkd <= `AMU_FKN;
                    rsp_syn <= {SYW{1'b0}};
                end else begin
                    rsp_flt <= 1'b1;
                    rsp_fkd <= `AMU_FKM;
                    rsp_syn <= acc_syn(q_acc) | ({{(SYW-1){1'b0}}, 1'b1} << `AMU_SPM);
                end
            end

            // -------- install
            if (ins) begin
                for (j = 0; j < NEN; j = j + 1)
                    if (vic[j]) begin
                        e_vld[j] <= 1'b1;
                        e_sid[j] <= q_sid;
                        e_vpn[j] <= q_va[VAW-1:PGS];
                        e_pfn[j] <= mrs_pfn;
                        e_att[j] <= mrs_att;
                    end
                rr <= {rr[NEN-2:0], rr[NEN-1]};
            end

            // -------- flush (last: wins over a same-cycle install)
            if (flu_vld)
                for (j = 0; j < NEN; j = j + 1)
                    if (flu_all ? (!flu_rng || e_vpn[j] == flu_vpn)
                                : (e_sid[j] == flu_sid && (!flu_rng || e_vpn[j] == flu_vpn)))
                        e_vld[j] <= 1'b0;
        end
    end

`ifdef FORMAL
    reg f_pv = 1'b0;
    always @(posedge clk) f_pv <= 1'b1;
    integer fa, fb, fc;
    always @(*) begin
        fa = 0; fb = 0;
        if (f_pv && rst_n) begin
        assert (!(pnd && rsp_vld));                        // a parked miss has not answered yet
        assert (!snt || pnd);
        assert (!rsp_flt || rsp_pa == {PAW{1'b0}});        // a fault never carries an address
        assert (rr != 0 && (rr & (rr - 1)) == 0);
        for (fa = 0; fa < NEN; fa = fa + 1)                // no duplicate {sid, vpn}
            for (fb = fa + 1; fb < NEN; fb = fb + 1)
                assert (!(e_vld[fa] && e_vld[fb] && e_sid[fa] == e_sid[fb] && e_vpn[fa] == e_vpn[fb]));
        end
    end
    // a flush leaves no matching entry behind
    always @(posedge clk)
        for (fc = 0; fc < NEN; fc = fc + 1)
            if (f_pv && rst_n && $past(rst_n) && $past(flu_vld))
                assert (!(e_vld[fc]
                       && ($past(flu_all) || e_sid[fc] == $past(flu_sid))
                       && (!$past(flu_rng) || e_vpn[fc] == $past(flu_vpn))));
    // ---- the L2 answers only a miss it has accepted (environment standalone,
    //      checked inside atg_mmu, where it proves the cid routing)
    always @(*) if (f_pv && rst_n)
`ifdef AMU_FV1
        assume (!mrs_vld || snt);
`else
        assert (!mrs_vld || snt);
`endif

    // ---- data integrity for one arbitrary {sid, vpn}: whatever was last
    //      installed for it is what every entry holds and every hit returns
    (* anyconst *) reg [SIW-1:0] f_ssid;
    (* anyconst *) reg [VPW-1:0] f_svpn;
    reg           f_sv;
    reg [PFW-1:0] f_spfn;
    reg [ATW-1:0] f_satt;
    wire f_qsym = (q_sid == f_ssid) && (q_va[VAW-1:PGS] == f_svpn);
    always @(posedge clk) begin
        if (!rst_n) f_sv <= 1'b0;
        else begin
            if (ins && f_qsym) begin
                f_sv <= 1'b1; f_spfn <= mrs_pfn; f_satt <= mrs_att;
            end
            if (flu_vld && (flu_all || flu_sid == f_ssid) && (!flu_rng || flu_vpn == f_svpn))
                f_sv <= 1'b0;
        end
    end
    assign f_snt = snt;
    integer fq;
    always @(*) begin
        f_qhit = 1'b0;
        for (fq = 0; fq < NEN; fq = fq + 1)
            if (e_vld[fq] && e_sid[fq] == f_qsid && e_vpn[fq] == f_qvpn) f_qhit = 1'b1;
    end
    integer fd;
    always @(*) begin
        fd = 0;
        for (fd = 0; fd < NEN; fd = fd + 1)
            if (f_pv && rst_n && e_vld[fd] && e_sid[fd] == f_ssid && e_vpn[fd] == f_svpn)
                assert (f_sv && e_pfn[fd] == f_spfn && e_att[fd] == f_satt);
        if (f_pv && rst_n && rsp_vld && !rsp_flt && f_qsym)
            assert (f_sv && r_pfn == f_spfn && rsp_att == f_satt);
        // syndrome access bits always describe the faulting access
        if (f_pv && rst_n && rsp_vld)
            assert (rsp_syn[`AMU_SWR] == (rsp_flt && q_acc == `AMU_AKW)
                 && rsp_syn[`AMU_SEX] == (rsp_flt && q_acc == `AMU_AKX));
        // a successful response always has the permission it was asked for
        if (f_pv && rst_n && rsp_vld && !rsp_flt)
            assert (prm_ok(q_acc, rsp_att));
        // a parked miss is never already cached
        if (f_pv && rst_n && pnd)
            for (fd = 0; fd < NEN; fd = fd + 1)
                assert (!(e_vld[fd] && e_sid[fd] == q_sid && e_vpn[fd] == q_va[VAW-1:PGS]));
    end
`endif
endmodule
