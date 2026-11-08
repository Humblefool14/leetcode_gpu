// ad_su_dcache -- the SU's data cache (spec/gpu/su/ad_su_dcache.md).
// DC_BYTES direct-mapped, LINE_BYTES lines, read-allocate, write-through,
// flash-invalidated.  One request at a time (u_req_ready only when idle).
// Read hit: answered the cycle after it is taken.  Read miss: one line read
// from the MC, filled (not when `inv` came during the miss or the MC answered
// an error), answered with the MC's data and error.  Write: through to the MC
// with the byte enables; when the MC answers (without error) and the line is
// present, the bytes are merged into it; answered after the MC's response.
// As the next request is taken only after the MC answered, a read never
// overtakes an earlier write to the same line (also with a memory whose reads
// may overtake writes).  The data are read synchronously (block RAM): the
// request's line is read in the cycle it is taken.
module ad_su_dcache #(
    parameter ADDR_W     = 32,
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5,
    parameter DC_BYTES   = 1024
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         inv,
    // upstream (from ad_su_lsu)
    input  wire                         u_req_valid,
    output wire                         u_req_ready,
    input  wire                         u_req_write,
    input  wire [ADDR_W-LINE_SHIFT-1:0] u_req_line,
    input  wire [LINE_BYTES-1:0]        u_req_be,
    input  wire [LINE_BYTES*8-1:0]      u_req_wdata,
    input  wire [7:0]                   u_req_tag,
    output wire                         u_rsp_valid,
    output wire                         u_rsp_write,
    output wire [7:0]                   u_rsp_tag,
    output wire [LINE_BYTES*8-1:0]      u_rsp_rdata,
    output wire                         u_rsp_error,
    // downstream (to the MC)
    output wire                         m_req_valid,
    input  wire                         m_req_ready,
    output wire                         m_req_write,
    output wire [ADDR_W-LINE_SHIFT-1:0] m_req_line,
    output wire [LINE_BYTES-1:0]        m_req_be,
    output wire [LINE_BYTES*8-1:0]      m_req_wdata,
    output wire [7:0]                   m_req_tag,
    input  wire                         m_rsp_valid,
    input  wire                         m_rsp_write,
    input  wire [7:0]                   m_rsp_tag,
    input  wire [LINE_BYTES*8-1:0]      m_rsp_rdata,
    input  wire                         m_rsp_error
