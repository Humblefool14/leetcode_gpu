// ad_rop_wb -- ROP write-back (spec/gpu/rop/ad_rop_wb.md): a two-entry write-combining
// buffer of render-target lines (entry r for row r of the quad).  A beat (one colour
// attachment of a quad) goes through ad_rop_wpix (places, path choice, new pixel bytes)
// and one of the three paths (ad_rop_blend outside, ad_rop_fblend inside wpix, or the
// packing); the result is merged into the entries (ad_wb_merge) and marked dirty.
// A miss writes the old line's dirty bytes back, then reads the new line when wpix's
// o_read says the old pixels are needed; a line kept without reading serves only beats
// that need no read (erok = valid for read; a later beat that needs a read fills the
// line around its dirty bytes).  After 16 idle cycles the dirty lines are written and
// both entries emptied; busy stays up until every request is answered.
// State machine (spec §5): IDLE, ROW, LOOK, EVW, FILL, BLEND, BWAIT, FLUSH, FLW.
// The streaming fast path of spec §6 (ad_rop_hazard) is not implemented (see §10).
`include "ad_rop_state.vh"
module ad_rop_wb #(
    parameter ADDR_W     = 32,
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         st_we,
    input  wire [8:0]                   st_idx,
    input  wire [31:0]                  st_wdata,
    input  wire                         d_valid,
    output wire                         d_ready,
    input  wire [31:0]                  d_xy,
    input  wire [15:0]                  d_smask,
    input  wire [511:0]                 d_color,
    input  wire [1:0]                   d_rt,
    input  wire                         d_nocol,
    output wire                         b_valid,
    output wire [511:0]                 b_src,
    output wire [127:0]                 b_dst,
    output wire [3:0]                   b_mask,
    output wire [1:0]                   b_rt,
    input  wire                         b_rvalid,
    input  wire [127:0]                 b_pix,
    output wire                         busy,
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
    localparam LS = LINE_SHIFT;
    localparam LW = ADDR_W - LINE_SHIFT;
    localparam LB = LINE_BYTES;
    localparam [3:0] S_IDLE = 4'd0, S_ROW = 4'd1, S_LOOK = 4'd2, S_EVW = 4'd3, S_FILL = 4'd4,
                     S_BLEND = 4'd5, S_BWAIT = 4'd6, S_FLUSH = 4'd7, S_FLW = 4'd8;
    localparam [3:0] OUT_MAX = 4'd15;

    reg [3:0]    st;
    // the beat
    reg [31:0]   q_xy;
    reg [15:0]   q_smask;
    reg [511:0]  q_color;
    reg [1:0]    q_rt;
    // the place: row, line of the row, pass; flush entry
    reg          cr, fe;
    reg [1:0]    cj, cg;
    reg [LS-1:0] off0, off1;
    reg [LW-1:0] nline;          // line looked up (latched in ROW)
    reg          q_read;         // the beat needs the old pixels (latched in ROW)
    reg          fill_sent;
    reg [4:0]    idle_cnt;
    reg [3:0]    outst;          // requests not yet answered
    // the two line entries
    reg [1:0]    ev, erok;
    reg [LW-1:0] etag0, etag1;
    reg [LB*8-1:0] edat0, edat1;
    reg [LB-1:0] edty0, edty1;

    // ----------------------------------------------------------------- wpix
    wire [31:0]  w_addr;
    wire [1:0]   w_nl, w_np, w_path;
    wire         w_multi, w_drop, w_read, w_lw, f_done;
    wire [3:0]   w_mask, w_ent;
    wire [511:0] w_bsrc, w_res;
    wire [127:0] w_bdst;
    wire [4*LS-1:0] w_soff;
    wire [4:0]   w_ps;
    wire         f_go   = (st == S_BLEND) && (w_path == 2'd1) && (w_mask != 4'd0);
    wire         f_take = (st == S_BWAIT) && (w_path == 2'd1);
    ad_rop_wpix #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_wpix (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .i_xy(q_xy), .i_rt(q_rt), .i_smask(q_smask), .i_color(q_color),
        .i_r(cr), .i_j(cj), .i_g(cg), .i_line0(edat0), .i_line1(edat1), .i_off0(off0), .i_off1(off1),
        .b_pix(b_pix), .f_go(f_go), .f_done(f_done), .f_take(f_take),
        .o_addr(w_addr), .o_nl(w_nl), .o_np(w_np), .o_multi(w_multi), .o_drop(w_drop), .o_read(w_read),
        .o_path(w_path), .o_lw(w_lw), .o_mask(w_mask), .o_bsrc(w_bsrc), .o_bdst(w_bdst), .o_res(w_res),
        .o_ent(w_ent), .o_soff(w_soff), .o_ps(w_ps));

    wire [ADDR_W+31:0] aext  = {{ADDR_W{1'b0}}, w_addr};
    wire [LW-1:0]      aline = aext[ADDR_W-1:LS];
    wire [LS-1:0]      aoff  = w_addr[LS-1:0];
    reg  [2:0]         w_lps;
    always @(*) case (w_ps)
        5'd2: w_lps = 3'd1;  5'd4: w_lps = 3'd2;  5'd8: w_lps = 3'd3;  5'd16: w_lps = 3'd4;
        default: w_lps = 3'd0;
    endcase

    // ------------------------------------------------------- blend path 0
    assign b_valid = (st == S_BLEND) && (w_path == 2'd0) && (w_mask != 4'd0);
    assign b_src   = w_bsrc;
    assign b_dst   = w_bdst;
    assign b_mask  = w_mask;
    assign b_rt    = q_rt;

    // --------------------------------------------------------------- merge
    wire merge = ((st == S_BLEND) && (w_path == 2'd2) && (w_mask != 4'd0)) ||
                 ((st == S_BWAIT) && (((w_path == 2'd0) && b_rvalid) || ((w_path == 2'd1) && f_done)));
    wire [LB-1:0]   mwe0, mwe1;
    wire [LB*8-1:0] mwd0, mwd1;
    ad_wb_merge #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_merge (
        .i_en(merge), .i_res(w_res), .i_mask(w_mask), .i_ent(w_ent), .i_soff(w_soff), .i_lps(w_lps),
        .o_we0(mwe0), .o_we1(mwe1), .o_wd0(mwd0), .o_wd1(mwd1));

    // ----------------------------------------------------------- AMB port
    wire          ef   = ((st == S_FLUSH) || (st == S_FLW)) ? fe : cr;     // entry of the request
    wire [LW-1:0] etag = ef ? etag1 : etag0;
    wire [LB-1:0] edty = ef ? edty1 : edty0;
    // Read-after-write: a refill read waits until every write of this block has
    // been answered (in FILL before its read, outst counts writes only), so a line
    // written back by an eviction or a flush is never read stale, whatever order
    // the memory side answers in.  (Review finding; a per-line match would wait less.)
`ifdef MUT_WB_NORAW
    wire fill_ok = 1'b1;
