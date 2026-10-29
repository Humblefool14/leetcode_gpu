// Formal harness: atg_tlb_l1, reduced widths (4 entries, 2-bit session, 8-bit VPN).
`include "atg_mmu_pkg.vh"
module fv_l1 (input clk, input rst_n,
    input req_vld, input [15:0] req_va, input [1:0] req_acc, input [1:0] req_sid, input [1:0] req_stg,
    input hld, input ful,
    input flu_vld, input flu_all, input flu_rng, input [1:0] flu_sid, input [7:0] flu_vpn,
    input mrq_rdy,
    input mrs_vld, input mrs_rty, input mrs_flt, input [3:0] mrs_fkd, input [11:0] mrs_syn,
    input [9:0] mrs_pfn, input [5:0] mrs_att);

    wire req_rdy, rsp_vld, rsp_flt, idl, mrq_vld;
    wire [13:0] rsp_pa; wire [5:0] rsp_att; wire [3:0] rsp_fkd; wire [11:0] rsp_syn;
    wire [15:0] rsp_va; wire [1:0] rsp_sid, rsp_stg, mrq_sid; wire [7:0] mrq_vpn;
    atg_tlb_l1 #(.VAW(12), .GVW(16), .PAW(14), .PGS(4), .VPW(8), .PFW(10), .SIW(2), .STW(2),
                 .NEN(4), .ATW(6), .FKW(4), .SYW(12)) dut (
        .clk(clk), .rst_n(rst_n), .req_vld(req_vld), .req_rdy(req_rdy), .req_va(req_va),
        .req_acc(req_acc), .req_sid(req_sid), .req_stg(req_stg), .rsp_vld(rsp_vld), .rsp_pa(rsp_pa),
        .rsp_att(rsp_att), .rsp_flt(rsp_flt), .rsp_fkd(rsp_fkd), .rsp_syn(rsp_syn), .rsp_va(rsp_va),
        .rsp_sid(rsp_sid), .rsp_stg(rsp_stg), .hld(hld), .ful(ful), .idl(idl),
        .flu_vld(flu_vld), .flu_all(flu_all), .flu_rng(flu_rng), .flu_sid(flu_sid), .flu_vpn(flu_vpn),
        .mrq_vld(mrq_vld), .mrq_rdy(mrq_rdy), .mrq_sid(mrq_sid), .mrq_vpn(mrq_vpn),
        .mrs_vld(mrs_vld), .mrs_rty(mrs_rty), .mrs_flt(mrs_flt), .mrs_fkd(mrs_fkd), .mrs_syn(mrs_syn),
        .mrs_pfn(mrs_pfn), .mrs_att(mrs_att), .f_qsid(2'd0), .f_qvpn(8'd0), .f_qhit(), .f_snt());

    reg f_pv = 0;
    always @(posedge clk) f_pv <= 1;
    always @(*) if (!f_pv) assume (!rst_n);

    // ---- environment: the L2 answers only an accepted miss; flushes only
    //      come from the sequencer (hold asserted, L1 idle)
    // (the "answer only an accepted miss" rule is an AMU_FV1 assumption in the RTL)
    always @(*) if (rst_n) begin
        assume (!flu_vld || (hld && idl));
        assume (!mrs_flt || (mrs_syn[`AMU_SWR] == 0 && mrs_syn[`AMU_SEX] == 0 && (mrs_fkd == `AMU_FKP || mrs_fkd == `AMU_FKA))); // walk faults only
    end

    // ---- port-level checks
    reg obusy; reg [1:0] oacc;
    wire acc = req_vld && req_rdy;
    always @(posedge clk)
        if (!rst_n) obusy <= 0;
        else begin
            if (rsp_vld) obusy <= 0;
            if (acc) begin obusy <= 1; oacc <= req_acc; end
        end
    always @(*) if (f_pv && rst_n) begin
        assert (!rsp_vld || obusy);                         // every answer has a request
        assert (obusy == !idl);                             // busy exactly while parked or answering
        assert (!acc || !obusy || rsp_vld);                 // one request at a time
        assert (!rsp_flt || rsp_pa == 0);                   // fault carries no address
        assert (!(hld && req_rdy) && !(ful && req_rdy));
        if (rsp_vld && rsp_flt) assert (rsp_fkd != 0);
        if (rsp_vld && rsp_flt && rsp_fkd == `AMU_FKM) assert (rsp_syn[`AMU_SPM]);
    end
    // miss request is held stable until accepted
    always @(posedge clk) if (f_pv && rst_n && $past(rst_n) && $past(mrq_vld) && !$past(mrq_rdy))
        assert (mrq_vld && mrq_sid == $past(mrq_sid) && mrq_vpn == $past(mrq_vpn));
    // VA above VAW faults immediately
    always @(posedge clk) if (f_pv && rst_n && $past(rst_n) && $past(acc) && $past(|req_va[15:12]))
        assert (rsp_vld && rsp_flt && rsp_fkd == `AMU_FKP && rsp_syn[`AMU_SOR]);

    reg p_acc;
    always @(posedge clk) p_acc <= acc;
    always @(*) if (rst_n) begin
        cover (rsp_vld && !rsp_flt && p_acc);                        // L1 hit
        cover (rsp_vld && !rsp_flt && !p_acc);                       // refill
        cover (rsp_vld && rsp_fkd == `AMU_FKM);                      // permission fault
        cover (mrs_vld && mrs_rty);                                  // retry path
        cover (flu_vld && flu_rng);
    end
endmodule
