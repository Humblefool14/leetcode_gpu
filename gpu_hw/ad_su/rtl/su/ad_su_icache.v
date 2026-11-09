// ad_su_icache -- the SU's instruction cache (spec ad_su_icache.md).
// IC_BYTES direct-mapped, LINE_BYTES lines, blocking (one miss at a time).
// Tags and valid bits in registers: the hit is known at the request, so in
// IDLE ic_ready = hit and the instruction comes one cycle later from the
// line-wide data RAM (registered read).  A miss (ic_ready 0) goes
// MREQ (req_valid until req_ready) -> MWAIT (rsp_valid) -> RESP; the fill is
// written into the RAM and tags unless it answered rsp_error or an inv came
// since the miss started (or with the response); RESP takes the waiting
// request (ic_ready 1 for an address in the filled line) and answers it the
// next cycle from the fill buffer (instruction 0 after rsp_error).  inv clears every valid bit (flash clear).
module ad_su_icache #(
    parameter ADDR_W     = 32,
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5,
    parameter IC_BYTES   = 2048
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         ic_req,
    output wire                         ic_ready,
    input  wire [31:0]                  ic_addr,
    output reg                          ic_rvalid,
    output wire [63:0]                  ic_rdata,
    input  wire                         inv,
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
);
    localparam NLINES = IC_BYTES / LINE_BYTES;
    localparam IDX_W  = (NLINES > 1) ? $clog2(NLINES) : 1;
    localparam IC_SH  = $clog2(IC_BYTES);
    localparam TAG_W  = 32 - IC_SH;
    localparam WPL    = LINE_BYTES / 8;               // instructions per line
    localparam OFF_W  = (WPL > 1) ? $clog2(WPL) : 1;
    localparam LW     = LINE_BYTES * 8;

    localparam [1:0] S_IDLE = 2'd0, S_MREQ = 2'd1, S_MWAIT = 2'd2, S_RESP = 2'd3;

    reg [1:0]        st;
    reg [NLINES-1:0] vld;
    reg [TAG_W-1:0]  tags [0:NLINES-1];
    reg [LW-1:0]     ram  [0:NLINES-1];
    reg [31:0]       maddr;        // the missing request's address
    reg              minv;         // inv since the miss started
    reg [LW-1:0]     fbuf;         // fill buffer
    reg              ferr;
    reg [LW-1:0]     rline;        // RAM read of the last accepted hit
    reg [OFF_W-1:0]  roff;
    reg              rfill;        // the answer comes from the fill buffer

    wire [IDX_W-1:0] idx  = ic_addr[LINE_SHIFT +: IDX_W];
    wire [TAG_W-1:0] tagi = ic_addr[31:IC_SH];
    wire             hit  = vld[idx] && tags[idx] == tagi;
    wire [OFF_W-1:0] off  = (WPL > 1) ? ic_addr[3 +: OFF_W] : {OFF_W{1'b0}};

    assign ic_ready = (st == S_IDLE && hit) || (st == S_RESP && ic_addr[31:LINE_SHIFT] == maddr[31:LINE_SHIFT]);
    wire   take     = ic_req && ic_ready;

    // AMB client port: reads only, one outstanding, tag 0
    assign req_valid = st == S_MREQ;
    assign req_write = 1'b0;
    assign req_line  = maddr[ADDR_W-1:LINE_SHIFT];
    assign req_be    = {LINE_BYTES{1'b0}};
    assign req_wdata = {LW{1'b0}};
    assign req_tag   = 8'd0;

    wire [IDX_W-1:0] midx = maddr[LINE_SHIFT +: IDX_W];
    wire fill = st == S_MWAIT && rsp_valid;
`ifdef MUT_IC_INV_KEEP
    wire keep = fill && !rsp_error;                  // mutation: keeps a fill during inv
`else
    wire keep = fill && !rsp_error && !minv && !inv;
`endif

    always @(posedge clk) begin
        if (keep) begin
            ram[midx]  <= rsp_rdata;
            tags[midx] <= maddr[31:IC_SH];
        end
        if (take && st == S_IDLE) rline <= ram[idx];
        if (take) roff <= off;
        if (fill) begin fbuf <= rsp_rdata; ferr <= rsp_error; end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            vld       <= {NLINES{1'b0}};
            minv      <= 1'b0;
            ic_rvalid <= 1'b0;
            rfill     <= 1'b0;
            maddr     <= 32'd0;
        end else begin
            ic_rvalid <= take;
            if (take) rfill <= st == S_RESP;
            case (st)
            S_IDLE: if (ic_req && !hit) begin
                st <= S_MREQ; maddr <= ic_addr; minv <= 1'b0;
            end
            S_MREQ:  if (req_ready) st <= S_MWAIT;
            S_MWAIT: if (rsp_valid) st <= S_RESP;
            default: st <= S_IDLE;            // S_RESP: the waiting request is taken
            endcase
            if (inv) minv <= 1'b1;
            if (inv) vld <= {NLINES{1'b0}};
            else if (keep) vld[midx] <= 1'b1;
        end
    end

    wire [LW-1:0] src = rfill ? (ferr ? {LW{1'b0}} : fbuf) : rline;
    generate if (WPL > 1) begin : g_sel
        assign ic_rdata = src[roff*64 +: 64];
    end else begin : g_one
        assign ic_rdata = src[63:0];
    end endgenerate

`ifdef AD_IC_FV
    // ---- formal (formal/ad_su_icache; enabled by AD_IC_FV only): for a
    // symbolic line fv_L the memory always answers fv_D without error; every
    // answer to a request in fv_L must be (the word of) fv_D.  Helper
    // invariants: a valid cache line tagged fv_L, the fill buffer of an fv_L
    // fill and the RAM read of an fv_L hit hold fv_D.
    (* anyconst *) reg [31-LINE_SHIFT:0] fv_L;
    (* anyconst *) reg [LW-1:0]          fv_D;
    reg [31:0] fv_ta;
    always @(posedge clk) if (take) fv_ta <= ic_addr;
    wire [LW-1:0] fv_rl = ram[fv_L[IDX_W-1:0]];
    wire [OFF_W-1:0] fv_off = (WPL > 1) ? fv_ta[3 +: OFF_W] : {OFF_W{1'b0}};
    wire [LW-1:0] fv_sh = fv_D >> (fv_off * 64);
    always @(*) if (rst_n) begin
        if (st == S_MWAIT && rsp_valid && maddr[31:LINE_SHIFT] == fv_L) assume (rsp_rdata == fv_D && !rsp_error);
        if (ic_rvalid && fv_ta[31:LINE_SHIFT] == fv_L) a_hit_data: assert (ic_rdata == fv_sh[63:0]);
        if (vld[fv_L[IDX_W-1:0]] && tags[fv_L[IDX_W-1:0]] == fv_L[31-LINE_SHIFT:IDX_W]) assert (fv_rl == fv_D);
        if (ic_rvalid && rfill && fv_ta[31:LINE_SHIFT] == fv_L) assert (fbuf == fv_D && !ferr);
        if (st == S_RESP && maddr[31:LINE_SHIFT] == fv_L) assert (fbuf == fv_D && !ferr);
        if (ic_rvalid && !rfill && fv_ta[31:LINE_SHIFT] == fv_L) assert (rline == fv_D);
        if (ic_rvalid) assert (roff == fv_off);
    end
    // inv forces a miss: after inv, until a line requested after it is
    // filled, no request is a hit (helpers: no valid line meanwhile; a miss
    // waiting without an inv since it began was requested after the last inv)
    reg fv_after, fv_since;
    always @(posedge clk) begin
        if (!rst_n) begin fv_after <= 1'b0; fv_since <= 1'b0; end
        else begin
            if (req_valid && req_ready && !inv) fv_after <= 1'b1;
            else if (inv) fv_after <= 1'b0;
            if (inv) fv_since <= 1'b1;
            else if (fill && fv_after) fv_since <= 1'b0;
        end
    end
    always @(*) if (rst_n) begin
        if (fv_since && st == S_IDLE) a_inv_miss: assert (!hit);
        if (fv_since) assert (vld == {NLINES{1'b0}});
        if (st == S_MWAIT && !minv) assert (fv_after);
        if (keep) a_keep: assert (!minv && !inv);
    end
`endif

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{1'b0, rsp_write, rsp_tag, maddr[LINE_SHIFT-1:0], roff};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
