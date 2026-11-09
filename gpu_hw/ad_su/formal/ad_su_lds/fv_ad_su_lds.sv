// fv_ad_su_lds -- formal harness of ad_su_lds, reduced: NPHYS `NP (2 by
// default), LDS_BYTES 16 (4 words).  Reset in the first cycle only, no
// group in the first cycle after it; scrub 0.  A symbolic word W (anyconst)
// is read every cycle through the meshlet port (mesh_rd_data: W's word one
// cycle later); the shadow of W starts from that first read.  At each group
// taken, a reference model runs the group's lanes in lane order on the shadow
// (lds reads, sts writes rs2, atoms reads then writes op(old, rs2, rs3)) and
// records the old value each lane on W must return.  Properties: (indivisible,
// lanes in order) whenever no group is in flight, W's word equals the
// shadow; each beat returns the recorded old values of its lanes on W; a beat
// only for a taken group with its x_last; one group at a time.
`ifndef NP
`define NP 2
`endif
module fv_ad_su_lds (
    input wire clk,
    input wire rst_n,
    input wire x_valid, input wire x_last, input wire [107:0] x_uop,
    input wire [`NP*32-1:0] x_a, input wire [`NP*32-1:0] x_b, input wire [`NP*32-1:0] x_c,
    input wire [2*`NP-1:0] x_mask,
    input wire l_ready
);
    localparam NP = `NP, AW = 2;
    `include "ad_su_uop.vh"
    reg init = 1'b1, first = 1'b1;
    always @(posedge clk) begin init <= 1'b0; first <= init; end
    always @(*) begin
        if (init) assume (!rst_n);
        else assume (rst_n);
        if (first) assume (!x_valid);
    end

    (* anyconst *) reg [AW-1:0] W;
    wire x_ready, l_valid, l_wr, l_last, scrub_busy;
    wire [1:0] l_warp; wire [1:0] l_grp; wire [2:0] l_sbe, l_cls; wire [6:0] l_rd;
    wire [NP*32-1:0] l_data; wire [NP-1:0] l_lanes; wire [31:0] mesh_rd_data;
    localparam LIW = (NP > 1) ? $clog2(NP) : 1;
    wire [2:0] fv_st; wire [1:0] fv_kind; wire [NP-1:0] fv_pend; wire [NP*32-1:0] fv_ad, fv_opb, fv_opc;
    wire [3:0] fv_aop; wire [31:0] fv_ram_rd, fv_awdata; wire fv_cap_v, fv_awe; wire [LIW-1:0] fv_cap_ln;
    wire [AW-1:0] fv_aaddr;
    ad_su_lds #(.NPHYS(NP), .GRP_W(2), .UOP_W(108), .LDS_BYTES(16)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(2'd0), .x_grp(2'd0), .x_last(x_last),
        .x_sbe(3'd0), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
        .x_info(32'd0), .x_ready(x_ready), .l_valid(l_valid), .l_ready(l_ready), .l_warp(l_warp),
        .l_grp(l_grp), .l_rd(l_rd), .l_data(l_data), .l_lanes(l_lanes), .l_wr(l_wr), .l_last(l_last),
        .l_sbe(l_sbe), .l_cls(l_cls), .scrub(1'b0), .scrub_busy(scrub_busy),
        .mesh_rd_en(1'b1), .mesh_rd_addr(W), .mesh_rd_data(mesh_rd_data),
        .fv_st(fv_st), .fv_kind(fv_kind), .fv_pend(fv_pend), .fv_ad(fv_ad), .fv_opb(fv_opb), .fv_opc(fv_opc),
        .fv_aop(fv_aop), .fv_ram_rd(fv_ram_rd), .fv_cap_v(fv_cap_v), .fv_cap_ln(fv_cap_ln),
        .fv_awe(fv_awe), .fv_aaddr(fv_aaddr), .fv_awdata(fv_awdata));

    wire take = x_valid && x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_LDS && x_ready;
    wire [7:0] op = x_uop[AD_UOP_OP +: 8];
    wire [31:0] imm = x_uop[AD_UOP_IMM +: 32];
    // the reference chain: lane i sees vin[i] and leaves vin[i+1]; the
    // operation is the module ad_mem_atom_alu, which this harness replaces by
    // fv_atom_abstract.sv (the real leaf is proven in formal/ad_mem_atom_alu)
    reg [31:0] shadow;
    wire [32*(NP+1)-1:0] vin;
    wire [NP*32-1:0] nv;
    reg [NP*32-1:0] t_old, e_old;
    reg [NP-1:0] t_on, e_on;
    reg [32*(NP+1)-1:0] vch;
    assign vin = vch;
    genvar g;
    generate for (g = 0; g < NP; g = g + 1) begin : g_ref
        ad_mem_atom_alu u_ref (.op(x_uop[AD_UOP_SUB +: 4]), .old(vin[g*32 +: 32]), .a(x_b[g*32 +: 32]),
                               .cmp(x_c[g*32 +: 32]), .nv(nv[g*32 +: 32]));
    end endgenerate
    reg [31:0] ba, v;
    integer i;
    always @(*) begin
        vch[31:0] = first ? mesh_rd_data : shadow;
        t_old = {(NP*32){1'b0}}; t_on = {NP{1'b0}};
        for (i = 0; i < NP; i = i + 1) begin
            v = vch[i*32 +: 32];
            ba = (op == AD_LDS_ATOM) ? x_a[i*32 +: 32] : x_a[i*32 +: 32] + imm;
            if (ba[AW+1:2] == W) begin
                if (op == AD_LDS_LDS && x_mask[i]) begin t_on[i] = 1'b1; t_old[i*32 +: 32] = v; end
                if (op == AD_LDS_STS && x_mask[NP+i]) v = x_b[i*32 +: 32];
                if (op == AD_LDS_ATOM && x_mask[NP+i]) begin
                    t_on[i] = 1'b1; t_old[i*32 +: 32] = v;
                    v = nv[i*32 +: 32];
                end
            end
            vch[(i+1)*32 +: 32] = v;
        end
    end
    reg inflight, g_last;
    // take-time copies (for the helper invariants)
    reg [NP*32-1:0] t_ad, tk_ad, tk_b, tk_c;
    reg [NP-1:0] t_lanes, t_pend, tk_lanes, tk_pend;
    reg [1:0] tk_kind; reg [3:0] tk_op;
    reg [32*(NP+1)-1:0] tk_vch;
    reg [31:0] memw, memw_d; reg [1:0] age;
    always @(*) begin
        for (i = 0; i < NP; i = i + 1)
            t_ad[i*32 +: 32] = (op == AD_LDS_ATOM) ? x_a[i*32 +: 32] : x_a[i*32 +: 32] + imm;
        t_pend  = (op == AD_LDS_LDS) ? x_mask[NP-1:0] :
                  (op == AD_LDS_STS || op == AD_LDS_ATOM) ? x_mask[2*NP-1:NP] : {NP{1'b0}};
        t_lanes = (op == AD_LDS_LDS) ? x_mask[NP-1:0] : (op == AD_LDS_ATOM) ? x_mask[2*NP-1:NP] : {NP{1'b0}};
    end
    always @(posedge clk) begin
        if (!rst_n) begin inflight <= 1'b0; age <= 2'd0; end
        else begin
            if (age != 2'd3) age <= age + 1'b1;
            if (first) begin shadow <= mesh_rd_data; memw <= mesh_rd_data; end
            else if (fv_awe && fv_aaddr == W) memw <= fv_awdata;
            if (l_valid && l_ready) inflight <= 1'b0;
            if (take) begin
                inflight <= 1'b1; g_last <= x_last; e_old <= t_old; e_on <= t_on;
                shadow <= vch[NP*32 +: 32];
                tk_ad <= t_ad; tk_b <= x_b; tk_c <= x_c; tk_pend <= t_pend; tk_lanes <= t_lanes;
                tk_kind <= (op == AD_LDS_ATOM) ? 2'd2 : (op == AD_LDS_STS) ? 2'd1 : 2'd0;
                tk_op <= x_uop[AD_UOP_SUB +: 4]; tk_vch <= vch;
            end
        end
        memw_d <= memw;
    end
    // the first pending lane and the value of W before it
    reg [LIW-1:0] al; reg [31:0] vb4; reg ordered, capok;
    integer j;
    always @(*) begin
        al = {LIW{1'b0}};
        for (j = NP - 1; j >= 0; j = j - 1) if (fv_pend[j]) al = j[LIW-1:0];
        vb4 = tk_vch[al*32 +: 32];
        ordered = 1'b1;
        for (i = 0; i < NP; i = i + 1)
            for (j = i + 1; j < NP; j = j + 1)
                if (fv_pend[i] && tk_pend[j] && !fv_pend[j]) ordered = 1'b0;
    end
    wire [31:0] al_ba = tk_ad[al*32 +: 32];
    // the chain recomputed from the take-time copies (the copies agree)
    wire [NP*32-1:0] rnv;
    reg  [32*(NP+1)-1:0] rch;
    reg  [NP*32-1:0] r_old; reg [NP-1:0] r_on;
    reg  [31:0] rv;
    generate for (g = 0; g < NP; g = g + 1) begin : g_rch
        ad_mem_atom_alu u_r (.op(tk_op), .old(rch[g*32 +: 32]), .a(tk_b[g*32 +: 32]),
                             .cmp(tk_c[g*32 +: 32]), .nv(rnv[g*32 +: 32]));
    end endgenerate
    always @(*) begin
        rch[31:0] = tk_vch[31:0];
        r_old = {(NP*32){1'b0}}; r_on = {NP{1'b0}};
        for (i = 0; i < NP; i = i + 1) begin
            rv = rch[i*32 +: 32];
            if (tk_pend[i] && tk_ad[i*32+2 +: AW] == W) begin
                if (tk_kind == 2'd0) begin r_on[i] = 1'b1; r_old[i*32 +: 32] = rv; end
                if (tk_kind == 2'd1) rv = tk_b[i*32 +: 32];
                if (tk_kind == 2'd2) begin r_on[i] = 1'b1; r_old[i*32 +: 32] = rv; rv = rnv[i*32 +: 32]; end
            end
            rch[(i+1)*32 +: 32] = rv;
        end
    end
    always @(*) if (rst_n && first) begin
        h_first: assert (fv_st == 3'd0 && !inflight && age == 2'd0);
    end
    always @(*) if (rst_n && !first && !init) begin
        if (!inflight) a_word: assert (mesh_rd_data == shadow);
        a_beat: assert (!l_valid || inflight);
        if (l_valid) begin
            a_last: assert (l_last == g_last);
            for (i = 0; i < NP; i = i + 1)
                if (e_on[i]) assert (l_lanes[i] && l_data[i*32 +: 32] == e_old[i*32 +: 32]);
        end
        a_one: assert (!(take && inflight));
        // helper invariants (k-induction).  States: 0 idle 1 acc 2 atr 3 atw 4 drain 5 beat
        h_scr:  assert (!scrub_busy);
        h_st:   assert (fv_st <= 3'd5);
        h_inf:  assert (inflight == (fv_st != 3'd0));
        if (age >= 2'd2) h_mesh: assert (mesh_rd_data == memw_d);
        h_age:  assert (age != 2'd0);
        if (age == 2'd1) h_age1: assert (fv_st == 3'd0 && !inflight && mesh_rd_data == memw);
        if (!inflight) h_idle: assert (memw == shadow);
        if (inflight) begin
            h_ops:  assert (fv_ad == tk_ad && fv_opb == tk_b && fv_opc == tk_c && fv_kind == tk_kind &&
                            fv_aop == tk_op && l_last == g_last && l_lanes == tk_lanes);
            h_sh:   assert (shadow == tk_vch[NP*32 +: 32]);
            h_rch:  assert (rch == tk_vch && r_on == e_on && r_old == e_old);
            h_lan:  assert (tk_lanes == (tk_kind == 2'd1 ? {NP{1'b0}} : tk_pend) && tk_kind != 2'd3);
            h_sub:  assert ((fv_pend & ~tk_pend) == {NP{1'b0}});
            h_ord:  assert (ordered);
            h_kst:  assert (tk_kind == 2'd0 ? (fv_st == 3'd1 || fv_st == 3'd4 || fv_st == 3'd5) :
                            tk_kind == 2'd1 ? (fv_st == 3'd1 || fv_st == 3'd5) :
                            (fv_st == 3'd2 || fv_st == 3'd3 || fv_st == 3'd5));
            h_pz:   assert ((fv_st == 3'd4 || fv_st == 3'd5) == (fv_pend == {NP{1'b0}}));
            if (fv_pend != {NP{1'b0}}) h_mw: assert (memw == vb4);
            else h_mwd: assert (memw == tk_vch[NP*32 +: 32]);
            if (fv_st == 3'd3 && al_ba[AW+1:2] == W) h_rd: assert (fv_ram_rd == vb4);
            h_cap:  assert (!fv_cap_v || (tk_kind == 2'd0 && (fv_st == 3'd1 || fv_st == 3'd4) &&
                            tk_pend[fv_cap_ln] && !fv_pend[fv_cap_ln]));
            for (i = 0; i < NP; i = i + 1)
                if (e_on[i] && !fv_pend[i]) begin
                    if (fv_cap_v && fv_cap_ln == i) assert (fv_ram_rd == e_old[i*32 +: 32]);
                    else assert (l_data[i*32 +: 32] == e_old[i*32 +: 32]);
                end
        end
    end
endmodule
