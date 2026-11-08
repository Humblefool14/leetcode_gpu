// ad_su_alu_tb -- ad_su_alu against tools/gsi1model.py alu() (sim/vec/core_alu.hex,
// tools/gen_core_vectors.py), NPHYS 8 and NPHYS 4 side by side.  Random issue
// (other units' groups, uops without WRD, rd 63, random lane masks); an in-TB
// scoreboard indexed by cycle checks s_* exactly SHORT_LAT cycles after the group
// and the forwarding taps fw4_* / fw5_* 2 and 1 cycles before it.
`timescale 1ns/1ps
module alu_h #(parameter NPHYS = 8, parameter SEED = 1) (
    input  wire clk,
    input  wire rst_n,
    input  wire run,
    output reg  done,
    output reg [31:0] ops_err,
    output reg [31:0] lat_err,
    output reg [31:0] nres
);
`include "ad_su_uop.vh"
    localparam L = 6, NV = 4000, WARP_W = 2, GRP_W = (NPHYS == 32) ? 1 : $clog2(32/NPHYS);
    reg [167:0] vec [0:NV-1];
    initial $readmemh("sim/vec/core_alu.hex", vec);
    reg x_valid; reg [WARP_W-1:0] x_warp; reg [GRP_W-1:0] x_grp; reg [107:0] x_uop;
    reg [NPHYS*32-1:0] x_a, x_b, x_c; reg [2*NPHYS-1:0] x_mask;
    wire x_ready, s_valid, f4v, f5v; wire [WARP_W-1:0] s_warp, f4w, f5w; wire [GRP_W-1:0] s_grp, f4g, f5g;
    wire [6:0] s_rd, f4r, f5r; wire [NPHYS*32-1:0] s_data, f4d, f5d; wire [NPHYS-1:0] s_lanes, f4l, f5l;
    ad_su_alu #(.NPHYS(NPHYS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SHORT_LAT(L)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(1'b0),
        .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
        .x_info(32'd0), .x_ready(x_ready), .s_valid(s_valid), .s_warp(s_warp), .s_grp(s_grp),
        .s_rd(s_rd), .s_data(s_data), .s_lanes(s_lanes),
        .fw4_valid(f4v), .fw4_warp(f4w), .fw4_grp(f4g), .fw4_rd(f4r), .fw4_data(f4d), .fw4_lanes(f4l),
        .fw5_valid(f5v), .fw5_warp(f5w), .fw5_grp(f5g), .fw5_rd(f5r), .fw5_data(f5d), .fw5_lanes(f5l));
    // scoreboard, by issue cycle mod 16
    reg               e_v [0:15];
    reg [WARP_W-1:0]  e_w [0:15];
    reg [GRP_W-1:0]   e_g [0:15];
    reg [6:0]         e_r [0:15];
    reg [NPHYS*32-1:0] e_d [0:15];
    reg [NPHYS-1:0]   e_l [0:15];
    integer cyc, vi, i, seed;
    reg [167:0] v; reg wrd; reg [107:0] t_uop; reg [NPHYS*32-1:0] t_a, t_b, t_c;
    reg [2*NPHYS-1:0] t_mask; reg [WARP_W-1:0] t_warp; reg [GRP_W-1:0] t_grp; reg [3:0] unit; reg [6:0] rd;
    initial begin
        seed = SEED; done = 0; ops_err = 0; lat_err = 0; nres = 0; cyc = 0; vi = 0; x_valid = 0;
        x_uop = 0; x_a = 0; x_b = 0; x_c = 0; x_mask = 0; x_warp = 0; x_grp = 0;
        for (i = 0; i < 16; i = i + 1) e_v[i] = 0;
    end
    always @(posedge clk) if (rst_n && run && !done) begin
        // ---- check this cycle's outputs (issued L cycles ago) ----
        begin : chk
            integer j4, j5, j6;
            j6 = (cyc - L - 1) & 15; j5 = (cyc - L) & 15; j4 = (cyc - L + 1) & 15;
            if (s_valid !== (cyc >= L+1 && e_v[j6])) begin lat_err = lat_err + 1;
                $display("ERROR alu%0d cyc %0d s_valid %b exp %b", NPHYS, cyc, s_valid, e_v[j6]); end
            else if (s_valid) begin
                nres = nres + 1;
                if (s_warp !== e_w[j6] || s_grp !== e_g[j6] || s_rd !== e_r[j6] || s_lanes !== e_l[j6])
                    begin lat_err = lat_err + 1; $display("ERROR alu%0d cyc %0d tag", NPHYS, cyc); end
                if (s_data !== e_d[j6]) begin ops_err = ops_err + 1;
                    $display("ERROR alu%0d cyc %0d data %h exp %h", NPHYS, cyc, s_data, e_d[j6]); end
            end
            if (f5v !== (cyc >= L && e_v[j5] && e_r[j5] < 63) ||
                (f5v && (f5d !== e_d[j5] || f5r !== e_r[j5] || f5w !== e_w[j5] || f5g !== e_g[j5] || f5l !== e_l[j5])))
                begin lat_err = lat_err + 1; $display("ERROR alu%0d cyc %0d fw5", NPHYS, cyc); end
            if (f4v !== (cyc >= L-1 && e_v[j4] && e_r[j4] < 63) ||
                (f4v && (f4d !== e_d[j4] || f4r !== e_r[j4] || f4w !== e_w[j4] || f4g !== e_g[j4] || f4l !== e_l[j4])))
                begin lat_err = lat_err + 1; $display("ERROR alu%0d cyc %0d fw4", NPHYS, cyc); end
        end
        if (x_ready !== 1'b1) lat_err = lat_err + 1;
        // ---- drive the next group ----
        x_valid <= 0; e_v[cyc & 15] = 0;
        if (vi < NV && $random(seed) % 4 != 0) begin
            unit = ($random(seed) % 5 == 0) ? AD_UNIT_FPU : AD_UNIT_ALU;
            wrd = ($random(seed) % 8 != 0);
            rd = ($random(seed) % 10 == 0) ? 7'd63 : ($random(seed) & 7'h3f);
            v = vec[vi];
            t_uop = 0;
            t_uop[AD_UOP_UNIT +: 4] = unit; t_uop[AD_UOP_OP +: 8] = v[167:160];
            t_uop[AD_UOP_IMM +: 32] = v[63:32]; t_uop[AD_UOP_WRD] = wrd; t_uop[AD_UOP_RD +: 7] = rd;
            t_uop[AD_UOP_MOD +: 7] = $random(seed);  // ignored by the ALU
            t_mask = $random(seed);
            for (i = 0; i < NPHYS; i = i + 1) begin
                // lane 0 carries the vector; the other lanes the vectors after it
                v = vec[(vi + i) % NV];
                if (i != 0) v[167:160] = vec[vi][167:160];
                if (i != 0) v[63:32] = vec[vi][63:32];
                t_a[32*i +: 32] = v[159:128]; t_b[32*i +: 32] = v[127:96]; t_c[32*i +: 32] = v[95:64];
                e_d[cyc & 15][32*i +: 32] = (i == 0) ? v[31:0] : ref1(v);
            end
            t_warp = $random(seed); t_grp = $random(seed);
            x_valid <= 1; x_uop <= t_uop; x_a <= t_a; x_b <= t_b; x_c <= t_c; x_mask <= t_mask;
            x_warp <= t_warp; x_grp <= t_grp;
            e_v[cyc & 15] = (unit == AD_UNIT_ALU) && wrd;
            e_w[cyc & 15] = t_warp; e_g[cyc & 15] = t_grp; e_r[cyc & 15] = rd;
            e_l[cyc & 15] = t_mask[NPHYS-1:0];
            if (unit == AD_UNIT_ALU) vi = vi + 1;
        end
        cyc = cyc + 1;
        if (vi >= NV && cyc > 0) begin : fin
            integer k; reg any; any = 0;
            for (k = 0; k < 16; k = k + 1) any = any | e_v[k];
            if (!any || cyc > 100000) done <= 1;
        end
    end
    // Reference for the lanes other than 0, whose (a, b, c) come from other vectors
    // with lane 0's op and imm: an independent re-statement of gsi1model.alu().
    function [31:0] ref1(input [167:0] w);
        reg [7:0] op; reg [31:0] a, b, c, im;
        begin
            op = w[167:160]; a = w[159:128]; b = w[127:96]; c = w[95:64]; im = w[63:32];
            if (op[7]) b = im;
            case (op[4:0])
            0: ref1 = a + b;  1: ref1 = a - b;  2: ref1 = a << b[4:0];
            3: ref1 = ($signed(a) < $signed(b)) ? 32'hFFFFFFFF : 0;
            4: ref1 = (a < b) ? 32'hFFFFFFFF : 0;
            5: ref1 = a ^ b;  6: ref1 = a >> b[4:0];  7: ref1 = $signed(a) >>> b[4:0];
            8: ref1 = a | b;  9: ref1 = a & b;
            10: ref1 = ($signed(a) < $signed(b)) ? a : b;  11: ref1 = ($signed(a) < $signed(b)) ? b : a;
            12: ref1 = (a < b) ? a : b;  13: ref1 = (a < b) ? b : a;
            14: ref1 = a & ~b;  15: ref1 = a | ~b;  16: ref1 = ~(a ^ b);
            17: ref1 = (a & b) | (~a & c);  18: ref1 = im;  default: ref1 = 0;
            endcase
        end
    endfunction
