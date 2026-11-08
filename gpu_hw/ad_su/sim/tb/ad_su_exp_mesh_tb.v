// ad_su_exp_mesh_tb -- the meshlet export (ad_su_exp_mesh through ad_su_exp: exp 0x200 kicks)
// against tools/gen_gfx_vectors.py mesh_ref() (sim/vec/gfx_mesh_lds.hex, gfx_mesh_cmd.hex,
// gfx_mesh_exp.hex).  The testbench is ad_su_opd (an exp 0x200 per meshlet, the base address in
// rs2 of the lowest side-effect lane; the first group with side-effect lanes kicks; other lanes
// and later groups carry other values), the LDS port B (one-cycle read latency) and ad_rx_setup
// (random mesh_ready).  Checks: every package, mesh_last, mesh_id in order (culled primitives,
// a meshlet whose last primitive is culled, one with every primitive culled, nprim 0, one
// wrapping around the LDS), x_ready 0 while mesh_busy, LDS reads only while busy.
`timescale 1ns/1ps
module ad_su_exp_mesh_tb;
`include "ad_su_uop.vh"
    localparam NPHYS = 8, GPW = 4;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg [31:0] lds [0:1023];
    reg [31:0] kk [0:63];
    reg [31:0] ex [0:4095];
    initial begin
        $readmemh("sim/vec/gfx_mesh_lds.hex", lds);
        $readmemh("sim/vec/gfx_mesh_cmd.hex", kk);
        $readmemh("sim/vec/gfx_mesh_exp.hex", ex);
    end
    reg x_valid = 0, x_last = 0; reg [1:0] x_warp = 0; reg [1:0] x_grp = 0; reg [107:0] x_uop = 0;
    reg [NPHYS*32-1:0] x_b = 0; reg [2*NPHYS-1:0] x_mask = 0;
    wire x_ready;
    wire mesh_valid, mesh_last, mesh_busy, lds_en; wire [701:0] mesh_tri; wire [15:0] mesh_id;
    wire [9:0] lds_a; reg [31:0] lds_q; reg mesh_ready = 0;
    wire ex_valid, ex_last, xr_valid, scrub_busy; wire [1:0] xr_warp; wire [15:0] ex_seq;
    wire [31:0] ex_xy; wire [3:0] ex_mask; wire [511:0] ex_color; wire [127:0] ex_depth;
    wire [153:0] ex_aux;
    ad_su_exp #(.NPHYS(NPHYS)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
        .x_last(x_last), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a({NPHYS{32'h0}}),
        .x_b(x_b), .x_c({NPHYS{32'h0}}), .x_mask(x_mask), .x_info(32'h0002_0000),
        .x_ready(x_ready), .ex_valid(ex_valid), .ex_ready(1'b1), .ex_seq(ex_seq), .ex_xy(ex_xy),
        .ex_mask(ex_mask), .ex_color(ex_color), .ex_depth(ex_depth), .ex_last(ex_last),
        .ex_next(16'd0), .fl_we(1'b0), .fl_slot(2'd0), .fl_reg(6'd0), .fl_lane(5'd0),
        .fl_data(32'd0), .fl_go(1'b0), .fl_info(64'd0), .fl_pw_we(1'b0), .fl_pw_addr(12'd0),
        .fl_pw_data(32'd0), .ex_aux(ex_aux), .xr_valid(xr_valid), .xr_warp(xr_warp),
        .wc_end(1'b0), .wc_warp(2'd0), .mesh_valid(mesh_valid), .mesh_ready(mesh_ready),
        .mesh_tri(mesh_tri), .mesh_last(mesh_last), .mesh_id(mesh_id), .mesh_busy(mesh_busy),
        .mesh_lds_rd_en(lds_en), .mesh_lds_rd_addr(lds_a), .mesh_lds_rd_data(lds_q),
        .scrub(1'b0), .scrub_busy(scrub_busy));

    always @(posedge clk) if (lds_en) lds_q <= lds[lds_a];

    integer seed = 5, err = 0, np = 0, ncull = 0, i;
    reg [701:0] want;
    reg pv; reg [719:0] pd;
    always @(posedge clk) begin
        if (rst_n) begin
            if (pv && (!mesh_valid || {mesh_id, mesh_last, mesh_tri} !== pd)) begin
                err = err + 1;
                $display("FAIL mesh: package %0d changed while not taken", np);
            end
            pv <= mesh_valid && !mesh_ready;
            pd <= {mesh_id, mesh_last, mesh_tri};
            if (lds_en && !mesh_busy) begin
                err = err + 1;
                $display("FAIL mesh: LDS read while idle");
            end
            if (mesh_busy && x_ready) begin
                err = err + 1;
                $display("FAIL mesh: x_ready while busy");
            end
            if (mesh_valid && mesh_ready) begin
                for (i = 0; i < 22; i = i + 1) want[32*i +: 32] = ex[1 + 24*np + 1 + i];
                if (np >= ex[0] || mesh_tri !== want || mesh_last !== ex[1 + 24*np][16] ||
                    mesh_id !== ex[1 + 24*np][15:0]) begin
                    err = err + 1;
                    $display("FAIL mesh: package %0d id %h last %b", np, mesh_id, mesh_last);
                end
                np = np + 1;
            end
            mesh_ready <= ($random(seed) % 3) != 0;
        end else pv <= 1'b0;
    end

    integer m, g, k, lo, t;
    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        for (m = 0; m < kk[0]; m = m + 1) begin
            // the instruction: groups 0..lo-1 without side-effect lanes, then the kick
            lo = $random(seed) & 1;
            for (g = 0; g < GPW; g = g + 1) begin
                while (!x_ready) @(posedge clk);
                x_valid <= 1'b1;
                x_uop <= 108'd0;
                x_uop[AD_UOP_UNIT +: 4] <= AD_UNIT_EXP;
                x_uop[AD_UOP_IMM +: 32] <= 32'h200;
                x_grp <= g;
                x_last <= (g == GPW - 1);
                for (k = 0; k < NPHYS; k = k + 1) begin
                    x_b[32*k +: 32] <= 32'h3FF & $random(seed);
                    x_mask[k] <= 1'b1;
                    x_mask[NPHYS + k] <= (g >= lo) && (k >= 2 || g > lo) && ($random(seed) & 1);
                end
                if (g == lo) begin
                    x_b[32*2 +: 32] <= kk[1 + m];
                    x_mask[NPHYS + 2] <= 1'b1;
                end
                @(posedge clk);
                x_valid <= 1'b0;
            end
            t = 0;
            @(posedge clk);
            while (mesh_busy && t < 5000) begin
                @(posedge clk);
                t = t + 1;
            end
            if (t >= 5000) begin
                err = err + 1;
                $display("FAIL mesh: meshlet %0d stuck", m);
            end
        end
        repeat (5) @(posedge clk);
        if (err == 0 && np == ex[0] && np > 10) $display("PASS ad_su_exp_mesh.stream");
        else $display("FAIL ad_su_exp_mesh.stream (%0d errors, %0d of %0d packages)", err, np, ex[0]);
        if (err == 0 && np == ex[0]) $display("PASS ad_su_exp_mesh");
        $finish;
    end
endmodule
