// fv_ad_su_pt -- ad_su_pt (NPHYS 4, PT_ENTRIES 64, VARY_WORDS 1: 5 words an entry).  The VF/RX
// rules of formal/ad_gfx_pt_alloc are assumed (take only with pt_ok and no vl_go due, one vl_go
// per take, frees only of entries in use, counted per block, wc_end not of the slot whose vl_go
// is due); exp groups are free.  Properties: the allocator's outputs as seen at the ports
// (pt_ok, pt_base the lowest free block, never a block in use, pt_done only by the latest
// taker); and the data path for one free constant (entry, word): pt_rdata after a read of it is
// the last value an exp group of a vertex warp wrote there (through the warp's block, the
// group's side-effect lanes, targets 0x000-0x003 and 0x010), checked once the word has been
// written (task bmc, define DATA: the memory is not in the prove task's cone).
module fv_ad_su_pt (
    input wire clk,
    input wire rst_n,
    input wire x_valid,
    input wire [1:0] x_warp,
    input wire [2:0] x_grp,
    input wire [107:0] x_uop,
    input wire [127:0] x_b,
    input wire [7:0] x_mask,
    input wire [31:0] x_info,
    input wire pt_rd,
    input wire [7:0] pt_idx,
    input wire [6:0] pt_word,
    input wire pt_free,
    input wire [7:0] pt_free_idx,
    input wire pt_take,
    input wire [1:0] pt_warp,
    input wire vl_go,
    input wire [31:0] vl_mask,
    input wire wc_end,
    input wire [1:0] wc_warp
);
    `include "ad_su_uop.vh"
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n); else assume (rst_n);

    wire [31:0] pt_rdata;
    wire pt_ok, scrub_busy;
    wire [7:0] pt_base, pt_done;
    ad_su_pt #(.NPHYS(4), .NWARPS(4), .WARP_W(2), .GRP_W(3), .PT_ENTRIES(64), .VARY_WORDS(1)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
        .x_uop(x_uop), .x_b(x_b), .x_mask(x_mask), .x_info(x_info), .pt_rd(pt_rd),
        .pt_idx(pt_idx), .pt_word(pt_word), .pt_rdata(pt_rdata), .pt_free(pt_free),
        .pt_free_idx(pt_free_idx), .pt_ok(pt_ok), .pt_take(pt_take), .pt_warp(pt_warp),
        .pt_base(pt_base), .vl_go(vl_go), .vl_mask(vl_mask), .pt_done(pt_done),
        .wc_end(wc_end), .wc_warp(wc_warp), .scrub(1'b0), .scrub_busy(scrub_busy));

    // ---- allocator rules and shadow (as formal/ad_gfx_pt_alloc) ----
    wire [5:0] nret;
    ad_popcount #(.W(32)) hp (.in(~vl_mask), .count(nret));
    reg [5:0] lc0, lc1;
    reg pend, pb;
    reg [1:0] ps, own0, own1;
    reg blk [0:3];                    // each slot's block (after its take)
    always @(*) if (rst_n) begin
        if (pt_take) assume (pt_ok && !pend);
        if (vl_go) assume (pend && !pt_take);
        if (pt_free) assume (pt_free_idx[7:6] == 2'd0 && (pt_free_idx[5] ? lc1 : lc0) != 6'd0 &&
                             !(vl_go && pb == pt_free_idx[5]));
        if (wc_end) assume (!(pend && wc_warp == ps) && !(pt_take && pt_warp == wc_warp));
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            lc0 <= 6'd0; lc1 <= 6'd0; pend <= 1'b0; pb <= 1'b0; ps <= 2'd0;
            own0 <= 2'd0; own1 <= 2'd0;
            blk[0] <= 1'b0; blk[1] <= 1'b0; blk[2] <= 1'b0; blk[3] <= 1'b0;
        end else begin
            if (pt_free && !pt_free_idx[5]) lc0 <= lc0 - 6'd1;
            if (pt_free && pt_free_idx[5]) lc1 <= lc1 - 6'd1;
            if (pt_take) begin
                pend <= 1'b1; pb <= pt_base[5]; ps <= pt_warp; blk[pt_warp] <= pt_base[5];
                if (pt_base[5]) own1 <= pt_warp; else own0 <= pt_warp;
            end
            if (vl_go) begin
                pend <= 1'b0;
                if (pb) lc1 <= 6'd32 - nret; else lc0 <= 6'd32 - nret;
            end
        end
    end
    reg [7:0] pdone;
    reg pr, ptake, pwc;
    reg [1:0] pwcw, pown0, pown1;
    reg [7:0] pbase;
    always @(posedge clk) begin
        pr <= rst_n; pdone <= pt_done; ptake <= pt_take && rst_n; pbase <= pt_base;
        pwc <= wc_end && rst_n; pwcw <= wc_warp; pown0 <= own0; pown1 <= own1;
    end
    always @(*) if (rst_n && !init) begin
        assert (pt_ok == ((!(pend && !pb) && lc0 == 6'd0) || (!(pend && pb) && lc1 == 6'd0)));
        if (pt_ok) assert (pt_base == ((!(pend && !pb) && lc0 == 6'd0) ? 8'd0 : 8'd32));
        if (pt_take) assert (pt_base[5] ? (lc1 == 6'd0 && !(pend && pb)) :
                                          (lc0 == 6'd0 && !(pend && !pb)));
        assert (pt_done[7:2] == 6'd0);
        if (pr) begin
            if (pt_done[0] && !pdone[0]) assert (pwc && pwcw == pown0 && !(ptake && !pbase[5]));
            if (pt_done[1] && !pdone[1]) assert (pwc && pwcw == pown1 && !(ptake && pbase[5]));
        end
    end

`ifdef DATA
    // ---- the data of one (entry, word) ----
    (* anyconst *) reg [5:0] ce;
    (* anyconst *) reg [2:0] cw;
    always @(*) assume (cw <= 3'd4);
    wire [11:0] tgt = x_uop[AD_UOP_IMM +: 12];
    wire wr_kind = x_valid && x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_EXP && x_info[17:16] == 2'd0;
    wire [2:0] tw = (tgt[11:2] == 10'd0) ? {1'b0, tgt[1:0]} : 3'd4;
    wire tok = tgt[11:2] == 10'd0 || tgt == 12'h010;
    // the group's entries: blk*32 + grp*4 + lane
    wire hit_e = {blk[x_warp], x_grp, 2'b00} == {ce[5:2], 2'b00};
    wire wr = rst_n && wr_kind && tok && tw == cw && hit_e && x_mask[4 + ce[1:0]];
    reg known;
    reg [31:0] sv;
    always @(posedge clk) begin
        if (!rst_n) known <= 1'b0;
        else if (wr) begin
            known <= 1'b1;
            sv <= x_b[32*ce[1:0] +: 32];
        end
    end
    reg prd, pk;
    reg [31:0] psv;
    always @(posedge clk) begin
        prd <= rst_n && pt_rd && pt_idx == {2'b00, ce} && pt_word == {4'd0, cw};
        pk <= known && !wr;
        psv <= sv;
    end
    always @(*) if (rst_n && !init && prd && pk) assert (pt_rdata == psv);
`endif
endmodule
