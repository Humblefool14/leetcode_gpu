// ad_rop_wb_tb.vh -- shared by ad_rop_wb_tb and ad_rop_mrt_tb:
//   ad_tb_blend_model  behavioural stand-in for ad_rop_blend (3-cycle pipeline): per lane in
//                      b_mask, formats 37/51 (RGBA8), 44 (BGRA8), 9 (R8), 16 (R8G8): blend
//                      disabled: pack(f2u8(src)) with the write mask; BLEND[0] = 1: per channel
//                      min(255, f2u8(src) + old) (= BLEND ONE/ONE/ADD); other formats and lanes
//                      outside b_mask: b_dst.  Same model as tools/wb_model.py path0_pix.
//                      With -DAD_REAL_BLEND the benches use rtl/rop/ad_rop_blend.v instead.
//   ad_rop_wb_bench    ad_rop_wb + blend + ad_amb_mem driven by a command file
//                      (tools/gen_wb_vectors.py); compares the whole memory after each drain.
`include "ad_rop_state.vh"

module ad_tb_blend_model (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         st_we,
    input  wire [8:0]   st_idx,
    input  wire [31:0]  st_wdata,
    input  wire         b_valid,
    input  wire [511:0] b_src,
    input  wire [127:0] b_dst,
    input  wire [3:0]   b_mask,
    input  wire [1:0]   b_rt,
    output wire         b_rvalid,
    output wire [127:0] b_pix
);
    reg [31:0] fmts, rtfmt, wms, bl [0:3];
    always @(posedge clk) begin
        if (!rst_n) begin fmts <= 0; rtfmt <= 0; wms <= 0; bl[0] <= 0; bl[1] <= 0; bl[2] <= 0; bl[3] <= 0; end
        else if (st_we) case (st_idx)
            `AD_S_RT_FORMATS: fmts <= st_wdata;
            `AD_S_RT_FORMAT:  rtfmt <= st_wdata;
            `AD_S_WRITE_MASK: wms <= st_wdata;
            `AD_S_BLEND:      bl[0] <= st_wdata;
            `AD_S_BLEND1:     bl[1] <= st_wdata;
            `AD_S_BLEND2:     bl[2] <= st_wdata;
            `AD_S_BLEND3:     bl[3] <= st_wdata;
            default: ;
        endcase
    end
    wire [7:0] s8 [0:15];
    genvar gi;
    generate for (gi = 0; gi < 16; gi = gi + 1) begin : g_f2u8
        ad_rop_f2u8 u (.f(b_src[32*gi +: 32]), .u(s8[gi]));
    end endgenerate
    reg [7:0] fmt;
    reg [3:0] wm, pres;
    reg       ben;
    reg [127:0] pix;
    reg [7:0] d [0:3];
    reg [7:0] o [0:3];
    reg [8:0] sum;
    integer k, c;
    always @(*) begin
        fmt = fmts[8*b_rt +: 8];
        if (b_rt == 0 && fmt == 0) fmt = (rtfmt == 0) ? 8'd44 : (rtfmt == 1) ? 8'd37 : (rtfmt <= 3) ? 8'd4 : 8'd0;
        wm  = wms[4*b_rt +: 4];
        ben = bl[b_rt][0];
        pres = (fmt == 37 || fmt == 44 || fmt == 51) ? 4'hF : (fmt == 9) ? 4'h1 : (fmt == 16) ? 4'h3 : 4'h0;
        pix = b_dst;
        for (k = 0; k < 4; k = k + 1) begin
            d[0] = (fmt == 44) ? b_dst[32*k+16 +: 8] : b_dst[32*k +: 8];
            d[1] = b_dst[32*k+8 +: 8];
            d[2] = (fmt == 44) ? b_dst[32*k +: 8] : b_dst[32*k+16 +: 8];
            d[3] = b_dst[32*k+24 +: 8];
            for (c = 0; c < 4; c = c + 1) begin
                sum = {1'b0, s8[4*k+c]} + (ben ? {1'b0, d[c]} : 9'd0);
                o[c] = !pres[c] ? 8'd0 : !wm[c] ? d[c] : (sum > 255) ? 8'd255 : sum[7:0];
            end
            if (b_mask[k] && pres != 0)
                case (fmt)
                    8'd44:   pix[32*k +: 32] = {o[3], o[0], o[1], o[2]};
                    8'd9:    pix[32*k +: 32] = {24'd0, o[0]};
                    8'd16:   pix[32*k +: 32] = {16'd0, o[1], o[0]};
                    default: pix[32*k +: 32] = {o[3], o[2], o[1], o[0]};
                endcase
        end
    end
    reg [2:0] v;
    reg [127:0] p1, p2, p3;
    always @(posedge clk) begin
        if (!rst_n) v <= 0; else v <= {v[1:0], b_valid};
        p1 <= pix; p2 <= p1; p3 <= p2;
    end
    assign b_rvalid = v[2];
    assign b_pix = p3;
