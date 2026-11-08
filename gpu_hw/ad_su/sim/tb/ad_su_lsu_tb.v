// ad_su_lsu_tb -- self-checking testbench of ad_su_lsu (spec §8).
// ad_su_lsu + ad_su_dcache + ad_amb_mem (128 lines; lines above answer an
// error) + a model of ad_mc_atom (atomic at acceptance on the memory's
// backdoor, old values in order after a random latency, error above the
// memory), for NPHYS 4 and 8 (one core each).  Vectors from
// tools/gen_mem_vectors.py (sim/vec/ad_su_lsu<N>_ops.hex: a count, then per
// group 12 header words {op, sub, imm, wrd, exec, side, last, exp lanes,
// exp l_wr, exp requests, section, rd}, a[N], b[N], c[N], exp[N];
// ad_su_lsu<N>_mem<k>.hex: the memory before section 0 and after section k-1).
// Checks per group: the beat (lanes, l_wr, data of the lanes, l_last, rd,
// warp, grp, sbe, cls), the D$ request count (lw, sw: distinct lines) or
// at_* count (atom), no beat before the last write response, dc_inv one
// cycle after a fence or an atom is taken, no beat for a fence, an empty
// group's beat within 2 cycles without a request; the memory after each section.
`timescale 1ns/1ps
module ad_su_lsu_tb_core #(
    parameter NP   = 8,
    parameter SEED = 1
) (
    input  wire clk,
    input  wire rst_n,
    output reg  done,
    output reg  [3:0] ok        // coalesce, store, atom, empty
);
    localparam LB = 32, LS = 5, AW = 32, LW = AW - LS, MEMLINES = 128;
    localparam GW = (NP == 32) ? 1 : $clog2(32 / NP);
    localparam RECW = 12 + 4 * NP;
    localparam MAXW = 200000;
    `include "ad_su_uop.vh"

    // DUT inputs
    reg              x_valid, x_last;
    reg  [1:0]       x_warp;
    reg  [GW-1:0]    x_grp;
    reg  [2:0]       x_sbe;
    reg  [107:0]     x_uop;
    reg  [NP*32-1:0] x_a, x_b, x_c;
    reg  [2*NP-1:0]  x_mask;
    reg              l_ready;
    wire             x_ready, l_valid, l_wr, l_last;
    wire [1:0]       l_warp;
    wire [GW-1:0]    l_grp;
    wire [6:0]       l_rd;
    wire [NP*32-1:0] l_data;
    wire [NP-1:0]    l_lanes;
    wire [2:0]       l_sbe, l_cls;
    wire             dq_v, dq_r, dq_w, dr_v, dr_w, dr_e, dc_inv;
    wire [LW-1:0]    dq_l;
    wire [LB-1:0]    dq_be;
    wire [LB*8-1:0]  dq_d, dr_d;
    wire [7:0]       dq_t, dr_t;
    wire             mq_v, mq_r, mq_w, mr_v, mr_w, mr_e;
    wire [LW-1:0]    mq_l;
    wire [LB-1:0]    mq_be;
    wire [LB*8-1:0]  mq_d, mr_d;
    wire [7:0]       mq_t, mr_t;
    wire             at_valid;
    reg              at_ready, at_rsp_valid, at_error;
    wire [3:0]       at_op;
    wire [29:0]      at_addr;
    wire [31:0]      at_a, at_b;
    reg  [31:0]      at_old;

    ad_su_lsu #(.NPHYS(NP), .GRP_W(GW), .UOP_W(108)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last),
        .x_sbe(x_sbe), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
        .x_info(32'd0), .x_ready(x_ready), .l_valid(l_valid), .l_ready(l_ready), .l_warp(l_warp),
        .l_grp(l_grp), .l_rd(l_rd), .l_data(l_data), .l_lanes(l_lanes), .l_wr(l_wr), .l_last(l_last),
        .l_sbe(l_sbe), .l_cls(l_cls),
        .dc_req_valid(dq_v), .dc_req_ready(dq_r), .dc_req_write(dq_w), .dc_req_line(dq_l),
        .dc_req_be(dq_be), .dc_req_wdata(dq_d), .dc_req_tag(dq_t), .dc_rsp_valid(dr_v),
        .dc_rsp_write(dr_w), .dc_rsp_tag(dr_t), .dc_rsp_rdata(dr_d), .dc_rsp_error(dr_e),
        .at_valid(at_valid), .at_ready(at_ready), .at_op(at_op), .at_addr(at_addr), .at_a(at_a),
        .at_b(at_b), .at_rsp_valid(at_rsp_valid), .at_old(at_old), .at_error(at_error), .dc_inv(dc_inv));
    ad_su_dcache dc (
        .clk(clk), .rst_n(rst_n), .inv(dc_inv),
        .u_req_valid(dq_v), .u_req_ready(dq_r), .u_req_write(dq_w), .u_req_line(dq_l), .u_req_be(dq_be),
        .u_req_wdata(dq_d), .u_req_tag(dq_t), .u_rsp_valid(dr_v), .u_rsp_write(dr_w), .u_rsp_tag(dr_t),
        .u_rsp_rdata(dr_d), .u_rsp_error(dr_e),
        .m_req_valid(mq_v), .m_req_ready(mq_r), .m_req_write(mq_w), .m_req_line(mq_l), .m_req_be(mq_be),
        .m_req_wdata(mq_d), .m_req_tag(mq_t), .m_rsp_valid(mr_v), .m_rsp_write(mr_w), .m_rsp_tag(mr_t),
        .m_rsp_rdata(mr_d), .m_rsp_error(mr_e));
    ad_amb_mem #(.MEM_LINES(MEMLINES), .LAT_MIN(1), .LAT_MAX(8), .READY_PCT(70), .SEED(SEED)) u_mem (
        .clk(clk), .rst_n(rst_n), .req_valid(mq_v), .req_ready(mq_r), .req_write(mq_w), .req_line(mq_l),
        .req_be(mq_be), .req_wdata(mq_d), .req_tag(mq_t), .rsp_valid(mr_v), .rsp_write(mr_w),
        .rsp_tag(mr_t), .rsp_rdata(mr_d), .rsp_error(mr_e));

    integer seed = SEED, errors = 0, i;
    integer sec_err [0:3];
    reg [31:0] v [0:MAXW-1];
    reg [31:0] snap [0:MEMLINES*LB/4-1];

    // ---- model of ad_mc_atom ----
    function [31:0] atomf(input [3:0] op, input [31:0] old, input [31:0] a, input [31:0] b);
        case (op)
            0: atomf = old & a;  1: atomf = old | a;  2: atomf = old ^ a;  3: atomf = a;
            4: atomf = old + a;  5: atomf = old - a;
            6: atomf = ($signed(old) > $signed(a)) ? old : a;
            7: atomf = ($signed(old) < $signed(a)) ? old : a;
            8: atomf = (old > a) ? old : a;
            9: atomf = (old < a) ? old : a;
            default: atomf = (old == b) ? a : old;
        endcase
    endfunction
    reg [31:0] aq_old [0:15]; reg aq_err [0:15]; integer aq_due [0:15];
    integer aq_h = 0, aq_t = 0, cyc = 0, n_at = 0;
    reg [31:0] ow, nw; integer bi;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        at_rsp_valid <= 1'b0;
        if (rst_n) begin
            if (at_valid && at_ready) begin
                n_at = n_at + 1;
                bi = at_addr * 4;
                aq_err[aq_t % 16] = (at_addr >= MEMLINES * LB / 4);
                if (!aq_err[aq_t % 16]) begin
                    ow = {u_mem.mem[bi+3], u_mem.mem[bi+2], u_mem.mem[bi+1], u_mem.mem[bi]};
                    nw = atomf(at_op, ow, at_a, at_b);
                    {u_mem.mem[bi+3], u_mem.mem[bi+2], u_mem.mem[bi+1], u_mem.mem[bi]} = nw;
                end else ow = 32'd0;
                aq_old[aq_t % 16] = ow;
                aq_due[aq_t % 16] = cyc + 1 + ($unsigned($random(seed)) % 6);
                aq_t = aq_t + 1;
            end
            if (aq_h != aq_t && aq_due[aq_h % 16] <= cyc) begin
                at_rsp_valid <= 1'b1; at_old <= aq_old[aq_h % 16]; at_error <= aq_err[aq_h % 16];
                aq_h = aq_h + 1;
            end
        end
        at_ready <= ($random(seed) % 3) != 0;
    end

    // ---- monitors: D$ requests, outstanding, inv ----
    integer n_dq = 0, outst = 0;
    always @(posedge clk) if (rst_n) begin
        if (dq_v && dq_r) n_dq = n_dq + 1;
        outst = outst + (dq_v && dq_r) - dr_v;
    end
    reg p_v, p_r, p_w; reg [LW-1:0] p_l; reg [LB-1:0] p_be; reg [LB*8-1:0] p_d;
    reg ap_v, ap_r; reg [29:0] ap_a; reg [31:0] ap_x;
    always @(posedge clk) begin
        if (rst_n && p_v && !p_r && !(dq_v && dq_w == p_w && dq_l == p_l && (!p_w || (dq_be == p_be && dq_d == p_d)))) begin
            $display("FAIL ad_su_lsu: dc request payload not held"); errors = errors + 1;
        end
        if (rst_n && ap_v && !ap_r && !(at_valid && at_addr == ap_a && at_a == ap_x)) begin
            $display("FAIL ad_su_lsu: at request not held"); errors = errors + 1;
        end
        p_v <= dq_v; p_r <= dq_r; p_w <= dq_w; p_l <= dq_l; p_be <= dq_be; p_d <= dq_d;
        ap_v <= at_valid; ap_r <= at_ready; ap_a <= at_addr; ap_x <= at_a;
    end
    integer n_beats = 0;
    always @(posedge clk) if (rst_n && l_valid && l_ready) n_beats = n_beats + 1;
    always @(posedge clk) l_ready <= ($random(seed) % 10) < 7;

    task automatic check_mem(input integer k, input integer sec);
        integer w; reg [31:0] got;
        begin
            case (k)
                1: $readmemh($sformatf("sim/vec/ad_su_lsu%0d_mem1.hex", NP), snap);
                2: $readmemh($sformatf("sim/vec/ad_su_lsu%0d_mem2.hex", NP), snap);
                3: $readmemh($sformatf("sim/vec/ad_su_lsu%0d_mem3.hex", NP), snap);
                default: $readmemh($sformatf("sim/vec/ad_su_lsu%0d_mem4.hex", NP), snap);
            endcase
            for (w = 0; w < MEMLINES * LB / 4; w = w + 1) begin
                got = {u_mem.mem[4*w+3], u_mem.mem[4*w+2], u_mem.mem[4*w+1], u_mem.mem[4*w]};
                if (got !== snap[w]) begin
                    if (sec_err[sec] < 10) $display("FAIL ad_su_lsu: NP%0d sec %0d mem word %0d %h exp %h", NP, sec, w, got, snap[w]);
                    sec_err[sec] = sec_err[sec] + 1;
                end
            end
        end
    endtask

    integer r, nrec, base, sec, cur_sec, op, ln, dq0, at0, b0, t0, wait_c;
    reg [31:0] h [0:11];
    reg [NP*32-1:0] e;
    initial begin
        done = 0; ok = 0; x_valid = 0; x_last = 0; x_warp = 0; x_grp = 0; x_sbe = 0; x_uop = 0;
        x_a = 0; x_b = 0; x_c = 0; x_mask = 0;
        for (i = 0; i < 4; i = i + 1) sec_err[i] = 0;
        $readmemh($sformatf("sim/vec/ad_su_lsu%0d_ops.hex", NP), v);
        $readmemh($sformatf("sim/vec/ad_su_lsu%0d_mem0.hex", NP), snap);
        for (i = 0; i < MEMLINES * LB / 4; i = i + 1)
            {u_mem.mem[4*i+3], u_mem.mem[4*i+2], u_mem.mem[4*i+1], u_mem.mem[4*i]} = snap[i];
        nrec = v[0];
        @(posedge rst_n); repeat (3) @(posedge clk);
        cur_sec = 0;
        for (r = 0; r < nrec; r = r + 1) begin
            base = 1 + r * RECW;
            for (i = 0; i < 12; i = i + 1) h[i] = v[base + i];
            sec = h[10]; op = h[0];
            if (sec != cur_sec) begin
                repeat (20) @(posedge clk);
                check_mem(cur_sec + 1, cur_sec);
                cur_sec = sec;
            end
            for (i = 0; i < NP; i = i + 1) begin
                x_a[i*32 +: 32] = v[base + 12 + i];
                x_b[i*32 +: 32] = v[base + 12 + NP + i];
                x_c[i*32 +: 32] = v[base + 12 + 2*NP + i];
                e[i*32 +: 32]   = v[base + 12 + 3*NP + i];
            end
            // sometimes another unit's group first (ignored by the LSU)
            if (($random(seed) & 7) == 0) begin
                x_valid <= 1; x_uop <= 0; x_uop[AD_UOP_UNIT +: 4] <= AD_UNIT_LDS;
                @(posedge clk);
            end
            x_uop = 0;
            x_uop[AD_UOP_UNIT +: 4] = AD_UNIT_LSU;
            x_uop[AD_UOP_OP +: 8]   = op;
            x_uop[AD_UOP_SUB +: 5]  = h[1];
            x_uop[AD_UOP_IMM +: 32] = h[2];
            x_uop[AD_UOP_WRD]       = h[3][0];
            x_uop[AD_UOP_RD +: 7]   = h[11];
            x_uop[AD_UOP_CLS +: 3]  = (op == 3) ? AD_CLS_A : AD_CLS_M;
            x_mask = {h[5][NP-1:0], h[4][NP-1:0]};
            x_last = h[6][0];
            x_warp = $random(seed); x_grp = $random(seed); x_sbe = $random(seed);
            x_valid <= 1;
            #1;
            while (!x_ready) begin @(posedge clk); #1; end
            dq0 = n_dq; at0 = n_at; b0 = n_beats;
            @(posedge clk);         // taken
            t0 = cyc;
            x_valid <= 0;
            #1;
            if (op == 3 || (op == 2 && h[5][NP-1:0] != 0)) begin
                if (!dc_inv) begin
                    $display("FAIL ad_su_lsu: no dc_inv after fence/atom (r %0d)", r);
                    sec_err[sec] = sec_err[sec] + 1;
                end
            end
            if (op == 3) begin
                repeat (5) @(posedge clk);
                if (n_beats != b0) begin $display("FAIL ad_su_lsu: beat for a fence"); sec_err[sec] = sec_err[sec] + 1; end
            end else begin
                wait_c = 0;
                while (!(l_valid && l_ready)) begin
                    @(posedge clk); #1; wait_c = wait_c + 1;
                    if (wait_c > 5000) begin $display("FAIL ad_su_lsu: no beat"); $finish; end
                end
                // the beat is taken at the next edge
                if (outst != 0) begin
                    $display("FAIL ad_su_lsu: beat with %0d D$ requests outstanding", outst);
                    sec_err[sec] = sec_err[sec] + 1;
                end
                if (l_lanes !== h[7][NP-1:0] || l_wr !== h[8][0] || l_last !== h[6][0] ||
                    l_rd !== h[11][6:0] || l_warp !== x_warp || l_grp !== x_grp || l_sbe !== x_sbe ||
                    l_cls !== AD_CLS_M) begin
                    $display("FAIL ad_su_lsu: NP%0d r %0d beat fields lanes %b/%b wr %b/%b last %b/%b", NP, r,
                             l_lanes, h[7][NP-1:0], l_wr, h[8][0], l_last, h[6][0]);
                    sec_err[sec] = sec_err[sec] + 1;
                end
                for (ln = 0; ln < NP; ln = ln + 1)
                    if (h[7][ln] && l_data[ln*32 +: 32] !== e[ln*32 +: 32]) begin
                        if (sec_err[sec] < 10) $display("FAIL ad_su_lsu: NP%0d r %0d op %0d lane %0d %h exp %h", NP, r, op, ln,
                                 l_data[ln*32 +: 32], e[ln*32 +: 32]);
                        sec_err[sec] = sec_err[sec] + 1;
                    end
                if ((op == 2 ? n_at - at0 : n_dq - dq0) != h[9]) begin
                    $display("FAIL ad_su_lsu: NP%0d r %0d op %0d requests %0d exp %0d", NP, r, op,
                             op == 2 ? n_at - at0 : n_dq - dq0, h[9]);
                    sec_err[sec] = sec_err[sec] + 1;
                end
                @(posedge clk);
            end
        end
        repeat (20) @(posedge clk);
        check_mem(cur_sec + 1, cur_sec);
        for (i = 0; i < 4; i = i + 1) ok[i] = (sec_err[i] == 0) && (errors == 0);
        done = 1;
    end

    // an empty group: l_valid within 2 cycles of the take
    reg [1:0] e_cnt; reg e_on;
    always @(posedge clk) begin
        if (!rst_n) e_on <= 0;
        else if (x_valid && x_ready && x_uop[3:0] == 4'd6 && x_uop[11:4] != 8'd3 && x_mask == 0) begin
            e_on <= 1; e_cnt <= 0;
        end else if (e_on) begin
            if (l_valid) e_on <= 0;
            else begin
                e_cnt <= e_cnt + 1;
                if (e_cnt == 1) begin $display("FAIL ad_su_lsu: empty group not completed at once"); sec_err[3] = sec_err[3] + 1; e_on <= 0; end
            end
        end
    end
