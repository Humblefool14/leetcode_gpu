// ad_vf_index_tb -- ad_vf_index at LINE_BYTES 32 and 64 side by side (same STATE and kick), each
// with its own sim/common/ad_amb_mem (random ready and latency) and random iv_ready, against the
// streams of tools/gen_index_vectors.py (reference model index_items()).
// Checked per draw and per line size: every iv item (index, inst, restart, last) in order;
// COUNT 0 / INSTANCE_COUNT 0 send nothing and busy does not rise; a kick while busy is ignored;
// iv payload held until iv_ready; AMB payload held until req_ready, reads only, tag bit 0 only,
// at most two requests in flight; rsp_error: the walk stops without iv_last, the items before are
// a prefix of the stream, busy stays up until every request is answered; busy falls after the
// last item.
`timescale 1ns/1ps
`include "ad_vf_state.vh"

module ad_vf_index_tb_lane #(
    parameter LBY  = 32,
    parameter LS   = 5,
    parameter SEED = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        st_we,
    input  wire [8:0]  st_idx,
    input  wire [31:0] st_wdata,
    input  wire        kick,
    input  wire        run,          // checking a draw
    input  wire        new_draw,     // pulse: reset the per-draw counters
    input  wire [31:0] e_off,        // offset of the draw's items in V
    input  wire [31:0] e_n,
    input  wire        e_err,
    output reg  [31:0] got,          // items received
    output wire        busy,
    output reg  [31:0] errs,
    output reg         saw_busy,
    output reg  [31:0] nreq
);
    localparam AW = 32, LW = AW - LS, MEMB = 65536;
    wire iv_valid, iv_restart, iv_last; reg iv_ready = 0; wire [31:0] iv_index, iv_inst;
    wire req_valid, req_ready, req_write; wire [LW-1:0] req_line; wire [LBY-1:0] req_be; wire [LBY*8-1:0] req_wdata, rsp_rdata;
    wire [7:0] req_tag, rsp_tag; wire rsp_valid, rsp_write, rsp_error;
    ad_vf_index #(.ADDR_W(AW), .LINE_BYTES(LBY), .LINE_SHIFT(LS)) dut (.clk(clk), .rst_n(rst_n), .st_we(st_we),
        .st_idx(st_idx), .st_wdata(st_wdata), .kick(kick), .busy(busy), .iv_valid(iv_valid), .iv_ready(iv_ready),
        .iv_index(iv_index), .iv_inst(iv_inst), .iv_restart(iv_restart), .iv_last(iv_last),
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line), .req_be(req_be),
        .req_wdata(req_wdata), .req_tag(req_tag), .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
        .rsp_rdata(rsp_rdata), .rsp_error(rsp_error));
    ad_amb_mem #(.LINE_BYTES(LBY), .LINE_SHIFT(LS), .ADDR_W(AW), .MEM_LINES(MEMB / LBY), .LAT_MIN(1), .LAT_MAX(14),
                 .READY_PCT(65), .SEED(SEED)) u_mem (.clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line), .req_be(req_be),
        .req_wdata(req_wdata), .req_tag(req_tag), .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
        .rsp_rdata(rsp_rdata), .rsp_error(rsp_error));

    reg [31:0] V [0:99999];
    reg [7:0]  M [0:MEMB-1];
    integer seed = SEED, k, outst = 0;
    initial begin
        $readmemh("sim/vec/index_vec.hex", V);
        $readmemh("sim/vec/index_mem.hex", M);
        for (k = 0; k < MEMB; k = k + 1) u_mem.mem[k] = M[k];
        errs = 0; got = 0; saw_busy = 0; nreq = 0;
    end

    task fail(input [8*48-1:0] what);
        begin errs = errs + 1; if (errs < 10) $display("FAIL ad_vf_index: LINE_BYTES %0d %0s item %0d t=%0t", LBY, what, got, $time); end
    endtask

    reg p_iv = 0, p_ir = 0, p_rl = 0, p_rr = 0; reg [31:0] p_ix, p_in; reg p_rs, p_la; reg [LW-1:0] p_line; reg [7:0] p_tag;
    reg seen_err = 0;
    always @(posedge clk) begin
        if (new_draw) begin got = 0; saw_busy = 0; seen_err = 0; nreq = 0; end
        if (rst_n) begin
            if (busy) saw_busy = 1;
            // AMB client rules
            if (req_valid && req_ready) begin
                outst = outst + 1; nreq = nreq + 1;
                if (req_write) fail("write request");
                if (req_tag[7:1] != 0) fail("tag bits 7:1");
            end
            if (rsp_valid) begin outst = outst - 1; if (rsp_error) seen_err = 1; end
            if (outst > 2) fail("more than two requests in flight");
            if (p_rl && !p_rr && (!req_valid || req_line !== p_line || req_tag !== p_tag)) fail("request changed before ready");
            if (!busy && (req_valid || outst != 0)) fail("idle with a request in flight");
            if (!busy && iv_valid) fail("iv_valid while idle");
            // iv held until taken (unless the walk stopped on rsp_error)
            if (p_iv && !p_ir && !seen_err && (!iv_valid || iv_index !== p_ix || iv_inst !== p_in || iv_restart !== p_rs || iv_last !== p_la))
                fail("iv changed before iv_ready");
            if (iv_valid && iv_ready) begin
                if (!run || got >= e_n) fail("item beyond the stream");
                else begin
                    if (iv_index !== V[e_off + 3*got] || iv_inst !== V[e_off + 3*got + 1] ||
                        iv_restart !== V[e_off + 3*got + 2][0]) fail("item (index / inst / restart)");
                    if (iv_last !== (V[e_off + 3*got + 2][1] && !e_err)) fail("iv_last");
                end
                got = got + 1;
            end
        end
        p_iv <= iv_valid && rst_n; p_ir <= iv_ready; p_ix <= iv_index; p_in <= iv_inst; p_rs <= iv_restart; p_la <= iv_last;
        p_rl <= req_valid && rst_n; p_rr <= req_ready; p_line <= req_line; p_tag <= req_tag;
        iv_ready <= ($unsigned($random(seed)) % 100) < 70;
    end
