// ad_amb_mux -- N AMB client ports -> 1 AMB port (common library; spec spec/common/ad_amb_mux.md; the
// "am_amb_mux" of ad_rop.md: requester 0 = ds, requester 1 = wb).
//
// Requests: round-robin among the valid requesters (priority to the one after the last
// granted), through the common arbiters rr_pick and rec_arbiter (rtl/common/arb/).  The granted request is presented downstream with req_tag replaced by an
// internal tag (index of a free entry of a 2^TBL_LOG2-entry table recording {requester,
// client tag}).  Once presented and not taken, grant, payload and internal tag are held
// until m_req_ready (no switching mid-request).  No free entry -> no new request is
// presented (c_req_ready all 0).  c_req_ready[i] = m_req_ready while i is presented.
// Responses: m_rsp_tag selects the entry; the response goes to that requester only
// (c_rsp_valid one-hot) with its original tag, and the entry is freed.  Payload (write,
// rdata, error) is shared by all clients.  A response with a tag of no live entry is dropped.
module ad_amb_mux #(
    parameter ADDR_W     = 32,
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5,
    parameter N          = 2,
    parameter TBL_LOG2   = 4           // table entries = 2^TBL_LOG2 (1..7)
) (
    input  wire                                clk,
    input  wire                                rst_n,
    // client ports
    input  wire [N-1:0]                        c_req_valid,
    output wire [N-1:0]                        c_req_ready,
    input  wire [N-1:0]                        c_req_write,
    input  wire [N*(ADDR_W-LINE_SHIFT)-1:0]    c_req_line,
    input  wire [N*LINE_BYTES-1:0]             c_req_be,
    input  wire [N*LINE_BYTES*8-1:0]           c_req_wdata,
    input  wire [N*8-1:0]                      c_req_tag,
    output wire [N-1:0]                        c_rsp_valid,
    output wire                                c_rsp_write,
    output wire [7:0]                          c_rsp_tag,
    output wire [LINE_BYTES*8-1:0]             c_rsp_rdata,
    output wire                                c_rsp_error,
    // memory-side port
    output wire                                m_req_valid,
    input  wire                                m_req_ready,
    output wire                                m_req_write,
    output wire [ADDR_W-LINE_SHIFT-1:0]        m_req_line,
    output wire [LINE_BYTES-1:0]               m_req_be,
    output wire [LINE_BYTES*8-1:0]             m_req_wdata,
    output wire [7:0]                          m_req_tag,
    input  wire                                m_rsp_valid,
    input  wire                                m_rsp_write,
    input  wire [7:0]                          m_rsp_tag,
    input  wire [LINE_BYTES*8-1:0]             m_rsp_rdata,
    input  wire                                m_rsp_error
`ifdef AD_FV_MUX
    // formal-only observation ports (not part of the spec interface)
    ,output wire [(1<<TBL_LOG2)-1:0]             fv_ent_v
    ,output wire [(1<<TBL_LOG2)*((N>1)?$clog2(N):1)-1:0] fv_ent_req
    ,output wire [(1<<TBL_LOG2)*8-1:0]           fv_ent_tag
    ,output wire                                 fv_lock
    ,output wire [((N>1)?$clog2(N):1)-1:0]       fv_lock_req
    ,output wire [TBL_LOG2-1:0]                  fv_lock_idx
`endif
);
    localparam LW = ADDR_W - LINE_SHIFT;
    localparam LB = LINE_BYTES * 8;
    localparam T  = 1 << TBL_LOG2;
    localparam RW = (N > 1) ? $clog2(N) : 1;
    localparam integer LASTI = N - 1;

    // ---- tag table ----
    reg  [T-1:0]  ent_v;
    reg  [RW-1:0] ent_req [0:T-1];       // datapath, qualified by ent_v
    reg  [7:0]    ent_tag [0:T-1];

    // lowest free entry: common fixed-priority arbiter (rtl/common/arb/rec_arbiter.sv)
    wire                any_free;
    wire [TBL_LOG2-1:0] free_idx;
    wire [T-1:0]        free_oh;
    rec_arbiter #(.N(T)) u_free (.req(~ent_v), .grant_onehot(free_oh), .grant_index(free_idx),
                                 .grant_valid(any_free));

    // ---- arbitration ----
    reg               lock;               // a request is presented and not yet taken
    reg  [RW-1:0]     lock_req;
    reg  [TBL_LOG2-1:0] lock_idx;
    reg  [RW-1:0]     rr_last;            // last granted requester

    // round-robin: the first valid requester after rr_last (common rr_pick, ptr = rr_last + 1)
