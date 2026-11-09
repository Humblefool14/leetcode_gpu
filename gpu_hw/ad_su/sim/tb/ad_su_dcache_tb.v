// ad_su_dcache_tb -- self-checking testbench of ad_su_dcache (spec §8).
// Two cores run the same checks: core 0 against ad_amb_mem (in order, random
// ready/latency, error lines), core 1 against ad_amb_mem_ooo (reads may
// overtake writes: a read after a write of the same line must never be stale).
// Each core: a shadow byte memory and a model of the cache's tags predict
// every response's data and whether it is a hit (answered the cycle after it
// was taken, no MC request) or a miss.
`timescale 1ns/1ps
module ad_su_dcache_tb_core #(
    parameter OOO  = 0,
    parameter SEED = 1
) (
    input  wire clk,
    input  wire rst_n,
    output reg  done,
    output reg  [2:0] ok        // hit, wt, inv
);
    localparam LB = 32, LS = 5, AW = 32, LW = AW - LS, NL = 32;
    localparam MEMLINES = 128;
    localparam RANGE = OOO ? 128 : 136;     // lines >= MEMLINES answer an error (in order memory)

    reg              inv;
    reg              u_req_valid, u_req_write;
    reg  [LW-1:0]    u_req_line;
    reg  [LB-1:0]    u_req_be;
    reg  [LB*8-1:0]  u_req_wdata;
    reg  [7:0]       u_req_tag;
    wire             u_req_ready, u_rsp_valid, u_rsp_write, u_rsp_error;
    wire [7:0]       u_rsp_tag;
    wire [LB*8-1:0]  u_rsp_rdata;
    wire             m_req_valid, m_req_ready, m_req_write, m_rsp_valid, m_rsp_write, m_rsp_error;
    wire [LW-1:0]    m_req_line;
    wire [LB-1:0]    m_req_be;
    wire [LB*8-1:0]  m_req_wdata, m_rsp_rdata;
    wire [7:0]       m_req_tag, m_rsp_tag;

    ad_su_dcache #(.ADDR_W(AW), .LINE_BYTES(LB), .LINE_SHIFT(LS), .DC_BYTES(NL*LB)) dut (
        .clk(clk), .rst_n(rst_n), .inv(inv),
        .u_req_valid(u_req_valid), .u_req_ready(u_req_ready), .u_req_write(u_req_write),
        .u_req_line(u_req_line), .u_req_be(u_req_be), .u_req_wdata(u_req_wdata), .u_req_tag(u_req_tag),
        .u_rsp_valid(u_rsp_valid), .u_rsp_write(u_rsp_write), .u_rsp_tag(u_rsp_tag),
        .u_rsp_rdata(u_rsp_rdata), .u_rsp_error(u_rsp_error),
        .m_req_valid(m_req_valid), .m_req_ready(m_req_ready), .m_req_write(m_req_write),
        .m_req_line(m_req_line), .m_req_be(m_req_be), .m_req_wdata(m_req_wdata), .m_req_tag(m_req_tag),
        .m_rsp_valid(m_rsp_valid), .m_rsp_write(m_rsp_write), .m_rsp_tag(m_rsp_tag),
        .m_rsp_rdata(m_rsp_rdata), .m_rsp_error(m_rsp_error));

    generate if (OOO) begin : g_mem
        ad_amb_mem_ooo #(.LINE_BYTES(LB), .LINE_SHIFT(LS), .ADDR_W(AW), .MEM_LINES(MEMLINES),
                         .WLAT(30), .RLAT(3)) u_mem (
            .clk(clk), .rst_n(rst_n), .req_valid(m_req_valid), .req_ready(m_req_ready),
            .req_write(m_req_write), .req_line(m_req_line), .req_be(m_req_be), .req_wdata(m_req_wdata),
            .req_tag(m_req_tag), .rsp_valid(m_rsp_valid), .rsp_write(m_rsp_write), .rsp_tag(m_rsp_tag),
            .rsp_rdata(m_rsp_rdata), .rsp_error(m_rsp_error));
    end else begin : g_mem
        ad_amb_mem #(.LINE_BYTES(LB), .LINE_SHIFT(LS), .ADDR_W(AW), .MEM_LINES(MEMLINES),
                     .LAT_MIN(1), .LAT_MAX(9), .READY_PCT(60), .SEED(SEED)) u_mem (
            .clk(clk), .rst_n(rst_n), .req_valid(m_req_valid), .req_ready(m_req_ready),
            .req_write(m_req_write), .req_line(m_req_line), .req_be(m_req_be), .req_wdata(m_req_wdata),
            .req_tag(m_req_tag), .rsp_valid(m_rsp_valid), .rsp_write(m_rsp_write), .rsp_tag(m_rsp_tag),
            .rsp_rdata(m_rsp_rdata), .rsp_error(m_rsp_error));
    end endgenerate

    // shadow memory and tag model
    reg [7:0]    shadow [0:MEMLINES*LB-1];
    reg          mv [0:NL-1];
    reg [LW-1:0] mtag [0:NL-1];
    integer seed = SEED, errors = 0, i, j;
    integer n_mreq;                 // MC requests seen
    integer n_hits, n_miss, n_err;
    reg     inv_seen;               // inv after the take (the fill is not kept)
    always @(posedge clk) begin
        if (m_req_valid && m_req_ready) n_mreq = n_mreq + 1;
        if (inv) inv_seen = 1'b1;
    end
    // AMB client rule: the payload is held until ready, checked on the m_ side
    reg p_v, p_r, p_w; reg [LW-1:0] p_l;
    always @(posedge clk) begin
        if (rst_n && p_v && !p_r && !(m_req_valid && m_req_write == p_w && m_req_line == p_l)) begin
            $display("FAIL ad_su_dcache: m_req payload not held"); errors = errors + 1;
        end
        p_v <= m_req_valid; p_r <= m_req_ready; p_w <= m_req_write; p_l <= m_req_line;
    end

    // one request; inv_at: cycle (counted from the take) of an inv pulse, -1 none
    task automatic xfer(input wr, input [LW-1:0] line, input [LB-1:0] be, input [LB*8-1:0] wd,
                        input integer inv_at);
        integer k, m0, idx; reg hit_exp, err_exp; reg [LB*8-1:0] exp_d; reg [7:0] tg;
        begin
            tg = $random(seed);
            idx = line % NL;
            err_exp = (line >= MEMLINES);
            for (k = 0; k < LB; k = k + 1) exp_d[8*k +: 8] = err_exp ? 8'h00 : shadow[line*LB + k];
            u_req_valid <= 1'b1; u_req_write <= wr; u_req_line <= line; u_req_be <= be;
            u_req_wdata <= wd; u_req_tag <= tg; inv <= 1'b0;
            #1;
            while (!u_req_ready) begin @(posedge clk); #1; end
            hit_exp = !wr && mv[idx] && mtag[idx] == line;
            @(posedge clk);                         // E0: taken
            #1;
            inv_seen = 1'b0; m0 = n_mreq;
            u_req_valid <= 1'b0;
            if (wr && !err_exp) for (k = 0; k < LB; k = k + 1) if (be[k]) shadow[line*LB + k] = wd[8*k +: 8];
            k = 0;
            while (!u_rsp_valid) begin
                inv <= (k == inv_at);
                k = k + 1;
                @(posedge clk); #1;
                if (k > 500) begin $display("FAIL ad_su_dcache: no response"); $finish; end
            end
            if (u_rsp_tag !== tg || u_rsp_write !== wr) begin
                $display("FAIL ad_su_dcache: tag/write %h/%b exp %h/%b", u_rsp_tag, u_rsp_write, tg, wr);
                errors = errors + 1;
            end
            if (u_rsp_error !== err_exp) begin
                $display("FAIL ad_su_dcache: error %b exp %b line %0d", u_rsp_error, err_exp, line);
                errors = errors + 1;
            end
            if (!wr && !err_exp && u_rsp_rdata !== exp_d) begin
                $display("FAIL ad_su_dcache: OOO%0d line %0d read %h exp %h (stale?)", OOO, line, u_rsp_rdata, exp_d);
                errors = errors + 1;
            end
            if (hit_exp && (k != 0 || n_mreq != m0)) begin
                $display("FAIL ad_su_dcache: expected hit line %0d lat %0d mreq %0d", line, k + 1, n_mreq - m0);
                errors = errors + 1;
            end
            if (!hit_exp && n_mreq == m0) begin
                $display("FAIL ad_su_dcache: unexpected hit line %0d (wr %b)", line, wr);
                errors = errors + 1;
            end
            if (hit_exp) n_hits = n_hits + 1; else if (err_exp) n_err = n_err + 1; else n_miss = n_miss + 1;
            inv <= (k == inv_at);                   // also at the response edge
            @(posedge clk); #1;                     // Er
            inv <= 1'b0;
            if (inv_seen) for (k = 0; k < NL; k = k + 1) mv[k] = 1'b0;
            if (!wr && !hit_exp && !err_exp && !inv_seen) begin mv[idx] = 1'b1; mtag[idx] = line; end
            if (($random(seed) & 3) == 0) @(posedge clk);
        end
    endtask

    task automatic rnd_line(output [LW-1:0] l, input integer hot);
        begin
            // mostly a few hot lines (hits), some conflicting and some anywhere
            if (($random(seed) & 3) != 0) l = ($unsigned($random(seed)) % hot) * ((($random(seed) & 1) ? NL : 1));
            else l = $unsigned($random(seed)) % RANGE;
            if (l >= RANGE) l = l % RANGE;
        end
    endtask

    task automatic check_mem;
        integer k;
        begin
            for (k = 0; k < MEMLINES*LB; k = k + 1)
                if (g_mem.u_mem.mem[k] !== shadow[k]) begin
                    if (errors < 20) $display("FAIL ad_su_dcache: OOO%0d mem[%0d] %h exp %h", OOO, k, g_mem.u_mem.mem[k], shadow[k]);
                    errors = errors + 1;
                end
        end
    endtask

    reg [LW-1:0] l; reg [LB-1:0] be; reg [LB*8-1:0] wd; integer e0, n;
    initial begin
        done = 0; ok = 0; inv = 0; u_req_valid = 0; u_req_write = 0; u_req_line = 0; u_req_be = 0;
        u_req_wdata = 0; u_req_tag = 0; n_mreq = 0; n_hits = 0; n_miss = 0; n_err = 0; inv_seen = 0;
        for (i = 0; i < NL; i = i + 1) mv[i] = 0;
        for (i = 0; i < MEMLINES*LB; i = i + 1) begin
            shadow[i] = $random(seed);
            g_mem.u_mem.mem[i] = shadow[i];
        end
        @(posedge rst_n); repeat (3) @(posedge clk);
        // ---- hit: reads only ----
        e0 = errors;
        for (n = 0; n < 1500; n = n + 1) begin
            rnd_line(l, 6);
            xfer(0, l, 0, 0, -1);
        end
        if (errors == e0 && n_hits > 300 && n_miss > 100 && (OOO || n_err > 5)) ok[0] = 1;
        else $display("FAIL ad_su_dcache.hit OOO%0d hits %0d misses %0d errors %0d", OOO, n_hits, n_miss, n_err);
        // ---- wt: reads and writes (read after write of one line), memory compared ----
        e0 = errors; n_hits = 0;
        for (n = 0; n < 2000; n = n + 1) begin
            rnd_line(l, 5);
            if ($random(seed) & 1) begin
                for (i = 0; i < LB; i = i + 1) be[i] = ($random(seed) & 3) != 0;
                for (i = 0; i < LB; i = i + 1) wd[8*i +: 8] = $random(seed);
                xfer(1, l, be, wd, -1);
                xfer(0, l, 0, 0, -1);           // read right after the write of the same line
            end else
                xfer(0, l, 0, 0, -1);
        end
        repeat (100) @(posedge clk);
        check_mem;
        if (errors == e0 && n_hits > 300) ok[1] = 1;
        else $display("FAIL ad_su_dcache.wt OOO%0d hits %0d", OOO, n_hits);
        // ---- inv: inv pulses at random points, also during misses ----
        e0 = errors; n_hits = 0;
        for (n = 0; n < 2000; n = n + 1) begin
            rnd_line(l, 4);
            j = (($random(seed) % 5) == 0) ? ($unsigned($random(seed)) % 12) : -1;
            if (($random(seed) % 4) == 0) begin
                for (i = 0; i < LB; i = i + 1) be[i] = $random(seed);
                for (i = 0; i < LB; i = i + 1) wd[8*i +: 8] = $random(seed);
                xfer(1, l, be, wd, j);
            end else
                xfer(0, l, 0, 0, j);
        end
        repeat (100) @(posedge clk);
        check_mem;
        if (errors == e0 && n_hits > 100) ok[2] = 1;
        else $display("FAIL ad_su_dcache.inv OOO%0d hits %0d", OOO, n_hits);
        done = 1;
    end
endmodule

module ad_su_dcache_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    wire d0, d1; wire [2:0] ok0, ok1;
    ad_su_dcache_tb_core #(.OOO(0), .SEED(11)) c0 (.clk(clk), .rst_n(rst_n), .done(d0), .ok(ok0));
    ad_su_dcache_tb_core #(.OOO(1), .SEED(23)) c1 (.clk(clk), .rst_n(rst_n), .done(d1), .ok(ok1));
    initial begin
        repeat (4) @(posedge clk); rst_n <= 1;
        wait (d0 && d1);
        if (ok0[0] && ok1[0]) $display("PASS ad_su_dcache.hit");
        if (ok0[1] && ok1[1]) $display("PASS ad_su_dcache.wt");
        if (ok0[2] && ok1[2]) $display("PASS ad_su_dcache.inv");
        if (&{ok0, ok1}) $display("PASS ad_su_dcache");
        else $display("FAIL ad_su_dcache");
        $finish;
    end
    initial begin #20000000; $display("FAIL ad_su_dcache timeout"); $finish; end
endmodule
