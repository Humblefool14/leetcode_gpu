// ad_gfx_pt_alloc -- the PT block allocator of ad_su_pt (spec ad_su_pt.md §4): one count per
// block of 32 entries, the owner of each block, the block of each slot, pt_done.
//   pt_ok: some count is 0; pt_base = 32 x the lowest such block.
//   pt_take: that block's count := 32, owner := pt_warp, the slot's block := it, pt_done := 0.
//   vl_go: subtracts the lanes outside vl_mask from the block of the latest take.
//   pt_free: subtracts 1 from the block of pt_free_idx.
//   wc_end: sets pt_done of the blocks whose owner is wc_warp (a block retaken by another
//   slot has another owner: the stale owner's end does not set it).
// Take, go and free on one block in one cycle add up.
module ad_gfx_pt_alloc #(
    parameter NB = 2,                  // blocks (PT_ENTRIES / 32), 1..8
    parameter NWARPS = 4,
    parameter WARP_W = 2
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                pt_take,
    input  wire [WARP_W-1:0]   pt_warp,
    input  wire                vl_go,
    input  wire [31:0]         vl_mask,
    input  wire                pt_free,
    input  wire [7:0]          pt_free_idx,
    input  wire                wc_end,
    input  wire [WARP_W-1:0]   wc_warp,
    output wire                pt_ok,
    output wire [7:0]          pt_base,
    output wire [7:0]          pt_done,
    output wire [NWARPS*3-1:0] sblk,          // block of each slot (3 bits a slot)
    output wire [NB*6-1:0]     counts         // the counts (for checks)
);
    reg [5:0] cnt [0:NB-1];
    reg [WARP_W-1:0] owner [0:NB-1];
    reg [NB-1:0] done;
    reg [2:0] slot_blk [0:NWARPS-1];
    reg [2:0] gob;                     // block of the latest take

    // lowest free block
    reg [2:0] low;
    reg any;
    integer b;
    always @(*) begin
        low = 3'd0;
        any = 1'b0;
        for (b = NB - 1; b >= 0; b = b - 1)
            if (cnt[b] == 6'd0) begin
                low = b[2:0];
                any = 1'b1;
            end
    end
    assign pt_ok = any;
    assign pt_base = {low, 5'd0};

    // lanes returned at vl_go
    wire [5:0] ret;
    ad_popcount #(.W(32)) pc (.in(~vl_mask), .count(ret));

    wire [2:0] fblk = pt_free_idx[7:5];
    genvar g;
    generate
        for (g = 0; g < NB; g = g + 1) begin : blk
            wire tk = pt_take && any && low == g;
            wire [5:0] base = tk ? 6'd32 : cnt[g];
            wire [5:0] sub_go = (vl_go && gob == g) ? ret : 6'd0;
            wire [5:0] sub_fr = (pt_free && fblk == g) ? 6'd1 : 6'd0;
            always @(posedge clk) begin
                if (!rst_n) begin
                    cnt[g] <= 6'd0;
                    owner[g] <= {WARP_W{1'b0}};
                    done[g] <= 1'b0;
                end else begin
`ifdef MUT_PT_NOFREE
                    cnt[g] <= base - sub_go;
`else
                    cnt[g] <= base - sub_go - sub_fr;
`endif
                    if (tk) begin
                        owner[g] <= pt_warp;
                        done[g] <= 1'b0;
`ifdef MUT_PT_STALE
                    end else if (wc_end) begin
`else
                    end else if (wc_end && owner[g] == wc_warp) begin
`endif
                        done[g] <= 1'b1;
                    end
                end
            end
            assign counts[g*6 +: 6] = cnt[g];
        end
    endgenerate

    integer s;
    always @(posedge clk) begin
        if (!rst_n) begin
            gob <= 3'd0;
            for (s = 0; s < NWARPS; s = s + 1) slot_blk[s] <= 3'd0;
        end else if (pt_take && any) begin
            gob <= low;
            slot_blk[pt_warp] <= low;
        end
    end
    generate
        for (g = 0; g < NWARPS; g = g + 1) begin : sb
            assign sblk[g*3 +: 3] = slot_blk[g];
        end
    endgenerate
    wire [NB+7:0] done_x = {8'd0, done};
    assign pt_done = done_x[7:0];
endmodule
