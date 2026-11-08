// ad_su_pipe_tb -- ad_su_pipe (NPHYS 8, SHORT_LAT 6) with ad_su_alu and the real
// ad_su_fpu (or sim/common/ad_su_fpu_stub.v with -DPIPE_FPU_STUB): random ALU (sim/vec/
// core_alu.hex, gsi1model.alu) and FPU (sim/vec/core_fpu.hex, gsi1fp.fpu) groups,
// other units' groups and uops without WRD, rd 63 sometimes, a group held on x_* while
// x_ready is 0.  Phase 1: en always 1; phase 2: en random.  Checks every cycle that s_*
// is the group SHORT_LAT en-cycles after it was taken (E counts the en cycles), held
// while en is 0.
//  .lat    en = 1: exactly SHORT_LAT cycles, one result a cycle back to back (ALU and FPU mixed)
//  .data   the merged results equal the references (ALU and FPU)
//  .freeze en = 0 freezes every stage (x_ready 0, s_* held, nothing lost or repeated)
`timescale 1ns/1ps
module ad_su_pipe_tb;
`include "ad_su_uop.vh"
    localparam NPHYS = 8, L = 6, WARP_W = 2, GRP_W = 2, NA = 4000, NF = 6000;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg [167:0] va [0:NA-1]; reg [143:0] vf [0:NF-1];
    initial begin $readmemh("sim/vec/core_alu.hex", va); $readmemh("sim/vec/core_fpu.hex", vf); end
    reg en = 1, x_valid = 0; reg [WARP_W-1:0] x_warp = 0; reg [GRP_W-1:0] x_grp = 0; reg [107:0] x_uop = 0;
    reg [NPHYS*32-1:0] x_a = 0, x_b = 0, x_c = 0; reg [2*NPHYS-1:0] x_mask = 0;
    wire x_ready, s_valid; wire [WARP_W-1:0] s_warp; wire [GRP_W-1:0] s_grp; wire [6:0] s_rd;
    wire [NPHYS*32-1:0] s_data; wire [NPHYS-1:0] s_lanes;
    ad_su_pipe #(.NPHYS(NPHYS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SHORT_LAT(L)) dut (
        .clk(clk), .rst_n(rst_n), .en(en), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(1'b1),
        .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
        .x_info(32'd0), .x_ready(x_ready), .s_valid(s_valid), .s_warp(s_warp), .s_grp(s_grp), .s_rd(s_rd),
        .s_data(s_data), .s_lanes(s_lanes));
    // expected results by en-cycle number
    reg ev [0:63]; reg [WARP_W+GRP_W+7+NPHYS-1:0] et [0:63]; reg [NPHYS*32-1:0] ed [0:63]; reg ef [0:63];
    reg [NPHYS*32-1:0] cur_d; reg cur_v; reg [WARP_W+GRP_W+7+NPHYS-1:0] cur_t;
    integer E = 0, cyc = 0, seed = 5, ia = 0, ifp = 0, phase = 1, i, j;
    integer e_lat = 0, e_dat = 0, e_frz = 0, n_res = 0, n_b2b = 0, n_frz = 0, n_fpu = 0, last_res = -9;
    reg [167:0] a; reg [143:0] f; reg [3:0] unit; reg wrd; reg [6:0] rd;
    reg p_v; reg [WARP_W+GRP_W+7+NPHYS*33-1:0] p_s;   // s_* of the last cycle (freeze check)
    reg p_en;
    initial begin for (i = 0; i < 64; i = i + 1) ev[i] = 0; p_v = 0; p_en = 1; end
    always @(posedge clk) if (rst_n) begin
        // ---------- check the ended cycle ----------
        j = (E - L) & 63;
        if (s_valid !== (E >= L && ev[j])) begin
            if (phase == 1) e_lat = e_lat + 1; else e_frz = e_frz + 1;
            if (e_lat + e_frz < 5) $display("ERROR pipe cyc %0d E %0d s_valid %b exp %b", cyc, E, s_valid, ev[j]);
        end else if (s_valid) begin
            if ({s_warp, s_grp, s_rd, s_lanes} !== et[j]) begin if (phase == 1) e_lat = e_lat + 1; else e_frz = e_frz + 1; end
            if (s_data !== ed[j]) begin e_dat = e_dat + 1; if (e_dat < 5) $display("ERROR pipe cyc %0d data %h exp %h (%s)", cyc, s_data, ed[j], ef[j] ? "fpu" : "alu"); end
            if (en) begin n_res = n_res + 1; if (last_res == cyc - 1 && phase == 1) n_b2b = n_b2b + 1; last_res = cyc; if (ef[j]) n_fpu = n_fpu + 1; end
        end
        if (!p_en) begin
            n_frz = n_frz + 1;
            if (s_valid !== p_v || (s_valid && {s_warp, s_grp, s_rd, s_data, s_lanes} !== p_s)) e_frz = e_frz + 1;
        end
        if (x_ready !== en) e_frz = e_frz + 1;
        p_v = s_valid; p_s = {s_warp, s_grp, s_rd, s_data, s_lanes}; p_en = en;
        // record the group taken in the ended cycle
        if (en) begin
            unit = x_uop[AD_UOP_UNIT +: 4];
            ev[E & 63] = x_valid && x_uop[AD_UOP_WRD] && (unit == AD_UNIT_ALU || unit == AD_UNIT_FPU);
            ef[E & 63] = unit == AD_UNIT_FPU;
            et[E & 63] = {x_warp, x_grp, x_uop[AD_UOP_RD +: 7], x_mask[NPHYS-1:0]};
            ed[E & 63] = cur_d;
            E = E + 1;
        end
        // ---------- drive the next cycle ----------
        if (!(x_valid && !x_ready)) begin
            x_valid <= 0;
            if ((phase == 1 && $random(seed) % 8 != 0) || (phase == 2 && $random(seed) % 3 != 0)) begin
                x_valid <= 1;
                i = {$random(seed)} % 10;
                unit = (i < 5) ? AD_UNIT_ALU : (i < 9) ? AD_UNIT_FPU : AD_UNIT_LSU;
                wrd = $random(seed) % 10 != 0; rd = ($random(seed) % 10 == 0) ? 63 : {$random(seed)} % 63;
                x_uop <= 0;
                if (unit == AD_UNIT_FPU) begin
                    f = vf[ifp % NF]; ifp = ifp + 1;
                    x_uop[AD_UOP_OP +: 8] <= f[143:136]; x_uop[AD_UOP_RM +: 3] <= f[135:132];
                    x_uop[AD_UOP_MOD + 6] <= f[128];
                    x_a <= {NPHYS{f[127:96]}}; x_b <= {NPHYS{f[95:64]}}; x_c <= {NPHYS{f[63:32]}};
`ifdef PIPE_FPU_STUB
                    cur_d = {NPHYS{f[127:96] ^ f[95:64] ^ f[63:32] ^ {24'd0, f[143:136]}}};
`else
                    cur_d = {NPHYS{f[31:0]}};
`endif
                end else begin
                    a = va[ia % NA]; ia = ia + 1;
                    x_uop[AD_UOP_OP +: 8] <= a[167:160]; x_uop[AD_UOP_IMM +: 32] <= a[63:32];
                    x_a <= {NPHYS{a[159:128]}}; x_b <= {NPHYS{a[127:96]}}; x_c <= {NPHYS{a[95:64]}};
                    cur_d = {NPHYS{a[31:0]}};
                end
                x_uop[AD_UOP_UNIT +: 4] <= unit; x_uop[AD_UOP_WRD] <= wrd; x_uop[AD_UOP_RD +: 7] <= rd;
                x_warp <= $random(seed); x_grp <= $random(seed); x_mask <= $random(seed);
            end
        end
        if (phase == 2) en <= ($random(seed) % 3 != 0); else en <= 1;
        cyc = cyc + 1;
        if (cyc == 12000) phase = 2;
        if (cyc == 24000) begin
            $display("pipe: %0d results (%0d fpu), %0d back to back, %0d frozen cycles", n_res, n_fpu, n_b2b, n_frz);
            if (e_lat == 0 && n_b2b > 3000) $display("PASS ad_su_pipe.lat"); else $display("FAIL ad_su_pipe.lat (%0d)", e_lat);
            if (e_dat == 0 && n_fpu > 3000) $display("PASS ad_su_pipe.data"); else $display("FAIL ad_su_pipe.data (%0d)", e_dat);
            if (e_frz == 0 && n_frz > 2000) $display("PASS ad_su_pipe.freeze"); else $display("FAIL ad_su_pipe.freeze (%0d)", e_frz);
            if (e_lat + e_dat + e_frz == 0) $display("PASS ad_su_pipe");
            $finish;
        end
    end
    initial begin repeat (3) @(posedge clk); rst_n <= 1; end
endmodule
