// fv_ad_vf_asm -- ad_vf_asm handshake and ordering properties (spec sections 4, 5).
// Environment: STATE written only while idle (the CP holds VF writes while busy); iv obeys
// valid/ready (held with its payload until taken) and no item follows iv_last within a draw;
// vl_gnt only while vl_req; conv_done, vb_ready, prim_ready, vl_ptbase free.
// Checked:
//   vb: only inside a granted warp, lanes 0, 1, 2, ... in order, at most 32, held until vb_ready,
//       vb_last ends the warp;
//   vl_go: once per warp, only after vb_last and a conv_done since; vl_mask only lanes sent;
//   prim: prim_valid only in PRIMS; every PT entry within ptbase .. ptbase + 31 (and below the
//       lanes sent) of the warp the primitive was formed in (granted with that ptbase); prim held
//       until prim_ready; prim_last once, only after iv_last was taken, nothing after it;
//   iv_ready only with iv_valid; busy: low => nothing pending (no vb, vl_req, vl_go, prim, held
//       primitive); busy rises only on an iv item.
// Tasks: bmc (AD_FV_ASM_LANES = 3: warps of 3 lanes, so that warp boundaries, carried vertices,
// the list fit rule and the held-back primitive across warps are reached), bmc32 (32 lanes),
// prove (3 lanes).  prove32_open (32 lanes) does not close within 10 minutes (abc pdr reached frame 28):
// PDR has to relate the lane counter, the held vertex, vl_mask and the primitive buffer over 32
// lanes; the logic is the same for any LANES and the 3-lane proof closes.
module fv_ad_vf_asm (
    input wire        clk,
    input wire        rst_n,
    input wire        st_we,
    input wire [8:0]  st_idx,
    input wire [31:0] st_wdata,
    input wire        iv_valid,
    input wire [31:0] iv_index,
    input wire [31:0] iv_inst,
    input wire        iv_restart,
    input wire        iv_last,
    input wire        vb_ready,
    input wire        conv_done,
    input wire        vl_gnt,
    input wire [7:0]  vl_ptbase,
    input wire        prim_ready
);
`ifdef AD_FV_ASM_LANES
    localparam [5:0] NL = `AD_FV_ASM_LANES;
