// ad_su_cbank_tb -- self-checking testbench of ad_su_cbank (spec §8).
// NPHYS 4 and 8 (one core each), ad_amb_mem (128 lines; lines above answer
// an error) with the image sim/vec/ad_su_cbank<N>_mem.hex.  Events from
// tools/gen_mem_vectors.py (sim/vec/ad_su_cbank<N>_ops.hex: a count, then per
// event 12 header words and 2N words): 0 LOAD_CONST {0, region, address,
// words} through STATE and lc_kick; 1 a lwc group {1, 0, imm, wrd, exec, 0,
// last, exp lanes, exp l_wr, 0, 1, rd}, a[N], exp[N]; 2 inv.  ad_su_cbank<N>_bank.hex:
// per event, the 256 words a read must give after it (0 for words not loaded
// since the last inv).
// load: after each LOAD the bank (backdoor RAM and valid bits) against the
// model, busy from the kick to the end, x_ready 0 meanwhile; a kick that
// comes during a lwc group waits for it.  read: after every event all
// c0-c31 through cr_* (three random indices per read, the data next cycle),
// the lwc beats; at the end a scrub (every word 0).
`timescale 1ns/1ps
module ad_su_cbank_tb_core #(
    parameter NP   = 8,
    parameter SEED = 1
) (
    input  wire clk,
    input  wire rst_n,
    output reg  done,
    output reg  [1:0] ok
);
    localparam LB = 32, LS = 5, AW = 32, LW = AW - LS, MEMLINES = 128;
    localparam GW = (NP == 32) ? 1 : $clog2(32 / NP);
    localparam RECW = 12 + 2 * NP;
    localparam CWORDS = 256;
    `include "ad_su_uop.vh"

    reg              x_valid, x_last;
    reg  [1:0]       x_warp;
    reg  [GW-1:0]    x_grp;
    reg  [2:0]       x_sbe;
    reg  [107:0]     x_uop;
    reg  [NP*32-1:0] x_a;
    reg  [2*NP-1:0]  x_mask;
    reg              l_ready, cr_en, st_we, lc_kick, inv, scrub;
    reg  [14:0]      cr_idx;
    reg  [8:0]       st_idx;
    reg  [31:0]      st_wdata;
    wire [95:0]      cr_data;
    wire             x_ready, l_valid, l_wr, l_last, busy, scrub_busy;
    wire [1:0]       l_warp;
    wire [GW-1:0]    l_grp;
    wire [6:0]       l_rd;
    wire [NP*32-1:0] l_data;
    wire [NP-1:0]    l_lanes;
    wire [2:0]       l_sbe, l_cls;
    wire             q_v, q_r, q_w, r_v, r_w, r_e;
    wire [LW-1:0]    q_l;
    wire [LB-1:0]    q_be;
    wire [LB*8-1:0]  q_d, r_d;
    wire [7:0]       q_t, r_t;

    ad_su_cbank #(.NPHYS(NP), .GRP_W(GW), .UOP_W(108)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last),
        .x_sbe(x_sbe), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b({(NP*32){1'b1}}), .x_c({(NP*32){1'b1}}),
        .x_mask(x_mask), .x_info(32'd0), .x_ready(x_ready), .l_valid(l_valid), .l_ready(l_ready),
        .l_warp(l_warp), .l_grp(l_grp), .l_rd(l_rd), .l_data(l_data), .l_lanes(l_lanes), .l_wr(l_wr),
        .l_last(l_last), .l_sbe(l_sbe), .l_cls(l_cls), .cr_en(cr_en), .cr_idx(cr_idx), .cr_data(cr_data),
        .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata), .lc_kick(lc_kick), .inv(inv), .busy(busy),
        .scrub(scrub), .scrub_busy(scrub_busy),
        .req_valid(q_v), .req_ready(q_r), .req_write(q_w), .req_line(q_l), .req_be(q_be), .req_wdata(q_d),
        .req_tag(q_t), .rsp_valid(r_v), .rsp_write(r_w), .rsp_tag(r_t), .rsp_rdata(r_d), .rsp_error(r_e));
    ad_amb_mem #(.MEM_LINES(MEMLINES), .LAT_MIN(1), .LAT_MAX(8), .READY_PCT(60), .SEED(SEED)) u_mem (
        .clk(clk), .rst_n(rst_n), .req_valid(q_v), .req_ready(q_r), .req_write(q_w), .req_line(q_l),
        .req_be(q_be), .req_wdata(q_d), .req_tag(q_t), .rsp_valid(r_v), .rsp_write(r_w),
        .rsp_tag(r_t), .rsp_rdata(r_d), .rsp_error(r_e));

    integer seed = SEED, i, errs_load = 0, errs_read = 0;
    reg [31:0] v [0:100000];
    reg [31:0] bk [0:400*CWORDS];
    reg [31:0] img [0:MEMLINES*LB/4-1];
    always @(posedge clk) l_ready <= ($random(seed) % 10) < 7;

    // payload held until ready
    reg p_v, p_r; reg [LW-1:0] p_l;
    always @(posedge clk) begin
        if (rst_n && p_v && !p_r && !(q_v && q_l == p_l)) begin
            $display("FAIL ad_su_cbank: request not held"); errs_load = errs_load + 1;
        end
        p_v <= q_v; p_r <= q_r; p_l <= q_l;
        if (rst_n && q_v && q_w) begin $display("FAIL ad_su_cbank: write request"); errs_load = errs_load + 1; end
    end

    task automatic st_write(input [8:0] idx, input [31:0] d);
        begin st_we <= 1; st_idx <= idx; st_wdata <= d; @(posedge clk); st_we <= 0; end
    endtask

    // all c0-c31 against event k's bank
    task automatic check_c(input integer k);
        integer n, j; reg [4:0] ix [0:2];
        begin
            for (n = 0; n < 24; n = n + 1) begin
                for (j = 0; j < 3; j = j + 1) ix[j] = (n < 11) ? (3 * n + j) % 32 : $random(seed);
                cr_en <= 1; cr_idx <= {ix[2], ix[1], ix[0]};
                @(posedge clk); #1;
                cr_en <= 0; cr_idx <= $random(seed);
                for (j = 0; j < 3; j = j + 1)
                    if (cr_data[32*j +: 32] !== bk[k*CWORDS + ix[j]]) begin
                        if (errs_read < 10) $display("FAIL ad_su_cbank: NP%0d ev %0d c%0d %h exp %h", NP, k, ix[j],
                                                     cr_data[32*j +: 32], bk[k*CWORDS + ix[j]]);
                        errs_read = errs_read + 1;
                    end
                // the data stay while cr_en is 0
                if ($random(seed) & 1) begin
                    @(posedge clk); #1;
                    if (cr_data[31:0] !== bk[k*CWORDS + ix[0]]) begin
                        $display("FAIL ad_su_cbank: cr_data not held"); errs_read = errs_read + 1;
                    end
                end
            end
        end
    endtask

    task automatic check_bank(input integer k);
        integer w; reg [31:0] got;
        begin
            for (w = 0; w < CWORDS; w = w + 1) begin
                got = dut.vb[w] ? dut.u_ram.mem[w] : 32'd0;
                if (got !== bk[k*CWORDS + w]) begin
                    if (errs_load < 10) $display("FAIL ad_su_cbank: NP%0d ev %0d word %0d %h exp %h", NP, k, w, got, bk[k*CWORDS + w]);
                    errs_load = errs_load + 1;
                end
            end
        end
    endtask

    integer r, nrec, base, kind, ln, wait_c, nb;
    reg [31:0] h [0:11];
    reg [NP*32-1:0] e;
    reg kick_early, kicked;
    initial begin
        done = 0; ok = 0; x_valid = 0; x_last = 0; x_warp = 0; x_grp = 0; x_sbe = 0; x_uop = 0;
        x_a = 0; x_mask = 0; cr_en = 0; cr_idx = 0; st_we = 0; st_idx = 0; st_wdata = 0;
        lc_kick = 0; inv = 0; scrub = 0;
        $readmemh($sformatf("sim/vec/ad_su_cbank%0d_ops.hex", NP), v);
        $readmemh($sformatf("sim/vec/ad_su_cbank%0d_bank.hex", NP), bk);
        $readmemh($sformatf("sim/vec/ad_su_cbank%0d_mem.hex", NP), img);
        for (i = 0; i < MEMLINES * LB / 4; i = i + 1)
            {u_mem.mem[4*i+3], u_mem.mem[4*i+2], u_mem.mem[4*i+1], u_mem.mem[4*i]} = img[i];
        nrec = v[0];
        @(posedge rst_n); repeat (3) @(posedge clk);
        kicked = 0;
        for (r = 0; r < nrec; r = r + 1) begin
            base = 1 + r * RECW;
            for (i = 0; i < 12; i = i + 1) h[i] = v[base + i];
            kind = h[0];
            if (kind == 0) begin
                if (!kicked) begin
                    st_write(`AD_S_LC_REGION, h[1]);
                    st_write(`AD_S_LC_ADDR, h[2]);
                    st_write(`AD_S_LC_WORDS, h[3]);
                    lc_kick <= 1; @(posedge clk); lc_kick <= 0;
                end
                #1;
                if (!kicked && !busy) begin $display("FAIL ad_su_cbank: busy not set by lc_kick"); errs_load = errs_load + 1; end
                kicked = 0;
                wait_c = 0;
                while (busy) begin
                    if (x_ready) begin $display("FAIL ad_su_cbank: x_ready while loading"); errs_load = errs_load + 1; end
                    @(posedge clk); #1; wait_c = wait_c + 1;
                    if (wait_c > 20000) begin $display("FAIL ad_su_cbank: load hangs"); $finish; end
                end
                check_bank(r);
                check_c(r);
            end else if (kind == 2) begin
                inv <= 1; @(posedge clk); inv <= 0; #1;
                check_bank(r);
                check_c(r);
            end else begin
                for (i = 0; i < NP; i = i + 1) begin
                    x_a[i*32 +: 32] = v[base + 12 + i];
                    e[i*32 +: 32]   = v[base + 12 + NP + i];
                end
                x_uop = 0;
                x_uop[AD_UOP_UNIT +: 4] = AD_UNIT_CBANK;
                x_uop[AD_UOP_OP +: 8]   = AD_CBANK_LWC;
                x_uop[AD_UOP_IMM +: 32] = h[2];
                x_uop[AD_UOP_WRD]       = h[3][0];
                x_uop[AD_UOP_RD +: 7]   = h[11];
                x_uop[AD_UOP_CLS +: 3]  = AD_CLS_M;
                x_mask = {{NP{1'b0}}, h[4][NP-1:0]};
                x_last = h[6][0];
                x_warp = $random(seed); x_grp = $random(seed); x_sbe = $random(seed);
                // the next event is a LOAD: sometimes kick it during this group
                kick_early = (r + 1 < nrec) && (v[1 + (r + 1) * RECW] == 0) && ($random(seed) & 1);
                if (kick_early) begin
                    st_write(`AD_S_LC_REGION, v[1 + (r + 1) * RECW + 1]);
                    st_write(`AD_S_LC_ADDR, v[1 + (r + 1) * RECW + 2]);
                    st_write(`AD_S_LC_WORDS, v[1 + (r + 1) * RECW + 3]);
                end
                x_valid <= 1;
                #1;
                while (!x_ready) begin @(posedge clk); #1; end
                @(posedge clk);
                x_valid <= 0;
                if (kick_early) begin lc_kick <= 1; @(posedge clk); lc_kick <= 0; kicked = 1; end
                #1;
                wait_c = 0;
                while (!(l_valid && l_ready)) begin
                    @(posedge clk); #1; wait_c = wait_c + 1;
                    if (wait_c > 1000) begin $display("FAIL ad_su_cbank: no beat"); $finish; end
                end
                if (l_lanes !== h[7][NP-1:0] || l_wr !== h[8][0] || l_last !== h[6][0] ||
                    l_rd !== h[11][6:0] || l_warp !== x_warp || l_grp !== x_grp || l_sbe !== x_sbe ||
                    l_cls !== AD_CLS_M) begin
                    $display("FAIL ad_su_cbank: NP%0d r %0d beat fields", NP, r);
                    errs_read = errs_read + 1;
                end
                for (ln = 0; ln < NP; ln = ln + 1)
                    if (h[7][ln] && l_data[ln*32 +: 32] !== e[ln*32 +: 32]) begin
                        if (errs_read < 10) $display("FAIL ad_su_cbank: NP%0d r %0d lwc lane %0d %h exp %h", NP, r, ln,
                                                     l_data[ln*32 +: 32], e[ln*32 +: 32]);
                        errs_read = errs_read + 1;
                    end
                @(posedge clk);
                if (kicked) begin
                    #1;
                    if (!busy) begin $display("FAIL ad_su_cbank: kick during lwc lost"); errs_load = errs_load + 1; end
                end
            end
        end
        // scrub: every word 0, scrub_busy CONST_WORDS cycles
        scrub <= 1; @(posedge clk); scrub <= 0; #1;
        nb = 0;
        while (scrub_busy) begin nb = nb + 1; @(posedge clk); #1; end
        if (nb != CWORDS) begin $display("FAIL ad_su_cbank: scrub_busy %0d cycles", nb); errs_read = errs_read + 1; end
        for (i = 0; i < CWORDS; i = i + 1)
            if (dut.u_ram.mem[i] !== 32'd0) begin
                $display("FAIL ad_su_cbank: word %0d not scrubbed", i); errs_read = errs_read + 1;
            end
        for (i = 0; i < CWORDS; i = i + 1) bk[i] = 32'd0;
        check_c(0);
        ok = {errs_read == 0, errs_load == 0};
        done = 1;
    end
endmodule

module ad_su_cbank_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    wire d0, d1; wire [1:0] ok0, ok1;
    ad_su_cbank_tb_core #(.NP(4), .SEED(13)) c4 (.clk(clk), .rst_n(rst_n), .done(d0), .ok(ok0));
    ad_su_cbank_tb_core #(.NP(8), .SEED(17)) c8 (.clk(clk), .rst_n(rst_n), .done(d1), .ok(ok1));
    initial begin
        repeat (4) @(posedge clk); rst_n <= 1;
        wait (d0 && d1);
        if (ok0[0] && ok1[0]) $display("PASS ad_su_cbank.load"); else $display("FAIL ad_su_cbank.load");
        if (ok0[1] && ok1[1]) $display("PASS ad_su_cbank.read"); else $display("FAIL ad_su_cbank.read");
        if (&{ok0, ok1}) $display("PASS ad_su_cbank");
        $finish;
    end
    initial begin #50000000; $display("FAIL ad_su_cbank timeout"); $finish; end
endmodule
