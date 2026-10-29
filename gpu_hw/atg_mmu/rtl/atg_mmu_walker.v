// ============================================================================
// atg_mmu_walker -- 2-level hardware page-table walker (GHCI 1.0 section 11.2)
// ----------------------------------------------------------------------------
//   PDE address = { ROOT_PT[sid][31:14], VA[31:21], 3'b000 }   (16 KiB root)
//   PTE address = { PDE.PPN,             VA[20:12], 3'b000 }   ( 4 KiB table)
// Both are pure concatenations: the root is 16 KiB aligned and tables are
// 4 KiB aligned, so no adder is needed (the original +4 / x4 math is gone).
// Each entry is 64 bits = exactly one beat of the 64-bit AXI read port.
//
// Faults (answered, never installed by the L2):
//   no root for the session   -> PAGE_FAULT, syndrome SNS (0x020)
//   PDE.V = 0                 -> PAGE_FAULT, syndrome SPD
//   PTE.V = 0                 -> PAGE_FAULT, syndrome SPT
//   PPN above AMU_PAW         -> PAGE_FAULT, syndrome SPA
//   RRESP != OKAY             -> AXI_ERROR
// D/A/U/G bits are ignored and never written back (tables are firmware-owned).
// ============================================================================
`include "atg_mmu_pkg.vh"
module atg_mmu_walker #(
    parameter PAW = `AMU_PAW,
    parameter PTW = `AMU_PTW,
    parameter PGS = `AMU_PGS,
    parameter VPW = `AMU_VPW,
    parameter PFW = `AMU_PFW,
    parameter D0W = `AMU_D0W,
    parameter RTW = `AMU_RTW,
    parameter SIW = `AMU_SIW,
    parameter ATW = `AMU_ATW,
    parameter FKW = `AMU_FKW,
    parameter SYW = `AMU_SYW
) (
    input  wire            clk,
    input  wire            rst_n,
    // ---- request from the L2 (only issued while idl = 1)
    input  wire            wrq_vld,
    input  wire [SIW-1:0]  wrq_sid,
    input  wire [VPW-1:0]  wrq_vpn,
    output wire            idl,
    // ---- root table lookup (combinational, in atg_mmu)
    output wire [SIW-1:0]  rot_sid,
    input  wire [RTW-1:0]  rot_ptr,
    input  wire            rot_ok,
    // ---- AXI4 read address / data (single beat, 8 bytes)
    output reg             ar_vld,
    input  wire            ar_rdy,
    output reg  [PAW-1:0]  ar_adr,
    input  wire            r_vld,
    output wire            r_rdy,
    input  wire [PTW-1:0]  r_dat,
    input  wire [1:0]      r_rsp,
    // ---- result to the L2 (one-cycle pulse)
    output reg             wrs_vld,
    output reg             wrs_flt,
    output reg  [FKW-1:0]  wrs_fkd,
    output reg  [SYW-1:0]  wrs_syn,
    output reg  [PFW-1:0]  wrs_pfn,
    output reg  [ATW-1:0]  wrs_att
);
    localparam [2:0] IDL = 3'd0, PDA = 3'd1, PDW = 3'd2, PTA = 3'd3, PTD = 3'd4;
    localparam       PEB = 3;                       // log2(bytes per entry)
    localparam       PPW = 48 - `AMU_PPL;           // PPN field width in the PTE ([47:12])

    reg [2:0]     st;
    reg [SIW-1:0] w_sid;
    reg [VPW-1:0] w_vpn;

    assign idl     = (st == IDL) && !wrs_vld;
    assign rot_sid = wrq_sid;
    assign r_rdy   = (st == PDW) || (st == PTD);

    wire [PAW-1:0] pde_adr = {{(PAW-RTW-(VPW-D0W)-PEB){1'b0}}, rot_ptr, wrq_vpn[VPW-1:D0W], {PEB{1'b0}}};
    wire [PFW-1:0] r_pfn   = r_dat[`AMU_PPL +: PFW];
    wire           r_big   = |r_dat[`AMU_PPL + PFW +: (PPW - PFW > 0 ? PPW - PFW : 1)] && (PPW > PFW);
    wire [PAW-1:0] pte_adr = {r_pfn, w_vpn[D0W-1:0], {PEB{1'b0}}};
    wire           r_err   = (r_rsp != 2'b00);

    function [SYW-1:0] sbit;
        input integer b;
        begin
            sbit    = {SYW{1'b0}};
            sbit[b] = 1'b1;
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            st      <= IDL;
            ar_vld  <= 1'b0;
            ar_adr  <= {PAW{1'b0}};
            w_sid   <= {SIW{1'b0}};
            w_vpn   <= {VPW{1'b0}};
            wrs_vld <= 1'b0;
            wrs_flt <= 1'b0;
            wrs_fkd <= `AMU_FKN;
            wrs_syn <= {SYW{1'b0}};
            wrs_pfn <= {PFW{1'b0}};
            wrs_att <= {ATW{1'b0}};
        end else begin
            wrs_vld <= 1'b0;
            case (st)
                IDL: if (wrq_vld) begin
                    w_sid <= wrq_sid;
                    w_vpn <= wrq_vpn;
                    if (!rot_ok) begin
                        wrs_vld <= 1'b1;
                        wrs_flt <= 1'b1;
                        wrs_fkd <= `AMU_FKP;
                        wrs_syn <= sbit(`AMU_SNS);
                        wrs_pfn <= {PFW{1'b0}};
                        wrs_att <= {ATW{1'b0}};
                    end else begin
                        ar_vld <= 1'b1;
                        ar_adr <= pde_adr;
                        st     <= PDA;
                    end
                end
                PDA: if (ar_rdy) begin
                    ar_vld <= 1'b0;
                    st     <= PDW;
                end
                PDW: if (r_vld) begin
                    if (r_err || !r_dat[`AMU_PVL] || r_big) begin
                        wrs_vld <= 1'b1;
                        wrs_flt <= 1'b1;
                        wrs_fkd <= r_err ? `AMU_FKA : `AMU_FKP;
                        wrs_syn <= r_err ? {SYW{1'b0}} : (!r_dat[`AMU_PVL] ? sbit(`AMU_SPD) : sbit(`AMU_SPA));
                        wrs_pfn <= {PFW{1'b0}};
                        wrs_att <= {ATW{1'b0}};
                        st      <= IDL;
                    end else begin
                        ar_vld <= 1'b1;
                        ar_adr <= pte_adr;
                        st     <= PTA;
                    end
                end
                PTA: if (ar_rdy) begin
                    ar_vld <= 1'b0;
                    st     <= PTD;
                end
                PTD: if (r_vld) begin
                    wrs_vld <= 1'b1;
                    st      <= IDL;
                    if (r_err || !r_dat[`AMU_PVL] || r_big) begin
                        wrs_flt <= 1'b1;
                        wrs_fkd <= r_err ? `AMU_FKA : `AMU_FKP;
                        wrs_syn <= r_err ? {SYW{1'b0}} : (!r_dat[`AMU_PVL] ? sbit(`AMU_SPT) : sbit(`AMU_SPA));
                        wrs_pfn <= {PFW{1'b0}};
                        wrs_att <= {ATW{1'b0}};
                    end else begin
                        wrs_flt <= 1'b0;
                        wrs_fkd <= `AMU_FKN;
                        wrs_syn <= {SYW{1'b0}};
                        wrs_pfn <= r_pfn;
                        wrs_att <= {ATW{1'b0}};
                        wrs_att[`AMU_ARD] <= r_dat[`AMU_PRD];
                        wrs_att[`AMU_AWR] <= r_dat[`AMU_PWR];
                        wrs_att[`AMU_AEX] <= r_dat[`AMU_PEX];
                        wrs_att[`AMU_ACO] <= r_dat[`AMU_PCO];
                        wrs_att[`AMU_AWC] <= r_dat[`AMU_PWC];
                        wrs_att[`AMU_ALO] <= r_dat[`AMU_PLO];
                    end
                end
                default: st <= IDL;
            endcase
        end
    end

`ifdef FORMAL
    // ---- embedded reference model (needs the FSM state, so it lives here)
    reg f_pv = 1'b0;
    always @(posedge clk) f_pv <= 1'b1;
    reg [RTW-1:0] f_root;
    reg           f_rok;
    reg [PTW-1:0] f_pde, f_pte;
    reg [1:0]     f_prs, f_trs;
    reg [1:0]     f_nr;                                   // reads answered in this walk
    always @(posedge clk) begin
        if (st == IDL && wrq_vld) begin
            f_root <= rot_ptr; f_rok <= rot_ok; f_nr <= 2'd0;
        end
        if (st == PDW && r_vld) begin f_pde <= r_dat; f_prs <= r_rsp; f_nr <= 2'd1; end
        if (st == PTD && r_vld) begin f_pte <= r_dat; f_trs <= r_rsp; f_nr <= 2'd2; end
    end
    wire f_pbad = f_prs != 2'b00 || !f_pde[`AMU_PVL] || (PPW > PFW && |f_pde[`AMU_PPL + PFW +: (PPW - PFW > 0 ? PPW - PFW : 1)]);
    wire f_tbad = f_trs != 2'b00 || !f_pte[`AMU_PVL] || (PPW > PFW && |f_pte[`AMU_PPL + PFW +: (PPW - PFW > 0 ? PPW - PFW : 1)]);

    always @(*) if (f_pv && rst_n) begin
        assert (st <= PTD);
        assert (ar_vld == (st == PDA || st == PTA));
        assert (!(wrs_vld && st != IDL));
        if (st != IDL) assert (f_rok);
        if (st == PDA) assert (f_nr == 0 && ar_adr == {{(PAW-RTW-(VPW-D0W)-PEB){1'b0}}, f_root, w_vpn[VPW-1:D0W], {PEB{1'b0}}});
        if (st == PDW) assert (f_nr == 0);
        if (st == PTA || st == PTD) assert (f_nr == 1 && !f_pbad);
        if (st == PTA) assert (ar_adr == {f_pde[`AMU_PPL +: PFW], w_vpn[D0W-1:0], {PEB{1'b0}}});
        if (wrs_vld) begin
            if (!f_rok)
                assert (wrs_flt && wrs_fkd == `AMU_FKP && wrs_syn == sbit(`AMU_SNS));
            else if (f_nr == 1) begin
                assert (wrs_flt && f_pbad);
                assert (wrs_fkd == (f_prs != 0 ? `AMU_FKA : `AMU_FKP));
                if (f_prs == 0) assert (wrs_syn == (!f_pde[`AMU_PVL] ? sbit(`AMU_SPD) : sbit(`AMU_SPA)));
            end else begin
                assert (f_nr == 2 && !f_pbad && wrs_flt == f_tbad);
                if (f_tbad) begin
                    assert (wrs_fkd == (f_trs != 0 ? `AMU_FKA : `AMU_FKP));
                    if (f_trs == 0) assert (wrs_syn == (!f_pte[`AMU_PVL] ? sbit(`AMU_SPT) : sbit(`AMU_SPA)));
                end else begin
                    assert (wrs_pfn == f_pte[`AMU_PPL +: PFW]);
                    assert (wrs_att[`AMU_ARD] == f_pte[`AMU_PRD] && wrs_att[`AMU_AWR] == f_pte[`AMU_PWR]
                         && wrs_att[`AMU_AEX] == f_pte[`AMU_PEX] && wrs_att[`AMU_ACO] == f_pte[`AMU_PCO]
                         && wrs_att[`AMU_AWC] == f_pte[`AMU_PWC] && wrs_att[`AMU_ALO] == f_pte[`AMU_PLO]);
                end
            end
            if (wrs_flt) assert (wrs_pfn == {PFW{1'b0}} && wrs_att == {ATW{1'b0}});
        end
    end
`endif
endmodule
