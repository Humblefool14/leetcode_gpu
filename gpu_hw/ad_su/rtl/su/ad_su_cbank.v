// ad_su_cbank -- the constant bank (spec/gpu/su/ad_su_cbank.md).
// CONST_WORDS words of block RAM (ad_mem_tdpram, port A) plus a copy of the
// first 32 words in registers for the c0-c31 operands (three per cycle,
// cr_data the cycle after cr_en) and a valid bit per word (inv clears them:
// reads give 0 until the word is loaded again).
// LOAD_CONST (lc_kick): STATE AD_S_LC_REGION/ADDR/WORDS; region 0 only (any
// other region loads nothing); min(words, CONST_WORDS) words from the byte
// address (bits 1:0 ignored), one line read at a time on the AMB port, then
// written one word per cycle; an error response ends the load.  busy while a
// load is pending or running.  A lc_kick during a lwc group waits for it;
// x_ready is 0 while a load is pending or running.
// lwc (unit CBANK): EXEC lanes read word (rs1 + imm) mod CONST_WORDS, one lane
// per cycle; one beat per group.  scrub: 0 to every word (ad_su_scrub).
module ad_su_cbank #(
    parameter NPHYS       = 8,
    parameter NWARPS      = 4,
    parameter WARP_W      = 2,
    parameter GRP_W       = 2,
    parameter SBE_W       = 2,
    parameter UOP_W       = 108,
    parameter ADDR_W      = 32,
    parameter LINE_BYTES  = 32,
    parameter LINE_SHIFT  = 5,
    parameter CONST_WORDS = 256
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
    // c-operand read port
    input  wire                         cr_en,
    input  wire [14:0]                  cr_idx,
    output reg  [95:0]                  cr_data,
    // STATE, LOAD_CONST, invalidate
    input  wire                         st_we,
    input  wire [8:0]                   st_idx,
    input  wire [31:0]                  st_wdata,
    input  wire                         lc_kick,
    input  wire                         inv,
    output wire                         busy,
    // scrub
    input  wire                         scrub,
    output wire                         scrub_busy,
    // AMB client
    output wire                         req_valid,
    input  wire                         req_ready,
    output wire                         req_write,
    output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
    output wire [LINE_BYTES-1:0]        req_be,
    output wire [LINE_BYTES*8-1:0]      req_wdata,
    output wire [7:0]                   req_tag,
    input  wire                         rsp_valid,
    input  wire                         rsp_write,
    input  wire [7:0]                   rsp_tag,
    input  wire [LINE_BYTES*8-1:0]      rsp_rdata,
    input  wire                         rsp_error