`ifdef MUT_MUX_FIXPRI
    wire [RW-1:0]     rr_ptr = {RW{1'b0}};                  // mutation: fixed priority (0 first)
`else
    wire [RW-1:0]     rr_ptr = (rr_last == LASTI[RW-1:0]) ? {RW{1'b0}} : rr_last + 1'b1;
`endif
    wire              rr_any;
    wire [RW-1:0]     rr_pick;
    wire [N-1:0]      rr_oh;
    rr_pick #(.N(N)) u_rr (.req(c_req_valid), .ptr(rr_ptr), .grant_onehot(rr_oh),
                           .grant_index(rr_pick), .grant_valid(rr_any));

    wire [RW-1:0]       g   = lock ? lock_req : rr_pick;
    wire [TBL_LOG2-1:0] idx = lock ? lock_idx : free_idx;
`ifdef MUT_MUX_NOLOCK
    assign m_req_valid = rr_any && any_free;              // mutation: may switch mid-request
    wire [RW-1:0] gs = rr_pick;
    wire [TBL_LOG2-1:0] is = free_idx;
`else
    assign m_req_valid = lock || (rr_any && any_free);
    wire [RW-1:0] gs = g;
    wire [TBL_LOG2-1:0] is = idx;
`endif
    assign m_req_write = c_req_write[gs];
    assign m_req_line  = c_req_line[gs*LW +: LW];
    assign m_req_be    = c_req_be[gs*LINE_BYTES +: LINE_BYTES];
    assign m_req_wdata = c_req_wdata[gs*LB +: LB];
    assign m_req_tag   = {{(8-TBL_LOG2){1'b0}}, is};
    wire m_fire = m_req_valid && m_req_ready;

    genvar gi;
    generate for (gi = 0; gi < N; gi = gi + 1) begin : g_c
        assign c_req_ready[gi] = m_req_valid && m_req_ready && (gs == gi);
    end endgenerate

    // ---- responses ----
    wire [TBL_LOG2-1:0] r_idx  = m_rsp_tag[TBL_LOG2-1:0];
    wire                r_live = m_rsp_valid && (m_rsp_tag[7:TBL_LOG2] == 0) && ent_v[r_idx];
    generate for (gi = 0; gi < N; gi = gi + 1) begin : g_r
        assign c_rsp_valid[gi] = r_live && (ent_req[r_idx] == gi);
    end endgenerate
    assign c_rsp_tag   = ent_tag[r_idx];
    assign c_rsp_write = m_rsp_write;
    assign c_rsp_rdata = m_rsp_rdata;
    assign c_rsp_error = m_rsp_error;

`ifdef AD_FV_MUX
    assign fv_ent_v = ent_v; assign fv_lock = lock; assign fv_lock_req = lock_req; assign fv_lock_idx = lock_idx;
    generate for (gi = 0; gi < T; gi = gi + 1) begin : g_fv
        assign fv_ent_req[gi*RW +: RW] = ent_req[gi];
        assign fv_ent_tag[gi*8 +: 8]   = ent_tag[gi];
    end endgenerate
`endif

    always @(posedge clk) begin
        if (!rst_n) begin
            ent_v <= {T{1'b0}}; lock <= 1'b0; lock_req <= {RW{1'b0}}; lock_idx <= {TBL_LOG2{1'b0}};
            rr_last <= LASTI[RW-1:0];
        end else begin
            if (r_live) ent_v[r_idx] <= 1'b0;
            if (m_fire) begin
                ent_v[is]   <= 1'b1;
                ent_req[is] <= gs;
                ent_tag[is] <= c_req_tag[gs*8 +: 8];
                rr_last     <= gs;
                lock        <= 1'b0;
            end else if (m_req_valid) begin
                lock <= 1'b1; lock_req <= gs; lock_idx <= is;
            end
        end
    end
endmodule
