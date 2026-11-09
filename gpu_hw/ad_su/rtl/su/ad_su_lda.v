// ad_su_lda -- the primitive table and lda (spec ad_su_lda.md).
// NC = min(NPHYS/4, 2) copies of NWARPS x PRIMS x 3 x VARY_WORDS words, each written by every
// table write (pw_*) and read through one synchronous port.  A group has NQ = NPHYS/4 quads;
// copy c reads quad p*NC + c in read cycle p, a group takes NR = NQ/NC cycles; x_ready is 0
// in the later read cycles.  lda: imm[8:2] PT word (4 + w: varying word w), imm[1:0] vertex;
// 0 for words < 4, >= 4 + VARY_WORDS, vertex 3.  The quad's primitive: the warp's map
// (pw_addr 0xFFF, 3 bits a quad).  The result SHORT_LAT cycles after the take, s_lanes =
// EXEC; s_valid only when the uop writes rd.  scrub zeroes the table (and the maps).
module ad_su_lda #(
    parameter NPHYS = 8,
    parameter NWARPS = 4,
    parameter WARP_W = 2,
    parameter GRP_W = 2,
    parameter SBE_W = 2,
    parameter UOP_W = 108,
    parameter PRIMS = 8,
    parameter VARY_WORDS = 32,
    parameter SHORT_LAT = 6
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
    output wire                 s_valid,
    output wire [WARP_W-1:0]    s_warp,
    output wire [GRP_W-1:0]     s_grp,
    output wire [6:0]           s_rd,
    output wire [NPHYS*32-1:0]  s_data,
    output wire [NPHYS-1:0]     s_lanes,
    input  wire                 pw_we,
    input  wire [WARP_W-1:0]    pw_warp,
    input  wire [11:0]          pw_addr,
    input  wire [31:0]          pw_data,
    input  wire                 scrub,
    output wire                 scrub_busy
);
`include "ad_su_uop.vh"
    localparam NQ = NPHYS / 4;
    localparam NC = (NQ < 2) ? NQ : 2;
    localparam NR = NQ / NC;
    localparam DEPTH = NWARPS * PRIMS * 3 * VARY_WORDS;
    localparam AW = $clog2(DEPTH);
    localparam PH_W = (NR > 1) ? $clog2(NR) : 1;
    localparam LGPW = $clog2(32 / NPHYS);      // bits of the group number used

    // ---- primitive maps ----
    reg [23:0] pmap [0:NWARPS-1];

    // ---- take, phase ----
    wire mine = x_valid && x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_LDA;
    reg [PH_W-1:0] ph;                          // read cycle of the current group (0 = idle)
`ifdef MUT_LDA_READY
    assign x_ready = 1'b1;                      // mutation: x_ready in the later read cycles
