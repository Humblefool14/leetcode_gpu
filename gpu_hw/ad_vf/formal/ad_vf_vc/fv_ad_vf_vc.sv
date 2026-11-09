// fv_ad_vf_vc -- ad_vf_vc (reduced: NENTRIES = NE (4), SLOT_W = SW (2), VDATA_W = 4; the index
// stays 32 bits) against a reference model written another way: a list of allocations in order
// (cnt entries in slots 0 .. cnt-1 after a flush; when full the oldest allocation, ord[0], is
// replaced and moves to the back of ord).  All inputs free every cycle.
// Asserted every cycle: hit / hit_slot / hit_vdata equal the model's lookup (a_ref_*); no two valid
// entries hold the same index (no label: in a loop); hit iff lookup_valid and a valid entry holds lookup_index
// (a_hit_iff); the cycle after a flush the cache is empty and the pointer 0 (a_flush).  The DUT
// state equals the model (h_*: helper invariants that make the proof inductive).
module fv_ad_vf_vc #(
    parameter NE = 4,
    parameter SW = 2
) (
    input wire        clk,
    input wire        rst_n,
    input wire        flush,
    input wire        lookup_valid,
    input wire [31:0] lookup_index,
    input wire        commit_valid,
    input wire [31:0] commit_index,
    input wire [3:0]  commit_vdata
);
    localparam VW = 4;
    wire hit; wire [VW-1:0] hit_vdata; wire [SW-1:0] hit_slot;
    wire [NE-1:0] f_v; wire [NE*32-1:0] f_t; wire [NE*VW-1:0] f_d; wire [SW-1:0] f_p;
    ad_vf_vc #(.NENTRIES(NE), .VDATA_W(VW), .SLOT_W(SW)) dut (.clk(clk), .rst_n(rst_n), .flush(flush),
        .lookup_valid(lookup_valid), .lookup_index(lookup_index), .hit(hit), .hit_vdata(hit_vdata), .hit_slot(hit_slot),
        .commit_valid(commit_valid), .commit_index(commit_index), .commit_vdata(commit_vdata),
        .fv_valid(f_v), .fv_tags(f_t), .fv_data(f_d), .fv_ptr(f_p));

    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);

    // ---------------- reference model ----------------
    reg [31:0] m_idx [0:NE-1]; reg [VW-1:0] m_dat [0:NE-1]; reg [SW-1:0] ord [0:NE-1];
    reg [SW:0] cnt;
    integer q;
    // lookup in the model: the allocated entry holding x (-> found, slot)
    reg l_f; reg [SW-1:0] l_s; reg c_f; reg [SW-1:0] c_s;
    always @(*) begin
        l_f = 1'b0; l_s = {SW{1'b0}}; c_f = 1'b0; c_s = {SW{1'b0}};
        for (q = 0; q < NE; q = q + 1) begin
            if (q < cnt && m_idx[q] == lookup_index) begin l_f = 1'b1; l_s = q; end
            if (q < cnt && m_idx[q] == commit_index) begin c_f = 1'b1; c_s = q; end
        end
    end
    always @(posedge clk) begin
        if (!rst_n || flush) begin
            cnt <= 0;
            for (q = 0; q < NE; q = q + 1) ord[q] <= q;
        end else if (commit_valid) begin
            if (c_f) m_dat[c_s] <= commit_vdata;
            else if (cnt < NE) begin
                m_idx[cnt[SW-1:0]] <= commit_index; m_dat[cnt[SW-1:0]] <= commit_vdata; cnt <= cnt + 1'b1;
            end else begin
                m_idx[ord[0]] <= commit_index; m_dat[ord[0]] <= commit_vdata;
                for (q = 0; q < NE - 1; q = q + 1) ord[q] <= ord[q + 1];
                ord[NE-1] <= ord[0];
            end
        end
    end

    reg p_flush = 1'b0;
    always @(posedge clk) p_flush <= flush && rst_n;

    // ---------------- properties ----------------
    integer a, b;
    reg any_m;
    always @(*) if (!init && rst_n) begin
        a_ref_hit:  assert (hit == (lookup_valid && l_f));
        if (hit) begin
            a_ref_slot: assert (hit_slot == l_s);
            a_ref_data: assert (hit_vdata == m_dat[l_s]);
        end else a_ref_zero: assert (hit_slot == 0 && hit_vdata == 0);
        any_m = 1'b0;
        for (a = 0; a < NE; a = a + 1) begin
            if (f_v[a] && f_t[32*a +: 32] == lookup_index) any_m = 1'b1;
            for (b = a + 1; b < NE; b = b + 1)
                if (f_v[a] && f_v[b]) assert (f_t[32*a +: 32] != f_t[32*b +: 32]);
        end
        a_hit_iff: assert (hit == (lookup_valid && any_m));
        if (p_flush) a_flush: assert (f_v == 0 && f_p == 0);
        // helper invariants: DUT state == model state
        for (a = 0; a < NE; a = a + 1) begin
            assert (f_v[a] == (a < cnt));
            if (a < cnt) begin
                assert (f_t[32*a +: 32] == m_idx[a]);
                assert (f_d[VW*a +: VW] == m_dat[a]);
                for (b = a + 1; b < NE; b = b + 1) assert (b >= cnt || m_idx[a] != m_idx[b]);
            end
            if (cnt == NE) assert (ord[a] == (f_p + a) % NE);
            else           assert (ord[a] == a);
        end
        if (cnt != NE) h_p0: assert (f_p == 0);
        h_cnt: assert (cnt <= NE);
        h_prange: assert (f_p < NE);
    end
    always @(*) if (!init && rst_n) begin
        c_repl: cover (cnt == NE && commit_valid && !c_f && f_p == NE - 1 && !flush);
        c_hit:  cover (hit && hit_slot == NE - 1);
    end
endmodule