`ifdef FORMAL
    ,
    // formal only (harness invariants): state, valid bits, the request's line
    // as read, and the line and tag at index fv_idx
    output wire [2:0]                   fv_st,
    output wire                         fv_drop,
    output wire [DC_BYTES/LINE_BYTES-1:0] fv_vld,
    output wire [LINE_BYTES*8-1:0]      fv_rdl,
    input  wire [((DC_BYTES/LINE_BYTES > 1) ? $clog2(DC_BYTES/LINE_BYTES) : 1)-1:0] fv_idx,
    output wire [LINE_BYTES*8-1:0]      fv_data,
    output wire [ADDR_W-LINE_SHIFT-1:0] fv_tag
`endif
);
    localparam NL  = DC_BYTES / LINE_BYTES;
    localparam IW  = (NL > 1) ? $clog2(NL) : 1;
    localparam LW  = ADDR_W - LINE_SHIFT;
    localparam TW  = (LW > IW) ? LW - IW : 1;
    localparam DW  = LINE_BYTES * 8;
    localparam [2:0] S_IDLE = 3'd0, S_HIT = 3'd1, S_MREQ = 3'd2, S_MWAIT = 3'd3;

    reg [DW-1:0] data [0:NL-1];
    reg [TW-1:0] tags [0:NL-1];
    reg [NL-1:0] vld;

    reg [2:0]           st;
    reg                 q_write, q_drop;
    reg [LW-1:0]        q_line;
    reg [LINE_BYTES-1:0] q_be;
    reg [DW-1:0]        q_wdata;
    reg [7:0]           q_tag;
    reg [DW-1:0]        rd_line;    // the request's line, read when it is taken

    wire [IW-1:0] u_idx = (NL > 1) ? u_req_line[IW-1:0] : {IW{1'b0}};
    wire [TW-1:0] u_tg  = (LW > IW) ? u_req_line[LW-1 -: TW] : {TW{1'b0}};
    wire [IW-1:0] q_idx = (NL > 1) ? q_line[IW-1:0] : {IW{1'b0}};
    wire [TW-1:0] q_tg  = (LW > IW) ? q_line[LW-1 -: TW] : {TW{1'b0}};

    wire take   = u_req_valid && u_req_ready;
    wire u_hit  = vld[u_idx] && (tags[u_idx] == u_tg);
    wire q_pres = vld[q_idx] && (tags[q_idx] == q_tg);

    // merged line of a write
    reg [DW-1:0] merged;
    integer b;
    always @(*) begin
        for (b = 0; b < LINE_BYTES; b = b + 1)
`ifdef MUT_DC_MERGE
            merged[8*b +: 8] = q_wdata[8*b +: 8];      // mutation: byte enables ignored
`else
            merged[8*b +: 8] = q_be[b] ? q_wdata[8*b +: 8] : rd_line[8*b +: 8];
`endif
    end

    assign u_req_ready = (st == S_IDLE);
    assign m_req_valid = (st == S_MREQ);
    assign m_req_write = q_write;
    assign m_req_line  = q_line;
    assign m_req_be    = q_write ? q_be : {LINE_BYTES{1'b0}};
    assign m_req_wdata = q_write ? q_wdata : {DW{1'b0}};
    assign m_req_tag   = 8'd0;

    wire m_done = (st == S_MWAIT) && m_rsp_valid;
    assign u_rsp_valid = (st == S_HIT) || m_done;
    assign u_rsp_write = q_write;
    assign u_rsp_tag   = q_tag;
    assign u_rsp_rdata = (st == S_HIT) ? rd_line : m_rsp_rdata;
    assign u_rsp_error = (st == S_HIT) ? 1'b0 : m_rsp_error;

    // fill / merge write of the data array
`ifdef MUT_DC_FILL_AFTER_INV
    wire fill_keep = !m_rsp_error;
`else
    wire fill_keep = !m_rsp_error && !q_drop && !inv;
`endif
    wire d_we  = m_done && (q_write ? (q_pres && !m_rsp_error && !inv) : fill_keep);
    wire [DW-1:0] d_wd = q_write ? merged : m_rsp_rdata;

    always @(posedge clk) begin
        if (take) rd_line <= data[u_idx];
        if (d_we) data[q_idx] <= d_wd;
    end

    always @(posedge clk) begin
        if (d_we && !q_write) tags[q_idx] <= q_tg;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; vld <= {NL{1'b0}}; q_write <= 1'b0; q_drop <= 1'b0;
            q_line <= {LW{1'b0}}; q_be <= {LINE_BYTES{1'b0}}; q_wdata <= {DW{1'b0}}; q_tag <= 8'd0;
        end else begin
            case (st)
            S_IDLE: if (take) begin
                q_write <= u_req_write; q_line <= u_req_line; q_be <= u_req_be;
                q_wdata <= u_req_wdata; q_tag <= u_req_tag; q_drop <= 1'b0;
                st <= (!u_req_write && u_hit && !inv) ? S_HIT : S_MREQ;
            end
            S_HIT: st <= S_IDLE;
            S_MREQ: begin
                if (inv) q_drop <= 1'b1;
                if (m_req_ready) st <= S_MWAIT;
            end
            S_MWAIT: begin
                if (inv) q_drop <= 1'b1;
                if (m_rsp_valid) st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
            if (inv) vld <= {NL{1'b0}};
            else if (d_we && !q_write) vld[q_idx] <= 1'b1;
        end
    end

`ifdef FORMAL
    assign fv_st = st; assign fv_drop = q_drop; assign fv_vld = vld; assign fv_rdl = rd_line;
    assign fv_data = data[fv_idx];
    assign fv_tag = {{(LW-TW){1'b0}}, tags[fv_idx]};
`endif

    wire unused = &{1'b0, m_rsp_write, m_rsp_tag};
endmodule