endmodule

module ad_su_alu_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    wire d8, d4; wire [31:0] o8, l8, n8, o4, l4, n4;
    reg run = 0;
    alu_h #(.NPHYS(8), .SEED(11)) h8 (.clk(clk), .rst_n(rst_n), .run(run), .done(d8), .ops_err(o8), .lat_err(l8), .nres(n8));
    alu_h #(.NPHYS(4), .SEED(23)) h4 (.clk(clk), .rst_n(rst_n), .run(run), .done(d4), .ops_err(o4), .lat_err(l4), .nres(n4));
    initial begin
        repeat (3) @(posedge clk); rst_n <= 1; run <= 1;
        wait (d8 && d4); @(posedge clk);
        $display("alu: %0d / %0d results checked (NPHYS 8 / 4)", n8, n4);
        if (o8 == 0 && o4 == 0 && n8 > 3000 && n4 > 3000) $display("PASS ad_su_alu.ops");
        else $display("FAIL ad_su_alu.ops (%0d %0d errors)", o8, o4);
        if (l8 == 0 && l4 == 0) $display("PASS ad_su_alu.lat"); else $display("FAIL ad_su_alu.lat (%0d %0d)", l8, l4);
        if (o8 == 0 && o4 == 0 && l8 == 0 && l4 == 0 && n8 > 3000) $display("PASS ad_su_alu");
        $finish;
    end
endmodule