endmodule

module ad_vf_index_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg st_we = 0; reg [8:0] st_idx = 0; reg [31:0] st_wdata = 0; reg kick = 0, run = 0, new_draw = 0;
    reg [31:0] e_off = 0, e_n = 0; reg e_err = 0;
    wire [31:0] got_a, got_b, errs_a, errs_b, nreq_a, nreq_b; wire busy_a, busy_b, sb_a, sb_b;
    ad_vf_index_tb_lane #(.LBY(32), .LS(5), .SEED(3)) la (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx),
        .st_wdata(st_wdata), .kick(kick), .run(run), .new_draw(new_draw), .e_off(e_off), .e_n(e_n), .e_err(e_err),
        .got(got_a), .busy(busy_a), .errs(errs_a), .saw_busy(sb_a), .nreq(nreq_a));
    ad_vf_index_tb_lane #(.LBY(64), .LS(6), .SEED(11)) lb (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx),
        .st_wdata(st_wdata), .kick(kick), .run(run), .new_draw(new_draw), .e_off(e_off), .e_n(e_n), .e_err(e_err),
        .got(got_b), .busy(busy_b), .errs(errs_b), .saw_busy(sb_b), .nreq(nreq_b));

    reg [31:0] V [0:99999];
    integer nd, d, p, sec, fmt, cnt, icnt, err, dbl, nit, tmo, sec_err0, cur_sec, items = 0, lines = 0, base_e, ndbl = 0;
    integer serr [0:3];

    task st_write(input [8:0] idx, input [31:0] v);
        begin @(posedge clk); st_we <= 1; st_idx <= idx; st_wdata <= v; @(posedge clk); st_we <= 0; end
    endtask
    task sfail(input [8*48-1:0] what);
        begin serr[sec] = serr[sec] + 1; $display("FAIL ad_vf_index: %0s draw %0d", what, d); end
    endtask

    initial begin
        $readmemh("sim/vec/index_vec.hex", V);
        serr[0] = 0; serr[1] = 0; serr[2] = 0; serr[3] = 0;
        repeat (3) @(posedge clk); rst_n <= 1; @(posedge clk);
        nd = V[0]; p = 1;
        for (d = 0; d < nd; d = d + 1) begin
            sec = V[p]; fmt = V[p+1]; cnt = V[p+4]; icnt = V[p+6]; err = V[p+8]; dbl = V[p+9]; nit = V[p+10];
            base_e = errs_a + errs_b;
            st_write(`AD_S_INDEX_FORMAT, fmt);
            st_write(`AD_S_INDEX_BASE, V[p+2]);
            st_write(`AD_S_FIRST, V[p+3]);
            st_write(`AD_S_COUNT, cnt);
            st_write(`AD_S_FIRST_INSTANCE, V[p+5]);
            st_write(`AD_S_INSTANCE_COUNT, icnt);
            st_write(`AD_S_PRIM_RESTART, V[p+7]);
            @(posedge clk); new_draw <= 1; e_off <= p + 11; e_n <= nit; e_err <= err; run <= 1;
            @(posedge clk); new_draw <= 0; kick <= 1;
            @(posedge clk); kick <= 0;
            @(posedge clk); #1;
            if (dbl && busy_a && busy_b) begin           // a kick while busy is ignored
                kick <= 1; @(posedge clk); kick <= 0; ndbl = ndbl + 1;
            end
            tmo = 0;
            while ((busy_a || busy_b || (!err && (got_a != nit || got_b != nit))) && tmo < 30000) begin
                @(posedge clk); #1; tmo = tmo + 1;
            end
            repeat (4) @(posedge clk);
            run <= 0;
            if (tmo >= 30000) sfail("timeout");
            if (!err && (got_a != nit || got_b != nit)) sfail("item count");
            if (err && (got_a > nit || got_b > nit)) sfail("items after the error");
            if ((cnt == 0 || icnt == 0) && (sb_a || sb_b)) sfail("busy rose for an empty draw");
            if (fmt == 0 && (nreq_a != 0 || nreq_b != 0)) sfail("memory read for a non-indexed draw");
            if (errs_a + errs_b != base_e) serr[sec] = serr[sec] + 1;
            items = items + got_a + got_b; lines = lines + nreq_a + nreq_b;
            p = p + 11 + 3*nit;
            if (d + 1 == nd || V[p] != sec) begin
                if (serr[sec] == 0) case (sec)
                    0: $display("PASS ad_vf_index.direct");
                    1: $display("PASS ad_vf_index.u16u32");
                    2: $display("PASS ad_vf_index.restart");
                    3: $display("PASS ad_vf_index.inst");
                endcase
            end
        end
        $display("INFO ad_vf_index: %0d draws, %0d items and %0d line reads checked (LINE_BYTES 32 and 64), %0d kicks while busy",
                 nd, items, lines, ndbl);
        if (serr[0] + serr[1] + serr[2] + serr[3] == 0) $display("PASS ad_vf_index");
        else $display("FAIL ad_vf_index");
        $finish;
    end
endmodule
