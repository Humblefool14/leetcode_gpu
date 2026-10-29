// Formal harness: atg_tlb_l2, reduced: 2 sets x 2 ways, 4-bit VPN, 1-bit session, 3 clients.
`include "atg_mmu_pkg.vh"
module fv_l2 (input clk, input rst_n,
    input lrq_vld, input [1:0] lrq_cid, input lrq_sid, input [3:0] lrq_vpn,
    input wrs_vld, input wrs_flt, input [3:0] wrs_fkd, input [11:0] wrs_syn, input [3:0] wrs_pfn, input [5:0] wrs_att,
    input flu_vld, input flu_all, input flu_rng, input flu_sid, input [3:0] flu_vpn);

    wire lrq_rdy, lrs_vld, lrs_rty, lrs_flt, wrq_vld, wrq_sid, idl;
    wire [1:0] lrs_cid; wire [3:0] lrs_fkd, lrs_pfn, wrq_vpn; wire [11:0] lrs_syn; wire [5:0] lrs_att;
    atg_tlb_l2 #(.VPW(4), .PFW(4), .SIW(1), .CIW(2), .NST(2), .SXW(1), .NWY(2), .TGW(3),
                 .ATW(6), .FKW(4), .SYW(12)) dut (
        .clk(clk), .rst_n(rst_n), .lrq_vld(lrq_vld), .lrq_rdy(lrq_rdy), .lrq_cid(lrq_cid),
        .lrq_sid(lrq_sid), .lrq_vpn(lrq_vpn), .lrs_vld(lrs_vld), .lrs_cid(lrs_cid), .lrs_rty(lrs_rty),
        .lrs_flt(lrs_flt), .lrs_fkd(lrs_fkd), .lrs_syn(lrs_syn), .lrs_pfn(lrs_pfn), .lrs_att(lrs_att),
        .wrq_vld(wrq_vld), .wrq_sid(wrq_sid), .wrq_vpn(wrq_vpn), .wrs_vld(wrs_vld), .wrs_flt(wrs_flt),
        .wrs_fkd(wrs_fkd), .wrs_syn(wrs_syn), .wrs_pfn(wrs_pfn), .wrs_att(wrs_att),
        .flu_vld(flu_vld), .flu_all(flu_all), .flu_rng(flu_rng), .flu_sid(flu_sid), .flu_vpn(flu_vpn),
        .idl(idl), .f_qsid(1'b0), .f_qvpn(4'd0), .f_qhit(), .f_pnd_o(), .f_wbz(), .f_wot(), .f_wci(), .f_s1k(), .f_s1c(), .f_s1s(), .f_s1v());

    reg f_pv = 0;
    always @(posedge clk) f_pv <= 1;
    always @(*) if (!f_pv) assume (!rst_n);

    // ---- environment
    // (one-miss-per-client and walker-answers-a-launch are AMU_FV2 assumptions in the RTL)
    always @(*) if (rst_n) begin
        assume (lrq_cid != 2'd3);
        assume (!flu_vld || (idl && !lrq_vld));      // flush sequencer: L2 quiet
    end

    // ---- port-level checks
    always @(*) if (f_pv && rst_n) begin
        assert (!(lrs_vld && lrs_flt) || (lrs_pfn == 0 && lrs_att == 0));
        assert (!(wrq_vld && lrs_vld));              // a launch is not also an answer
    end

    always @(*) if (rst_n) begin
        cover (lrs_vld && !lrs_rty && !lrs_flt && lrs_cid == 2);
        cover (lrs_vld && lrs_rty);
        cover (wrq_vld);
        cover (lrs_vld && lrs_flt);
        cover (flu_vld && flu_rng);
    end
endmodule