endmodule

module ad_rop_wb_bench #(
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5,
    parameter CMDF = "sim/vec/wb_cmd_32.hex",
    parameter EXPF = "sim/vec/wb_exp_32.hex",
    parameter NCMD = 2048,
    parameter NEXP = 32,
    parameter SEED = 1
) (
    input wire clk
);
    localparam LB = LINE_BYTES, LS = LINE_SHIFT, MEMB = 16384;
    localparam LW = 32 - LS;
    reg rst_n = 0, st_we = 0;
    reg [8:0] st_idx = 0;
    reg [31:0] st_wdata = 0;
    reg d_valid = 0, d_nocol = 0;
    reg [31:0] d_xy = 0; reg [15:0] d_smask = 0; reg [511:0] d_color = 0; reg [1:0] d_rt = 0;
    wire d_ready, busy, b_valid, b_rvalid;
    wire [511:0] b_src; wire [127:0] b_dst, b_pix; wire [3:0] b_mask; wire [1:0] b_rt;
    wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
    wire [LW-1:0] req_line; wire [LB-1:0] req_be; wire [LB*8-1:0] req_wdata, rsp_rdata;
    wire [7:0] req_tag, rsp_tag;

    ad_rop_wb #(.ADDR_W(32), .LINE_BYTES(LB), .LINE_SHIFT(LS)) dut (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .d_valid(d_valid), .d_ready(d_ready), .d_xy(d_xy), .d_smask(d_smask), .d_color(d_color),
        .d_rt(d_rt), .d_nocol(d_nocol),
        .b_valid(b_valid), .b_src(b_src), .b_dst(b_dst), .b_mask(b_mask), .b_rt(b_rt),
        .b_rvalid(b_rvalid), .b_pix(b_pix), .busy(busy),
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line),
        .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
        .rsp_error(rsp_error));
`ifdef AD_REAL_BLEND
    ad_rop_blend #(.LAT(3)) u_blend (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .b_valid(b_valid), .b_src(b_src), .b_src1(512'd0), .b_has_src1(1'b0), .b_dst(b_dst),
        .b_mask(b_mask), .b_rt(b_rt), .b_rvalid(b_rvalid), .b_pix(b_pix));
`else
    ad_tb_blend_model u_blend (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .b_valid(b_valid), .b_src(b_src), .b_dst(b_dst), .b_mask(b_mask), .b_rt(b_rt),
        .b_rvalid(b_rvalid), .b_pix(b_pix));
