// fv_ad_vf_fetch_lbuf -- one stream's line buffer.
// Environment (ad_vf_fetch's contract): a line is allocated only when it misses (no valid entry
// holds it) and no entry is pending; a_en1 only with two, and two means l0 != l1.
// Properties:
//   lookup: h0 iff some valid entry holds l0, and then entry he0 is valid with tag l0 (same for l1);
//   allocation: the two allocated entries differ; an allocated entry is never the entry the
//     other line of the attribute hits;
//   no two entries that are valid or pending hold the same line; valid and pend exclusive;
//   data: for a symbolic entry E and byte B, a valid E reads (rd0 / rd1) the byte of its last
//     fill (0 after rsp_error); fills of non-pending entries are ignored; clr empties everything.
module fv_ad_vf_fetch_lbuf #(parameter LW = 27, parameter LBY = 32) (
    input wire           clk,
    input wire           rst_n,
    input wire           clr,
    input wire [LW-1:0]  l0,
    input wire [LW-1:0]  l1,
    input wire           two,
    input wire           a_en0,
    input wire           a_en1,
    input wire           w_en,
    input wire [2:0]     w_ent,
    input wire [LBY*8-1:0] w_data,
    input wire           w_err,
    input wire [2:0]     r_e0,
    input wire [2:0]     r_e1
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);
    wire h0, h1, rv0, rv1; wire [2:0] he0, he1, ae0, ae1; wire [LBY*8-1:0] rd0, rd1;
    wire [7:0] vld, pnd; wire [8*LW-1:0] tags; wire [8*LBY*8-1:0] fvd;
    ad_vf_fetch_lbuf #(.LW(LW), .LINE_BYTES(LBY)) dut (.clk(clk), .rst_n(rst_n), .clr(clr),
        .l0(l0), .l1(l1), .two(two), .h0(h0), .he0(he0), .h1(h1), .he1(he1),
        .a_en0(a_en0), .a_en1(a_en1), .ae0(ae0), .ae1(ae1),
        .w_en(w_en), .w_ent(w_ent), .w_data(w_data), .w_err(w_err),
        .r_e0(r_e0), .r_e1(r_e1), .rd0(rd0), .rd1(rd1), .rv0(rv0), .rv1(rv1),
        .o_valid(vld), .o_pend(pnd), .o_tags(tags), .fv_data(fvd));

    // environment
    always @(*) begin
        if (two) assume (l0 != l1);
        if (a_en0) assume (!h0 && pnd == 8'd0);
        if (a_en1) assume (two && !h1 && pnd == 8'd0);
    end

    (* anyconst *) reg [2:0] E;
    (* anyconst *) reg [$clog2(LBY)-1:0] B;
    // reference lookup
    integer x, y;
    reg r_h0, r_h1, dup;
    reg [LW-1:0] t_he0, t_he1;
    reg [7:0] b_rd0, b_rd1, b_wd, b_e;
    always @(*) begin
        r_h0 = 0; r_h1 = 0; dup = 0; t_he0 = 0; t_he1 = 0; b_rd0 = 0; b_rd1 = 0; b_wd = 0; b_e = 0;
        for (x = 0; x < LBY; x = x + 1) if (B == x) begin
            b_rd0 = rd0[8*x +: 8]; b_rd1 = rd1[8*x +: 8]; b_wd = w_data[8*x +: 8];
            for (y = 0; y < 8; y = y + 1) if (E == y) b_e = fvd[y*LBY*8 + 8*x +: 8];
        end
        for (x = 0; x < 8; x = x + 1) begin
            if (he0 == x) t_he0 = tags[x*LW +: LW];
            if (he1 == x) t_he1 = tags[x*LW +: LW];
            if (vld[x] && tags[x*LW +: LW] == l0) r_h0 = 1;
            if (vld[x] && tags[x*LW +: LW] == l1) r_h1 = 1;
            for (y = x + 1; y < 8; y = y + 1)
                if ((vld[x] || pnd[x]) && (vld[y] || pnd[y]) && tags[x*LW +: LW] == tags[y*LW +: LW]) dup = 1;
        end
    end

    // data shadow for entry E, byte B
    reg [7:0] sb;
    always @(posedge clk)
        if (rst_n && !clr && w_en && pnd[w_ent] && w_ent == E) sb <= w_err ? 8'd0 : b_wd;

    always @(*) if (!init && rst_n) begin
        a_h0:   assert (h0 == r_h0);
        a_h1:   assert (h1 == r_h1);
        if (h0) a_he0: assert (vld[he0] && t_he0 == l0);
        if (h1) a_he1: assert (vld[he1] && t_he1 == l1);
        if (a_en0 && a_en1) a_ae: assert (ae0 != ae1);
        if (a_en1 && h0)  a_ae1: assert (ae1 != he0);
        if (a_en0 && two && h1) a_ae0: assert (ae0 != he1);
        a_dup:  assert (!dup);
        a_vp:   assert ((vld & pnd) == 8'd0);
        a_rv:   assert (rv0 == vld[r_e0] && rv1 == vld[r_e1]);
        if (vld[E] && r_e0 == E) a_d0: assert (b_rd0 == sb);
        if (vld[E] && r_e1 == E) a_d1: assert (b_rd1 == sb);
        h_de:  assert (!vld[E] || b_e == sb);        // helper (AD_FV_LBUF observation)
        c_two: cover (a_en0 && a_en1);
    end
    // clr empties, fills set valid only for pending entries
    reg p_clr, p_wen, p_pnd; reg [2:0] p_went;
    always @(posedge clk) begin p_clr <= clr && rst_n; p_wen <= w_en && rst_n && !clr; p_went <= w_ent; p_pnd <= pnd[w_ent]; end
    always @(*) if (!init && rst_n) begin
        if (p_clr) a_clr: assert (vld == 8'd0 && pnd == 8'd0);
        if (p_wen && p_pnd) a_fill: assert (vld[p_went]);
    end
endmodule
