// fv_ad_vf_asm_pout -- the held-back primitive output (spec section 4: "the last primitive out is
// held back (prim_valid low) until the next one exists or the draw ends"; prim_last).
// Parent (ad_vf_asm) assumptions: an input is held with its payload until taken; fin (the draw
// ended) never with an input and stays up until the held primitive is out.
// Checked: every input comes out once, in order, with PT entries ptbase + lane, its free bits and
// kind; prim_valid only when a primitive is held and the next one exists or fin; prim_last only
// with fin and no further input; prim_* held until prim_ready; in_ready whenever nothing is held.
module fv_ad_vf_asm_pout (
    input wire       clk,
    input wire       rst_n,
    input wire       in_valid,
    input wire [4:0] in_l0, in_l1, in_l2,
    input wire [2:0] in_free,
    input wire [1:0] in_kind,
    input wire [7:0] ptbase,
    input wire       fin,
    input wire       prim_ready
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);
    wire in_ready, hold_v, prim_valid, prim_last; wire [25:0] prim_vtx; wire [2:0] prim_free;
    ad_vf_asm_pout dut (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_ready(in_ready), .in_l0(in_l0),
        .in_l1(in_l1), .in_l2(in_l2), .in_free(in_free), .in_kind(in_kind), .ptbase(ptbase), .fin(fin),
        .hold_v(hold_v), .prim_valid(prim_valid), .prim_ready(prim_ready), .prim_vtx(prim_vtx),
        .prim_free(prim_free), .prim_last(prim_last));

    // parent behaviour
    reg p_iv = 1'b0, p_ir = 1'b0, p_fin = 1'b0, p_hold = 1'b0; reg [4:0] p0, p1, p2; reg [2:0] pf; reg [1:0] pk; reg [7:0] pb;
    always @(posedge clk) begin
        p_iv <= in_valid && rst_n; p_ir <= in_ready; p_fin <= fin && rst_n; p_hold <= hold_v;
        p0 <= in_l0; p1 <= in_l1; p2 <= in_l2; pf <= in_free; pk <= in_kind; pb <= ptbase;
    end
    always @(*) if (!init && rst_n) begin
        assume (!(fin && in_valid));
        if (p_iv && !p_ir) assume (in_valid && in_l0 == p0 && in_l1 == p1 && in_l2 == p2 && in_free == pf &&
                                   in_kind == pk && ptbase == pb);
        if (p_fin && p_hold) assume (fin);
    end

    // reference: the expected encoding of the last accepted input; counts
    reg [25:0] e_vtx; reg [2:0] e_free; reg [1:0] n_in, n_out;
    wire [25:0] in_enc = {in_kind, ptbase + {3'd0, in_l2}, ptbase + {3'd0, in_l1}, ptbase + {3'd0, in_l0}};
    always @(posedge clk) begin
        if (!rst_n) begin n_in <= 2'd0; n_out <= 2'd0; end
        else begin
            if (in_valid && in_ready) begin n_in <= n_in + 2'd1; e_vtx <= in_enc; e_free <= in_free; end
            if (prim_valid && prim_ready) n_out <= n_out + 2'd1;
        end
    end
    reg q_v = 1'b0, q_r; reg [25:0] q_vtx; reg [2:0] q_free; reg q_last;
    always @(posedge clk) begin q_v <= prim_valid && rst_n; q_r <= prim_ready; q_vtx <= prim_vtx; q_free <= prim_free; q_last <= prim_last; end
    always @(*) if (!init && rst_n) begin
        a_cnt:   assert (n_in - n_out == {1'b0, hold_v});
        if (hold_v) begin a_vtx: assert (prim_vtx == e_vtx); a_free: assert (prim_free == e_free); end
        a_valid: assert (prim_valid == (hold_v && (in_valid || fin)));
        a_last:  assert (prim_last == (prim_valid && fin));
        if (in_valid && !hold_v) a_take: assert (in_ready);
        if (in_ready) a_rdy: assert (in_valid);
        if (q_v && !q_r) a_hold: assert (prim_valid && prim_vtx == q_vtx && prim_free == q_free && prim_last == q_last);
    end
endmodule