`else
    assign x_ready = (ph == {PH_W{1'b0}});
`endif
    localparam [31:0] PHL32 = NR - 1, NQ32 = NQ;
    localparam [PH_W-1:0] PH_LAST = PHL32[PH_W-1:0];
    localparam [8:0] NQ9 = NQ32[8:0];
    wire take = mine && x_ready;

    always @(posedge clk) begin
        if (!rst_n) ph <= {PH_W{1'b0}};
        else if (NR > 1) begin
            if (take) ph <= {{(PH_W-1){1'b0}}, 1'b1};
            else if (ph != {PH_W{1'b0}}) ph <= (ph == PH_LAST) ? {PH_W{1'b0}} : ph + 1'b1;
        end
    end

    // the group's quads' primitives (3 bits each), from the warp's map
    wire [23:0] xmap = pmap[x_warp];
    wire [8:0] xg9 = {{(9-GRP_W){1'b0}}, x_grp};
    wire [8:0] qbase = (LGPW == 0) ? 9'd0 : (xg9 * NQ9);  // first quad of the group
    wire [23:0] xsh = xmap >> (3 * qbase);
    wire [3*NQ-1:0] xprims = xsh[3*NQ-1:0];
    wire [8:0] imm = x_uop[AD_UOP_IMM +: 9];

    // latched for the later read cycles
    reg [WARP_W-1:0] l_warp;
    reg [3*NQ-1:0] l_prims;
    reg [8:0] l_imm;
    always @(posedge clk) begin
        if (take) begin
            l_warp <= x_warp;
            l_prims <= xprims;
            l_imm <= imm;
        end
    end

    // the read of cycle p (p = 0 from x_*, else the latched group)
    wire [WARP_W-1:0] r_warp = (ph == 0) ? x_warp : l_warp;
`ifdef MUT_LDA_PHASE
    wire [3*NQ-1:0] r_prims = (ph == 0) ? xprims : l_prims;
    wire [3*NQ-1:0] r_sel = r_prims;            // the later reads with the first quads
`else
    wire [3*NQ-1:0] r_prims = (ph == 0) ? xprims : l_prims;
    wire [3*NQ-1:0] r_sel = r_prims >> (3 * NC * ph);
`endif
    wire [8:0] r_imm = (ph == 0) ? imm : l_imm;
    wire [1:0] r_vtx = r_imm[1:0];
    wire [6:0] r_word = r_imm[8:2];
    wire [6:0] r_w = r_word - 7'd4;
    wire r_zero = r_vtx == 2'd3 || r_word < 7'd4 || r_w >= VARY_WORDS;

    // ---- table writes ----
    localparam [AW+8:0] PRW = PRIMS, VWW = VARY_WORDS, THR = 3;
    wire t_we = pw_we && !pw_addr[11] && {26'd0, pw_addr[5:0]} < VARY_WORDS &&
                pw_addr[7:6] != 2'd3 && {29'd0, pw_addr[10:8]} < PRIMS;
    wire [AW+8:0] waddr = (({{(AW+9-WARP_W){1'b0}}, pw_warp} * PRW + {{(AW+6){1'b0}}, pw_addr[10:8]}) * THR +
                           {{(AW+7){1'b0}}, pw_addr[7:6]}) * VWW + {{(AW+3){1'b0}}, pw_addr[5:0]};
    wire sc_on;
    wire [AW-1:0] sc_a;
    ad_su_scrub #(.DEPTH(DEPTH), .AW(AW)) sc (.clk(clk), .rst_n(rst_n), .start(scrub),
        .on(sc_on), .a(sc_a));
    assign scrub_busy = sc_on;

    integer k;
    always @(posedge clk) begin
        if (!rst_n || scrub) begin
            for (k = 0; k < NWARPS; k = k + 1) pmap[k] <= 24'd0;
        end else if (pw_we && pw_addr == 12'hFFF) begin
            pmap[pw_warp] <= pw_data[23:0];
        end
    end

    // ---- the copies ----
    wire [31:0] cq [0:NC-1];
    genvar c;
    generate
        for (c = 0; c < NC; c = c + 1) begin : cp
            reg [31:0] mem [0:DEPTH-1];
            reg [31:0] q;
            wire [2:0] prim = r_sel[3*c +: 3];
            wire [AW+8:0] raddr = (({{(AW+9-WARP_W){1'b0}}, r_warp} * PRW + {{(AW+6){1'b0}}, prim}) * THR +
                                   {{(AW+7){1'b0}}, r_vtx}) * VWW + {{(AW+2){1'b0}}, r_w};
            wire unused_c = &{1'b0, raddr[AW+8:AW]};
            always @(posedge clk) begin
                if (sc_on) mem[sc_a] <= 32'd0;
                else if (t_we) mem[waddr[AW-1:0]] <= pw_data;
            end
            always @(posedge clk) q <= mem[raddr[AW-1:0]];
            assign cq[c] = q;
        end
    endgenerate

    // ---- the result pipeline: stage k = k cycles after the take ----
    reg [SHORT_LAT:1] pv;                     // a group, writes rd
    reg [WARP_W-1:0] pw [1:SHORT_LAT];
    reg [GRP_W-1:0] pg [1:SHORT_LAT];
    reg [6:0] prd [1:SHORT_LAT];
    reg [NPHYS-1:0] pl [1:SHORT_LAT];
    reg [SHORT_LAT:1] pz;                     // the result is 0
    reg [31:0] acc [0:NQ-1];                  // quads read in the earlier cycles
    reg [NPHYS*32-1:0] pd [NR+1:SHORT_LAT];

    // the data read in cycle p arrive in cycle p+1: quads p*NC + c
    reg [PH_W-1:0] rph;                       // read cycle whose data arrive now
    reg rgo;
    always @(posedge clk) begin
        if (!rst_n) begin
            rph <= {PH_W{1'b0}};
            rgo <= 1'b0;
        end else begin
            rgo <= take || ph != 0;
            rph <= ph;
        end
    end
    integer qq;
    always @(posedge clk) begin
        if (rgo)
            for (qq = 0; qq < NC; qq = qq + 1) acc[rph * NC + qq] <= cq[qq];
    end
    // the complete group in stage NR (its last data arrive now)
    reg [NPHYS*32-1:0] full;
    integer ln;
    always @(*) begin
        for (ln = 0; ln < NPHYS; ln = ln + 1) begin
            if (ln / 4 >= (NR - 1) * NC)
                full[32*ln +: 32] = cq[ln / 4 - (NR - 1) * NC];
            else
                full[32*ln +: 32] = acc[ln / 4];
            if (pz[NR]) full[32*ln +: 32] = 32'd0;
        end
    end

    integer st;
    always @(posedge clk) begin
        if (!rst_n) begin
            pv <= {SHORT_LAT{1'b0}};
        end else begin
            pv[1] <= take && x_uop[AD_UOP_WRD];
            for (st = 2; st <= SHORT_LAT; st = st + 1) pv[st] <= pv[st-1];
        end
    end
    always @(posedge clk) begin
        pw[1] <= x_warp;
        pg[1] <= x_grp;
        prd[1] <= x_uop[AD_UOP_RD +: 7];
        pl[1] <= x_mask[NPHYS-1:0];
        pz[1] <= (take ? (imm[1:0] == 2'd3 || imm[8:2] < 7'd4 || (imm[8:2] - 7'd4) >= VARY_WORDS)
                       : 1'b0);
        for (st = 2; st <= SHORT_LAT; st = st + 1) begin
            pw[st] <= pw[st-1];
            pg[st] <= pg[st-1];
            prd[st] <= prd[st-1];
            pl[st] <= pl[st-1];
            pz[st] <= pz[st-1];
        end
        pd[NR+1] <= full;
        for (st = NR + 2; st <= SHORT_LAT; st = st + 1) pd[st] <= pd[st-1];
    end

    assign s_valid = pv[SHORT_LAT];
    assign s_warp = pw[SHORT_LAT];
    assign s_grp = pg[SHORT_LAT];
    assign s_rd = prd[SHORT_LAT];
    assign s_lanes = pl[SHORT_LAT];
    assign s_data = pd[SHORT_LAT];

    wire unused = &{1'b0, x_last, x_sbe, x_pc, x_a, x_b, x_c, x_info, r_zero, x_mask, waddr[AW+8:AW],
                    xsh, qbase};
endmodule
