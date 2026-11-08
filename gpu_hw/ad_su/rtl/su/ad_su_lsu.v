// ad_su_lsu -- global memory unit of the SU (spec/gpu/su/ad_su_lsu.md).
// lw / sw (sub 0: side-effect lanes) / sw.x (sub 1: EXEC lanes) / atom / fence.
// One lane group at a time.  lw and sw go through the coalescer
// (ad_lsu_coalesce: the first pending lane's line and every pending lane in it,
// one D$ request per distinct line), one D$ request outstanding; sw waits for
// each write response (higher lane wins on one word, ad_lsu_wbe); lw scatters
// the returned line (ad_lsu_scatter).  atom: one at_* operation per
// side-effect lane, serial, the D$ invalidated (dc_inv) one cycle after the
// group is taken.  fence: dc_inv one cycle after it is taken, no beat.  An
// empty lane mask gives an immediate completion beat.  Errors give 0.
// One beat per group (l_last = the group's x_last).
module ad_su_lsu #(
    parameter NPHYS      = 8,
    parameter NWARPS     = 4,
    parameter WARP_W     = 2,
    parameter GRP_W      = 2,
    parameter SBE_W      = 2,
    parameter UOP_W      = 108,
    parameter ADDR_W     = 32,
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5
) (
    input  wire                         clk,
    input  wire                         rst_n,
    // execution bus
    input  wire                         x_valid,
    input  wire [WARP_W-1:0]            x_warp,
    input  wire [GRP_W-1:0]             x_grp,
    input  wire                         x_last,
    input  wire [SBE_W:0]               x_sbe,
    input  wire [15:0]                  x_pc,
    input  wire [UOP_W-1:0]             x_uop,
    input  wire [NPHYS*32-1:0]          x_a,
    input  wire [NPHYS*32-1:0]          x_b,
    input  wire [NPHYS*32-1:0]          x_c,
    input  wire [2*NPHYS-1:0]           x_mask,
    input  wire [31:0]                  x_info,
    output wire                         x_ready,
    // long result
    output wire                         l_valid,
    input  wire                         l_ready,
    output reg  [WARP_W-1:0]            l_warp,
    output reg  [GRP_W-1:0]             l_grp,
    output reg  [6:0]                   l_rd,
    output reg  [NPHYS*32-1:0]          l_data,
    output reg  [NPHYS-1:0]             l_lanes,
    output reg                          l_wr,
    output reg                          l_last,
    output reg  [SBE_W:0]               l_sbe,
    output reg  [2:0]                   l_cls,
    // D$ (AMB client)
    output wire                         dc_req_valid,
    input  wire                         dc_req_ready,
    output wire                         dc_req_write,
    output wire [ADDR_W-LINE_SHIFT-1:0] dc_req_line,
    output wire [LINE_BYTES-1:0]        dc_req_be,
    output wire [LINE_BYTES*8-1:0]      dc_req_wdata,
    output wire [7:0]                   dc_req_tag,
    input  wire                         dc_rsp_valid,
    input  wire                         dc_rsp_write,
    input  wire [7:0]                   dc_rsp_tag,
    input  wire [LINE_BYTES*8-1:0]      dc_rsp_rdata,
    input  wire                         dc_rsp_error,
    // atomics (ad_mc_atom)
    output wire                         at_valid,
    input  wire                         at_ready,
    output wire [3:0]                   at_op,
    output wire [29:0]                  at_addr,
    output wire [31:0]                  at_a,
    output wire [31:0]                  at_b,
    input  wire                         at_rsp_valid,
    input  wire [31:0]                  at_old,
    input  wire                         at_error,
    output wire                         dc_inv
`ifdef FORMAL
    ,
    output wire [2:0]                   fv_st       // formal only: the state (harness invariants)
`endif
);
`include "ad_su_uop.vh"

    localparam [2:0] S_IDLE = 3'd0, S_REQ = 3'd1, S_WAIT = 3'd2, S_AT = 3'd3, S_ATW = 3'd4,
                     S_BEAT = 3'd5;
    localparam LW = ADDR_W - LINE_SHIFT;
    localparam LIW = (NPHYS > 1) ? $clog2(NPHYS) : 1;

    reg [2:0]              st;
    reg [NPHYS-1:0]        pend;
    reg [NPHYS*ADDR_W-1:0] addr;
    reg [NPHYS*32-1:0]     opb, opc;
    reg                    is_sw;
    reg [3:0]              aop;
    reg                    inv_q;

    // ---- take ----
    wire       mine  = x_valid && (x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_LSU);
    wire       take  = mine && x_ready;
    wire [7:0] op    = x_uop[AD_UOP_OP +: 8];
    wire [4:0] sub   = x_uop[AD_UOP_SUB +: 5];
    wire [31:0] imm  = x_uop[AD_UOP_IMM +: 32];
    wire [NPHYS-1:0] m_exec = x_mask[NPHYS-1:0];
    wire [NPHYS-1:0] m_side = x_mask[2*NPHYS-1:NPHYS];
    wire op_lw = (op == AD_LSU_LW), op_sw = (op == AD_LSU_SW), op_at = (op == AD_LSU_ATOM),
         op_fn = (op == AD_LSU_FENCE);
    wire [NPHYS-1:0] t_pend = op_lw ? m_exec : op_sw ? (sub[0] ? m_exec : m_side) :
                              op_at ? m_side : {NPHYS{1'b0}};
    wire [NPHYS-1:0] t_lanes = op_lw ? m_exec : op_at ? m_side : {NPHYS{1'b0}};
    reg  [NPHYS*ADDR_W-1:0] t_addr;
    integer i;
    always @(*) begin
        for (i = 0; i < NPHYS; i = i + 1)
            t_addr[i*ADDR_W +: ADDR_W] = op_at ? x_a[i*32 +: ADDR_W] : (x_a[i*32 +: ADDR_W] + imm[ADDR_W-1:0]);
    end

    assign x_ready = (st == S_IDLE);

    // ---- coalescer, write enables, scatter ----
    wire          co_any;
    wire [LW-1:0] co_line;
    wire [NPHYS-1:0] co_lanes;
    ad_lsu_coalesce #(.NPHYS(NPHYS), .ADDR_W(ADDR_W), .LINE_SHIFT(LINE_SHIFT)) u_co (
        .pend(pend), .addr(addr), .any(co_any), .line(co_line), .lanes(co_lanes));
    ad_lsu_wbe #(.NPHYS(NPHYS), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_wbe (
        .lanes(co_lanes), .addr(addr), .data(opb), .be(dc_req_be), .wdata(dc_req_wdata));
    wire [NPHYS*32-1:0] sc_words;
    ad_lsu_scatter #(.NPHYS(NPHYS), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_sc (
        .rdata(dc_rsp_rdata), .error(dc_rsp_error), .addr(addr), .lanes(co_lanes), .words(sc_words));

    assign dc_req_valid = (st == S_REQ);
    assign dc_req_write = is_sw;
    assign dc_req_line  = co_line;
    assign dc_req_tag   = 8'd0;

    // ---- atomics: the first pending lane ----
    reg [LIW-1:0] al;
    always @(*) begin
        al = {LIW{1'b0}};
        for (i = NPHYS - 1; i >= 0; i = i - 1) if (pend[i]) al = i[LIW-1:0];
    end
    wire [ADDR_W-1:0] al_addr = addr[al*ADDR_W +: ADDR_W];
    wire [63:0] al_full = {{(64-ADDR_W){1'b0}}, al_addr};
    assign at_valid = (st == S_AT);
    assign at_op    = aop;
    assign at_addr  = al_full[31:2];
    assign at_a     = opb[al*32 +: 32];
    assign at_b     = opc[al*32 +: 32];
    assign dc_inv   = inv_q;

    assign l_valid = (st == S_BEAT);
`ifdef FORMAL
    assign fv_st = st;
