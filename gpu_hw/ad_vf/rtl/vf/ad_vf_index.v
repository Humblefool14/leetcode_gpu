// ad_vf_index -- VF index stage (spec/gpu/vf/ad_vf_index.md).
// Walks FIRST..FIRST+COUNT-1 (non-indexed) or reads the index buffer (u16 / u32) line by line
// through the AMB (two line buffers, one request ahead, tag bit 0 = buffer), detects primitive
// restart and repeats the walk for INSTANCE_COUNT instances.  rsp_error stops the walk (DRAIN:
// busy until the requests in flight are answered).
// Children (rtl/vf/idx/): ad_vf_idx_walk (item and line counters), ad_vf_idx_extract,
// ad_vf_idx_restart.
`include "ad_vf_state.vh"
module ad_vf_index #(
    parameter ADDR_W     = 32,
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         st_we,
    input  wire [8:0]                   st_idx,
    input  wire [31:0]                  st_wdata,
    input  wire                         kick,
    output wire                         busy,
    output wire                         iv_valid,
    input  wire                         iv_ready,
    output wire [31:0]                  iv_index,
    output wire [31:0]                  iv_inst,
    output wire                         iv_restart,
    output wire                         iv_last,
    output reg                          req_valid,
    input  wire                         req_ready,
    output wire                         req_write,
    output reg  [ADDR_W-LINE_SHIFT-1:0] req_line,
    output wire [LINE_BYTES-1:0]        req_be,
    output wire [LINE_BYTES*8-1:0]      req_wdata,
    output reg  [7:0]                   req_tag,
    input  wire                         rsp_valid,
    input  wire                         rsp_write,
    input  wire [7:0]                   rsp_tag,
    input  wire [LINE_BYTES*8-1:0]      rsp_rdata,
    input  wire                         rsp_error
`ifdef AD_FV_IDX
    // formal visibility (formal/ad_vf_index)
    , output wire [1:0] fv_st, output wire [1:0] fv_bst0, output wire [1:0] fv_bst1, output wire fv_eptr,
    output wire fv_rptr, output wire fv_we_act, output wire [3:0] fv_we_n, output wire [3:0] fv_we_i,
    output wire fv_we_lastn, output wire fv_kidx, output wire fv_wr_act
`endif
);
    localparam LW = ADDR_W - LINE_SHIFT;
    // walk counter width: 32 (COUNT, INSTANCE_COUNT); formal/ad_vf_index's prove task narrows it
    // with AD_FV_IDX_CW under assumed small counts (identical behaviour there)
`ifdef AD_FV_IDX_CW
    localparam CW = `AD_FV_IDX_CW;
`else
    localparam CW = 32;
