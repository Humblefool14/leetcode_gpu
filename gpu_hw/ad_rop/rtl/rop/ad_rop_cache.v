// ad_rop_cache -- 4-way set-associative write-back L1 tile cache (spec/gpu/rop/ad_rop_cache.md).
//
// Request side: accepted when req_valid && req_ready (req_ready = idle and no flush).
//   hit : read  -> data RAM read this cycle, rsp_valid/rsp_rdata the next cycle;
//         write -> byte-enabled RAM write this cycle, dirty set, rsp_valid pulse next cycle
//         (rsp_rdata of a write response is not meaningful).  1 request/cycle on hits.
//   miss: write-allocate.  MISS (pick victim: lowest invalid way, else tree-PLRU) ->
//         [EVICT: write the dirty victim line, mem_req_write=1, full line] ->
//         REFILL_REQ (mem_req_write=0) -> REFILL_WAIT (mem_rsp_valid: line written into
//         the victim way, tag/valid set, clean) -> REPLAY (the request performed as a hit)
//         -> IDLE; rsp_valid the cycle after REPLAY.  No request is taken meanwhile.
// flush: (pulse; remembered while busy) scans every {set, way} and writes back each dirty
//   line (lines stay valid, become clean).  busy = not IDLE.
// Memory side: mem_req_* held until mem_req_ready.  mem_rsp_valid carries the data of the
//   (single outstanding) refill read; writes get no response here (the integrator drops
//   AMB write responses).  Requires WAYS == 4 (3-bit tree PLRU).
module ad_rop_cache #(
    parameter LINE_BYTES = 64,
    parameter WAYS       = 4,
    parameter SETS_LOG2  = 5
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         req_valid,
    output wire                         req_ready,
    input  wire                         req_write,
    input  wire [31:0]                  req_addr,
    input  wire [LINE_BYTES-1:0]        req_be,
    input  wire [LINE_BYTES*8-1:0]      req_wdata,
    output reg                          rsp_valid,
    output wire [LINE_BYTES*8-1:0]      rsp_rdata,
    output wire                         mem_req_valid,
    input  wire                         mem_req_ready,
    output wire                         mem_req_write,
    output wire [31-$clog2(LINE_BYTES):0] mem_req_line,
    output wire [LINE_BYTES*8-1:0]      mem_req_wdata,
    input  wire                         mem_rsp_valid,
    input  wire [LINE_BYTES*8-1:0]      mem_rsp_rdata,
    input  wire                         flush,
    output wire                         busy
