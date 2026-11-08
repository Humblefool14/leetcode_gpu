// ad_su_pt -- the post-transform buffer (PT) and its block allocator (spec ad_su_pt.md).
// Vertex warps' exp 0x000+k (POS, PT word k) and 0x010+v (varying v < VARY_WORDS, PT word
// 4+v) write the side-effect lanes of the group into entry base + lane (base = the warp's
// block x 32).  NPHYS banks (bank = entry mod NPHYS) of PT_ENTRIES/NPHYS x (4+VARY_WORDS)
// words; pt_rdata the cycle after pt_rd (held until the next read).  The allocator is the
// leaf ad_gfx_pt_alloc.  scrub writes 0 to every word (ad_su_scrub), scrub_busy meanwhile.
module ad_su_pt #(
    parameter NPHYS = 8,
    parameter NWARPS = 4,
    parameter WARP_W = 2,
    parameter GRP_W = 2,
    parameter UOP_W = 108,
    parameter PT_ENTRIES = 64,
    parameter VARY_WORDS = 16
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 x_valid,
    input  wire [WARP_W-1:0]    x_warp,
    input  wire [GRP_W-1:0]     x_grp,
    input  wire [UOP_W-1:0]     x_uop,
    input  wire [NPHYS*32-1:0]  x_b,
    input  wire [2*NPHYS-1:0]   x_mask,
    input  wire [31:0]          x_info,
    input  wire                 pt_rd,
    input  wire [7:0]           pt_idx,
    input  wire [6:0]           pt_word,
    output reg  [31:0]          pt_rdata,
    input  wire                 pt_free,
    input  wire [7:0]           pt_free_idx,
    output wire                 pt_ok,
    input  wire                 pt_take,
    input  wire [WARP_W-1:0]    pt_warp,
    output wire [7:0]           pt_base,
    input  wire                 vl_go,
    input  wire [31:0]          vl_mask,
    output wire [7:0]           pt_done,
    input  wire                 wc_end,
    input  wire [WARP_W-1:0]    wc_warp,
    input  wire                 scrub,
    output wire                 scrub_busy
);
`include "ad_su_uop.vh"
    localparam NB = PT_ENTRIES / 32;
    localparam WPE = 4 + VARY_WORDS;            // words per entry
    localparam EPB = PT_ENTRIES / NPHYS;        // entries per bank
    localparam BDEPTH = EPB * WPE;              // words per bank
    localparam BAW = $clog2(BDEPTH);
    localparam LNP = $clog2(NPHYS);

    // ---- allocator ----
    wire [NWARPS*3-1:0] sblk;
    wire [NB*6-1:0] counts;
    ad_gfx_pt_alloc #(.NB(NB), .NWARPS(NWARPS), .WARP_W(WARP_W)) alloc (
        .clk(clk), .rst_n(rst_n), .pt_take(pt_take), .pt_warp(pt_warp), .vl_go(vl_go),
        .vl_mask(vl_mask), .pt_free(pt_free), .pt_free_idx(pt_free_idx), .wc_end(wc_end),
        .wc_warp(wc_warp), .pt_ok(pt_ok), .pt_base(pt_base), .pt_done(pt_done),
        .sblk(sblk), .counts(counts));

    // ---- the write of an exp group ----
    wire [11:0] tgt = x_uop[AD_UOP_IMM +: 12];
    wire is_exp = x_valid && x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_EXP && x_info[17:16] == 2'd0;
    wire t_pos = tgt[11:2] == 10'd0;
    wire [11:0] tv = tgt - 12'h010;
    wire t_vary = tgt >= 12'h010 && tv < VARY_WORDS;
    wire wr_go = is_exp && (t_pos || t_vary);
`ifdef MUT_PT_WORD
    wire [6:0] wword = t_pos ? {5'd0, tgt[1:0]} : (7'd3 + tv[6:0]);   // mutation: varying word 0 on POS w
`else
    wire [6:0] wword = t_pos ? {5'd0, tgt[1:0]} : (7'd4 + tv[6:0]);
`endif
    wire [2:0] wblk = sblk[x_warp*3 +: 3];
    // entry = wblk*32 + x_grp*NPHYS + i; bank i; entry/NPHYS = (wblk*32 + x_grp*NPHYS)/NPHYS
    wire [8:0] xg9 = {{(9-GRP_W){1'b0}}, x_grp};
    wire [8:0] went0 = {1'b0, wblk, 5'd0} + (xg9 << LNP);
    wire [8:0] wrow = went0 >> LNP;
    localparam [BAW+8:0] WPEW = WPE;
    wire [BAW+8:0] waddr = {{BAW{1'b0}}, wrow} * WPEW + {{(BAW+2){1'b0}}, wword};

    // ---- read ----
    wire [8:0] rrow = {1'b0, pt_idx} >> LNP;
    wire [BAW+8:0] raddr = {{BAW{1'b0}}, rrow} * WPEW + {{(BAW+2){1'b0}}, pt_word};
    wire [LNP-1:0] rbank = pt_idx[LNP-1:0];
    wire rd_ok = pt_word < WPE;

    // ---- scrub ----
    wire sc_on;
    wire [BAW-1:0] sc_a;
    ad_su_scrub #(.DEPTH(BDEPTH), .AW(BAW)) sc (.clk(clk), .rst_n(rst_n), .start(scrub),
        .on(sc_on), .a(sc_a));
    assign scrub_busy = sc_on;

    wire [31:0] bank_q [0:NPHYS-1];
    genvar g;
    generate
        for (g = 0; g < NPHYS; g = g + 1) begin : bk
            reg [31:0] mem [0:BDEPTH-1];
            reg [31:0] q;
            always @(posedge clk) begin
                if (sc_on)
                    mem[sc_a] <= 32'd0;
                else if (wr_go && x_mask[NPHYS + g])
                    mem[waddr[BAW-1:0]] <= x_b[32*g +: 32];
            end
            always @(posedge clk) begin
                if (pt_rd) q <= mem[raddr[BAW-1:0]];
            end
            assign bank_q[g] = q;
        end
    endgenerate

    reg [LNP-1:0] rbank_r;
    reg rd_ok_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            rbank_r <= {LNP{1'b0}};
            rd_ok_r <= 1'b0;
        end else if (pt_rd) begin
            rbank_r <= rbank;
            rd_ok_r <= rd_ok;
        end
    end
    always @(*) pt_rdata = rd_ok_r ? bank_q[rbank_r] : 32'd0;

    wire unused = &{1'b0, counts, x_uop, x_info, waddr[BAW+8:BAW], raddr[BAW+8:BAW], went0};
endmodule