`else
    wire fill_ok = (outst == 4'd0);
`endif
    assign req_valid = ((st == S_EVW) || (st == S_FLW) || ((st == S_FILL) && !fill_sent && fill_ok)) && (outst != OUT_MAX);
    assign req_write = (st != S_FILL);
    assign req_line  = etag;
    assign req_be    = req_write ? edty : {LB{1'b0}};
    assign req_wdata = ef ? edat1 : edat0;
    assign req_tag   = {6'd0, req_write, ef};
    wire req_fire = req_valid && req_ready;
    wire rd_rsp   = rsp_valid && !rsp_write;

    assign d_ready = (st == S_IDLE);
    assign busy    = (st != S_IDLE) || (ev != 2'b00) || (outst != 4'd0);

    // ------------------------------------------- next place (combinational)
    // after a row's line is found (one line per row): row 1, or the passes
    wire [3:0] rd_st = cr ? S_BLEND : S_ROW;
    // after a pass (one line: next sample) or a line (several: next line / row)
    reg  [3:0] pn_st;
    reg        pn_r;
    reg  [1:0] pn_j, pn_g;
    always @(*) begin
        pn_st = S_IDLE; pn_r = cr; pn_j = cj; pn_g = cg;
        if (w_multi) begin
            if (cj != w_nl)  begin pn_st = S_ROW; pn_j = cj + 2'd1; end
            else if (!cr)    begin pn_st = S_ROW; pn_r = 1'b1; pn_j = 2'd0; end
        end else if (cg != w_np) begin pn_st = S_BLEND; pn_g = cg + 2'd1; end
    end
    wire       hit  = (cr ? ev[1] : ev[0]) && ((cr ? etag1 : etag0) == nline);
    wire       rok  = cr ? erok[1] : erok[0];
    wire       dty  = cr ? (edty1 != {LB{1'b0}}) : (edty0 != {LB{1'b0}});

    // -------------------------------------------------- control registers
    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; cr <= 1'b0; cj <= 2'd0; cg <= 2'd0; fe <= 1'b0; fill_sent <= 1'b0;
            idle_cnt <= 5'd0; outst <= 4'd0; q_read <= 1'b0; nline <= {LW{1'b0}};
            off0 <= {LS{1'b0}}; off1 <= {LS{1'b0}};
            q_xy <= 32'd0; q_smask <= 16'd0; q_rt <= 2'd0;
        end else begin
            outst <= outst + {3'd0, req_fire} - {3'd0, rsp_valid};
            case (st)
                S_IDLE: begin
                    if (d_valid) begin
                        idle_cnt <= 5'd0;
                        q_xy <= d_xy; q_smask <= d_smask; q_rt <= d_rt;
                        cr <= 1'b0; cj <= 2'd0; cg <= 2'd0;
                        if (!d_nocol) st <= S_ROW;
                    end else if (ev != 2'b00) begin
                        if (idle_cnt == 5'd15) begin st <= S_FLUSH; fe <= 1'b0; idle_cnt <= 5'd0; end
                        else idle_cnt <= idle_cnt + 5'd1;
                    end else idle_cnt <= 5'd0;
                end
                S_ROW: begin
                    if (w_drop) st <= S_IDLE;
                    else if (!w_lw) begin
                        if (w_multi) begin st <= pn_st; cr <= pn_r; cj <= pn_j; end
                        else begin st <= rd_st; cr <= 1'b1; cg <= 2'd0; end
                    end else begin
                        nline <= aline; q_read <= w_read;
                        if (cr) off1 <= aoff; else off0 <= aoff;
                        st <= S_LOOK;
                    end
                end
                S_LOOK: begin
                    if (hit) begin
                        if (q_read && !rok) st <= S_FILL;
                        else if (w_multi) st <= S_BLEND;
                        else begin st <= rd_st; cr <= 1'b1; cg <= 2'd0; end
                    end else if (dty) st <= S_EVW;
                    else if (q_read) st <= S_FILL;
                    else if (w_multi) st <= S_BLEND;
                    else begin st <= rd_st; cr <= 1'b1; cg <= 2'd0; end
                end
                S_EVW: if (req_fire) begin
                    if (q_read) st <= S_FILL;
                    else if (w_multi) st <= S_BLEND;
                    else begin st <= rd_st; cr <= 1'b1; cg <= 2'd0; end
                end
                S_FILL: begin
                    if (req_fire) fill_sent <= 1'b1;
                    if (fill_sent && rd_rsp) begin
                        fill_sent <= 1'b0;
                        if (w_multi) st <= S_BLEND;
                        else begin st <= rd_st; cr <= 1'b1; cg <= 2'd0; end
                    end
                end
                S_BLEND: begin
                    if (w_mask != 4'd0 && (w_path == 2'd0 || w_path == 2'd1)) st <= S_BWAIT;
                    else begin st <= pn_st; cr <= pn_r; cj <= pn_j; cg <= pn_g; end
                end
                S_BWAIT: begin
                    if (merge || (w_path[1])) begin st <= pn_st; cr <= pn_r; cj <= pn_j; cg <= pn_g; end
                end
                S_FLUSH: begin
                    if ((fe ? ev[1] : ev[0]) && edty != {LB{1'b0}}) st <= S_FLW;
                    else if (fe) st <= S_IDLE;
                    else fe <= 1'b1;
                end
                S_FLW: if (req_fire) begin
                    if (fe) st <= S_IDLE;
                    else begin fe <= 1'b1; st <= S_FLUSH; end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
    // the beat's colour: pure datapath, qualified by the state
    always @(posedge clk) if (st == S_IDLE && d_valid) q_color <= d_color;

    // ----------------------------------------------------------- entries
    // allocation: LOOK on a miss of a clean or empty entry, EVW when the old line is taken
    wire alloc = ((st == S_LOOK) && !hit && !dty) || ((st == S_EVW) && req_fire);
    wire fill  = (st == S_FILL) && fill_sent && rd_rsp;
    wire flushed = ((st == S_FLUSH) && !((fe ? ev[1] : ev[0]) && edty != {LB{1'b0}})) ||
                   ((st == S_FLW) && req_fire);
    wire [LB*8-1:0] rdat = rsp_error ? {LB*8{1'b0}} : rsp_rdata;
    integer b;
    always @(posedge clk) begin
        if (!rst_n) begin
            ev <= 2'b00; erok <= 2'b00; etag0 <= {LW{1'b0}}; etag1 <= {LW{1'b0}};
            edty0 <= {LB{1'b0}}; edty1 <= {LB{1'b0}};
        end else begin
            if (alloc) begin
                if (cr) begin ev[1] <= 1'b1; erok[1] <= 1'b0; etag1 <= nline; edty1 <= {LB{1'b0}}; end
                else    begin ev[0] <= 1'b1; erok[0] <= 1'b0; etag0 <= nline; edty0 <= {LB{1'b0}}; end
            end
            if (fill) begin
                if (cr) erok[1] <= 1'b1; else erok[0] <= 1'b1;
            end
            if (merge) begin
                edty0 <= edty0 | mwe0;
                edty1 <= edty1 | mwe1;
            end
            if (flushed) begin
                if (fe) begin ev[1] <= 1'b0; erok[1] <= 1'b0; edty1 <= {LB{1'b0}}; end
                else    begin ev[0] <= 1'b0; erok[0] <= 1'b0; edty0 <= {LB{1'b0}}; end
            end
        end
    end
    // line data: pure datapath (meaningful where erok or dirty)
    always @(posedge clk) begin
        for (b = 0; b < LB; b = b + 1) begin
            if (fill && !cr && !edty0[b]) edat0[8*b +: 8] <= rdat[8*b +: 8];
            if (fill &&  cr && !edty1[b]) edat1[8*b +: 8] <= rdat[8*b +: 8];
            if (mwe0[b]) edat0[8*b +: 8] <= mwd0[8*b +: 8];
            if (mwe1[b]) edat1[8*b +: 8] <= mwd1[8*b +: 8];
        end
    end

`ifndef SYNTHESIS
`ifndef FORMAL
    // ---------------------------------- simulation only: the alignment of ghci §8.5
    wire [7:0] rowb = {3'd0, w_ps} << ((w_np == 2'd3) ? 3 : 1);    // 2 S ps
    always @(posedge clk) if (rst_n && st == S_ROW && !w_drop && w_lw) begin
        if (!w_multi && ({{(32-LS){1'b0}}, aoff} + {24'd0, rowb} > LB))
            $display("FAIL ad_rop_wb: row of one line crosses it (addr %h, %0d bytes)", w_addr, rowb);
        if (w_multi && aoff != {LS{1'b0}})
            $display("FAIL ad_rop_wb: row of several lines not line-aligned (addr %h)", w_addr);
    end
`endif
`endif

`ifdef FORMAL
    // ------------------------------------------- embedded properties (formal only)
    always @(*) if (rst_n) begin
        a_st:      assert (st <= S_FLW);
        a_bvalid:  assert (!b_valid || st == S_BLEND);
        a_dready:  assert (!d_ready || st == S_IDLE);
        a_wbe:     assert (!(req_valid && req_write) || (req_be == edty && req_be != {LB{1'b0}}));
        a_wvalid:  assert (!(req_valid && req_write) || (ef ? ev[1] : ev[0]));
        a_dty0:    assert (edty0 == {LB{1'b0}} || ev[0]);
        a_dty1:    assert (edty1 == {LB{1'b0}} || ev[1]);
        a_rok:     assert ((erok & ~ev) == 2'b00);
        a_idle:    assert (busy || (edty0 == {LB{1'b0}} && edty1 == {LB{1'b0}} && ev == 2'b00 && outst == 4'd0));
        a_fill:    assert (!fill_sent || st == S_FILL);
        a_icnt:    assert (idle_cnt <= 5'd15);
    end
    always @(posedge clk) if (rst_n) begin
        c_evw:   cover (st == S_EVW && req_fire);
        c_fill:  cover (st == S_FILL && fill_sent && rd_rsp && edty0 != {LB{1'b0}});
        c_bwait: cover (st == S_BWAIT && b_rvalid && w_path == 2'd0);
        c_fbl:   cover (st == S_BWAIT && f_done);
        c_multi: cover (st == S_BLEND && w_multi && cr && cj == 2'd1);
    end
`endif
endmodule
