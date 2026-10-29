// Formal harness: atg_mmu top at production address widths (32-bit VA, 40-bit PA,
// 4 KiB pages), reduced counts.  Run as bounded model check only (task bmc).
// (their AMU_FVx environment assumptions become assertions).
`include "atg_mmu_pkg.vh"
module fv_topw (input clk, input rst_n,
    input [1:0] c_req_vld, input [127:0] c_req_va, input [3:0] c_req_acc, input [1:0] c_req_sid,
    input [3:0] c_req_stg, input [1:0] c_cmp_vld, input [1:0] c_cmp_epo,
    input m_arready, input m_rvalid, input [63:0] m_rdata, input [1:0] m_rresp,
    input cfg_wen, input [4:0] cfg_adr, input [31:0] cfg_wdt);

    wire [1:0] c_req_rdy, c_rsp_vld, c_rsp_flt, c_rsp_epo;
    wire [79:0] c_rsp_pa; wire [11:0] c_rsp_att;
    wire m_arvalid, m_rready, irq_flt; wire [39:0] m_araddr; wire [7:0] m_arlen; wire [2:0] m_arsize;
    wire [1:0] m_arburst; wire [31:0] cfg_rdt;

    atg_mmu #(
             .SIW(1), .NSS(2), .NCL(2), .CIW(1), .L1E(2), .L2S(2), .L2X(1), .L2W(2), .L2T(19), .OSD(4)) dut (
        .clk(clk), .rst_n(rst_n),
        .c_req_vld(c_req_vld), .c_req_rdy(c_req_rdy), .c_req_va(c_req_va), .c_req_acc(c_req_acc),
        .c_req_sid(c_req_sid), .c_req_stg(c_req_stg), .c_rsp_vld(c_rsp_vld), .c_rsp_pa(c_rsp_pa),
        .c_rsp_att(c_rsp_att), .c_rsp_flt(c_rsp_flt), .c_rsp_epo(c_rsp_epo),
        .c_cmp_vld(c_cmp_vld), .c_cmp_epo(c_cmp_epo),
        .m_arvalid(m_arvalid), .m_arready(m_arready), .m_araddr(m_araddr), .m_arlen(m_arlen),
        .m_arsize(m_arsize), .m_arburst(m_arburst), .m_rvalid(m_rvalid), .m_rready(m_rready),
        .m_rdata(m_rdata), .m_rresp(m_rresp),
        .cfg_wen(cfg_wen), .cfg_adr(cfg_adr), .cfg_wdt(cfg_wdt), .cfg_rdt(cfg_rdt), .irq_flt(irq_flt));

    reg f_pv = 0;
    always @(posedge clk) f_pv <= 1;
    always @(*) if (!f_pv) assume (!rst_n);

    // ---- environment
    // AXI slave: one read outstanding, data only while the walker waits
    always @(*) if (rst_n) assume (!m_rvalid || m_rready);
    // clients complete only transactions they were given: an assumption inside atg_mmu_ifc

    // ---- port-level checks
    always @(*) if (f_pv && rst_n) begin
        assert (!c_rsp_flt[0] || c_rsp_pa[39:0] == 0);
        assert (!c_rsp_flt[1] || c_rsp_pa[79:40] == 0);
        assert (m_arlen == 0 && m_arsize == 3 && m_arburst == 1);
        assert (!m_arvalid || m_araddr[2:0] == 0);         // 8-byte aligned PTE reads
    end

    // ---- covers: the interesting end-to-end scenarios are reachable
    reg flushed;
    always @(posedge clk)
        if (!rst_n) flushed <= 0;
        else if (cfg_wen && cfg_adr == `AMU_RFL) flushed <= 1;
    always @(*) if (rst_n) begin
        cover (c_rsp_vld[1] && !c_rsp_flt[1]);                         // full walk to a client
        cover (c_rsp_vld[0] && c_rsp_flt[0] && irq_flt);
        cover (flushed && c_rsp_vld[0] && !c_rsp_flt[0] && c_rsp_epo[0]); // translation after a flush
    end
endmodule
