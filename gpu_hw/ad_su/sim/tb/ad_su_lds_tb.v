// ad_su_lds_tb -- self-checking testbench of ad_su_lds (spec §8).
// NPHYS 4 and 8 (one core each).  The LDS is scrubbed first (scrub_busy for
// LDS_BYTES/4 cycles, then every word 0, as the model's initial LDS).  Vectors
// from tools/gen_mem_vectors.py (sim/vec/ad_su_lds<N>_ops.hex: a count, then
// per group 12 header words {op, sub, imm, wrd, exec, side, last, exp lanes,
// exp l_wr, 0, section, rd}, a[N], b[N], c[N], exp[N]; ad_su_lds<N>_mem<k>.hex:
// the LDS after section k-1).  Per group: the beat (lanes, l_wr, the lanes'
// data, l_last, rd, warp, grp, sbe, cls); after each section the RAM
// (backdoor); at the end every word again through the meshlet read port.
// Sections: 0 rw (sts, lds), 1 mask (side-effect lanes a subset of EXEC, few
// words), 2 atom (every operation, cmpxchg equal and not, many lanes on one
// word, the immediate field random, mixed with sts and lds).
`timescale 1ns/1ps
module ad_su_lds_tb_core #(
    parameter NP   = 8,
    parameter SEED = 1
) (
    input  wire clk,
    input  wire rst_n,
    output reg  done,
    output reg  [2:0] ok
);
    localparam GW = (NP == 32) ? 1 : $clog2(32 / NP);
    localparam RECW = 12 + 4 * NP;
    localparam MAXW = 200000;
    localparam WORDS = 1024, LAW = 10;
    `include "ad_su_uop.vh"

    reg              x_valid, x_last;
    reg  [1:0]       x_warp;
    reg  [GW-1:0]    x_grp;
    reg  [2:0]       x_sbe;
    reg  [107:0]     x_uop;
    reg  [NP*32-1:0] x_a, x_b, x_c;
    reg  [2*NP-1:0]  x_mask;
    reg              l_ready, scrub, mesh_rd_en;
    reg  [LAW-1:0]   mesh_rd_addr;
    wire [31:0]      mesh_rd_data;
    wire             x_ready, l_valid, l_wr, l_last, scrub_busy;
    wire [1:0]       l_warp;
    wire [GW-1:0]    l_grp;
    wire [6:0]       l_rd;
    wire [NP*32-1:0] l_data;
    wire [NP-1:0]    l_lanes;
    wire [2:0]       l_sbe, l_cls;

    ad_su_lds #(.NPHYS(NP), .GRP_W(GW), .UOP_W(108), .LDS_BYTES(4096)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last),
        .x_sbe(x_sbe), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
        .x_info(32'd0), .x_ready(x_ready), .l_valid(l_valid), .l_ready(l_ready), .l_warp(l_warp),
        .l_grp(l_grp), .l_rd(l_rd), .l_data(l_data), .l_lanes(l_lanes), .l_wr(l_wr), .l_last(l_last),
        .l_sbe(l_sbe), .l_cls(l_cls), .scrub(scrub), .scrub_busy(scrub_busy),
        .mesh_rd_en(mesh_rd_en), .mesh_rd_addr(mesh_rd_addr), .mesh_rd_data(mesh_rd_data));

    integer seed = SEED, i, nb;
    integer sec_err [0:2];
    reg [31:0] v [0:MAXW-1];
    reg [31:0] snap [0:WORDS-1];
    always @(posedge clk) l_ready <= ($random(seed) % 10) < 7;

    task automatic load_snap(input integer k);
        begin
            case (k)
                0: $readmemh($sformatf("sim/vec/ad_su_lds%0d_mem0.hex", NP), snap);
                1: $readmemh($sformatf("sim/vec/ad_su_lds%0d_mem1.hex", NP), snap);
                2: $readmemh($sformatf("sim/vec/ad_su_lds%0d_mem2.hex", NP), snap);
                default: $readmemh($sformatf("sim/vec/ad_su_lds%0d_mem3.hex", NP), snap);
            endcase
        end
    endtask
    task automatic check_ram(input integer k, input integer sec);
        integer w;
        begin
            load_snap(k);
            for (w = 0; w < WORDS; w = w + 1)
                if (dut.u_ram.mem[w] !== snap[w]) begin
                    if (sec_err[sec] < 10) $display("FAIL ad_su_lds: NP%0d sec %0d word %0d %h exp %h", NP, sec, w, dut.u_ram.mem[w], snap[w]);
                    sec_err[sec] = sec_err[sec] + 1;
                end
        end
    endtask

    integer r, nrec, base, sec, cur_sec, op, ln, wait_c;
    reg [31:0] h [0:11];
    reg [NP*32-1:0] e;
    initial begin
        done = 0; ok = 0; x_valid = 0; x_last = 0; x_warp = 0; x_grp = 0; x_sbe = 0; x_uop = 0;
        x_a = 0; x_b = 0; x_c = 0; x_mask = 0; scrub = 0; mesh_rd_en = 0; mesh_rd_addr = 0;
        for (i = 0; i < 3; i = i + 1) sec_err[i] = 0;
        $readmemh($sformatf("sim/vec/ad_su_lds%0d_ops.hex", NP), v);
        for (i = 0; i < WORDS; i = i + 1) dut.u_ram.mem[i] = $random(seed);
        nrec = v[0];
        @(posedge rst_n); repeat (3) @(posedge clk);
        // scrub: every word 0, busy for WORDS cycles, x_ready 0 meanwhile
        scrub <= 1; @(posedge clk); scrub <= 0; #1;
        nb = 0;
        while (scrub_busy) begin
            if (x_ready) begin $display("FAIL ad_su_lds: x_ready during scrub"); sec_err[0] = sec_err[0] + 1; end
            nb = nb + 1; @(posedge clk); #1;
        end
        if (nb != WORDS) begin $display("FAIL ad_su_lds: scrub_busy %0d cycles", nb); sec_err[0] = sec_err[0] + 1; end
        check_ram(0, 0);
        cur_sec = 0;
        for (r = 0; r < nrec; r = r + 1) begin
            base = 1 + r * RECW;
            for (i = 0; i < 12; i = i + 1) h[i] = v[base + i];
            sec = h[10]; op = h[0];
            if (sec != cur_sec) begin
                check_ram(cur_sec + 1, cur_sec);
                cur_sec = sec;
            end
            for (i = 0; i < NP; i = i + 1) begin
                x_a[i*32 +: 32] = v[base + 12 + i];
                x_b[i*32 +: 32] = v[base + 12 + NP + i];
                x_c[i*32 +: 32] = v[base + 12 + 2*NP + i];
                e[i*32 +: 32]   = v[base + 12 + 3*NP + i];
            end
            if (($random(seed) & 7) == 0) begin
                x_valid <= 1; x_uop <= 0; x_uop[AD_UOP_UNIT +: 4] <= AD_UNIT_LSU;
                @(posedge clk);
            end
            x_uop = 0;
            x_uop[AD_UOP_UNIT +: 4] = AD_UNIT_LDS;
            x_uop[AD_UOP_OP +: 8]   = op;
            x_uop[AD_UOP_SUB +: 5]  = h[1];
            x_uop[AD_UOP_IMM +: 32] = h[2];
            x_uop[AD_UOP_WRD]       = h[3][0];
            x_uop[AD_UOP_RD +: 7]   = h[11];
            x_uop[AD_UOP_CLS +: 3]  = AD_CLS_M;
            x_mask = {h[5][NP-1:0], h[4][NP-1:0]};
            x_last = h[6][0];
            x_warp = $random(seed); x_grp = $random(seed); x_sbe = $random(seed);
            x_valid <= 1;
            #1;
            while (!x_ready) begin @(posedge clk); #1; end
            @(posedge clk);
            x_valid <= 0;
            #1;
            wait_c = 0;
            while (!(l_valid && l_ready)) begin
                @(posedge clk); #1; wait_c = wait_c + 1;
                if (wait_c > 1000) begin $display("FAIL ad_su_lds: no beat"); $finish; end
            end
            if (l_lanes !== h[7][NP-1:0] || l_wr !== h[8][0] || l_last !== h[6][0] ||
                l_rd !== h[11][6:0] || l_warp !== x_warp || l_grp !== x_grp || l_sbe !== x_sbe ||
                l_cls !== AD_CLS_M) begin
                $display("FAIL ad_su_lds: NP%0d r %0d beat fields lanes %b/%b wr %b/%b", NP, r,
                         l_lanes, h[7][NP-1:0], l_wr, h[8][0]);
                sec_err[sec] = sec_err[sec] + 1;
            end
            for (ln = 0; ln < NP; ln = ln + 1)
                if (h[7][ln] && l_data[ln*32 +: 32] !== e[ln*32 +: 32]) begin
                    if (sec_err[sec] < 10) $display("FAIL ad_su_lds: NP%0d r %0d op %0d sub %0d lane %0d %h exp %h", NP, r, op, h[1], ln,
                             l_data[ln*32 +: 32], e[ln*32 +: 32]);
                    sec_err[sec] = sec_err[sec] + 1;
                end
            @(posedge clk);
        end
        check_ram(cur_sec + 1, cur_sec);
        // every word through the meshlet read port (one cycle latency)
        for (i = 0; i < WORDS; i = i + 1) begin
            mesh_rd_en <= 1; mesh_rd_addr <= i;
            @(posedge clk); #1;
            if (mesh_rd_data !== dut.u_ram.mem[i]) begin
                if (sec_err[0] < 10) $display("FAIL ad_su_lds: mesh port word %0d %h exp %h", i, mesh_rd_data, dut.u_ram.mem[i]);
                sec_err[0] = sec_err[0] + 1;
            end
        end
        mesh_rd_en <= 0;
        for (i = 0; i < 3; i = i + 1) ok[i] = (sec_err[i] == 0);
        done = 1;
    end
endmodule

module ad_su_lds_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    wire d0, d1; wire [2:0] ok0, ok1;
    ad_su_lds_tb_core #(.NP(4), .SEED(3)) c4 (.clk(clk), .rst_n(rst_n), .done(d0), .ok(ok0));
    ad_su_lds_tb_core #(.NP(8), .SEED(7)) c8 (.clk(clk), .rst_n(rst_n), .done(d1), .ok(ok1));
    initial begin
        repeat (4) @(posedge clk); rst_n <= 1;
        wait (d0 && d1);
        if (ok0[0] && ok1[0]) $display("PASS ad_su_lds.rw");   else $display("FAIL ad_su_lds.rw");
        if (ok0[1] && ok1[1]) $display("PASS ad_su_lds.mask"); else $display("FAIL ad_su_lds.mask");
        if (ok0[2] && ok1[2]) $display("PASS ad_su_lds.atom"); else $display("FAIL ad_su_lds.atom");
        if (&{ok0, ok1}) $display("PASS ad_su_lds");
        $finish;
    end
    initial begin #50000000; $display("FAIL ad_su_lds timeout"); $finish; end
endmodule
