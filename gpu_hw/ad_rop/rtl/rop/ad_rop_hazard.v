// ad_rop_hazard -- pixel-lock CAM / RAW hazard tracker (spec/gpu/rop/ad_rop_hazard.md).
// NUM_ENTRIES (<= 16) entries {valid, tag}.  An entry released this cycle counts as free
// and non-matching for this cycle's allocation (combinational forwarding, spec §4).
//   alloc_ready = a free entry exists && no (non-releasing) valid entry matches alloc_tag
//   alloc_id    = lowest-index free entry (after forwarding)
// Allocation fires on alloc_valid && alloc_ready.  Releasing an invalid entry is ignored.
module ad_rop_hazard #(
    parameter NUM_ENTRIES = 16,
    parameter TAG_W       = 32
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             alloc_valid,
    output wire             alloc_ready,
    input  wire [TAG_W-1:0] alloc_tag,
    output wire [3:0]       alloc_id,
    input  wire             release_valid,
    input  wire [3:0]       release_id
`ifdef AD_FV_HAZARD
    // formal-only observation ports (not part of the spec interface)
    ,output wire [NUM_ENTRIES-1:0]       fv_valid
    ,output wire [NUM_ENTRIES*TAG_W-1:0] fv_tags
`endif
);
    localparam N = NUM_ENTRIES;

    reg  [N-1:0]       valid;
    reg  [N*TAG_W-1:0] tags;     // datapath, qualified by valid (not reset)

    // one-hot of the entry released this cycle (ids >= N address nothing)
    wire [N-1:0] rel_oh;
    genvar g;
    generate for (g = 0; g < N; g = g + 1) begin : g_rel
        assign rel_oh[g] = release_valid && (release_id == g);
    end endgenerate

    wire [N-1:0] live = valid & ~rel_oh;      // entries still locked this cycle
`ifdef MUT_HAZ_FWD
    wire [N-1:0] free = ~valid;               // mutation: no release forwarding
`else
    wire [N-1:0] free = ~live;
`endif

`ifdef AD_FV_HAZARD
    assign fv_valid = valid;
    assign fv_tags  = tags;
`endif

    wire [N-1:0] match;
    ad_hazard_cam #(.N(N), .TAG_W(TAG_W)) u_cam (.tags(tags), .en(live), .key(alloc_tag), .match(match));

    wire any_free;
    ad_hazard_prienc #(.N(N), .IDX_W(4)) u_enc (.req(free), .any(any_free), .idx(alloc_id));

`ifdef MUT_HAZ_CAM
    assign alloc_ready = any_free;            // mutation: ignores RAW hazards
`else
    assign alloc_ready = any_free && !(|match);
`endif
    wire fire = alloc_valid && alloc_ready;

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            valid <= {N{1'b0}};
        end else begin
            for (i = 0; i < N; i = i + 1) begin
                if (fire && alloc_id == i[3:0]) begin
                    valid[i] <= 1'b1;
                    tags[i*TAG_W +: TAG_W] <= alloc_tag;
                end else if (rel_oh[i]) begin
                    valid[i] <= 1'b0;
                end
            end
        end
    end
endmodule