`endif
    ad_amb_mem #(.LINE_BYTES(LB), .LINE_SHIFT(LS), .ADDR_W(32), .MEM_LINES(MEMB / LB),
                 .LAT_MIN(2), .LAT_MAX(12), .READY_PCT(70), .SEED(SEED)) mem (
        .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
        .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
        .rsp_error(rsp_error));

    reg [607:0] cmd [0:NCMD-1];
    reg [127:0] expv [0:NEXP*MEMB/16-1];
    reg [607:0] c;
    integer err_sec [0:3];
    integer err_drain = 0, n_runs = 0, n_bv = 0, n_rd = 0, n_wr = 0, n_flush_wait = 0;
    reg done = 0;

    // ---------------- monitors: AMB rules, busy vs outstanding, write enables
    integer outc = 0;
    reg p_v = 0, p_r = 0, p_w = 0; reg [LW-1:0] p_l; reg [LB-1:0] p_be; reg [LB*8-1:0] p_d;
    always @(posedge clk) if (rst_n) begin
        if (!busy && outc != 0) begin
            err_drain = err_drain + 1;
            if (err_drain < 5) $display("FAIL ad_rop_wb.drain LB %0d busy low with %0d requests outstanding", LB, outc);
        end
        if (p_v && !p_r && (!req_valid || req_write !== p_w || req_line !== p_l || (p_w && (req_be !== p_be || req_wdata !== p_d)))) begin
            err_drain = err_drain + 1; $display("FAIL ad_rop_wb.drain LB %0d request changed before taken", LB);
        end
        if (req_valid && req_write && req_be == 0) begin
            err_drain = err_drain + 1; $display("FAIL ad_rop_wb.drain LB %0d empty write", LB);
        end
        if (rsp_valid && rsp_error) begin
            err_drain = err_drain + 1; $display("FAIL ad_rop_wb.drain LB %0d request outside memory", LB);
        end
        if (b_valid) n_bv = n_bv + 1;
        if (req_valid && req_ready) begin if (req_write) n_wr = n_wr + 1; else n_rd = n_rd + 1; end
        outc = outc + (req_valid && req_ready) - rsp_valid;
        p_v <= req_valid; p_r <= req_ready; p_w <= req_write; p_l <= req_line; p_be <= req_be; p_d <= req_wdata;
    end

    integer n, i, k, e, t, gap, seed, sec, last_beat, cyc = 0;
    reg changed;
    always @(posedge clk) cyc <= cyc + 1;
    // the flush waits for 16 idle cycles: busy may fall sooner after a beat only if no line
    // was held since that beat (a dropped beat with empty entries)
    reg p_busy = 0, held = 0;
    integer hs_cyc = 0;
    always @(posedge clk) if (rst_n) begin
        if (d_valid && d_ready) begin hs_cyc = cyc; held = 1'b0; end
        else if (dut.ev != 2'b00) held = 1'b1;
        if (p_busy && !busy && held && cyc - hs_cyc < 17) begin
            err_drain = err_drain + 1;
            $display("FAIL ad_rop_wb.drain LB %0d lines flushed %0d cycles after the last beat", LB, cyc - hs_cyc);
        end
        p_busy <= busy;
    end
    initial begin
        for (k = 0; k < 4; k = k + 1) err_sec[k] = 0;
        for (n = 0; n < NCMD; n = n + 1) cmd[n] = {608{1'b0}};
        $readmemh(CMDF, cmd);
        $readmemh(EXPF, expv);
        repeat (3) @(negedge clk);
        rst_n = 1;
        last_beat = 0;
        for (n = 0; n < NCMD && cmd[n][607:600] != 0; n = n + 1) begin
            c = cmd[n];
            case (c[607:600])
                8'd4: begin                          // init memory
                    if (busy) begin err_drain = err_drain + 1; $display("FAIL ad_rop_wb.drain busy at a new run"); end
                    seed = c[599:568];
                    for (i = 0; i < MEMB; i = i + 1) mem.mem[i] = (i * 131 + seed * 17 + (i >> 7) * 29) & 255;
                end
                8'd1: begin                          // STATE write
                    @(negedge clk); st_we = 1; st_idx = c[520:512]; st_wdata = c[599:568];
                    @(negedge clk); st_we = 0;
                end
                8'd2: begin                          // beat
                    gap = c[527:520];
                    repeat (gap) @(negedge clk);
                    d_valid = 1; d_xy = c[599:568]; d_smask = c[567:552]; d_rt = c[513:512];
                    d_nocol = c[514]; d_color = c[511:0];
                    @(posedge clk); while (!d_ready) @(posedge clk);
                    last_beat = cyc;
                    @(negedge clk); d_valid = 0; d_color = {512{1'bx}}; d_xy = 32'hx;
                end
                8'd3: begin                          // drain, then compare
                    e = c[599:568]; sec = c[567:552];
                    t = 0;
                    @(posedge clk);
                    while (busy && t < 50000) begin @(posedge clk); t = t + 1; end
                    if (busy) begin err_drain = err_drain + 1; $display("FAIL ad_rop_wb.drain LB %0d busy never falls", LB); end
                    if (mem.head != mem.tail) begin err_drain = err_drain + 1; $display("FAIL ad_rop_wb.drain LB %0d responses pending", LB); end
                    changed = 0;
                    for (i = 0; i < MEMB; i = i + 1) begin
                        if (mem.mem[i] !== ((i * 131 + seed * 17 + (i >> 7) * 29) & 255)) changed = 1;
                        if (mem.mem[i] !== expv[e*MEMB/16 + i/16][8*(i%16) +: 8]) begin
                            err_sec[sec] = err_sec[sec] + 1;
                            if (err_sec[sec] < 6)
                                $display("FAIL LB %0d run %0d section %0d byte %h (rt %0d) got %h exp %h", LB, e, sec, i, i / 4096,
                                         mem.mem[i], expv[e*MEMB/16 + i/16][8*(i%16) +: 8]);
                        end
                    end
                    if (changed) n_flush_wait = n_flush_wait + 1;
                    n_runs = n_runs + 1;
                end
                default: ;
            endcase
        end
        $display("ad_rop_wb bench LB %0d: %0d runs, %0d blend passes, %0d line reads, %0d line writes",
                 LB, n_runs, n_bv, n_rd, n_wr);
        done = 1;
    end
endmodule
