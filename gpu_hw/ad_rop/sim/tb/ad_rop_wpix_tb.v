// ad_rop_wpix_tb -- ad_rop_wpix against tools/wb_model.py (vectors sim/vec/wb_wpix_<LB>.hex
// from tools/gen_wb_vectors.py): addresses, lines/passes, o_drop/o_read/o_path, slots
// (mask, entry, offset), ps, the old pixels (o_bdst) and the new pixels (o_res: path 2
// packing with the kept bits merged, path 0 = b_pix lanes) for every path-2 format,
// one and four samples, LINE_BYTES 32 and 64.  Path 1 results are ad_rop_fblend's (not
// checked here).
`timescale 1ns/1ps
`include "ad_rop_state.vh"

module ad_rop_wpix_bench #(
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5,
    parameter VECF = "sim/vec/wb_wpix_32.hex",
    parameter NVEC = 4096
) (
    input wire clk
);
`include "sim/tb/ad_rop_wpix_tb.vh"
    localparam LS = LINE_SHIFT, LB = LINE_BYTES;
    reg [WPIX_W-1:0] vec [0:NVEC-1];
    reg [WPIX_W-1:0] v;
    reg rst_n = 0, st_we = 0;
    reg [8:0] st_idx = 0;
    reg [31:0] st_wdata = 0;
    reg [31:0] i_xy = 0; reg [1:0] i_rt = 0; reg [15:0] i_smask = 0; reg [511:0] i_color = 0;
    reg i_r = 0; reg [1:0] i_j = 0, i_g = 0;
    reg [LB*8-1:0] i_line0 = 0, i_line1 = 0;
    reg [LS-1:0] i_off0 = 0, i_off1 = 0;
    reg [127:0] b_pix = 0;
    wire f_done;
    wire [31:0] o_addr; wire [1:0] o_nl, o_np, o_path; wire o_multi, o_drop, o_read, o_lw;
    wire [3:0] o_mask, o_ent; wire [511:0] o_bsrc, o_res; wire [127:0] o_bdst;
    wire [4*LS-1:0] o_soff; wire [4:0] o_ps;
    ad_rop_wpix #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) dut (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .i_xy(i_xy), .i_rt(i_rt), .i_smask(i_smask), .i_color(i_color), .i_r(i_r), .i_j(i_j), .i_g(i_g),
        .i_line0(i_line0), .i_line1(i_line1), .i_off0(i_off0), .i_off1(i_off1), .b_pix(b_pix),
        .f_go(1'b0), .f_done(f_done), .f_take(1'b0),
        .o_addr(o_addr), .o_nl(o_nl), .o_np(o_np), .o_multi(o_multi), .o_drop(o_drop), .o_read(o_read),
        .o_path(o_path), .o_lw(o_lw), .o_mask(o_mask), .o_bsrc(o_bsrc), .o_bdst(o_bdst), .o_res(o_res),
        .o_ent(o_ent), .o_soff(o_soff), .o_ps(o_ps));

    integer n, k, err_places = 0, err_pack = 0, n_pack = 0, n_multi = 0, n_s4 = 0, n_drop = 0, n_read = 0;
    integer cov2 [0:255];
    reg done = 0;
    reg [1:0] rt;
    reg [7:0] f;
    reg [LS-1:0] es;

    task stw(input [8:0] idx, input [31:0] d);
        begin @(negedge clk); st_we = 1; st_idx = idx; st_wdata = d; @(negedge clk); st_we = 0; end
    endtask
    task bad(input [8*12-1:0] what);
        begin
            err_places = err_places + 1;
            if (err_places < 8) $display("FAIL ad_rop_wpix.places LB %0d vec %0d %0s", LB, n, what);
        end
    endtask

    initial begin
        for (k = 0; k < 256; k = k + 1) cov2[k] = 0;
        for (n = 0; n < NVEC; n = n + 1) vec[n] = {WPIX_W{1'bx}};
        $readmemh(VECF, vec);
        repeat (2) @(negedge clk);
        rst_n = 1;
        for (n = 0; n < NVEC && vec[n][0] !== 1'bx; n = n + 1) begin
            v  = vec[n];
            rt = v[`WP_RT];
            stw(`AD_S_RT_FORMATS, v[`WP_FMTS]);
            stw(`AD_S_RT_FORMAT, {30'd0, v[`WP_RTFMT]});
            stw(`AD_S_MS_CTRL, {28'd0, v[`WP_MS]});
            stw(`AD_S_WRITE_MASK, {16'd0, v[`WP_WM]});
            stw(rt == 0 ? `AD_S_BLEND  : rt == 1 ? `AD_S_BLEND1 : rt == 2 ? `AD_S_BLEND2 : `AD_S_BLEND3, v[`WP_BLEND]);
            stw(rt == 0 ? `AD_S_RT_BASE : rt == 1 ? `AD_S_RT1_BASE : rt == 2 ? `AD_S_RT2_BASE : `AD_S_RT3_BASE, v[`WP_BASE]);
            stw(rt == 0 ? `AD_S_RT_STRIDE : rt == 1 ? `AD_S_RT1_STRIDE : rt == 2 ? `AD_S_RT2_STRIDE : `AD_S_RT3_STRIDE, v[`WP_STRIDE]);
            i_rt = rt; i_xy = v[`WP_XY]; i_smask = v[`WP_SMASK]; i_r = v[`WP_R]; i_j = v[`WP_J]; i_g = v[`WP_G];
            i_off0 = v[`WP_OFF0]; i_off1 = v[`WP_OFF1]; b_pix = v[`WP_BPIX]; i_color = v[`WP_COLOR];
            i_line0 = v[`WP_LINE0]; i_line1 = v[`WP_LINE1];
            #1;
            if (o_addr  !== v[`WP_E_ADDR])  bad("addr");
            if (o_nl    !== v[`WP_E_NL])    bad("nl");
            if (o_np    !== v[`WP_E_NP])    bad("np");
            if (o_multi !== v[`WP_E_MULTI]) bad("multi");
            if (o_drop  !== v[`WP_E_DROP])  bad("drop");
            if (o_read  !== v[`WP_E_READ])  bad("read");
            if (o_path  !== v[`WP_E_PATH])  bad("path");
            if (o_lw    !== v[`WP_E_LW])    bad("lw");
            if (o_mask  !== v[`WP_E_MASK])  bad("mask");
            if (o_ent   !== v[`WP_E_ENT])   bad("ent");
            if (o_ps    !== v[`WP_E_PS])    bad("ps");
            if (o_bdst  !== v[`WP_E_BDST])  bad("bdst");
            for (k = 0; k < 4; k = k + 1) begin
                es = v[`WP_E_SOFF] >> (8 * k);
                if (o_soff[k*LS +: LS] !== es) bad("soff");
            end
            if (o_multi) n_multi = n_multi + 1;
            if (o_np == 2'd3) n_s4 = n_s4 + 1;
            if (o_drop) n_drop = n_drop + 1;
            if (o_read) n_read = n_read + 1;
            if (v[`WP_E_CHK]) begin
                n_pack = n_pack + 1;
                f = v[`WP_FMTS] >> (8 * rt);
                if (o_path == 2'd2) cov2[f] = cov2[f] + 1;
                if (o_res !== v[`WP_E_RES]) begin
                    err_pack = err_pack + 1;
                    if (err_pack < 8) $display("FAIL ad_rop_wpix.pack LB %0d vec %0d path %0d fmt %0d got %h exp %h",
                                               LB, n, o_path, f, o_res, v[`WP_E_RES]);
                end
            end
        end
        if (n < 1000 || n_multi == 0 || n_s4 == 0 || n_drop == 0 || n_read == 0) begin
            err_places = err_places + 1;
            $display("FAIL ad_rop_wpix.places LB %0d coverage: %0d vectors, multi %0d, s4 %0d, drop %0d, read %0d",
                     LB, n, n_multi, n_s4, n_drop, n_read);
        end
        $display("ad_rop_wpix LB %0d: %0d vectors (%0d several-line, %0d four-sample, %0d result checks)",
                 LB, n, n_multi, n_s4, n_pack);
        done = 1;
    end
endmodule

module ad_rop_wpix_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    ad_rop_wpix_bench #(.LINE_BYTES(32), .LINE_SHIFT(5), .VECF("sim/vec/wb_wpix_32.hex")) b32 (.clk(clk));
    ad_rop_wpix_bench #(.LINE_BYTES(64), .LINE_SHIFT(6), .VECF("sim/vec/wb_wpix_64.hex")) b64 (.clk(clk));
    // the 24 path-2 formats
    reg [7:0] p2 [0:23];
    integer i, miss;
    initial begin
        p2[0] = 13; p2[1] = 14; p2[2] = 20; p2[3] = 21; p2[4] = 41; p2[5] = 42; p2[6] = 55; p2[7] = 56;
        p2[8] = 68; p2[9] = 74; p2[10] = 75; p2[11] = 81; p2[12] = 82; p2[13] = 95; p2[14] = 96;
        p2[15] = 98; p2[16] = 99; p2[17] = 100; p2[18] = 101; p2[19] = 102; p2[20] = 103;
        p2[21] = 107; p2[22] = 108; p2[23] = 109;
        wait (b32.done && b64.done);
        miss = 0;
        for (i = 0; i < 24; i = i + 1)
            if (b32.cov2[p2[i]] < 4 || b64.cov2[p2[i]] < 4) begin
                miss = miss + 1;
                $display("FAIL ad_rop_wpix.pack format %0d not covered", p2[i]);
            end
        if (b32.err_places + b64.err_places == 0) $display("PASS ad_rop_wpix.places");
        if (b32.err_pack + b64.err_pack + miss == 0) $display("PASS ad_rop_wpix.pack");
        if (b32.err_places + b64.err_places + b32.err_pack + b64.err_pack + miss == 0) $display("PASS ad_rop_wpix");
        $finish;
    end
    initial begin #50000000; $display("FAIL ad_rop_wpix timeout"); $finish; end
endmodule
