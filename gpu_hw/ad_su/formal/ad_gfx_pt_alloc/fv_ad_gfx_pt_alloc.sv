// fv_ad_gfx_pt_alloc -- ad_gfx_pt_alloc (NB 2 blocks, NWARPS 4).  The VF/RX rules are assumed:
// pt_take only with pt_ok and no vl_go outstanding; vl_go only once after each take; pt_free
// only of a block with entries in use (the rule "each entry of a lane in vl_mask is freed
// exactly once", counted per block: the harness's lc = the lanes of the latest vl_mask, through
// a second ad_gfx_popc32, minus the frees); wc_end only of a running slot and not of the slot
// whose vl_go is still due.  Properties: each count is 32 while its vl_go is due, else lc (so
// never below 0, never above 32); pt_ok / pt_base are the lowest free block; a block is never
// granted while in use; pt_done of a block rises only at the end of its latest taker (never by a
// stale owner) and falls only at its take; the bits of absent blocks are 0.
module fv_ad_gfx_pt_alloc (
    input wire clk,
    input wire rst_n,
    input wire pt_take,
    input wire [1:0] pt_warp,
    input wire vl_go,
    input wire [31:0] vl_mask,
    input wire pt_free,
    input wire [7:0] pt_free_idx,
    input wire wc_end,
    input wire [1:0] wc_warp
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n); else assume (rst_n);

    wire pt_ok;
    wire [7:0] pt_base, pt_done;
    wire [11:0] sblk;
    wire [11:0] counts;
    ad_gfx_pt_alloc #(.NB(2), .NWARPS(4), .WARP_W(2)) dut (.clk(clk), .rst_n(rst_n),
        .pt_take(pt_take), .pt_warp(pt_warp), .vl_go(vl_go), .vl_mask(vl_mask),
        .pt_free(pt_free), .pt_free_idx(pt_free_idx), .wc_end(wc_end), .wc_warp(wc_warp),
        .pt_ok(pt_ok), .pt_base(pt_base), .pt_done(pt_done), .sblk(sblk), .counts(counts));
    wire [5:0] nret;
    ad_gfx_popc32 hp (.m(~vl_mask), .n(nret));
    wire [5:0] nlive = 6'd32 - nret;

    reg [5:0] lc0, lc1;               // entries in use per block
    reg pend, pb;                     // a vl_go is due for block pb, slot ps
    reg [1:0] ps;
    reg [1:0] own0, own1;             // latest taker per block
    wire [5:0] c0 = counts[5:0], c1 = counts[11:6];
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
        end else begin
            if (pt_free && !pt_free_idx[5]) lc0 <= lc0 - 6'd1;
            if (pt_free && pt_free_idx[5]) lc1 <= lc1 - 6'd1;
            if (pt_take) begin
                pend <= 1'b1;
                pb <= pt_base[5];
                ps <= pt_warp;
                if (pt_base[5]) own1 <= pt_warp; else own0 <= pt_warp;
            end
            if (vl_go) begin
                pend <= 1'b0;
                if (pb) lc1 <= nlive; else lc0 <= nlive;
            end
        end
    end

    reg [7:0] pdone;
    reg pr, ptake, pwc;
    reg [1:0] pwcw;
    reg [7:0] pbase;
    reg [1:0] pown0, pown1;
    always @(posedge clk) begin
        pr <= rst_n;
        pdone <= pt_done;
        ptake <= pt_take && rst_n;
        pbase <= pt_base;
        pwc <= wc_end && rst_n;
        pwcw <= wc_warp;
        pown0 <= own0;
        pown1 <= own1;
    end
    always @(*) if (rst_n && !init) begin
        assert (c0 == ((pend && !pb) ? 6'd32 : lc0));
        assert (c1 == ((pend && pb) ? 6'd32 : lc1));
        assert (c0 <= 6'd32 && c1 <= 6'd32);
        assert (pt_ok == (c0 == 6'd0 || c1 == 6'd0));
        if (pt_ok) assert (pt_base == ((c0 == 6'd0) ? 8'd0 : 8'd32));
        if (pt_take) assert (pt_base[5] ? (lc1 == 6'd0 && !(pend && pb)) :
                                          (lc0 == 6'd0 && !(pend && !pb)));
        assert (pt_done[7:2] == 6'd0);
        if (pr) begin
            if (pt_done[0] && !pdone[0]) assert (pwc && pwcw == pown0 && !(ptake && !pbase[5]));
            if (pt_done[1] && !pdone[1]) assert (pwc && pwcw == pown1 && !(ptake && pbase[5]));
            if (!pt_done[0] && pdone[0]) assert (ptake && pbase == 8'd0);
            if (!pt_done[1] && pdone[1]) assert (ptake && pbase == 8'd32);
        end
    end
endmodule