`else
    localparam [5:0] NL = 6'd32;
`endif
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);

    wire iv_ready, vb_valid, vb_last, vl_req, vl_go, prim_valid, prim_last, busy;
    wire [31:0] vb_index, vb_inst, vl_mask; wire [2:0] f_st; wire f_in_fire, f_hold; wire [4:0] vb_lane; wire [25:0] prim_vtx; wire [2:0] prim_free;
    ad_vf_asm dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .iv_valid(iv_valid), .iv_ready(iv_ready), .iv_index(iv_index), .iv_inst(iv_inst), .iv_restart(iv_restart),
        .iv_last(iv_last), .vb_valid(vb_valid), .vb_ready(vb_ready), .vb_index(vb_index), .vb_inst(vb_inst),
        .vb_lane(vb_lane), .vb_last(vb_last), .conv_done(conv_done), .vl_req(vl_req), .vl_gnt(vl_gnt),
        .vl_ptbase(vl_ptbase), .vl_go(vl_go), .vl_mask(vl_mask), .prim_valid(prim_valid), .prim_ready(prim_ready),
        .prim_vtx(prim_vtx), .prim_free(prim_free), .prim_last(prim_last), .busy(busy),
        .fv_st(f_st), .fv_in_fire(f_in_fire), .fv_hold(f_hold));

    // ---------------- environment ----------------
    reg p_iv = 1'b0, p_ir = 1'b0, p_rs, p_la; reg [31:0] p_ix, p_in;
    reg last_taken = 1'b0;          // iv_last taken in this draw
    always @(posedge clk) begin
        p_iv <= iv_valid && rst_n; p_ir <= iv_ready; p_ix <= iv_index; p_in <= iv_inst; p_rs <= iv_restart; p_la <= iv_last;
        if (!rst_n) last_taken <= 1'b0;
        else if (iv_valid && iv_ready && iv_last) last_taken <= 1'b1;
        else if (!busy) last_taken <= 1'b0;
    end
    always @(*) if (!init && rst_n) begin
        if (st_we) assume (!busy);
        if (p_iv && !p_ir) assume (iv_valid && iv_index == p_ix && iv_inst == p_in && iv_restart == p_rs && iv_last == p_la);
        if (last_taken) assume (!iv_valid);
        if (vl_gnt) assume (vl_req);
    end

    // ---------------- observers ----------------
    reg       w_open = 1'b0, w_closed = 1'b0, cd_seen = 1'b0, last_out = 1'b0;
    reg [5:0] h_lane = 6'd0;
    reg [7:0] g_pt = 8'd0;          // PT base of the current warp
    reg [7:0] hb = 8'd0;            // PT base of the warp of the held primitive
    reg [5:0] hn = 6'd0, g_n = 6'd0;// lanes sent in those warps
    reg p_vb = 1'b0, p_vr; reg [31:0] p_vi, p_vn; reg [4:0] p_vl; reg p_vla;
    reg p_pv = 1'b0, p_pr; reg [25:0] p_pt; reg [2:0] p_pf; reg p_pl; reg p_busy = 1'b0;
    always @(posedge clk) begin
        p_vb <= vb_valid && rst_n; p_vr <= vb_ready; p_vi <= vb_index; p_vn <= vb_inst; p_vl <= vb_lane; p_vla <= vb_last;
        p_pv <= prim_valid && rst_n; p_pr <= prim_ready; p_pt <= prim_vtx; p_pf <= prim_free; p_pl <= prim_last;
        p_busy <= busy && rst_n;
        if (!rst_n) begin
            w_open <= 1'b0; w_closed <= 1'b0; cd_seen <= 1'b0; h_lane <= 6'd0; last_out <= 1'b0;
        end else begin
            if (vl_gnt) begin w_open <= 1'b1; h_lane <= 6'd0; g_pt <= vl_ptbase; end
            if (vb_valid && vb_ready) begin
                h_lane <= h_lane + 6'd1;
                if (vb_last) begin w_open <= 1'b0; w_closed <= 1'b1; cd_seen <= 1'b0; g_n <= h_lane + 6'd1; end
            end
            if (w_closed && conv_done) cd_seen <= 1'b1;
            if (vl_go) begin w_closed <= 1'b0; cd_seen <= 1'b0; end
            if (f_in_fire) begin hb <= g_pt; hn <= g_n; end
            if (prim_valid && prim_ready && prim_last) last_out <= 1'b1;
            if (!busy) last_out <= 1'b0;
        end
    end
    wire [7:0] d0 = prim_vtx[7:0] - hb, d1 = prim_vtx[15:8] - hb, d2 = prim_vtx[23:16] - hb;

    always @(*) if (!init && rst_n) begin
        // vb
        if (vb_valid) begin
            a_vb_open: assert (w_open);
            a_vb_lane: assert ({1'b0, vb_lane} == h_lane && h_lane < NL);
            if (h_lane == NL - 6'd1) a_vb_full: assert (vb_last);
        end
        if (p_vb && !p_vr) a_vb_hold: assert (vb_valid && vb_index == p_vi && vb_inst == p_vn && vb_lane == p_vl && vb_last == p_vla);
        if (vl_req) a_req: assert (!w_open && !w_closed);
        // vl_go
        if (vl_go) begin
            a_go: assert (w_closed && cd_seen);
            a_mask: assert ((vl_mask >> g_n) == 32'd0);
        end
        // primitives
        if (prim_valid) begin
            a_pst: assert (f_st == 3'd7);
            a_pent: assert (d0 < {2'b0, hn} && d1 < {2'b0, hn} && d2 < {2'b0, hn} && hn <= NL);
            a_pkind: assert (prim_vtx[25:24] != 2'd3);
            a_pdone: assert (!last_out);
        end
        if (prim_last) a_plast: assert (last_taken);
        if (p_pv && !p_pr) a_phold: assert (prim_valid && prim_vtx == p_pt && prim_free == p_pf);
        if (iv_ready) a_ivr: assert (iv_valid);
        // busy
        if (!busy) a_idle: assert (!vb_valid && !vl_req && !vl_go && !prim_valid && !f_hold && !w_open && !w_closed);
        if (busy && !p_busy) a_rise: assert (p_iv);
    end
endmodule