endmodule

module ad_su_lsu_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    wire d0, d1; wire [3:0] ok0, ok1;
    ad_su_lsu_tb_core #(.NP(4), .SEED(5)) c4 (.clk(clk), .rst_n(rst_n), .done(d0), .ok(ok0));
    ad_su_lsu_tb_core #(.NP(8), .SEED(9)) c8 (.clk(clk), .rst_n(rst_n), .done(d1), .ok(ok1));
    initial begin
        repeat (4) @(posedge clk); rst_n <= 1;
        wait (d0 && d1);
        if (ok0[0] && ok1[0]) $display("PASS ad_su_lsu.coalesce"); else $display("FAIL ad_su_lsu.coalesce");
        if (ok0[1] && ok1[1]) $display("PASS ad_su_lsu.store");    else $display("FAIL ad_su_lsu.store");
        if (ok0[2] && ok1[2]) $display("PASS ad_su_lsu.atom");     else $display("FAIL ad_su_lsu.atom");
        if (ok0[3] && ok1[3]) $display("PASS ad_su_lsu.empty");    else $display("FAIL ad_su_lsu.empty");
        if (&{ok0, ok1}) $display("PASS ad_su_lsu");
        $finish;
    end
    initial begin #50000000; $display("FAIL ad_su_lsu timeout"); $finish; end
endmodule