`ifdef FORMAL
    ,
    // formal only (harness invariants): state, load progress, STATE copy,
    // and the valid bit and c copy of word fv_i
    output wire [2:0]                   fv_st,
    output wire                         fv_lc_pend,
    output wire [ADDR_W-1:0]            fv_ld_cur,
    output wire [$clog2(CONST_WORDS):0] fv_ld_left,
    output wire [$clog2(CONST_WORDS)-1:0] fv_ld_idx,
    output wire [LINE_BYTES*8-1:0]      fv_ld_line,
    output wire [95:0]                  fv_lc,
    input  wire [4:0]                   fv_i,
    output wire                         fv_vb_i,
    output wire [31:0]                  fv_cpy_i
`endif
);
`include "ad_su_uop.vh"
`include "ad_su_state.vh"

    localparam CW  = $clog2(CONST_WORDS);
    localparam LIW = (NPHYS > 1) ? $clog2(NPHYS) : 1;
    localparam OW  = LINE_SHIFT - 2;
    localparam NC  = 32;                       // c0-c31 copy
    localparam [2:0] S_IDLE = 3'd0, S_ACC = 3'd1, S_DRAIN = 3'd2, S_BEAT = 3'd3,
                     S_LREQ = 3'd4, S_LWAIT = 3'd5, S_LFILL = 3'd6;

    // ---- STATE ----
    reg [31:0] lc_region, lc_addr, lc_words;
    always @(posedge clk) begin
        if (!rst_n) begin
            lc_region <= 32'd0; lc_addr <= 32'd0; lc_words <= 32'd0;
        end else if (st_we) begin
            if (st_idx == `AD_S_LC_REGION) lc_region <= st_wdata;
            if (st_idx == `AD_S_LC_ADDR)   lc_addr   <= st_wdata;
            if (st_idx == `AD_S_LC_WORDS)  lc_words  <= st_wdata;
        end
    end

    reg [2:0]          st;
    reg                lc_pend;
    reg [NPHYS-1:0]    pend;
    reg [NPHYS*CW-1:0] widx;            // lwc word per lane
    reg                cap_v, cap_vb;
    reg [LIW-1:0]      cap_ln;
    reg [ADDR_W-1:0]   ld_cur;          // byte address of the next word to load
    reg [CW:0]         ld_left;         // words left
    reg [CW-1:0]       ld_idx;          // bank word written next
    reg [LINE_BYTES*8-1:0] ld_line;

    reg [CONST_WORDS-1:0] vb;
    reg [31:0]            cpy [0:NC-1];

    // ---- scrub ----
    wire          sc_on;
    wire [CW-1:0] sc_a;
    ad_su_scrub #(.DEPTH(CONST_WORDS), .AW(CW)) sc (
        .clk(clk), .rst_n(rst_n), .start(scrub), .on(sc_on), .a(sc_a));
    assign scrub_busy = sc_on;

    // ---- lwc take ----
    wire take = x_valid && (x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_CBANK) && x_ready;
    wire [31:0] imm = x_uop[AD_UOP_IMM +: 32];
    wire [NPHYS-1:0] m_exec = x_mask[NPHYS-1:0];
    wire op_lwc = (x_uop[AD_UOP_OP +: 8] == AD_CBANK_LWC);
    wire [NPHYS-1:0] t_pend = op_lwc ? m_exec : {NPHYS{1'b0}};
    reg  [NPHYS*CW-1:0] t_widx;
    reg  [31:0] t_sum;
    integer i;
    always @(*) begin
        for (i = 0; i < NPHYS; i = i + 1) begin
            t_sum = x_a[i*32 +: 32] + imm;
            t_widx[i*CW +: CW] = t_sum[CW-1:0];
        end
    end

    assign x_ready = (st == S_IDLE) && !lc_pend && !sc_on;
    assign busy    = lc_pend || (st == S_LREQ) || (st == S_LWAIT) || (st == S_LFILL);
    assign l_valid = (st == S_BEAT);

    reg [LIW-1:0] al;
    always @(*) begin
        al = {LIW{1'b0}};
        for (i = NPHYS - 1; i >= 0; i = i - 1) if (pend[i]) al = i[LIW-1:0];
    end
    wire [NPHYS-1:0] pend_left = pend & ~({{(NPHYS-1){1'b0}}, 1'b1} << al);
    wire [CW-1:0]    al_w      = widx[al*CW +: CW];

    // ---- load ----
    wire [OW-1:0]  ld_off  = ld_cur[OW+1:2];
    wire [31:0]    ld_word = ld_line[ld_off*32 +: 32];
    wire [CW:0]    n_words = (lc_words > CONST_WORDS) ? CONST_WORDS[CW:0] : lc_words[CW:0];
    wire           ld_go   = lc_pend && (st == S_IDLE) && !sc_on;
    assign req_valid = (st == S_LREQ);
    assign req_write = 1'b0;
    assign req_line  = ld_cur[ADDR_W-1:LINE_SHIFT];
    assign req_be    = {LINE_BYTES{1'b0}};
    assign req_wdata = {(LINE_BYTES*8){1'b0}};
    assign req_tag   = 8'd0;

    // ---- bank RAM: port A (scrub / load write, lwc read) ----
    wire          fill_we = (st == S_LFILL);
    wire          a_rd    = (st == S_ACC);
    wire          a_we    = rst_n && (sc_on || fill_we);   // no write in a reset cycle
    wire [CW-1:0] a_addr  = sc_on ? sc_a : fill_we ? ld_idx : al_w;
    wire [31:0]   a_wdata = sc_on ? 32'd0 : ld_word;
    wire [31:0]   ram_rd;
    wire [31:0]   b_unused;
    ad_ram_tdp #(.DEPTH(CONST_WORDS), .AW(CW), .DW(32)) u_ram (
        .clk(clk), .a_en(a_we || a_rd), .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wdata),
        .a_rdata(ram_rd), .b_en(1'b0), .b_addr({CW{1'b0}}), .b_rdata(b_unused));

    // c-operand copy
    always @(posedge clk) begin
        if (a_we && (a_addr < NC)) cpy[a_addr[4:0]] <= a_wdata;
    end
    integer k;
    /* verilator lint_off WIDTHEXPAND */
    always @(posedge clk) begin
        if (!rst_n) cr_data <= 96'd0;
        else if (cr_en)
            for (k = 0; k < 3; k = k + 1)
                cr_data[k*32 +: 32] <= vb[cr_idx[k*5 +: 5]] ? cpy[cr_idx[k*5 +: 5]] : 32'd0;
    end
    /* verilator lint_on WIDTHEXPAND */

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; lc_pend <= 1'b0; pend <= {NPHYS{1'b0}}; widx <= 0;
            cap_v <= 1'b0; cap_vb <= 1'b0; cap_ln <= {LIW{1'b0}}; vb <= {CONST_WORDS{1'b0}};
            ld_cur <= {ADDR_W{1'b0}}; ld_left <= 0; ld_idx <= {CW{1'b0}}; ld_line <= 0;
            l_warp <= 0; l_grp <= 0; l_rd <= 7'd0; l_data <= 0; l_lanes <= 0; l_wr <= 1'b0;
            l_last <= 1'b0; l_sbe <= 0; l_cls <= 3'd0;
        end else begin
            if (lc_kick) lc_pend <= 1'b1;
            cap_v <= 1'b0;
            if (cap_v) l_data[cap_ln*32 +: 32] <= cap_vb ? ram_rd : 32'd0;
            // valid bits
`ifdef MUT_CB_NOINV
            if (1'b0) vb <= {CONST_WORDS{1'b0}};