`endif

    wire [NPHYS-1:0] pend_left = pend & ~co_lanes;

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; pend <= {NPHYS{1'b0}}; inv_q <= 1'b0;
            l_warp <= 0; l_grp <= 0; l_rd <= 7'd0; l_data <= 0; l_lanes <= 0; l_wr <= 1'b0;
            l_last <= 1'b0; l_sbe <= 0; l_cls <= 3'd0; is_sw <= 1'b0; aop <= 4'd0;
            addr <= 0; opb <= 0; opc <= 0;
        end else begin
            inv_q <= 1'b0;
            case (st)
            S_IDLE: if (take) begin
                if (op_fn) begin
                    inv_q <= 1'b1;
                end else begin
                    l_warp <= x_warp; l_grp <= x_grp; l_rd <= x_uop[AD_UOP_RD +: 7];
                    l_last <= x_last; l_sbe <= x_sbe; l_cls <= x_uop[AD_UOP_CLS +: 3];
                    l_lanes <= t_lanes; l_data <= {(NPHYS*32){1'b0}};
                    l_wr <= x_uop[AD_UOP_WRD] && (|t_lanes);
                    pend <= t_pend; addr <= t_addr; opb <= x_b; opc <= x_c;
                    is_sw <= op_sw; aop <= sub[3:0];
`ifndef MUT_LSU_NOINV
                    if (op_at && (|t_pend)) inv_q <= 1'b1;
`endif
                    st <= (t_pend == {NPHYS{1'b0}}) ? S_BEAT : op_at ? S_AT : S_REQ;
                end
            end
`ifdef MUT_LSU_EARLY
            // mutation: a store completes when its last write is accepted, not answered
            S_REQ: if (dc_req_ready) begin
                if (is_sw && pend_left == {NPHYS{1'b0}}) begin pend <= pend_left; st <= S_BEAT; end
                else st <= S_WAIT;
            end
`else
            S_REQ: if (dc_req_ready) st <= S_WAIT;
`endif
            S_WAIT: if (dc_rsp_valid) begin
                if (!is_sw) l_data <= l_data | sc_words;
                pend <= pend_left;
                st <= (pend_left == {NPHYS{1'b0}}) ? S_BEAT : S_REQ;
            end
            S_AT: if (at_ready) st <= S_ATW;
            S_ATW: if (at_rsp_valid) begin
                l_data[al*32 +: 32] <= at_error ? 32'd0 : at_old;
                pend[al] <= 1'b0;
                st <= ((pend & ~({{(NPHYS-1){1'b0}}, 1'b1} << al)) == {NPHYS{1'b0}}) ? S_BEAT : S_AT;
            end
            S_BEAT: if (l_ready) st <= S_IDLE;
            default: st <= S_IDLE;
            endcase
        end
    end

    // unused inputs
    wire unused = &{1'b0, x_pc, x_info, sub[4], al_full[63:32], al_full[1:0], dc_rsp_write, dc_rsp_tag, NWARPS[0], co_any};
endmodule
