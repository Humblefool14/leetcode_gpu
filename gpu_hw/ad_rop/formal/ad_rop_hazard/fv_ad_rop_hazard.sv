// fv_ad_rop_hazard -- pixel-lock CAM properties (spec §4).  Harness reduction: TAG_W = 4
// (the logic is tag-width independent), NUM_ENTRIES = 16.  The DUT is read with
// -DAD_FV_HAZARD, which adds observation ports fv_valid / fv_tags.
module fv_ad_rop_hazard #(
    parameter N  = 16,
    parameter TW = 4
) (
    input wire          clk,
    input wire          rst_n,
    input wire          alloc_valid,
    input wire [TW-1:0] alloc_tag,
    input wire          release_valid,
    input wire [3:0]    release_id
);
    wire alloc_ready; wire [3:0] alloc_id;
    wire [N-1:0] v; wire [N*TW-1:0] t;
    ad_rop_hazard #(.NUM_ENTRIES(N), .TAG_W(TW)) dut (.clk(clk), .rst_n(rst_n),
        .alloc_valid(alloc_valid), .alloc_ready(alloc_ready), .alloc_tag(alloc_tag), .alloc_id(alloc_id),
        .release_valid(release_valid), .release_id(release_id), .fv_valid(v), .fv_tags(t));

    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);

    // reference view of this cycle (release forwarding)
    wire [N-1:0] rel; wire [N-1:0] free; wire [N-1:0] hit;
    genvar g;
    generate for (g = 0; g < N; g = g + 1) begin : g_ref
        assign rel[g]  = release_valid && release_id == g;
        assign free[g] = !v[g] || rel[g];
        assign hit[g]  = v[g] && !rel[g] && t[g*TW +: TW] == alloc_tag;
    end endgenerate
    wire fire = alloc_valid && alloc_ready;

    integer i, j;
    always @(*) if (!init && rst_n) begin
        // no two valid entries hold the same tag
        for (i = 0; i < N; i = i + 1)
            for (j = i + 1; j < N; j = j + 1)
                if (v[i] && v[j]) assert (t[i*TW +: TW] != t[j*TW +: TW]);
        // alloc_ready <=> a (forwarded) free entry exists and no live entry matches
        a_ready: assert (alloc_ready == ((|free) && !(|hit)));
        // alloc_id: a free entry, the lowest one
        if (alloc_ready) begin
            a_id_rng:  assert (alloc_id < N);
            a_id_free: assert (free[alloc_id]);
            for (i = 0; i < N; i = i + 1)
                if (i < alloc_id) assert (!free[i]);
        end
        // full CAM: no allocation unless a release frees an entry
        if ((&v) && !(release_valid && release_id < N)) a_full: assert (!alloc_ready);
    end

    // one-cycle history
    reg p_ok = 1'b0, p_fire, p_rel; reg [3:0] p_id, p_rid; reg [TW-1:0] p_tag; reg [N-1:0] p_v;
    always @(posedge clk) begin
        p_ok <= rst_n && !init; p_fire <= fire; p_rel <= release_valid; p_id <= alloc_id; p_rid <= release_id;
        p_tag <= alloc_tag; p_v <= v;
    end
    always @(*) if (p_ok && rst_n) begin
        // an allocated entry becomes valid with the given tag
        if (p_fire) begin
            a_alloc_v: assert (v[p_id]);
            a_alloc_t: assert (t[p_id*TW +: TW] == p_tag);
        end
        for (i = 0; i < N; i = i + 1) begin
            // a valid entry only becomes invalid by its release
            if (p_v[i] && !v[i]) assert (p_rel && p_rid == i);
            // an invalid entry only becomes valid by allocation into it
            if (!p_v[i] && v[i]) assert (p_fire && p_id == i);
        end
    end
    // reachability
    always @(*) if (!init && rst_n) begin
        c_full:    cover (&v);
        c_fwd:     cover ((&v) && fire);
    end
endmodule
