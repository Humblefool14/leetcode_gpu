// ad_vf_vc -- post-transform vertex cache (spec/gpu/vf/ad_vf_vc.md): NENTRIES-entry fully
// associative CAM of {vertex index, VDATA_W shaded data}.
//
// Lookup (combinational, 0 cycles): hit = lookup_valid && a valid entry holds lookup_index;
//   hit_slot / hit_vdata are that entry's (0 when no hit).  The lookup sees the cache as it is at
//   the start of the cycle: a commit or flush in the same cycle takes effect at the clock edge.
// Commit: an entry already holding commit_index is updated (data only, it keeps its place);
//   otherwise the lowest unused entry is allocated; otherwise (full) the entry the FIFO victim
//   pointer names is replaced and the pointer moves on (wrapping).  Allocation into an unused
//   entry does not move the pointer: after a flush entries fill 0, 1, 2 ... so the pointer always
//   names the oldest allocation (true FIFO).
// Flush: all entries invalid and the victim pointer 0; a commit in the same cycle is dropped.
// Leaves: ad_vf_vc_match (CAM compare, x2), ad_vf_vc_penc (priority encoder, x2), ad_vf_vc_victim.
module ad_vf_vc #(
    parameter NENTRIES = 32,
    parameter VDATA_W  = 512,
    parameter SLOT_W   = 5
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               flush,
    input  wire               lookup_valid,
    input  wire [31:0]        lookup_index,
    output wire               hit,
    output wire [VDATA_W-1:0] hit_vdata,
    output wire [SLOT_W-1:0]  hit_slot,
    input  wire               commit_valid,
    input  wire [31:0]        commit_index,
    input  wire [VDATA_W-1:0] commit_vdata
`ifdef AD_FV_VC
    , output wire [NENTRIES-1:0]    fv_valid,
    output wire [NENTRIES*32-1:0]   fv_tags,
    output wire [NENTRIES*VDATA_W-1:0] fv_data,
    output wire [SLOT_W-1:0]        fv_ptr
`endif
);
    reg  [NENTRIES-1:0]         valid;
    reg  [NENTRIES*32-1:0]      tags;
    reg  [NENTRIES*VDATA_W-1:0] data;
    wire [SLOT_W-1:0]           ptr;

    // ---------------- lookup ----------------
    wire [NENTRIES-1:0] l_match; wire l_any;
    ad_vf_vc_match #(.NENTRIES(NENTRIES), .KEY_W(32)) u_lmatch (.valid(valid), .tags(tags), .key(lookup_index), .match(l_match));
    wire [SLOT_W-1:0] l_slot;
    rec_arbiter #(.N(NENTRIES)) u_lpenc (.req(l_match), .grant_index(l_slot), .grant_valid(l_any));
    assign hit      = lookup_valid && l_any;
    assign hit_slot = hit ? l_slot : {SLOT_W{1'b0}};
    // one-hot AND-OR read mux (at most one entry matches)
    reg [VDATA_W-1:0] rd;
    integer e;
    always @(*) begin
        rd = {VDATA_W{1'b0}};
        for (e = 0; e < NENTRIES; e = e + 1)
            if (l_match[e]) rd = rd | data[VDATA_W*e +: VDATA_W];
    end
    assign hit_vdata = hit ? rd : {VDATA_W{1'b0}};

    // ---------------- commit ----------------
    wire [NENTRIES-1:0] c_match; wire c_hit;
    ad_vf_vc_match #(.NENTRIES(NENTRIES), .KEY_W(32)) u_cmatch (.valid(valid), .tags(tags), .key(commit_index), .match(c_match));
    wire [SLOT_W-1:0] c_hslot, c_free; wire c_any_free;
    rec_arbiter #(.N(NENTRIES)) u_chpenc (.req(c_match), .grant_index(c_hslot), .grant_valid(c_hit));
    rec_arbiter #(.N(NENTRIES)) u_fpenc  (.req(~valid), .grant_index(c_free), .grant_valid(c_any_free));
`ifdef MUT_VC_NOUPD
    wire c_upd = 1'b0;                    // mutation: a committed index already present is allocated again
`else
    wire c_upd = c_hit;
`endif
    wire              do_commit = commit_valid && !flush;
    wire [SLOT_W-1:0] w_slot    = c_upd ? c_hslot : c_any_free ? c_free : ptr;
    wire              replace   = do_commit && !c_upd && !c_any_free;

    ad_vf_vc_victim #(.NENTRIES(NENTRIES), .SLOT_W(SLOT_W)) u_victim (.clk(clk), .rst_n(rst_n), .flush(flush),
        .adv(replace), .ptr(ptr));

    always @(posedge clk) begin
        if (!rst_n || flush)
            valid <= {NENTRIES{1'b0}};
        else if (do_commit)
            valid[w_slot] <= 1'b1;
    end
    // datapath: tags and data are qualified by valid (no reset)
    always @(posedge clk) begin
        if (do_commit) begin
            tags[32*w_slot +: 32]           <= commit_index;
            data[VDATA_W*w_slot +: VDATA_W] <= commit_vdata;
        end
    end
`ifdef AD_FV_VC
    assign fv_valid = valid; assign fv_tags = tags; assign fv_data = data; assign fv_ptr = ptr;
`endif
endmodule
