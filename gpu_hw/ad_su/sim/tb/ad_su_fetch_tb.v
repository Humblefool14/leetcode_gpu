// ad_su_fetch_tb -- self-checking TB of ad_su_fetch (spec §8).
// The TB is the scheduler (random requests held until f_ready), an I$ model
// (random ic_ready, in-order answers after 1 cycle (hit) or a random miss
// latency; the instruction is a hash of the address) and the decoder (random
// d_ready).  Every instruction must leave in request order with its own
// warp and pc and the hash of its own address.  A final phase checks one
// instruction per cycle on hits.
`timescale 1ns/1ps
module ad_su_fetch_tb;
    localparam WARP_W = 3;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg               f_valid = 0;
    wire              f_ready;
    reg  [WARP_W-1:0] f_warp = 0;
    reg  [15:0]       f_pc = 0;
    reg  [31:0]       f_addr = 0;
    wire              ic_req;
    reg               ic_ready = 0;
    wire [31:0]       ic_addr;
    reg               ic_rvalid = 0;
    reg  [63:0]       ic_rdata = 0;
    wire              d_valid;
    reg               d_ready = 0;
    wire [WARP_W-1:0] d_warp;
    wire [15:0]       d_pc;
    wire [63:0]       d_instr;

    ad_su_fetch #(.WARP_W(WARP_W)) dut (.*);

    function [63:0] hash(input [31:0] a);
        hash = {a ^ 32'h5A5A_1234, ~a + 32'd77};
    endfunction

    // expected tokens
    reg [WARP_W+16+32-1:0] exq [0:4095];
    integer exh = 0, ext = 0;
    // I$ model queue
    reg [31:0] icq_a [0:63];
    integer    icq_due [0:63];
    integer    ich = 0, ict = 0, cyc = 0, last_due = 0;
    integer    errors = 0, seed = 11, nout = 0, mode = 0, i;
    integer    ready_pct = 70, dready_pct = 70, miss_pct = 30;

    always @(posedge clk) begin
        cyc <= cyc + 1;
        // the I$ model
        if (rst_n && ic_req && ic_ready) begin
            icq_a[ict % 64] = ic_addr;
            icq_due[ict % 64] = cyc + 1 + ((($random(seed) & 255) % 100 < miss_pct) ? 2 + ($random(seed) & 15) : 0);
            if (icq_due[ict % 64] <= last_due) icq_due[ict % 64] = last_due + 1;
            last_due = icq_due[ict % 64];
            ict = ict + 1;
        end
        ic_rvalid <= 1'b0;
        if (ich != ict && icq_due[ich % 64] <= cyc + 1) begin
            ic_rvalid <= 1'b1; ic_rdata <= hash(icq_a[ich % 64]); ich = ich + 1;
        end
        ic_ready <= (($random(seed) & 255) % 100) < ready_pct;
        // the scheduler
        if (rst_n && f_valid && f_ready) begin
            exq[ext % 4096] = {f_warp, f_pc, f_addr}; ext = ext + 1;
            f_valid <= 1'b0;
        end
        if (rst_n && (!f_valid || f_ready) && mode != 2 && (mode == 1 || ($random(seed) & 3) != 0)) begin
            f_valid <= 1'b1; f_warp <= $random(seed); f_pc <= $random(seed); f_addr <= $random(seed) & ~32'd7;
        end
        // the decoder
        if (rst_n && d_valid && d_ready) begin
            if ({d_warp, d_pc} !== exq[exh % 4096][WARP_W+16+31:32] || d_instr !== hash(exq[exh % 4096][31:0])) begin
                $display("FAIL ad_su_fetch.order: out %0d got w%0d pc %h %h exp %h", exh, d_warp, d_pc, d_instr, exq[exh % 4096]);
                errors = errors + 1;
            end
            exh = exh + 1; nout = nout + 1;
        end
        if (exh > ext) begin $display("FAIL ad_su_fetch.order: more out than in"); errors = errors + 1; end
        d_ready <= (($random(seed) & 255) % 100) < dready_pct;
    end

    integer n0;
    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1;
        for (i = 0; i < 6; i = i + 1) begin
            ready_pct = 30 + 14 * i; dready_pct = 100 - 12 * i; miss_pct = 5 * i;
            repeat (3000) @(posedge clk);
        end
        // drain
        mode = 2; ready_pct = 100; dready_pct = 100;
        @(posedge clk);
        repeat (100) @(posedge clk);
        if (exh != ext || ext < 1000) begin $display("FAIL ad_su_fetch.order: in %0d out %0d", ext, exh); errors = errors + 1; end
        // throughput on hits
        miss_pct = 0; mode = 1;
        repeat (20) @(posedge clk);
        n0 = nout;
        repeat (200) @(posedge clk);
        if (nout - n0 < 199) begin $display("FAIL ad_su_fetch.order: %0d in 200 cycles on hits", nout - n0); errors = errors + 1; end
        if (errors == 0) $display("PASS ad_su_fetch.order");
        if (errors == 0) $display("PASS ad_su_fetch");
        else $display("FAIL ad_su_fetch: %0d errors", errors);
        $finish;
    end
endmodule
