// fv_ad_su_lane: ad_su_lane with SUBGROUP 1 on a reduced warp (WARP 8 via
// the added parameter, NPHYS 4, so G = 2 groups; SHORT_LAT 3).  The
// harness plays ad_su_opd: one instruction (free constant op/sub/rd/wrd/
// warp, rs1/rs2/EXEC of the 8 lanes) issued again and again, its groups in
// order with free idle cycles or other units' groups between them, a group
// held while x_ready is 0.  Checked against a reference of spec §4 (and
// tools/gsi1model.py lane()):
//  - qd: qdx/qdy = ad_lane_fsub of the partner lanes (l|1, l&~1 / l|2,
//    l&~2), qswap1/2/3 = v[l^1/2/3], qbcast = v[l&~3]: partner selection;
//  - shfl idx/xor/up/down/rot with the source rules (32-bit rs2, no
//    wraparound, out of range or outside EXEC -> own rs1), vote any/all,
//    ballot (every lane written);
//  - every result exactly SHORT_LAT after its slot (group g of a subgroup
//    op SHORT_LAT after x_end - (G-1) + g), s_valid only with wrd, s_rd,
//    s_warp, s_grp, s_lanes;
//  - x_ready 1 on every group but the last of a subgroup op, which sees it
//    0 for exactly G cycles, then 1.
module fv_ad_su_lane #(
    parameter WARP = 8,
    parameter NPHYS = 4,
    parameter GRP_W = 1,
    parameter SL = 3
) (
    input wire clk,
    input wire go,
    input wire o_valid,
    input wire [3:0] o_unit,
    input wire [NPHYS*32-1:0] o_a,
    input wire o_last
);
    localparam G = WARP / NPHYS;
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;

    (* anyconst *) reg [1:0] op;
    (* anyconst *) reg [4:0] sub;
    (* anyconst *) reg [6:0] rd;
    (* anyconst *) reg wrd;
    (* anyconst *) reg [1:0] warp;
    (* anyconst *) reg [WARP*32-1:0] rs1;
    (* anyconst *) reg [WARP*32-1:0] rs2;
    (* anyconst *) reg [WARP-1:0] ex;
    always @(*) begin
        case (op)
        2'd0: assume (sub <= 5'd5);
        2'd1: assume (sub <= 5'd4);
        2'd2: assume (sub <= 5'd1);
        default: assume (sub == 5'd0);
        endcase
        assume (o_unit != 4'd12);
    end

    // ---- reference -------------------------------------------------------
    reg [WARP*32-1:0] rf;		// result per warp lane
    reg [WARP-1:0] rw;			// written lanes
    reg [WARP-1:0] bal;
    reg [32:0] sx;
    reg okx;
    reg [31:0] r2;
    integer l, s;
    wire [WARP*32-1:0] fs;		// qdx/qdy of each lane through a reference fsub
    genvar gl;
    generate
    for (gl = 0; gl < WARP; gl = gl + 1) begin : g_ref
        localparam integer PA = (gl | 1), PB = (gl & ~1), PC = (gl | 2), PD = (gl & ~2);
        ad_lane_fsub u_f (
            .a(sub == 5'd0 ? rs1[PA*32 +: 32] : rs1[PC*32 +: 32]),
            .b(sub == 5'd0 ? rs1[PB*32 +: 32] : rs1[PD*32 +: 32]),
            .y(fs[gl*32 +: 32]));
    end
    endgenerate
    always @(*) begin
        for (l = 0; l < WARP; l = l + 1)
            bal[l] = ex[l] && rs1[l*32 +: 32] != 32'd0;
        rf = {WARP*32{1'b0}};
        rw = {WARP{1'b0}};
        sx = 33'd0;
        okx = 1'b0;
        r2 = 32'd0;
        s = 0;
        for (l = 0; l < WARP; l = l + 1) begin
            case (op)
            2'd0: begin
                rw[l] = ex[l];
                case (sub)
                5'd0, 5'd1: rf[l*32 +: 32] = fs[l*32 +: 32];
                5'd2: rf[l*32 +: 32] = rs1[(l ^ 1)*32 +: 32];
                5'd3: rf[l*32 +: 32] = rs1[(l ^ 2)*32 +: 32];
                5'd4: rf[l*32 +: 32] = rs1[(l ^ 3)*32 +: 32];
                default: rf[l*32 +: 32] = rs1[(l & ~3)*32 +: 32];
                endcase
            end
            2'd1: begin
                rw[l] = ex[l];
                r2 = rs2[l*32 +: 32];
                case (sub)
                5'd0: sx = {1'b0, r2};
                5'd1: sx = {1'b0, r2 ^ l};
                5'd2: sx = {1'b0, l} - {1'b0, r2};	// negative: bit 32 set
                5'd3: sx = {1'b0, l} + {1'b0, r2};
                default: sx = (l + r2) % WARP;
                endcase
                okx = (sx < WARP);
                s = sx % WARP;
                rf[l*32 +: 32] = (okx && ex[s]) ? rs1[s*32 +: 32] : rs1[l*32 +: 32];
            end
            2'd2: begin
                rw[l] = 1'b1;
                rf[l*32 +: 32] = (sub == 5'd0 ? bal != 0 : bal == ex) ? 32'hFFFFFFFF : 32'd0;
            end
            default: begin
                rw[l] = 1'b1;
                rf[l*32 +: 32] = {{(32-WARP){1'b0}}, bal};
            end
            endcase
        end
    end

    // ---- driver (ad_su_opd) ----------------------------------------------
    reg [GRP_W-1:0] g = 0;
    reg hold = 1'b0;
    reg [3:0] hc = 4'd0;		// cycles on the last group of a subgroup op
    wire pres = hold || go;
    wire is_sub = (op != 2'd0);
    wire lastg = (g == G - 1);
    reg [107:0] uop;
    always @(*) begin
        uop = 108'd0;
        uop[3:0] = 4'd12;
        uop[11:4] = {6'd0, op};
        uop[18:12] = rd;
        uop[85:81] = sub;
        uop[98] = wrd;
    end
    wire x_valid = pres ? 1'b1 : o_valid;
    wire [107:0] x_uop = pres ? uop : {104'd0, o_unit};
    wire [NPHYS*32-1:0] x_a = pres ? rs1[g*NPHYS*32 +: NPHYS*32] : o_a;
    wire [NPHYS*32-1:0] x_b = pres ? rs2[g*NPHYS*32 +: NPHYS*32] : o_a;
    wire [2*NPHYS-1:0] x_mask = pres ? {ex[g*NPHYS +: NPHYS], ex[g*NPHYS +: NPHYS]} : 0;
    wire x_last = pres ? lastg : o_last;
    wire x_ready;
    wire s_valid;
    wire [1:0] s_warp;
    wire [GRP_W-1:0] s_grp;
    wire [6:0] s_rd;
    wire [NPHYS*32-1:0] s_data;
    wire [NPHYS-1:0] s_lanes;

    ad_su_lane #(.NPHYS(NPHYS), .GRP_W(GRP_W), .SUBGROUP(1), .SHORT_LAT(SL), .WARP(WARP)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(pres ? warp : 2'd0),
        .x_grp(pres ? g : {GRP_W{1'b0}}), .x_last(x_last), .x_sbe(3'd7), .x_pc(16'd0),
        .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c({NPHYS*32{1'b0}}), .x_mask(x_mask),
        .x_info(32'd0), .x_ready(x_ready), .s_valid(s_valid), .s_warp(s_warp), .s_grp(s_grp),
        .s_rd(s_rd), .s_data(s_data), .s_lanes(s_lanes)
    );

    // expected results: a delay line of (valid, group)
    reg [3:0] em = 4'd0;		// 1..G: emission slot of group em-1
    reg push;
    reg [GRP_W-1:0] pg;
    always @(*) begin
        push = 1'b0;
        pg = g;
        if (em != 4'd0) begin
            push = wrd;
            pg = em - 1;
        end else if (rst_n && pres && !is_sub && x_ready) begin
            push = wrd;
            pg = g;
        end
    end
    reg [SL-1:0] dv = 0;
    reg [GRP_W-1:0] dg [0:SL-1];
    integer k;
    always @(posedge clk) begin
        if (init) begin
            g <= 0; hold <= 1'b0; hc <= 4'd0; em <= 4'd0; dv <= 0;
        end else begin
            dv <= {dv[SL-2:0], push};
            dg[0] <= pg;
            for (k = 1; k < SL; k = k + 1)
                dg[k] <= dg[k-1];
            if (em != 4'd0)
                em <= (em == G) ? 4'd0 : em + 1'b1;
            else if (pres && is_sub && lastg && !hold)
                em <= 4'd1;
            if (pres) begin
                if (x_ready) begin
                    hold <= 1'b0;
                    hc <= 4'd0;
                    g <= lastg ? {GRP_W{1'b0}} : g + 1'b1;
                end else begin
                    hold <= 1'b1;
                    if (hc != 4'hF) hc <= hc + 1'b1;
                end
            end
        end
    end

    // ---- properties --------------------------------------------------------
    wire [GRP_W-1:0] og = dg[SL-1];
    integer j;
    always @(*) begin
        if (!init) begin
            if (pres && is_sub && lastg)
                assert (x_ready == (hc == G));
            else
                assert (x_ready);
            assert (s_valid == dv[SL-1]);
            if (s_valid) begin
                assert (s_grp == og && s_rd == rd && s_warp == warp);
                assert (s_lanes == rw[og*NPHYS +: NPHYS]);
                for (j = 0; j < NPHYS; j = j + 1)
                    if (rw[og*NPHYS + j])
                        assert (s_data[j*32 +: 32] == rf[(og*NPHYS + j)*32 +: 32]);
            end
        end
    end
endmodule
