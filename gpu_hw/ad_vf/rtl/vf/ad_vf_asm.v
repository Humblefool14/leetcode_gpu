// ad_vf_asm -- VF warp and primitive assembly (spec/gpu/vf/ad_vf_asm.md).
// Packs iv vertices into 32-lane warps (vb_*), requests an SU slot (vl_req/vl_gnt), starts the
// warp after conv_done (vl_go, vl_mask) and emits the warp's primitives (prim_*) as PT entries
// vl_ptbase + lane with last-use flags; the last primitive is held back for prim_last.
// Children (rtl/vf/asm/): ad_vf_asm_topo (classifier), ad_vf_asm_step (assembly step + list fit
// rule), ad_vf_asm_order (provoking rotation), ad_vf_asm_carry (vertices re-sent into lanes 0/1),
// ad_vf_asm_lastuse (prim_free), ad_vf_asm_pout (held-back output, prim_last).
// Reference: tools/asm_model.py assemble().
`include "ad_vf_state.vh"
module ad_vf_asm (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        st_we,
    input  wire [8:0]  st_idx,
    input  wire [31:0] st_wdata,
    input  wire        iv_valid,
    output reg         iv_ready,
    input  wire [31:0] iv_index,
    input  wire [31:0] iv_inst,
    input  wire        iv_restart,
    input  wire        iv_last,
    output reg         vb_valid,
    input  wire        vb_ready,
    output reg  [31:0] vb_index,
    output reg  [31:0] vb_inst,
    output reg  [4:0]  vb_lane,
    output reg         vb_last,
    input  wire        conv_done,
    output wire        vl_req,
    input  wire        vl_gnt,
    input  wire [7:0]  vl_ptbase,
    output wire        vl_go,
    output wire [31:0] vl_mask,
    output wire        prim_valid,
    input  wire        prim_ready,
    output wire [25:0] prim_vtx,
    output wire [2:0]  prim_free,
    output wire        prim_last,
    output wire        busy
`ifdef AD_FV_ASM
    // formal visibility (formal/ad_vf_asm)
    , output wire [2:0] fv_st, output wire fv_in_fire, output wire fv_hold