`endif
    assign req_write = 1'b0;
    assign req_be    = {LINE_BYTES{1'b0}};
    assign req_wdata = {LINE_BYTES*8{1'b0}};

    // ---------------- STATE snoop (VF range) ----------------
    reg [31:0] s_base, s_first, s_count, s_finst, s_icnt;
    reg [1:0]  s_fmt;
    reg        s_rst;
    always @(posedge clk) begin
        if (!rst_n) begin
            s_base <= 32'd0; s_first <= 32'd0; s_count <= 32'd0; s_finst <= 32'd0; s_icnt <= 32'd0;
            s_fmt <= 2'd0; s_rst <= 1'b0;
        end else if (st_we) begin
            if (st_idx == `AD_S_INDEX_BASE)     s_base  <= st_wdata;
            if (st_idx == `AD_S_INDEX_FORMAT)   s_fmt   <= st_wdata[1:0];
            if (st_idx == `AD_S_FIRST)          s_first <= st_wdata;
            if (st_idx == `AD_S_COUNT)          s_count <= st_wdata;
            if (st_idx == `AD_S_FIRST_INSTANCE) s_finst <= st_wdata;
            if (st_idx == `AD_S_INSTANCE_COUNT) s_icnt  <= st_wdata;
            if (st_idx == `AD_S_PRIM_RESTART)   s_rst   <= st_wdata[0];
        end
    end

    // ---------------- kick ----------------
    localparam S_IDLE = 2'd0, S_WALK = 2'd1, S_DRAIN = 2'd2;
    reg [1:0] st;
    assign busy = (st != S_IDLE);
    wire start = kick && (st == S_IDLE) && (s_count != 32'd0) && (s_icnt != 32'd0);

    wire              n_idx = (s_fmt != 2'd0);
    wire              n_u32 = s_fmt[1];                 // 2 u32, 3 reserved = u32
    wire [ADDR_W-1:0] n_sa  = s_base[ADDR_W-1:0] + (n_u32 ? {s_first[ADDR_W-3:0], 2'b00} : {s_first[ADDR_W-2:0], 1'b0});
    wire [ADDR_W-1:0] n_cm1 = s_count[ADDR_W-1:0] - 1'b1;
    wire [ADDR_W-1:0] n_ea  = n_sa + (n_u32 ? {n_cm1[ADDR_W-3:0], 2'b00} : {n_cm1[ADDR_W-2:0], 1'b0});
    wire [LW-1:0]     n_sl  = n_sa[ADDR_W-1:LINE_SHIFT];
    wire [LW-1:0]     n_nl  = n_ea[ADDR_W-1:LINE_SHIFT] - n_sl + 1'b1;   // lines per instance

    reg               k_idx, k_u32, k_rst;
    reg [31:0]        k_first;
    reg [ADDR_W-1:0]  k_sa;
    reg [LW-1:0]      k_sl;

    // ---------------- walks ----------------
    wire iv_fire = iv_valid && iv_ready;
    wire [CW-1:0] we_n, we_i, wr_n, wr_i; wire we_act, we_lastn, we_last, wr_act, wr_lastn, wr_last;
    ad_vf_idx_walk #(.W(CW)) u_we (.clk(clk), .rst_n(rst_n), .load(start), .cnt_n(s_count[CW-1:0]), .cnt_i(s_icnt[CW-1:0]),
        .step(iv_fire), .n(we_n), .i(we_i), .active(we_act), .last_n(we_lastn), .last(we_last));
    reg  issue;
    wire [31:0] n_nl32 = {{(32-LW){1'b0}}, n_nl};
    ad_vf_idx_walk #(.W(CW)) u_wr (.clk(clk), .rst_n(rst_n), .load(start && n_idx),
        .cnt_n(n_nl32[CW-1:0]), .cnt_i(s_icnt[CW-1:0]),
        .step(issue), .n(wr_n), .i(wr_i), .active(wr_act), .last_n(wr_lastn), .last(wr_last));

    // ---------------- line buffers ----------------
    localparam B_EMPTY = 2'd0, B_PEND = 2'd1, B_FULL = 2'd2;
    reg [1:0]              bst0, bst1;
    reg [LINE_BYTES*8-1:0] bdat0, bdat1;
    reg                    e_ptr, r_ptr;
    wire [1:0]             bst_e = e_ptr ? bst1 : bst0;
    wire [1:0]             bst_r = r_ptr ? bst1 : bst0;

    // ---------------- emission ----------------
    reg [31:0]       cur_val, cur_inst;
    reg [ADDR_W-1:0] cur_addr;
    wire [31:0] ext; wire rhit;
    ad_vf_idx_extract #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_ext (.line(e_ptr ? bdat1 : bdat0),
        .off(cur_addr[LINE_SHIFT-1:0]), .u32(k_u32), .idx(ext));
    ad_vf_idx_restart u_rst (.idx(ext), .u32(k_u32), .en(k_rst && k_idx), .hit(rhit));

    assign iv_valid   = (st == S_WALK) && we_act && (!k_idx || bst_e == B_FULL);
    assign iv_index   = k_idx ? ext : cur_val;
    assign iv_inst    = cur_inst;
    assign iv_restart = rhit;
    assign iv_last    = we_last;
    wire [LINE_SHIFT-1:0] off_l4 = LINE_BYTES - 4, off_l2 = LINE_BYTES - 2;
    wire [LINE_SHIFT-1:0] off_lastidx = k_u32 ? off_l4 : off_l2;     // offset of a line's last index
    wire line_done = we_lastn || (cur_addr[LINE_SHIFT-1:0] == off_lastidx);
    wire npend = (bst0 == B_PEND) || (bst1 == B_PEND);

    // the line address advances when the request is taken: remember whether it was an instance's
    // last line
    reg wr_lastn_q;
    always @(posedge clk) if (!rst_n) wr_lastn_q <= 1'b0; else if (issue) wr_lastn_q <= wr_lastn;

    always @(*) issue = (st == S_WALK) && k_idx && wr_act && !req_valid && (bst_r == B_EMPTY) &&
                        !(rsp_valid && rsp_error);

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; k_idx <= 1'b0; k_u32 <= 1'b0; k_rst <= 1'b0; k_first <= 32'd0;
            k_sa <= {ADDR_W{1'b0}}; k_sl <= {LW{1'b0}};
            cur_val <= 32'd0; cur_inst <= 32'd0; cur_addr <= {ADDR_W{1'b0}};
            bst0 <= B_EMPTY; bst1 <= B_EMPTY; e_ptr <= 1'b0; r_ptr <= 1'b0;
            req_valid <= 1'b0; req_line <= {LW{1'b0}}; req_tag <= 8'd0;
        end else begin
            if (start) begin
                st <= S_WALK; k_idx <= n_idx; k_u32 <= n_u32; k_rst <= s_rst; k_first <= s_first;
                k_sa <= n_sa; k_sl <= n_sl;
                cur_val <= s_first; cur_inst <= s_finst; cur_addr <= n_sa;
                bst0 <= B_EMPTY; bst1 <= B_EMPTY; e_ptr <= 1'b0; r_ptr <= 1'b0;
                req_line <= n_sl;
            end
            // requests: one line ahead into the empty buffer
            if (req_valid && req_ready) req_valid <= 1'b0;
            if (issue) begin
                req_valid <= 1'b1; req_tag <= {7'd0, r_ptr};
                if (r_ptr) bst1 <= B_PEND; else bst0 <= B_PEND;
                r_ptr <= ~r_ptr;
            end
            if (req_valid && req_ready) req_line <= wr_lastn_q ? k_sl : req_line + 1'b1;
            // responses
            if (rsp_valid && !rsp_write) begin
                if (rsp_tag[0]) begin bst1 <= B_FULL; bdat1 <= rsp_rdata; end
                else            begin bst0 <= B_FULL; bdat0 <= rsp_rdata; end
                if (rsp_error && st != S_IDLE) st <= S_DRAIN;
            end
            // emission
            if (iv_fire) begin
                if (we_lastn) begin cur_val <= k_first; cur_addr <= k_sa; cur_inst <= cur_inst + 1'b1; end
                else begin cur_val <= cur_val + 1'b1; cur_addr <= cur_addr + (k_u32 ? 3'd4 : 3'd2); end
                if (k_idx && line_done) begin
                    if (e_ptr) bst1 <= B_EMPTY; else bst0 <= B_EMPTY;
                    e_ptr <= ~e_ptr;
                end
                if (we_last) st <= S_IDLE;
            end
            if (st == S_DRAIN && !npend && !req_valid && !(rsp_valid && !rsp_write)) st <= S_IDLE;
        end
    end
`ifdef AD_FV_IDX
    assign fv_st = st; assign fv_bst0 = bst0; assign fv_bst1 = bst1; assign fv_eptr = e_ptr; assign fv_rptr = r_ptr;
    assign fv_we_act = we_act; assign fv_we_n = we_n[3:0]; assign fv_we_i = we_i[3:0]; assign fv_we_lastn = we_lastn;
    assign fv_kidx = k_idx; assign fv_wr_act = wr_act;
`endif
endmodule