`ifdef AD_FV_CACHE
    // formal-only observation ports (not part of the spec interface)
    ,output wire [3:0]                                  fv_state
    ,output wire [(1<<SETS_LOG2)*WAYS-1:0]               fv_valid
    ,output wire [(1<<SETS_LOG2)*WAYS-1:0]               fv_dirty
    ,output wire [(1<<SETS_LOG2)*WAYS*(32-$clog2(LINE_BYTES)-SETS_LOG2)-1:0] fv_tags
    ,output wire [(1<<SETS_LOG2)*WAYS*LINE_BYTES*8-1:0]  fv_ram
    ,output wire [31:0]                                 fv_q_addr
    ,output wire                                        fv_q_write
    ,output wire [1:0]                                  fv_vway
    ,output wire [SETS_LOG2+1:0]                        fv_fl_idx
    ,output wire [LINE_BYTES-1:0]                       fv_q_be
    ,output wire [LINE_BYTES*8-1:0]                     fv_q_wdata
`endif
);
    localparam LS   = $clog2(LINE_BYTES);
    localparam SL   = SETS_LOG2;
    localparam SETS = 1 << SL;
    localparam TW   = 32 - LS - SL;
    localparam NE   = SETS * WAYS;       // entries {set, way}; WAYS must be 4
    localparam EW   = SL + 2;
    localparam LB   = LINE_BYTES * 8;

    localparam [3:0] S_IDLE = 4'd0, S_MISS = 4'd1, S_EVICT = 4'd2, S_RREQ = 4'd3,
                     S_RWAIT = 4'd4, S_REPLAY = 4'd5, S_FSCAN = 4'd6, S_FWB = 4'd7;

    reg  [3:0]          state;
    reg  [NE-1:0]       valid, dirty;
    reg  [3*SETS-1:0]   plru;
    reg  [TW-1:0]       tag_mem [0:NE-1];     // datapath, qualified by valid
    reg  [31:0]         q_addr;               // latched missing request
    reg                 q_write;
    reg  [LINE_BYTES-1:0] q_be;
    reg  [LB-1:0]       q_wdata;
    reg  [1:0]          vway;
    reg  [EW-1:0]       fl_idx;
    reg                 flush_pend;

    wire idle = (state == S_IDLE);
    assign busy      = !idle;
    assign req_ready = idle && !flush && !flush_pend;
    wire accept = req_valid && req_ready;

    // ---- lookup (request in IDLE, latched request otherwise) ----
    wire [31:0]   c_addr = idle ? req_addr : q_addr;
    wire [SL-1:0] c_set  = c_addr[LS +: SL];
    wire [TW-1:0] c_tag  = c_addr[31 -: TW];
    wire [4*TW-1:0] set_tags = {tag_mem[{c_set, 2'd3}], tag_mem[{c_set, 2'd2}],
                                tag_mem[{c_set, 2'd1}], tag_mem[{c_set, 2'd0}]};
    wire [3:0] set_valid = valid[{c_set, 2'd0} +: 4];
    wire [3:0] set_dirty = dirty[{c_set, 2'd0} +: 4];
    wire [2:0] set_plru  = plru[3*c_set +: 3];
    wire       hit;
    wire [1:0] hit_way;
    ad_cache_tagmatch #(.WAYS(4), .TAG_W(TW), .WW(2)) u_tm (.tags(set_tags), .valid(set_valid),
        .key(c_tag), .hit(hit), .way(hit_way));

    // ---- replacement ----
    wire [1:0] plru_victim;
    wire       touch     = (accept && hit) || (state == S_REPLAY);
    wire [1:0] touch_way = idle ? hit_way : vway;
    wire [2:0] plru_next;
    ad_cache_plru u_plru (.state(set_plru), .touch(touch), .touch_way(touch_way),
        .next_state(plru_next), .victim(plru_victim));
    wire [1:0] victim = !set_valid[0] ? 2'd0 : !set_valid[1] ? 2'd1 :
                        !set_valid[2] ? 2'd2 : !set_valid[3] ? 2'd3 : plru_victim;
    wire [EW-1:0] q_ent = {c_set, vway};       // valid outside IDLE (c_set = latched set)
    wire          v_dirty = set_valid[victim] && set_dirty[victim];
    wire          f_dirty = valid[fl_idx] && dirty[fl_idx];
    wire          f_last  = (fl_idx == NE - 1);

    // ---- data RAM port ----
    reg  [EW-1:0]         ram_addr;
    reg                   ram_re;
    reg  [LINE_BYTES-1:0] ram_we;
    reg  [LB-1:0]         ram_wdata;
    always @(*) begin
        ram_addr  = {c_set, hit_way};
        ram_re    = 1'b0;
        ram_we    = {LINE_BYTES{1'b0}};
        ram_wdata = req_wdata;
        case (state)
            S_IDLE:   if (accept && hit) begin
                          if (req_write) ram_we = req_be; else ram_re = 1'b1;
                      end
            S_MISS:   begin ram_addr = {c_set, victim}; ram_re = v_dirty; end
            S_RWAIT:  begin ram_addr = q_ent; ram_wdata = mem_rsp_rdata;
                            if (mem_rsp_valid) ram_we = {LINE_BYTES{1'b1}}; end
            S_REPLAY: begin ram_addr = q_ent; ram_wdata = q_wdata;
                            if (q_write) ram_we = q_be; else ram_re = 1'b1; end
            S_FSCAN:  begin ram_addr = fl_idx; ram_re = f_dirty; end
            default:  ram_addr = q_ent;
        endcase
    end
    wire [LB-1:0] ram_rdata;
`ifdef AD_FV_CACHE
    wire [NE*LB-1:0] ram_fv;
`endif
    ad_ram_sp_be #(.DEPTH(NE), .AW(EW), .NBYTES(LINE_BYTES)) u_ram (.clk(clk), .addr(ram_addr),
        .re(ram_re), .we(ram_we), .wdata(ram_wdata), .rdata(ram_rdata)
`ifdef AD_FV_CACHE
        , .fv_mem(ram_fv)
`endif
        );
    assign rsp_rdata = ram_rdata;

    // ---- memory request (payload from state + held registers; RAM output holds) ----
    assign mem_req_valid = (state == S_EVICT) || (state == S_RREQ) || (state == S_FWB);
    assign mem_req_write = (state == S_EVICT) || (state == S_FWB);
    assign mem_req_line  = (state == S_FWB)   ? {tag_mem[fl_idx], fl_idx[EW-1:2]} :
                           (state == S_EVICT) ? {tag_mem[q_ent], c_set} : q_addr[31:LS];
    assign mem_req_wdata = ram_rdata;
    wire mem_fire = mem_req_valid && mem_req_ready;

    // ---- state ----
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; valid <= {NE{1'b0}}; dirty <= {NE{1'b0}}; plru <= {3*SETS{1'b0}};
            rsp_valid <= 1'b0; flush_pend <= 1'b0; fl_idx <= {EW{1'b0}}; vway <= 2'd0;
            q_addr <= 32'd0; q_write <= 1'b0; q_be <= {LINE_BYTES{1'b0}}; q_wdata <= {LB{1'b0}};
        end else begin
            rsp_valid <= 1'b0;
            if (touch) plru[3*c_set +: 3] <= plru_next;
            if (flush && !idle) flush_pend <= 1'b1;
            case (state)
                S_IDLE: begin
                    if (flush || flush_pend) begin
                        flush_pend <= 1'b0; fl_idx <= {EW{1'b0}}; state <= S_FSCAN;
                    end else if (accept) begin
                        if (hit) begin
                            rsp_valid <= 1'b1;
`ifndef MUT_CACHE_DIRTY
                            if (req_write) dirty[{c_set, hit_way}] <= 1'b1;
`endif
                        end else begin
                            q_addr <= req_addr; q_write <= req_write; q_be <= req_be; q_wdata <= req_wdata;
                            state <= S_MISS;
                        end
                    end
                end
                S_MISS: begin
                    vway  <= victim;
                    state <= v_dirty ? S_EVICT : S_RREQ;
                end
                S_EVICT: if (mem_fire) begin
                    dirty[q_ent] <= 1'b0;
                    state <= S_RREQ;
                end
                S_RREQ: if (mem_fire) state <= S_RWAIT;
                S_RWAIT: if (mem_rsp_valid) begin
                    tag_mem[q_ent] <= c_tag;
                    valid[q_ent]   <= 1'b1;
                    dirty[q_ent]   <= 1'b0;
                    state <= S_REPLAY;
                end
                S_REPLAY: begin
                    if (q_write) dirty[q_ent] <= 1'b1;
                    rsp_valid <= 1'b1;
                    state <= S_IDLE;
                end
                S_FSCAN: begin
                    if (f_dirty) state <= S_FWB;
                    else if (f_last) state <= S_IDLE;
                    else fl_idx <= fl_idx + 1'b1;
                end
                S_FWB: if (mem_fire) begin
                    dirty[fl_idx] <= 1'b0;
                    if (f_last) state <= S_IDLE;
                    else begin fl_idx <= fl_idx + 1'b1; state <= S_FSCAN; end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

`ifdef AD_FV_CACHE
    assign fv_state = state; assign fv_valid = valid; assign fv_dirty = dirty; assign fv_ram = ram_fv;
    assign fv_q_addr = q_addr; assign fv_q_write = q_write; assign fv_vway = vway; assign fv_fl_idx = fl_idx;
    assign fv_q_be = q_be; assign fv_q_wdata = q_wdata;
    genvar g;
    generate for (g = 0; g < NE; g = g + 1) begin : g_fvt
        assign fv_tags[g*TW +: TW] = tag_mem[g];
    end endgenerate
`endif
endmodule