`endif
);
    // ---------------- STATE snoop ----------------
    reg [2:0]  s_topo;
    reg [1:0]  s_ifmt;
    reg [31:0] s_voff;
    reg        s_prov;
    always @(posedge clk) begin
        if (!rst_n) begin
            s_topo <= 3'd0; s_ifmt <= 2'd0; s_voff <= 32'd0; s_prov <= 1'b0;
        end else if (st_we) begin
            if (st_idx == `AD_S_TOPOLOGY)      s_topo <= st_wdata[2:0];
            if (st_idx == `AD_S_INDEX_FORMAT)  s_ifmt <= st_wdata[1:0];
            if (st_idx == `AD_S_VERTEX_OFFSET) s_voff <= st_wdata;
            if (st_idx == `AD_S_PROVOKING)     s_prov <= st_wdata[0];
        end
    end
    wire [2:0] cls; wire [1:0] kind, psize; wire is_list;
    ad_vf_asm_topo u_topo (.topo(s_topo), .cls(cls), .kind(kind), .is_list(is_list), .psize(psize));

    // lanes per warp: 32 (formal/ad_vf_asm's bmc task reduces it with AD_FV_ASM_LANES to reach
    // several warps within its depth)
`ifdef AD_FV_ASM_LANES
    localparam [5:0] NLANES = `AD_FV_ASM_LANES;
`else
    localparam [5:0] NLANES = 6'd32;
`endif

    // ---------------- state ----------------
    localparam S_IDLE = 3'd0, S_NEXT = 3'd1, S_ALLOC = 3'd2, S_CARRY = 3'd3, S_SEND = 3'd4,
               S_WAIT = 3'd5, S_GO = 3'd6, S_PRIMS = 3'd7;
    reg [2:0]  st;
    reg        draw_end;              // the draw's last item has been taken
    // run (strip / fan / list primitive) state, kept across warps
    reg [1:0]  r_n;
    reg        r_par;
    reg [31:0] r_inst;
    reg [4:0]  r0_l, r1_l;
    reg [31:0] r0_idx, r1_idx;
    // warp
    reg [7:0]  ptbase;
    reg [5:0]  lane;                  // lanes used (next lane)
    reg [1:0]  cr_n, cr_k;            // carried vertices to send / sent
    reg        cr_c0_r1;
    reg        h_v, h_last;           // held newest vertex (lane - 1)
    reg [31:0] h_idx, h_inst;
    reg [31:0] mask;
    reg [5:0]  np, pj;                // primitives formed / emitted
    reg [14:0] pbuf [0:31];

    assign busy    = (st != S_IDLE);
    assign vl_req  = (st == S_ALLOC);
    assign vl_go   = (st == S_GO);
    assign vl_mask = mask;

    // ---------------- assembly step for the iv vertex ----------------
    wire iv_vtx = iv_valid && !iv_restart;
    wire clr_i  = (r_n != 2'd0) && (iv_inst != r_inst);
    wire nofit, pv, ppar, par_nx, r1_new; wire [4:0] px, py, pz; wire [1:0] n_nx, r0_sel;
    ad_vf_asm_step #(.LANES(NLANES)) u_step (.cls(cls), .is_list(is_list), .psize(psize), .n(r_n), .par(r_par), .clr(clr_i),
        .r0_l(r0_l), .r1_l(r1_l), .lane(lane[4:0]), .nofit(nofit), .pv(pv), .x(px), .y(py), .z(pz),
        .ppar(ppar), .n_nx(n_nx), .par_nx(par_nx), .r0_sel(r0_sel), .r1_new(r1_new));
    wire [4:0] ol0, ol1, ol2;
    ad_vf_asm_order u_order (.cls(cls), .prov(s_prov), .par(ppar), .x(px), .y(py), .z(pz),
        .l0(ol0), .l1(ol1), .l2(ol2));
    // carry decision (in NEXT, with the run ended by a change of instance)
    wire [1:0] c_cnt; wire c_c0_r1, c_r0_mv, c_r1_mv, c_r1_l;
    ad_vf_asm_carry u_carry (.cls(cls), .n(clr_i ? 2'd0 : r_n), .cnt(c_cnt), .c0_r1(c_c0_r1),
        .r0_mv(c_r0_mv), .r1_mv(c_r1_mv), .r1_l(c_r1_l));

    wire [31:0] new_idx = (s_ifmt != 2'd0) ? iv_index + s_voff : iv_index;

    // ---------------- SEND / CARRY combinational handshake ----------------
    reg take;                 // take the iv vertex into the warp
    always @(*) begin
        iv_ready = 1'b0; vb_valid = 1'b0; vb_last = 1'b0; take = 1'b0;
        vb_index = h_idx; vb_inst = h_inst; vb_lane = lane[4:0] - 5'd1;
        case (st)
            S_NEXT: iv_ready = iv_valid && iv_restart;
            S_CARRY: begin
                vb_valid = 1'b1;
                vb_index = (cr_k == 2'd0 && !cr_c0_r1) ? r0_idx : r1_idx;
                vb_inst  = r_inst;
                vb_lane  = lane[4:0];
            end
            S_SEND: begin
                if (h_v && h_last) begin
                    vb_valid = 1'b1; vb_last = 1'b1;
                end else if (iv_valid && iv_restart) begin
                    iv_ready = 1'b1;
                end else if (iv_vtx && !(nofit && h_v)) begin
                    vb_valid = h_v;
                    take     = !h_v || vb_ready;
                    iv_ready = take;
                end
            end
            default: ;
        endcase
    end

    // ---------------- primitive emission ----------------
    wire [14:0] pcur = pbuf[pj[4:0]];
    wire [2:0]  lfree;
    ad_vf_asm_lastuse u_lu (.clk(clk), .rst_n(rst_n), .clr(st == S_ALLOC), .we(take && pv), .wj(np[4:0]),
        .wl0(ol0), .wl1(ol1), .wl2(ol2), .rj(pj[4:0]), .rl0(pcur[4:0]), .rl1(pcur[9:5]), .rl2(pcur[14:10]),
        .free(lfree));
    wire p_in_valid = (st == S_PRIMS) && (pj != np);
    wire p_fin      = (st == S_PRIMS) && (pj == np) && draw_end;
    wire p_in_ready, p_hold;
    ad_vf_asm_pout u_pout (.clk(clk), .rst_n(rst_n), .in_valid(p_in_valid), .in_ready(p_in_ready),
        .in_l0(pcur[4:0]), .in_l1(pcur[9:5]), .in_l2(pcur[14:10]), .in_free(lfree), .in_kind(kind),
        .ptbase(ptbase), .fin(p_fin), .hold_v(p_hold), .prim_valid(prim_valid), .prim_ready(prim_ready),
        .prim_vtx(prim_vtx), .prim_free(prim_free), .prim_last(prim_last));

    // ---------------- sequential ----------------
    always @(posedge clk) begin
        if (take && pv) pbuf[np[4:0]] <= {ol2, ol1, ol0};
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; draw_end <= 1'b0;
            r_n <= 2'd0; r_par <= 1'b0; r_inst <= 32'd0; r0_l <= 5'd0; r1_l <= 5'd0;
            r0_idx <= 32'd0; r1_idx <= 32'd0;
            ptbase <= 8'd0; lane <= 6'd0; cr_n <= 2'd0; cr_k <= 2'd0; cr_c0_r1 <= 1'b0;
            h_v <= 1'b0; h_last <= 1'b0; h_idx <= 32'd0; h_inst <= 32'd0;
            mask <= 32'd0; np <= 6'd0; pj <= 6'd0;
        end else begin
            case (st)
                S_IDLE: begin
                    r_n <= 2'd0; r_par <= 1'b0; draw_end <= 1'b0; np <= 6'd0; pj <= 6'd0;
                    if (iv_valid) st <= S_NEXT;
                end
                S_NEXT: if (iv_valid) begin
                    if (iv_restart) begin
                        r_n <= 2'd0; r_par <= 1'b0;
                        if (iv_last) begin draw_end <= 1'b1; st <= S_PRIMS; end
                    end else begin
                        // carried vertices: rebase the run's lanes onto 0 / 1
                        if (clr_i) begin r_n <= 2'd0; r_par <= 1'b0; end
                        cr_n <= c_cnt; cr_c0_r1 <= c_c0_r1; cr_k <= 2'd0;
                        if (c_r0_mv) r0_l <= 5'd0;
                        if (c_r1_mv) r1_l <= {4'd0, c_r1_l};
                        st <= S_ALLOC;
                    end
                end
                S_ALLOC: begin
                    lane <= 6'd0; h_v <= 1'b0; h_last <= 1'b0; mask <= 32'd0; np <= 6'd0; pj <= 6'd0;
                    if (vl_gnt) begin
                        ptbase <= vl_ptbase;
                        st <= (cr_n != 2'd0) ? S_CARRY : S_SEND;
                    end
                end
                S_CARRY: if (vb_ready) begin
                    lane <= lane + 6'd1; cr_k <= cr_k + 2'd1;
                    if (cr_k + 2'd1 == cr_n) st <= S_SEND;
                end
                S_SEND: begin
                    if (h_v && h_last) begin
                        if (vb_ready) begin h_v <= 1'b0; st <= S_WAIT; end
                    end else if (iv_valid && iv_restart) begin
                        r_n <= 2'd0; r_par <= 1'b0;
                        if (iv_last) begin draw_end <= 1'b1; h_last <= 1'b1; end
                    end else if (iv_vtx && nofit && h_v) begin
                        h_last <= 1'b1;
                    end else if (take) begin
                        h_v <= 1'b1; h_idx <= new_idx; h_inst <= iv_inst;
                        h_last <= iv_last || (lane == NLANES - 6'd1);
                        if (iv_last) draw_end <= 1'b1;
                        lane <= lane + 6'd1;
                        r_n <= n_nx; r_par <= par_nx; r_inst <= iv_inst;
                        if (r0_sel == 2'd1) begin r0_l <= lane[4:0]; r0_idx <= new_idx; end
                        else if (r0_sel == 2'd2) begin r0_l <= r1_l; r0_idx <= r1_idx; end
                        if (r1_new) begin r1_l <= lane[4:0]; r1_idx <= new_idx; end
                        if (pv) begin
                            np <= np + 6'd1;
                            mask <= mask | (32'd1 << ol0) | (32'd1 << ol1) | (32'd1 << ol2);
                        end
                    end
                end
`ifdef MUT_ASM_GO_EARLY
                S_WAIT: st <= S_GO;                         // mutation: vl_go without conv_done
`else
                S_WAIT: if (conv_done) st <= S_GO;
`endif
                S_GO:   st <= S_PRIMS;
                S_PRIMS: begin
                    if (p_in_ready) pj <= pj + 6'd1;
                    if (pj == np) begin
                        if (!draw_end) st <= S_NEXT;
                        else if (!p_hold || (prim_valid && prim_ready)) st <= S_IDLE;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

`ifdef AD_FV_ASM
    assign fv_st = st; assign fv_in_fire = p_in_ready; assign fv_hold = p_hold;
`endif
endmodule
