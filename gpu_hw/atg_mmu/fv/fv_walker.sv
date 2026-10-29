// Formal harness: atg_mmu_walker, production widths.  The reference model is
// embedded in the RTL (it needs the FSM state); this file is the environment,
// a few port-level checks, and covers.
`include "atg_mmu_pkg.vh"
module fv_walker (input clk, input rst_n,
    input wrq_vld, input [3:0] wrq_sid, input [19:0] wrq_vpn,
    input [17:0] rot_ptr, input rot_ok,
    input ar_rdy, input r_vld, input [63:0] r_dat, input [1:0] r_rsp);

    wire idl, ar_vld, r_rdy, wrs_vld, wrs_flt;
    wire [3:0] rot_sid, wrs_fkd; wire [39:0] ar_adr; wire [11:0] wrs_syn;
    wire [27:0] wrs_pfn; wire [5:0] wrs_att;
    atg_mmu_walker dut (.clk(clk), .rst_n(rst_n), .wrq_vld(wrq_vld), .wrq_sid(wrq_sid), .wrq_vpn(wrq_vpn),
        .idl(idl), .rot_sid(rot_sid), .rot_ptr(rot_ptr), .rot_ok(rot_ok),
        .ar_vld(ar_vld), .ar_rdy(ar_rdy), .ar_adr(ar_adr), .r_vld(r_vld), .r_rdy(r_rdy),
        .r_dat(r_dat), .r_rsp(r_rsp), .wrs_vld(wrs_vld), .wrs_flt(wrs_flt), .wrs_fkd(wrs_fkd),
        .wrs_syn(wrs_syn), .wrs_pfn(wrs_pfn), .wrs_att(wrs_att));

    reg f_pv = 0;
    always @(posedge clk) f_pv <= 1;
    always @(*) if (!f_pv) assume (!rst_n);

    // ---- environment: L2 launches only on an idle walker; AXI data only
    //      while the walker waits for it (one read outstanding at a time)
    always @(*) if (rst_n) begin
        assume (!wrq_vld || idl);
        assume (!r_vld || r_rdy);
    end

    // ---- port-level checks
    reg busy;
    always @(posedge clk)
        if (!rst_n) busy <= 0;
        else if (wrq_vld) busy <= 1;
        else if (wrs_vld) busy <= 0;
    always @(*) if (f_pv && rst_n) begin
        assert (!wrs_vld || busy);                 // every result answers a request
        assert (!ar_vld || busy);                  // no reads outside a walk
        assert (idl == !busy);
        assert (!(ar_vld && r_rdy));               // address and data phases never overlap
        assert (rot_sid == wrq_sid);
    end
    // AXI: ARVALID held and ARADDR stable until ARREADY
    always @(posedge clk) if (f_pv && rst_n && $past(rst_n) && $past(ar_vld) && !$past(ar_rdy))
        assert (ar_vld && ar_adr == $past(ar_adr));

    always @(*) if (rst_n) begin
        cover (wrs_vld && !wrs_flt);
        cover (wrs_vld && wrs_flt && wrs_syn == 12'h004);
        cover (wrs_vld && wrs_flt && wrs_syn == 12'h008);
        cover (wrs_vld && wrs_fkd == `AMU_FKA);
        cover (wrs_vld && wrs_syn == 12'h020);
    end
endmodule
