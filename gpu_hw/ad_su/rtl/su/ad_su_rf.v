// ad_su_rf -- the SU's register file (spec/gpu/su/ad_su_rf.md): NWARPS x NREGS x 32
// lanes x 32 bits, banked per physical lane, two copies (one per read port) written
// together.  Address {warp, reg, grp} (grp omitted for NPHYS 32).  Read latency 1,
// r_data holds while r_en is 0, a read of a register written in the same cycle
// returns the old value.  scrub writes 0 to every word (ad_su_scrub, one word of
// every lane and copy per cycle); the write port has priority while it runs.
// LW (default 32) is the bits per lane word; only formal harnesses reduce it.
module ad_su_rf #(
    parameter NPHYS  = 8,
    parameter NWARPS = 4,
    parameter WARP_W = 2,
    parameter GRP_W  = 2,
    parameter NREGS  = 32,
    parameter LW     = 32
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 w_en,
    input  wire [WARP_W-1:0]    w_warp,
    input  wire [GRP_W-1:0]     w_grp,
    input  wire [5:0]           w_reg,
    input  wire [NPHYS*LW-1:0]  w_data,
    input  wire [NPHYS-1:0]     w_lanes,
    input  wire                 r_en,
    input  wire [WARP_W-1:0]    r_warp,
    input  wire [GRP_W-1:0]     r_grp,
    input  wire [5:0]           r_reg1,
    input  wire [5:0]           r_reg2,
    output wire [NPHYS*LW-1:0]  r_data1,
    output wire [NPHYS*LW-1:0]  r_data2,
    input  wire                 scrub,
    output wire                 scrub_busy
);
    localparam G     = 32 / NPHYS;
    localparam GB    = (G > 1) ? $clog2(G) : 0;
    localparam RW    = $clog2(NREGS);
    localparam AW    = WARP_W + RW + GB;
    localparam DEPTH = NWARPS * NREGS * G;

    /* verilator lint_off UNUSEDSIGNAL */
    function [AW-1:0] addr(input [WARP_W-1:0] w, input [5:0] r, input [GRP_W-1:0] g);
        reg [31:0] t;
        begin
            t = {{(32-WARP_W-RW){1'b0}}, w, r[RW-1:0]};
            t = (t << GB) | ({{(32-GRP_W){1'b0}}, g} & (G - 1));
            addr = t[AW-1:0];
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    wire          sc_on;
    wire [AW-1:0] sc_a;
    ad_su_scrub #(.DEPTH(DEPTH), .AW(AW)) sc (
        .clk(clk), .rst_n(rst_n), .start(scrub), .on(sc_on), .a(sc_a));
    assign scrub_busy = sc_on;

    wire [AW-1:0] wa  = sc_on ? sc_a : addr(w_warp, w_reg, w_grp);
`ifdef MUT_RF_ADDR
    wire [AW-1:0] ra1 = addr(r_warp, r_reg1, {GRP_W{1'b0}});   // mutation: group dropped
`else
    wire [AW-1:0] ra1 = addr(r_warp, r_reg1, r_grp);
`endif
    wire [AW-1:0] ra2 = addr(r_warp, r_reg2, r_grp);

    genvar i;
    generate
        for (i = 0; i < NPHYS; i = i + 1) begin : lane
            wire          we = sc_on || (w_en && w_lanes[i]);
            wire [LW-1:0] wd = sc_on ? {LW{1'b0}} : w_data[LW*i +: LW];
            ad_ram_1r1w #(.DW(LW), .AW(AW), .DEPTH(DEPTH)) m1 (
                .clk(clk), .we(we), .wa(wa), .wd(wd), .re(r_en), .ra(ra1), .rq(r_data1[LW*i +: LW]));
            ad_ram_1r1w #(.DW(LW), .AW(AW), .DEPTH(DEPTH)) m2 (
                .clk(clk), .we(we), .wa(wa), .wd(wd), .re(r_en), .ra(ra2), .rq(r_data2[LW*i +: LW]));
        end
    endgenerate
endmodule
