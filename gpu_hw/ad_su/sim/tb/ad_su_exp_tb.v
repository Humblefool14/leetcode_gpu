// ad_su_exp_tb -- ad_su_exp (with ad_su_exp_drain) against tools/gsi1model.py write_exports()
// (--exp-out / --ms-out) through sim/vec/gfx_exp_cmd.hex and gfx_exp_beats.hex
// (tools/gen_gfx_vectors.py).  NPHYS 8 and NPHYS 4 side by side.  The testbench is the RX
// (fl_*), ad_su_opd (exp groups with other units' groups in between, random gaps), ad_su_exec
// (wc_end in random warp order) and the ROP (random ex_ready, ex_next counting ex_last).
// Checks: every beat (seq, rt, qlast, qfirst, nocol, ex_last, mask, xy, colours of the lanes
// that exported the attachment, depth, ex_aux's front, d_s, zexp, smask), ex_* stable while
// ex_valid && !ex_ready, vertex releases exactly the cycle after wc_end, fragment releases
// once after their last beat, and the scrub.
`timescale 1ns/1ps
module exp_h #(parameter NPHYS = 8, parameter SEED = 1) (
    input  wire clk,
    input  wire rst_n,
    input  wire run,
    output reg  done,
    output reg [31:0] e_frag,
    output reg [31:0] e_rel,
    output reg [31:0] e_ms,
    output reg [31:0] e_mrt,
    output reg [31:0] nbeat
);
`include "ad_su_uop.vh"
    localparam WARP_W = 2, GRP_W = (NPHYS == 32) ? 1 : $clog2(32 / NPHYS), GPW = 32 / NPHYS;
    localparam NCMD = 200000, NBT = 30000;
    reg [31:0] cmd [0:NCMD-1];
    reg [31:0] bt [0:NBT-1];
    initial begin
        $readmemh("sim/vec/gfx_exp_cmd.hex", cmd);
        $readmemh("sim/vec/gfx_exp_beats.hex", bt);
    end

    reg x_valid, x_last; reg [WARP_W-1:0] x_warp; reg [GRP_W-1:0] x_grp; reg [107:0] x_uop;
    reg [NPHYS*32-1:0] x_b; reg [2*NPHYS-1:0] x_mask; reg [31:0] x_info;
    wire x_ready;
    reg ex_ready; reg [15:0] ex_next;
    wire ex_valid, ex_last; wire [15:0] ex_seq; wire [31:0] ex_xy; wire [3:0] ex_mask;
    wire [511:0] ex_color; wire [127:0] ex_depth; wire [153:0] ex_aux;
    reg fl_we, fl_go, fl_pw_we; reg [WARP_W-1:0] fl_slot; reg [5:0] fl_reg; reg [4:0] fl_lane;
    reg [31:0] fl_data, fl_pw_data; reg [63:0] fl_info; reg [11:0] fl_pw_addr;
    wire xr_valid; wire [WARP_W-1:0] xr_warp;
    reg wc_end; reg [WARP_W-1:0] wc_warp;
    reg scrub; wire scrub_busy;
    wire mesh_valid, mesh_last, mesh_busy, lds_en; wire [701:0] mesh_tri; wire [15:0] mesh_id;
    wire [9:0] lds_a;

    ad_su_exp #(.NPHYS(NPHYS), .NWARPS(4), .WARP_W(WARP_W), .GRP_W(GRP_W)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
        .x_last(x_last), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a({NPHYS{32'h0}}),
        .x_b(x_b), .x_c({NPHYS{32'h0}}), .x_mask(x_mask), .x_info(x_info), .x_ready(x_ready),
        .ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy),
        .ex_mask(ex_mask), .ex_color(ex_color), .ex_depth(ex_depth), .ex_last(ex_last),
        .ex_next(ex_next), .fl_we(fl_we), .fl_slot(fl_slot), .fl_reg(fl_reg), .fl_lane(fl_lane),
        .fl_data(fl_data), .fl_go(fl_go), .fl_info(fl_info), .fl_pw_we(fl_pw_we),
        .fl_pw_addr(fl_pw_addr), .fl_pw_data(fl_pw_data), .ex_aux(ex_aux),
        .xr_valid(xr_valid), .xr_warp(xr_warp), .wc_end(wc_end), .wc_warp(wc_warp),
        .mesh_valid(mesh_valid), .mesh_ready(1'b1), .mesh_tri(mesh_tri), .mesh_last(mesh_last),
        .mesh_id(mesh_id), .mesh_busy(mesh_busy), .mesh_lds_rd_en(lds_en),
        .mesh_lds_rd_addr(lds_a), .mesh_lds_rd_data(32'd0), .scrub(scrub),
        .scrub_busy(scrub_busy));

    integer seed;
    initial seed = SEED;

    // ---------------- the ROP: beats against the model ----------------
    integer bi;                       // beats taken
    reg [3:0] fragslot;               // slots that had fl_go (until released)
    reg [3:0] ended, drained;
    reg [3:0] seqslot_valid;
    reg [15:0] sseq [0:3];
    reg pv; reg [15:0] p_seq; reg [31:0] p_xy; reg [3:0] p_mask; reg [511:0] p_col;
    reg [127:0] p_dep; reg [153:0] p_aux; reg p_last;
    reg vexp; reg [1:0] vw;           // a vertex release is due this cycle
    integer i, base, w0, ln;
    reg [31:0] ms;
    always @(posedge clk) begin
        if (!rst_n) begin
            ex_ready <= 1'b0;
            ex_next <= 16'h0100;
            bi = 0;
            pv <= 1'b0;
            e_frag <= 0; e_rel <= 0; e_ms <= 0; e_mrt <= 0;
            vexp <= 1'b0;
        end else begin
            // stability while not taken
            if (pv && (ex_valid !== 1'b1 || ex_seq !== p_seq || ex_xy !== p_xy ||
                       ex_mask !== p_mask || ex_color !== p_col || ex_depth !== p_dep ||
                       ex_aux !== p_aux || ex_last !== p_last)) begin
                e_frag <= e_frag + 1;
                $display("FAIL exp%0d: beat %0d changed while not taken", NPHYS, bi);
            end
            pv <= ex_valid && !ex_ready;
            p_seq <= ex_seq; p_xy <= ex_xy; p_mask <= ex_mask; p_col <= ex_color;
            p_dep <= ex_depth; p_aux <= ex_aux; p_last <= ex_last;
            if (ex_valid && ex_ready) begin
                base = 1 + 28 * bi;
                w0 = bt[base];
                if (bi >= bt[0]) begin
                    e_frag <= e_frag + 1;
                    $display("FAIL exp%0d: beat %0d beyond the model's %0d", NPHYS, bi, bt[0]);
                end else begin
                    if (ex_seq !== w0[31:16] || ex_last !== w0[8] || ex_mask !== w0[3:0] ||
                        ex_xy !== bt[base + 1]) begin
                        e_frag <= e_frag + 1;
                        $display("FAIL exp%0d: beat %0d seq %h/%h last %b/%b mask %h/%h xy %h/%h",
                                 NPHYS, bi, ex_seq, w0[31:16], ex_last, w0[8], ex_mask, w0[3:0],
                                 ex_xy, bt[base + 1]);
                    end
                    for (i = 0; i < 4; i = i + 1) begin
                        if ((bt[base + 27][1 + i] || !w0[i]) &&
                            ex_color[128*i +: 128] !== {bt[base + 2 + 5*i + 3], bt[base + 2 + 5*i + 2],
                                                        bt[base + 2 + 5*i + 1], bt[base + 2 + 5*i]}) begin
                            e_frag <= e_frag + 1;
                            $display("FAIL exp%0d: beat %0d lane %0d colour %h", NPHYS, bi, i,
                                     ex_color[128*i +: 128]);
                        end
                        if (ex_depth[32*i +: 32] !== bt[base + 2 + 5*i + 4]) begin
                            e_frag <= e_frag + 1;
                            $display("FAIL exp%0d: beat %0d lane %0d depth %h/%h", NPHYS, bi, i,
                                     ex_depth[32*i +: 32], bt[base + 2 + 5*i + 4]);
                        end
                    end
                    ms = bt[base + 22];
                    if (ex_aux[19:0] !== ms[19:0] ||
                        ex_aux[147:20] !== {bt[base + 26], bt[base + 25], bt[base + 24], bt[base + 23]}) begin
                        e_ms <= e_ms + 1;
                        $display("FAIL exp%0d: beat %0d zexp/smask %h/%h d_s %h", NPHYS, bi,
                                 ex_aux[19:0], ms[19:0], ex_aux[147:20]);
                    end
                    if (ex_aux[153:152] !== w0[14:13] || ex_aux[151] !== w0[12] ||
                        ex_aux[150] !== w0[11] || ex_aux[149] !== w0[10] ||
                        ex_aux[148] !== bt[base + 27][0]) begin
                        e_mrt <= e_mrt + 1;
                        $display("FAIL exp%0d: beat %0d rt/qlast/qfirst/nocol/front %b %b %b %b %b exp %h %b",
                                 NPHYS, bi, ex_aux[153:152], ex_aux[151], ex_aux[150], ex_aux[149],
                                 ex_aux[148], w0, bt[base + 27][0]);
                    end
                end
                bi = bi + 1;
                if (ex_last) begin
                    ex_next <= ex_next + 16'd1;
                    for (i = 0; i < 4; i = i + 1)
                        if (fragslot[i] && sseq[i] == ex_seq) drained[i] = 1'b1;
                end
            end
            ex_ready <= ($random(seed) & 3) != 0;
            // releases
            if (vexp && !(xr_valid && xr_warp == vw)) begin
                e_rel <= e_rel + 1;
                $display("FAIL exp%0d: vertex warp %0d not released the cycle after its end", NPHYS, vw);
            end
            vexp <= 1'b0;
            if (wc_end && !fragslot[wc_warp]) begin
                vexp <= 1'b1;
                vw <= wc_warp;
            end
            if (xr_valid) begin
                if (!ended[xr_warp] || (fragslot[xr_warp] && !drained[xr_warp])) begin
                    e_rel <= e_rel + 1;
                    $display("FAIL exp%0d: release of warp %0d (ended %b, drained %b)", NPHYS,
                             xr_warp, ended[xr_warp], drained[xr_warp]);
                end
                ended[xr_warp] = 1'b0;
                drained[xr_warp] = 1'b0;
                fragslot[xr_warp] = 1'b0;
            end
            if (wc_end) ended[wc_warp] = 1'b1;
            if (fl_go) begin
                fragslot[fl_slot] = 1'b1;
                sseq[fl_slot] = fl_info[47:32];
            end
        end
        nbeat <= bi;
    end

    // ---------------- the driver ----------------
    integer pc, g, k, wait_n, t0;
    reg [31:0] op;
    task idle_cycles;
        begin
            while (($random(seed) & 3) == 0) @(posedge clk);
        end
    endtask
    task other_group;              // another unit's group (ignored by exp)
        begin
            x_valid <= 1'b1;
            x_uop <= 108'd0;
            x_uop[AD_UOP_UNIT +: 4] <= 4'd1 + ($random(seed) & 7);
            x_uop[AD_UOP_IMM +: 12] <= 12'h100;
            x_info <= 32'h0001_0000;
            x_mask <= {2*NPHYS{1'b1}};
            x_b <= {NPHYS{32'hFFFF_FFFF}};
            @(posedge clk);
            x_valid <= 1'b0;
        end
    endtask

    initial begin
        done = 1'b0;
        x_valid = 0; x_last = 0; x_warp = 0; x_grp = 0; x_uop = 0; x_b = 0; x_mask = 0;
        x_info = 0; fl_we = 0; fl_go = 0; fl_pw_we = 0; fl_slot = 0; fl_reg = 0; fl_lane = 0;
        fl_data = 0; fl_pw_data = 0; fl_info = 0; fl_pw_addr = 0; wc_end = 0; wc_warp = 0;
        scrub = 0;
        fragslot = 0; ended = 0; drained = 0;
        @(posedge run);
        @(posedge clk);
        // scrub: scrub_busy for 17 x NWARPS x 32/NPHYS cycles
        scrub <= 1'b1;
        @(posedge clk);
        scrub <= 1'b0;
        t0 = 0;
        @(posedge clk);
        while (scrub_busy) begin
            t0 = t0 + 1;
            @(posedge clk);
        end
        if (t0 != 17 * 4 * GPW) begin
            e_frag <= e_frag + 1;
            $display("FAIL exp%0d: scrub lasted %0d cycles", NPHYS, t0);
        end
        if (dut.bk[0].cm[5] !== 32'd0 || dut.bk[NPHYS-1].zm[3] !== 32'd0) begin
            e_frag <= e_frag + 1;
            $display("FAIL exp%0d: scrub left a word", NPHYS);
        end
        pc = 0;
        op = cmd[0];
        while (op != 0) begin
            case (op)
            1: begin
                idle_cycles;
                fl_we <= 1'b1; fl_slot <= cmd[pc+1]; fl_reg <= cmd[pc+2]; fl_lane <= cmd[pc+3];
                fl_data <= cmd[pc+4];
                @(posedge clk);
                fl_we <= 1'b0;
                pc = pc + 5;
            end
            2: begin
                idle_cycles;
                fl_pw_we <= 1'b1; fl_slot <= cmd[pc+1]; fl_pw_addr <= cmd[pc+2];
                fl_pw_data <= cmd[pc+3];
                @(posedge clk);
                fl_pw_we <= 1'b0;
                pc = pc + 4;
            end
            3: begin
                idle_cycles;
                fl_go <= 1'b1; fl_slot <= cmd[pc+1];
                fl_info <= {15'd0, cmd[pc+4][0], cmd[pc+3][15:0], cmd[pc+2]};
                @(posedge clk);
                fl_go <= 1'b0;
                pc = pc + 5;
            end
            4: begin
                for (g = 0; g < GPW; g = g + 1) begin
                    idle_cycles;
                    if (($random(seed) & 7) == 0) other_group;
                    x_valid <= 1'b1;
                    x_warp <= cmd[pc+1];
                    x_info <= {14'd0, cmd[pc+2][1:0], 16'h0};
                    x_uop <= 108'd0;
                    x_uop[AD_UOP_UNIT +: 4] <= AD_UNIT_EXP;
                    x_uop[AD_UOP_IMM +: 32] <= cmd[pc+3];
                    x_uop[AD_UOP_SIDE] <= 1'b1;
                    x_grp <= g;
                    x_last <= (g == GPW - 1);
                    for (k = 0; k < NPHYS; k = k + 1) begin
                        x_b[32*k +: 32] <= cmd[pc + 5 + g*NPHYS + k];
                        x_mask[k] <= cmd[pc+4][g*NPHYS + k] | ($random(seed) & 1);  // EXEC >= side
                        x_mask[NPHYS + k] <= cmd[pc+4][g*NPHYS + k];
                    end
                    @(posedge clk);
                    while (!x_ready) @(posedge clk);
                    x_valid <= 1'b0;
                end
                pc = pc + 37;
            end
            5: begin
                idle_cycles;
                wc_end <= 1'b1; wc_warp <= cmd[pc+1];
                @(posedge clk);
                wc_end <= 1'b0;
                pc = pc + 2;
            end
            6: begin
                wait_n = cmd[pc+1];
                t0 = 0;
                while ((bi < wait_n || ended != 0) && t0 < 20000) begin
                    @(posedge clk);
                    t0 = t0 + 1;
                end
                if (t0 >= 20000) begin
                    e_frag <= e_frag + 1;
                    $display("FAIL exp%0d: stuck at %0d beats of %0d (ended %b)", NPHYS, bi,
                             wait_n, ended);
                end
                pc = pc + 2;
            end
            default: begin
                $display("FAIL exp%0d: bad command %0d at %0d", NPHYS, op, pc);
                op = 0;
            end
            endcase
            op = cmd[pc];
        end
        repeat (10) @(posedge clk);
        done = 1'b1;
    end
endmodule

module ad_su_exp_tb;
    reg clk = 0, rst_n = 0, run = 0;
    always #5 clk = ~clk;
    wire d8, d4;
    wire [31:0] f8, r8, m8, t8, n8, f4, r4, m4, t4, n4;
    exp_h #(.NPHYS(8), .SEED(11)) h8 (.clk(clk), .rst_n(rst_n), .run(run), .done(d8),
        .e_frag(f8), .e_rel(r8), .e_ms(m8), .e_mrt(t8), .nbeat(n8));
    exp_h #(.NPHYS(4), .SEED(23)) h4 (.clk(clk), .rst_n(rst_n), .run(run), .done(d4),
        .e_frag(f4), .e_rel(r4), .e_ms(m4), .e_mrt(t4), .nbeat(n4));
    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        run = 1;
        wait (d8 && d4);
        if (f8 == 0 && f4 == 0 && n8 == h8.bt[0] && n4 == h4.bt[0] && n8 > 500)
            $display("PASS ad_su_exp.frag");
        else $display("FAIL ad_su_exp.frag (%0d %0d errors, %0d %0d beats)", f8, f4, n8, n4);
        if (r8 == 0 && r4 == 0) $display("PASS ad_su_exp.release");
        else $display("FAIL ad_su_exp.release (%0d %0d)", r8, r4);
        if (m8 == 0 && m4 == 0) $display("PASS ad_su_exp.ms");
        else $display("FAIL ad_su_exp.ms (%0d %0d)", m8, m4);
        if (t8 == 0 && t4 == 0) $display("PASS ad_su_exp.mrt");
        else $display("FAIL ad_su_exp.mrt (%0d %0d)", t8, t4);
        if (f8 == 0 && f4 == 0 && r8 == 0 && r4 == 0 && m8 == 0 && m4 == 0 && t8 == 0 && t4 == 0 &&
            n8 == h8.bt[0] && n4 == h4.bt[0])
            $display("PASS ad_su_exp");
        $finish;
    end
    initial begin
        #200000000;
        $display("FAIL ad_su_exp: timeout");
        $finish;
    end
endmodule
