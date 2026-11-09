// ad_su_icache_tb -- self-checking TB of ad_su_icache (spec §8).
// A reference model (valid/tag per line) predicts hit or miss of every
// request: a hit must be taken at once (ic_ready in the request cycle) and
// answered the next cycle; a miss must make exactly one AMB read.  Every
// answer is checked against the memory backdoor (0 for lines that answer
// rsp_error).  Prints PASS ad_su_icache.hit/.conflict/.inv and PASS ad_su_icache.
`timescale 1ns/1ps
module ad_su_icache_tb;
    localparam LINE_BYTES = 32, LINE_SHIFT = 5, IC_BYTES = 2048, NL = IC_BYTES / LINE_BYTES;
    localparam MEM_LINES = 512;   // 16 KiB; lines above answer rsp_error
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg         ic_req = 0;
    reg  [31:0] ic_addr = 0;
    reg         inv = 0;
    wire        ic_ready, ic_rvalid;
    wire [63:0] ic_rdata;
    wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
    wire [26:0] req_line;
    wire [31:0] req_be;
    wire [255:0] req_wdata, rsp_rdata;
    wire [7:0] req_tag, rsp_tag;

    ad_su_icache #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .IC_BYTES(IC_BYTES)) dut (
        .clk(clk), .rst_n(rst_n), .ic_req(ic_req), .ic_ready(ic_ready), .ic_addr(ic_addr),
        .ic_rvalid(ic_rvalid), .ic_rdata(ic_rdata), .inv(inv),
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line),
        .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
        .rsp_error(rsp_error));
    ad_amb_mem #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .MEM_LINES(MEM_LINES),
                 .LAT_MIN(2), .LAT_MAX(9), .READY_PCT(60), .SEED(7)) mem (
        .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
        .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
        .rsp_error(rsp_error));

    reg          mv [0:NL-1];
    reg [20:0]   mt [0:NL-1];
    integer errors = 0, i, j, k, seed = 3, nhit = 0, nmiss = 0;

    function [63:0] expect_word(input [31:0] a);
        integer b;
        begin
            expect_word = 64'd0;
            if ((a >> LINE_SHIFT) < MEM_LINES)
                for (b = 0; b < 8; b = b + 1) expect_word[8*b +: 8] = mem.mem[(a & ~32'd7) + b];
        end
    endfunction

    // One access; inv_at > 0 pulses inv that many cycles into a miss.
    task access(input [31:0] a, input integer inv_at);
        integer reads0, cyc, lidx;
        reg     phit, sawinv;
        begin
            lidx = (a >> LINE_SHIFT) % NL;
            phit = mv[lidx] && mt[lidx] == a[31:11];
            reads0 = mem.n_reads;
            sawinv = 0;
            @(negedge clk);
            ic_req = 1; ic_addr = a;
            #1;
            if (ic_ready !== phit) begin
                $display("FAIL ad_su_icache: addr %h hit predicted %0d, ic_ready %0d t=%0t", a, phit, ic_ready, $time);
                errors = errors + 1;
            end
            cyc = 0;
            while (!ic_ready) begin
                @(negedge clk); cyc = cyc + 1;
                inv = (inv_at > 0 && cyc == inv_at);
                if (inv) sawinv = 1;
                #1;
                if (cyc > 200) begin $display("FAIL ad_su_icache: hang"); errors = errors + 1; disable access; end
            end
            @(posedge clk); #1;
            ic_req = 0; inv = 0;
            if (!ic_rvalid || ic_rdata !== expect_word(a)) begin
                $display("FAIL ad_su_icache: addr %h data %h exp %h rvalid %0d", a, ic_rdata, expect_word(a), ic_rvalid);
                errors = errors + 1;
            end
            if (mem.n_reads - reads0 != (phit ? 0 : 1)) begin
                $display("FAIL ad_su_icache: addr %h made %0d reads (hit %0d)", a, mem.n_reads - reads0, phit);
                errors = errors + 1;
            end
            if (phit) nhit = nhit + 1; else nmiss = nmiss + 1;
            if (!phit && (a >> LINE_SHIFT) < MEM_LINES) begin   // an error fill leaves the line
                mv[lidx] = 1;
                mt[lidx] = a[31:11];
            end
            if (sawinv) for (j = 0; j < NL; j = j + 1) mv[j] = 0;   // flash clear
        end
    endtask

    task do_inv;
        begin
            @(negedge clk); inv = 1; @(negedge clk); inv = 0;
            for (k = 0; k < NL; k = k + 1) mv[k] = 0;
        end
    endtask

    integer e0;
    initial begin
        for (i = 0; i < MEM_LINES * LINE_BYTES; i = i + 1) mem.mem[i] = $random(seed);
        for (i = 0; i < NL; i = i + 1) begin mv[i] = 0; mt[i] = 0; end
        repeat (3) @(posedge clk);
        rst_n = 1;
        // hit: every instruction of some lines, then random addresses in 4 KiB
        e0 = errors;
        for (i = 0; i < 8 * 4; i = i + 1) access(32'h100 + 8 * i, 0);
        if (nmiss != 8) begin $display("FAIL ad_su_icache.hit: %0d misses for 8 lines", nmiss); errors = errors + 1; end
        // back-to-back hits: one per cycle
        @(negedge clk); ic_req = 1;
        for (i = 0; i < 16; i = i + 1) begin
            ic_addr = 32'h100 + 8 * i; #1;
            if (!ic_ready) begin $display("FAIL ad_su_icache.hit: no back-to-back hit"); errors = errors + 1; end
            @(posedge clk); #1;
            if (!ic_rvalid || ic_rdata !== expect_word(ic_addr)) begin
                $display("FAIL ad_su_icache.hit: back-to-back data"); errors = errors + 1; end
            @(negedge clk);
        end
        ic_req = 0;
        for (i = 0; i < 600; i = i + 1) access(($random(seed) & 32'hFF8), 0);
        if (errors == e0) $display("PASS ad_su_icache.hit");
        // conflict: same index, other tag
        e0 = errors;
        for (i = 0; i < 40; i = i + 1) access((i % 2) ? 32'h0840 : 32'h0040, 0);
        for (i = 0; i < 300; i = i + 1) access((($random(seed) & 3) << 11) | ($random(seed) & 32'h1F8), 0);
        if (errors == e0) $display("PASS ad_su_icache.conflict");
        // inv: forces misses; inv during a miss; error lines are not kept
        e0 = errors;
        for (i = 0; i < 8; i = i + 1) access(32'h200 + 32 * i, 0);
        do_inv;
        for (i = 0; i < 8; i = i + 1) access(32'h200 + 32 * i, 0);   // all miss (predicted)
        for (k = 1; k < 12; k = k + 1) begin
            access(32'h400 + 32 * k, k);         // inv k cycles into the miss
            access(32'h400 + 32 * k, 0);         // must miss again
            access(32'h400 + 32 * k + 8, 0);     // hit now
        end
        for (i = 0; i < 4; i = i + 1) begin
            access(32'h0001_0000 + 64 * i, 0);   // rsp_error: instruction 0
            access(32'h0001_0000 + 64 * i, 0);   // not kept: misses again
        end
        for (i = 0; i < 400; i = i + 1) begin
            if (($random(seed) & 31) == 0) do_inv;
            access(($random(seed) & 32'h1FF8) | ((($random(seed) & 15) == 0) ? 32'h20000 : 0),
                   (($random(seed) & 7) == 0) ? 1 + ($random(seed) & 7) : 0);
        end
        if (errors == e0) $display("PASS ad_su_icache.inv");
        if (errors == 0) $display("PASS ad_su_icache");
        else $display("FAIL ad_su_icache: %0d errors", errors);
        $finish;
    end
endmodule