`else
            if (inv) vb <= {CONST_WORDS{1'b0}};
`endif
            else if (a_we) vb[a_addr] <= 1'b1;
            case (st)
            S_IDLE: if (ld_go) begin
                lc_pend <= lc_kick;
                ld_cur  <= {lc_addr[ADDR_W-1:2], 2'b00};
                ld_left <= n_words;
                ld_idx  <= {CW{1'b0}};
                st <= (lc_region == 32'd0 && n_words != 0) ? S_LREQ : S_IDLE;
            end else if (take) begin
                l_warp <= x_warp; l_grp <= x_grp; l_rd <= x_uop[AD_UOP_RD +: 7];
                l_last <= x_last; l_sbe <= x_sbe; l_cls <= x_uop[AD_UOP_CLS +: 3];
                l_lanes <= t_pend; l_data <= {(NPHYS*32){1'b0}};
                l_wr <= x_uop[AD_UOP_WRD] && (|t_pend);
                pend <= t_pend; widx <= t_widx;
                st <= (t_pend == {NPHYS{1'b0}}) ? S_BEAT : S_ACC;
            end
            S_ACC: begin
                cap_v <= 1'b1; cap_ln <= al; cap_vb <= vb[al_w];
                pend <= pend_left;
                if (pend_left == {NPHYS{1'b0}}) st <= S_DRAIN;
            end
            S_DRAIN: st <= S_BEAT;
            S_BEAT: if (l_ready) st <= S_IDLE;
            S_LREQ: if (req_ready) st <= S_LWAIT;
            S_LWAIT: if (rsp_valid) begin
                ld_line <= rsp_rdata;
                st <= rsp_error ? S_IDLE : S_LFILL;
            end
            S_LFILL: begin
                ld_idx  <= ld_idx + 1'b1;
                ld_left <= ld_left - 1'b1;
                ld_cur  <= ld_cur + {{(ADDR_W-3){1'b0}}, 3'd4};
                if (ld_left == 1) st <= S_IDLE;
                else if (ld_off == {OW{1'b1}}) st <= S_LREQ;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

`ifdef FORMAL
    assign fv_st = st; assign fv_lc_pend = lc_pend; assign fv_ld_cur = ld_cur; assign fv_ld_left = ld_left;
    assign fv_ld_idx = ld_idx; assign fv_ld_line = ld_line; assign fv_lc = {lc_words, lc_addr, lc_region};
    /* verilator lint_off WIDTHEXPAND */
    assign fv_vb_i = vb[fv_i]; assign fv_cpy_i = cpy[fv_i];
    /* verilator lint_on WIDTHEXPAND */
`endif

    wire unused = &{1'b0, x_pc, x_info, x_b, x_c, rsp_write, rsp_tag, NWARPS[0], lc_addr[1:0], t_sum, b_unused, x_mask[2*NPHYS-1:NPHYS]};
endmodule
