// ad_su_exp -- the fragment export buffer (spec ad_su_exp.md).
// Fragment warps' exp 0x100 + 16 k + c (colour attachment k, component c), 0x104 (DEPTH) and
// 0x105 (SAMPLE_MASK) write the side-effect lanes of the group into the warp's buffer: NPHYS
// lane banks x 17 words (16 colour words, exported depth) x NWARPS*32/NPHYS rows, and a
// separate bank set of the rasterized z (RX's r3) so the RX's writes never collide with an
// exp's.  The RX's writes (fl_*) give r3 (z), r4/r5 (x + 0.5, y + 0.5: the quad's position from
// lane 4q), r6 (the rasterized sample mask); fl_pw_* 0xFF8-0xFFB the warp's d_s words.  The
// drain (ad_su_exp_drain) sends the ended warp whose number is ex_next as beats; exp 0x200
// kicks the meshlet sequencer (ad_su_exp_mesh).  scrub zeroes the colour/depth/z banks.
module ad_su_exp #(
    parameter NPHYS = 8,
    parameter NWARPS = 4,
    parameter WARP_W = 2,
    parameter GRP_W = 2,
    parameter SBE_W = 2,
    parameter UOP_W = 108,
    parameter LDS_AW = 10
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 x_valid,
    input  wire [WARP_W-1:0]    x_warp,
    input  wire [GRP_W-1:0]     x_grp,
    input  wire                 x_last,
    input  wire [SBE_W:0]       x_sbe,
    input  wire [15:0]          x_pc,
    input  wire [UOP_W-1:0]     x_uop,
    input  wire [NPHYS*32-1:0]  x_a,
    input  wire [NPHYS*32-1:0]  x_b,
    input  wire [NPHYS*32-1:0]  x_c,
    input  wire [2*NPHYS-1:0]   x_mask,
    input  wire [31:0]          x_info,
    output wire                 x_ready,
    output wire                 ex_valid,
    input  wire                 ex_ready,
    output wire [15:0]          ex_seq,
    output wire [31:0]          ex_xy,
    output wire [3:0]           ex_mask,
    output wire [511:0]         ex_color,
    output wire [127:0]         ex_depth,
    output wire                 ex_last,
    input  wire [15:0]          ex_next,
    input  wire                 fl_we,
    input  wire [WARP_W-1:0]    fl_slot,
    input  wire [5:0]           fl_reg,
    input  wire [4:0]           fl_lane,
    input  wire [31:0]          fl_data,
    input  wire                 fl_go,
    input  wire [63:0]          fl_info,
    input  wire                 fl_pw_we,
    input  wire [11:0]          fl_pw_addr,
    input  wire [31:0]          fl_pw_data,
    output wire [153:0]         ex_aux,
    output wire                 xr_valid,
    output wire [WARP_W-1:0]    xr_warp,
    input  wire                 wc_end,
    input  wire [WARP_W-1:0]    wc_warp,
    output wire                 mesh_valid,
    input  wire                 mesh_ready,
    output wire [701:0]         mesh_tri,
    output wire                 mesh_last,
    output wire [15:0]          mesh_id,
    output wire                 mesh_busy,
    output wire                 mesh_lds_rd_en,
    output wire [LDS_AW-1:0]    mesh_lds_rd_addr,
    input  wire [31:0]          mesh_lds_rd_data,
    input  wire                 scrub,
    output wire                 scrub_busy
);
`include "ad_su_uop.vh"
    localparam GPW = 32 / NPHYS;               // groups (rows) per warp
    localparam LGPW = $clog2(GPW);
    localparam LNP = $clog2(NPHYS);
    localparam NROW = NWARPS * GPW;
    localparam RW = $clog2(NROW);
    localparam CDEPTH = 17 * NROW;             // colour words 0-15, depth 16, address {word, row}
    localparam CAW = $clog2(CDEPTH);

    // ---- the issued group ----
    wire [11:0] tgt = x_uop[AD_UOP_IMM +: 12];
    wire is_exp = x_valid && x_ready && x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_EXP;
    wire is_frag = is_exp && x_info[17:16] == 2'd1;
    wire t_col = tgt[11:6] == 6'h04 && tgt[3:2] == 2'b00;
    wire t_dep = tgt == 12'h104;
    wire t_sm = tgt == 12'h105;
    wire [4:0] cword = t_dep ? 5'd16 : {1'b0, tgt[5:4], tgt[1:0]};
    wire [NPHYS-1:0] side = x_mask[2*NPHYS-1:NPHYS];
    wire [31:0] xg32 = {{(32-GRP_W){1'b0}}, x_grp} % GPW;   // the group within the warp
    wire [31:0] xrow32 = {{(32-WARP_W){1'b0}}, x_warp} * GPW + xg32;
    wire [RW-1:0] xrow = xrow32[RW-1:0];
    wire c_we = is_frag && (t_col || t_dep);

    // ---- meshlet kick: the first group of an exp 0x200 with a side-effect lane ----
    reg kseen;                                  // this instruction already kicked
    wire is_mesh = is_exp && tgt == 12'h200;
    reg [LDS_AW-1:0] kbase;
    reg kany;
    integer kl;
    always @(*) begin
        kany = 1'b0;
        kbase = {LDS_AW{1'b0}};
        for (kl = NPHYS - 1; kl >= 0; kl = kl - 1)
            if (side[kl]) begin
                kany = 1'b1;
                kbase = x_b[32*kl +: LDS_AW];
            end
    end
    wire kick = is_mesh && kany && !kseen;
    always @(posedge clk) begin
        if (!rst_n) kseen <= 1'b0;
        else if (is_mesh) kseen <= x_last ? 1'b0 : (kseen || kick);
    end
    assign x_ready = !mesh_busy;

    // ---- per-slot and per-lane state ----
    reg [31:0] cov [0:NWARPS-1];
    reg [NWARPS-1:0] front;
    reg [3:0] rtw [0:NWARPS-1];
    reg [127:0] ds [0:NWARPS-1];
    reg [31:0] xp [0:NWARPS-1];                // lane exported
    reg [31:0] dxp [0:NWARPS-1];               // lane exported DEPTH
    reg [31:0] smf [0:NWARPS-1];               // lane exported SAMPLE_MASK
    reg [31:0] r6f [0:NWARPS-1];               // RX wrote the lane's r6
    reg [3:0] smv [0:NWARPS*32-1];
    reg [3:0] r6v [0:NWARPS*32-1];
    reg [15:0] px [0:NWARPS*8-1];
    reg [15:0] py [0:NWARPS*8-1];

    wire [15:0] fl_fl;
    ad_gfx_floor16 flr (.f(fl_data), .i(fl_fl));

    wire [63:0] side64 = {{(64-NPHYS){1'b0}}, side};
    wire [63:0] side_sh = side64 << (xg32 * NPHYS);
    wire [31:0] side32 = side_sh[31:0];

    function [4:0] xl5;                          // a lane number's low 5 bits
        input [31:0] v;
        xl5 = v[4:0];
    endfunction
    integer w, l;
    always @(posedge clk) begin
        if (!rst_n) begin
            front <= {NWARPS{1'b0}};
            for (w = 0; w < NWARPS; w = w + 1) begin
                cov[w] <= 32'd0;
                rtw[w] <= 4'd0;
                ds[w] <= 128'd0;
                xp[w] <= 32'd0;
                dxp[w] <= 32'd0;
                smf[w] <= 32'd0;
                r6f[w] <= 32'd0;
            end
        end else begin
            if (is_frag && (t_col || t_dep || t_sm)) begin
                xp[x_warp] <= xp[x_warp] | side32;
                if (t_dep) dxp[x_warp] <= dxp[x_warp] | side32;
                if (t_sm) smf[x_warp] <= smf[x_warp] | side32;
                if (t_col && side != 0) rtw[x_warp] <= rtw[x_warp] | (4'd1 << tgt[5:4]);
            end
            if (fl_we && fl_reg == 6'd6) r6f[fl_slot][fl_lane] <= 1'b1;
            if (fl_pw_we && fl_pw_addr[11:2] == 10'h3FE)
                ds[fl_slot][32*fl_pw_addr[1:0] +: 32] <= fl_pw_data;
            if (xr_valid) begin
                r6f[xr_warp] <= 32'd0;
                ds[xr_warp] <= 128'd0;
            end
            if (fl_go) begin
                cov[fl_slot] <= fl_info[31:0];
                front[fl_slot] <= fl_info[48];
                rtw[fl_slot] <= 4'd0;
                xp[fl_slot] <= 32'd0;
                dxp[fl_slot] <= 32'd0;
                smf[fl_slot] <= 32'd0;
            end
        end
    end
    // datapath words (qualified by the flags above)
    always @(posedge clk) begin
        if (fl_we && fl_reg == 6'd6) r6v[{fl_slot, fl_lane}] <= fl_data[3:0];
        if (fl_we && fl_reg == 6'd4 && fl_lane[1:0] == 2'b00) px[{fl_slot, fl_lane[4:2]}] <= fl_fl;
        if (fl_we && fl_reg == 6'd5 && fl_lane[1:0] == 2'b00) py[{fl_slot, fl_lane[4:2]}] <= fl_fl;
        if (is_frag && t_sm)
            for (l = 0; l < NPHYS; l = l + 1)
                if (side[l]) smv[{x_warp, xl5(xg32 * NPHYS + l)}] <= x_b[32*l +: 4];
    end

    // ---- scrub ----
    wire sc_on;
    wire [CAW-1:0] sc_a;
    ad_su_scrub #(.DEPTH(CDEPTH), .AW(CAW)) sc (.clk(clk), .rst_n(rst_n), .start(scrub),
        .on(sc_on), .a(sc_a));
    assign scrub_busy = sc_on;

    // ---- drain ----
    wire [WARP_W-1:0] d_warp;
    wire [2:0] d_q;
    wire [1:0] d_rt;
    wire d_first, d_lastb, d_nocol;
    ad_su_exp_drain #(.NWARPS(NWARPS), .WARP_W(WARP_W)) drain (
        .clk(clk), .rst_n(rst_n), .fl_go(fl_go), .fl_slot(fl_slot), .fl_seq(fl_info[47:32]),
        .wc_end(wc_end), .wc_warp(wc_warp), .d_cov(cov[d_warp]), .d_rtw(rtw[d_warp]),
        .d_warp(d_warp), .d_q(d_q), .d_rt(d_rt), .d_first(d_first), .d_lastb(d_lastb),
        .d_nocol(d_nocol), .ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq),
        .ex_last(ex_last), .ex_next(ex_next), .xr_valid(xr_valid), .xr_warp(xr_warp));

    // the beat's lanes: lane 4 d_q + i is bank (4 d_q + i) mod NPHYS of row d_warp*GPW + lane/NPHYS
    wire [4:0] qlane = {d_q, 2'b00};
    wire [31:0] drow32 = {{(32-WARP_W){1'b0}}, d_warp} * GPW + {27'd0, qlane} / NPHYS;
    wire [RW-1:0] drow = drow32[RW-1:0];
    wire [LNP-1:0] dbank0 = qlane[LNP-1:0];

    // ---- the banks ----
    wire [32*5-1:0] bq [0:NPHYS-1];             // per bank: attachment d_rt's RGBA, depth
    wire [31:0] zq [0:NPHYS-1];
    genvar g;
    generate
        for (g = 0; g < NPHYS; g = g + 1) begin : bk
            reg [31:0] cm [0:CDEPTH-1];
            reg [31:0] zm [0:NROW-1];
            wire [31:0] zrow32 = {{(32-WARP_W){1'b0}}, fl_slot} * GPW + {27'd0, fl_lane} / NPHYS;
            wire [RW-1:0] zrow = zrow32[RW-1:0];
            always @(posedge clk) begin
                if (sc_on)
                    cm[sc_a] <= 32'd0;
                else if (c_we && side[g])
                    cm[{cword, xrow}] <= x_b[32*g +: 32];
            end
            always @(posedge clk) begin
                if (sc_on) begin
                    if ({{(32-CAW){1'b0}}, sc_a} < NROW) zm[sc_a[RW-1:0]] <= 32'd0;
                end else if (fl_we && fl_reg == 6'd3 && fl_lane[LNP-1:0] == g)
                    zm[zrow] <= fl_data;
            end
            assign bq[g] = {cm[{5'd16, drow}], cm[{1'b0, d_rt, 2'd3, drow}],
                            cm[{1'b0, d_rt, 2'd2, drow}], cm[{1'b0, d_rt, 2'd1, drow}],
                            cm[{1'b0, d_rt, 2'd0, drow}]};
            assign zq[g] = zm[drow];
        end
    endgenerate

    // ---- the beat ----
    wire [3:0] q_cov = cov[d_warp][4*d_q +: 4];
    wire [3:0] q_xp = xp[d_warp][4*d_q +: 4];
    wire [3:0] q_dxp = dxp[d_warp][4*d_q +: 4];
    wire [3:0] q_smf = smf[d_warp][4*d_q +: 4];
    wire [3:0] q_r6f = r6f[d_warp][4*d_q +: 4];
    reg [3:0] lmask;
    reg [15:0] smask;
    reg [511:0] col;
    reg [127:0] dep;
    reg [3:0] sm_l;
    integer i;
    always @(*) begin
        for (i = 0; i < 4; i = i + 1) begin
`ifdef MUT_SMASK_AND
            sm_l = (q_r6f[i] ? r6v[{d_warp, qlane[4:0] + i[4:0]}] : 4'hF) |
                   (q_smf[i] ? smv[{d_warp, qlane[4:0] + i[4:0]}] : 4'hF);
`else
            sm_l = (q_r6f[i] ? r6v[{d_warp, qlane[4:0] + i[4:0]}] : 4'hF) &
                   (q_smf[i] ? smv[{d_warp, qlane[4:0] + i[4:0]}] : 4'hF);
`endif
            lmask[i] = q_cov[i] && q_xp[i] && sm_l != 4'd0;
            smask[4*i +: 4] = lmask[i] ? sm_l : 4'd0;
            col[128*i +: 128] = lmask[i] ? bq[{{(32-LNP){1'b0}}, dbank0} + i][127:0] : 128'd0;
            dep[32*i +: 32] = !lmask[i] ? 32'd0 :
                              q_dxp[i] ? bq[{{(32-LNP){1'b0}}, dbank0} + i][159:128] : zq[{{(32-LNP){1'b0}}, dbank0} + i];
        end
    end
    assign ex_mask = lmask;
    assign ex_color = col;
    assign ex_depth = dep;
    assign ex_xy = {py[{d_warp, d_q}], px[{d_warp, d_q}]};
`ifdef MUT_EXP_FRONT
    wire fr = 1'b0;
`else
    wire fr = front[d_warp];
`endif
    assign ex_aux = {d_nocol ? 2'd0 : d_rt, d_lastb, d_first, d_nocol, fr, ds[d_warp],
                     q_dxp & lmask, smask};

    // ---- meshlet sequencer ----
    ad_su_exp_mesh #(.LDS_AW(LDS_AW)) mesh (
        .clk(clk), .rst_n(rst_n), .kick_valid(kick), .kick_base(kbase),
        .mesh_lds_rd_en(mesh_lds_rd_en), .mesh_lds_rd_addr(mesh_lds_rd_addr),
        .mesh_lds_rd_data(mesh_lds_rd_data), .mesh_valid(mesh_valid), .mesh_ready(mesh_ready),
        .mesh_tri(mesh_tri), .mesh_last(mesh_last), .mesh_id(mesh_id), .mesh_busy(mesh_busy));

    wire unused = &{1'b0, x_sbe, x_pc, x_a, x_c, fl_info, x_mask, xrow32, drow32, xg32};
endmodule
