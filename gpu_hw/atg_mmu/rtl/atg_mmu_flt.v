// ============================================================================
// atg_mmu_flt -- first-fault capture (feeds GHCI FAULT_INFO / FAULT_ADDR)
// ----------------------------------------------------------------------------
// * Latches the first fault and holds it until the CP clears it (W1C).
// * Several clients faulting in one cycle: the lowest client index wins
//   (CP before VF before SU ...); the rest set the sticky overflow bit.
// * A fault arriving in the same cycle as the clear is captured, not lost.
// ============================================================================
`include "atg_mmu_pkg.vh"
module atg_mmu_flt #(
    parameter NCL = `AMU_NCL,
    parameter GVW = `AMU_GVW,
    parameter SIW = `AMU_SIW,
    parameter STW = `AMU_STW,
    parameter FKW = `AMU_FKW,
    parameter SYW = `AMU_SYW,
    parameter UMP = `AMU_UMP
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire [NCL-1:0]     f_vld,
    input  wire [NCL*FKW-1:0] f_knd,
    input  wire [NCL*SYW-1:0] f_syn,
    input  wire [NCL*SIW-1:0] f_sid,
    input  wire [NCL*STW-1:0] f_stg,
    input  wire [NCL*GVW-1:0] f_va,
    input  wire               clr,      // CP W1C write
    output reg                vld,
    output reg                ovf,
    output reg  [FKW-1:0]     knd,
    output reg  [3:0]         unt,
    output reg  [SIW-1:0]     sid,
    output reg  [STW-1:0]     stg,
    output reg  [SYW-1:0]     syn,
    output reg  [GVW-1:0]     va
);
    // lowest-index winner, unrolled (no arithmetic on signals)
    reg  [NCL-1:0] win;
    reg            any;
    integer i;
    always @(*) begin
        win = {NCL{1'b0}};
        any = 1'b0;
        for (i = 0; i < NCL; i = i + 1)
            if (f_vld[i] && !any) begin
                win[i] = 1'b1;
                any    = 1'b1;
            end
    end

    integer q;
    reg [FKW-1:0] w_knd; reg [SYW-1:0] w_syn; reg [SIW-1:0] w_sid;
    reg [STW-1:0] w_stg; reg [GVW-1:0] w_va;  reg [3:0]     w_unt;
    always @(*) begin
        w_knd = 0; w_syn = 0; w_sid = 0; w_stg = 0; w_va = 0; w_unt = 0;
        for (q = 0; q < NCL; q = q + 1)
            if (win[q]) begin
                w_knd = f_knd[q*FKW +: FKW];
                w_syn = f_syn[q*SYW +: SYW];
                w_sid = f_sid[q*SIW +: SIW];
                w_stg = f_stg[q*STW +: STW];
                w_va  = f_va [q*GVW +: GVW];
                w_unt = UMP[q*4 +: 4];
            end
    end

    wire arm = !vld || clr;                       // latch is (or becomes) free
    wire lost = (|(f_vld & ~win)) || (any && !arm);

    always @(posedge clk) begin
        if (!rst_n) begin
            vld <= 1'b0; ovf <= 1'b0;
            knd <= 0; unt <= 0; sid <= 0; stg <= 0; syn <= 0; va <= 0;
        end else begin
            if (clr) begin
                vld <= 1'b0;
                ovf <= 1'b0;
            end
            if (any && arm) begin
                vld <= 1'b1;
                knd <= w_knd; unt <= w_unt; sid <= w_sid;
                stg <= w_stg; syn <= w_syn; va  <= w_va;
            end
            if (lost)
                ovf <= 1'b1;
        end
    end
endmodule
