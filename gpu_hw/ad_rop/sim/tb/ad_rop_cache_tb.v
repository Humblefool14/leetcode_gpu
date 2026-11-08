// ad_rop_cache_tb -- hit streaming, PLRU eviction order, flush, and a random test against a
// flat reference memory.  Memory: ad_amb_mem (random ready, random in-order latency); its write
// responses are dropped (the cache's mem_rsp carries read data only).
`timescale 1ns/1ps
module ad_rop_cache_tb;
    localparam LBY = 64, LS = 6, SL = 5, LB = LBY*8, ML = 1024;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg req_valid = 0, req_write = 0; reg [31:0] req_addr = 0; reg [LBY-1:0] req_be = 0; reg [LB-1:0] req_wdata = 0;
    reg flush = 0;
    wire req_ready, rsp_valid, mem_req_valid, mem_req_ready, mem_req_write, busy;
    wire [LB-1:0] rsp_rdata, mem_req_wdata, m_rsp_rdata;
    wire [31-LS:0] mem_req_line;
    wire m_rsp_valid, m_rsp_write, m_rsp_error; wire [7:0] m_rsp_tag;

    ad_rop_cache #(.LINE_BYTES(LBY), .WAYS(4), .SETS_LOG2(SL)) dut (.clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_addr(req_addr),
        .req_be(req_be), .req_wdata(req_wdata), .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready), .mem_req_write(mem_req_write),
        .mem_req_line(mem_req_line), .mem_req_wdata(mem_req_wdata),
        .mem_rsp_valid(m_rsp_valid && !m_rsp_write), .mem_rsp_rdata(m_rsp_rdata),
        .flush(flush), .busy(busy));
    ad_amb_mem #(.LINE_BYTES(LBY), .LINE_SHIFT(LS), .ADDR_W(32), .MEM_LINES(ML), .LAT_MIN(1), .LAT_MAX(9),
                 .READY_PCT(60), .SEED(5)) u_mem (.clk(clk), .rst_n(rst_n),
        .req_valid(mem_req_valid), .req_ready(mem_req_ready), .req_write(mem_req_write),
        .req_line(mem_req_line), .req_be({LBY{1'b1}}), .req_wdata(mem_req_wdata), .req_tag(8'd0),
        .rsp_valid(m_rsp_valid), .rsp_write(m_rsp_write), .rsp_tag(m_rsp_tag), .rsp_rdata(m_rsp_rdata),
        .rsp_error(m_rsp_error));

    // ---------------- reference + expected-response queue ----------------
    reg [7:0]  ref_mem [0:ML*LBY-1];
    reg [LB-1:0] q_exp [0:255]; reg q_isrd [0:255];
    integer qh = 0, qt = 0, err = 0, sec_err = 0, seed = 3, i, k, n_rsp = 0;
    integer n_evict = 0, n_fill = 0, n_memw = 0;
    integer evl [0:15];

    function [LB-1:0] ref_line(input integer line);
        integer b; begin for (b = 0; b < LBY; b = b + 1) ref_line[8*b +: 8] = ref_mem[line*LBY + b]; end
    endfunction

    // response monitor (values sampled at the edge = previous cycle's outputs)
    always @(posedge clk) if (rst_n && rsp_valid) begin
        n_rsp = n_rsp + 1;
        if (qh == qt) begin sec_err = sec_err + 1; $display("FAIL ad_rop_cache unexpected response t=%0t", $time); end
        else begin
            if (q_isrd[qh % 256] && rsp_rdata !== q_exp[qh % 256]) begin
                sec_err = sec_err + 1;
                if (sec_err < 6) $display("FAIL ad_rop_cache read data mismatch t=%0t", $time);
            end
            qh = qh + 1;
        end
    end
    // memory-side monitor
    always @(posedge clk) if (rst_n && mem_req_valid && mem_req_ready) begin
        if (mem_req_write) begin
            if (n_memw < 16) evl[n_memw] = mem_req_line;
            n_memw = n_memw + 1;
            if (dut.state == 2) n_evict = n_evict + 1;
        end else n_fill = n_fill + 1;
    end

    // present one request; returns after the edge that accepts it (stalls counted)
    integer stalls;
    task issue(input wr, input integer line, input [LBY-1:0] be, input [LB-1:0] wd);
        integer b;
        begin
            req_valid = 1; req_write = wr; req_addr = (line << LS) | ($random(seed) & (LBY-1));
            req_be = be; req_wdata = wd;
            @(negedge clk);
            while (!req_ready) begin stalls = stalls + 1; @(negedge clk); end
            // accepted at the next edge: update the reference / expectation now
            if (wr) begin
                for (b = 0; b < LBY; b = b + 1) if (be[b]) ref_mem[line*LBY + b] = wd[8*b +: 8];
                q_isrd[qt % 256] = 0;
            end else begin
                q_exp[qt % 256] = ref_line(line); q_isrd[qt % 256] = 1;
            end
            qt = qt + 1;
            @(posedge clk); #1;
            req_valid = 0;
        end
    endtask
    task wait_idle; begin
        @(negedge clk); while (busy || qh != qt) @(negedge clk);
        @(posedge clk); #1;
    end endtask
    task do_flush; begin
        flush = 1; @(posedge clk); #1; flush = 0;
        @(negedge clk); while (busy) begin if (req_ready) begin sec_err = sec_err + 1; $display("FAIL ad_rop_cache.flush req_ready while flushing"); end @(negedge clk); end
        @(posedge clk); #1;
    end endtask
    task check_mem(input [255:0] sec); integer a, bad; begin
        bad = 0;
        for (a = 0; a < ML*LBY; a = a + 1) if (u_mem.mem[a] !== ref_mem[a]) bad = bad + 1;
        if (bad) begin sec_err = sec_err + 1; $display("FAIL %0s memory differs from reference in %0d bytes", sec, bad); end
    end endtask
    function [LB-1:0] rnd_line(input integer dummy); integer w; begin
        for (w = 0; w < LBY/4; w = w + 1) rnd_line[32*w +: 32] = $random(seed);
    end endfunction
    function [LBY-1:0] rnd_be(input integer dummy); begin
        case ($unsigned($random(seed)) % 4)
            0: rnd_be = {LBY{1'b1}};
            1: rnd_be = {LBY{1'b0}};
            default: rnd_be = {$random(seed), $random(seed)};
        endcase
    end endfunction
    function integer line_of(input integer set, input integer tag); line_of = tag * (1 << SL) + set; endfunction

    integer t0, wr;
    initial begin
        #1;
        for (i = 0; i < ML*LBY; i = i + 1) begin u_mem.mem[i] = $random(seed); ref_mem[i] = u_mem.mem[i]; end
        repeat (3) @(posedge clk); #1 rst_n = 1;
        @(posedge clk); #1;

        // ---------------- hit: streaming at 1 request/cycle ----------------
        sec_err = 0; stalls = 0;
        issue(0, 5, 0, 0); issue(1, 6, {LBY{1'b1}}, rnd_line(0)); wait_idle;
        stalls = 0; t0 = $time;
        for (k = 0; k < 64; k = k + 1) begin
            wr = $random(seed) & 1;
            issue(wr, (k & 2) ? 6 : 5, rnd_be(0), rnd_line(0));
            req_valid = 0;
        end
        wait_idle;
        if (stalls != 0) begin sec_err = sec_err + 1; $display("FAIL ad_rop_cache.hit %0d stall cycles on hits", stalls); end
        if (sec_err == 0) $display("PASS ad_rop_cache.hit");
        err = err + sec_err;

        // ---------------- plru: fill a set, check victim order + writeback ----------------
        sec_err = 0;
        for (k = 20; k < 24; k = k + 1) issue(1, line_of(3, k), {LBY{1'b1}}, rnd_line(0));   // ways 0..3, dirty
        wait_idle;
        issue(0, line_of(3, 21), 0, 0); wait_idle;                  // touch way 1 -> victim way 2 (tag 22)
        n_memw = 0;
        issue(0, line_of(3, 24), 0, 0); wait_idle;                  // evicts tag 22, refills way 2
        issue(0, line_of(3, 25), 0, 0); wait_idle;                  // victim now way 0 (tag 20)
        if (n_memw != 2 || evl[0] != line_of(3, 22) || evl[1] != line_of(3, 20)) begin
            sec_err = sec_err + 1; $display("FAIL ad_rop_cache.plru evictions %0d: %0d %0d", n_memw, evl[0], evl[1]);
        end
        for (i = 0; i < LBY; i = i + 1)
            if (u_mem.mem[line_of(3, 22)*LBY + i] !== ref_mem[line_of(3, 22)*LBY + i] ||
                u_mem.mem[line_of(3, 20)*LBY + i] !== ref_mem[line_of(3, 20)*LBY + i]) begin
                sec_err = sec_err + 1; $display("FAIL ad_rop_cache.plru writeback data"); i = LBY;
            end
        issue(0, line_of(3, 22), 0, 0); issue(0, line_of(3, 20), 0, 0); wait_idle;   // read back
        if (sec_err == 0) $display("PASS ad_rop_cache.plru");
        err = err + sec_err;

        // ---------------- flush ----------------
        sec_err = 0;
        for (k = 0; k < 40; k = k + 1) issue(1, line_of(k % 32, k / 32 + 2), rnd_be(0), rnd_line(0));
        wait_idle;
        do_flush;
        check_mem("ad_rop_cache.flush");
        n_memw = 0; do_flush;                                          // clean cache: no writes
        if (n_memw != 0) begin sec_err = sec_err + 1; $display("FAIL ad_rop_cache.flush clean flush wrote %0d", n_memw); end
        if (sec_err == 0) $display("PASS ad_rop_cache.flush");
        err = err + sec_err;

        // ---------------- random ----------------
        sec_err = 0; n_evict = 0; n_fill = 0;
        for (k = 0; k < 6000; k = k + 1) begin
            if (($random(seed) % 4) == 0) begin @(posedge clk); #1; end
            if (($unsigned($random(seed)) % 200) == 0) begin flush = 1; @(posedge clk); #1; flush = 0; end
            issue($random(seed) & 1, line_of($unsigned($random(seed)) % 4, $unsigned($random(seed)) % 8),
                  rnd_be(0), rnd_line(0));
        end
        wait_idle;
        do_flush;
        check_mem("ad_rop_cache.random");
        if (n_evict < 500 || n_fill < 1000) begin sec_err = sec_err + 1; $display("FAIL ad_rop_cache.random coverage evict %0d fill %0d", n_evict, n_fill); end
        if (sec_err == 0) $display("PASS ad_rop_cache.random (6000 requests, %0d refills, %0d dirty evictions)", n_fill, n_evict);
        err = err + sec_err;

        if (err == 0) $display("PASS ad_rop_cache");
        $finish;
    end
    initial begin #20000000; $display("FAIL ad_rop_cache timeout"); $finish; end
endmodule
