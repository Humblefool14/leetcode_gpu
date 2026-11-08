// ad_ms_zclamp: clamp01 lands in [0, 1] for every input (NaN, infinities,
// denormals, -0) and is the identity on [+0, 1]; the [lo, hi] clamp (lo <= hi,
// both ordered) lands in [lo, hi] for every input, NaN included, and is the
// identity inside; both stages together land in [lo, hi].
module fv_ad_ms_zclamp;
    (* anyconst *) reg [31:0] x;
    (* anyconst *) reg [31:0] lo;
    (* anyconst *) reg [31:0] hi;
    localparam [31:0] ONE = 32'h3F80_0000;
    wire [31:0] y01, ymm, yb;
    ad_ms_zclamp u01 (.x(x), .en01(1'b1), .enmm(1'b0), .lo(lo), .hi(hi), .y(y01));
    ad_ms_zclamp umm (.x(x), .en01(1'b0), .enmm(1'b1), .lo(lo), .hi(hi), .y(ymm));
    ad_ms_zclamp ub  (.x(x), .en01(1'b1), .enmm(1'b1), .lo(lo), .hi(hi), .y(yb));
    wire [31:0] yn;
    ad_ms_zclamp un0 (.x(x), .en01(1'b0), .enmm(1'b0), .lo(lo), .hi(hi), .y(yn));

    wire c1_lt, c1_eq, c1_un, c2_lt, c2_eq, c2_un;     // y01 vs 1, x vs 1
    ad_fp_cmp k1 (.a(ONE), .b(y01), .lt(c1_lt), .eq(c1_eq), .un(c1_un));
    ad_fp_cmp k2 (.a(ONE), .b(x),   .lt(c2_lt), .eq(c2_eq), .un(c2_un));
    wire lh_lt, lh_eq, lh_un;
    ad_fp_cmp k3 (.a(hi), .b(lo), .lt(lh_lt), .eq(lh_eq), .un(lh_un));
    wire m1_lt, m1_eq, m1_un, m2_lt, m2_eq, m2_un;     // ymm < lo, hi < ymm
    ad_fp_cmp k4 (.a(ymm), .b(lo), .lt(m1_lt), .eq(m1_eq), .un(m1_un));
    ad_fp_cmp k5 (.a(hi), .b(ymm), .lt(m2_lt), .eq(m2_eq), .un(m2_un));
    wire b1_lt, b1_eq, b1_un, b2_lt, b2_eq, b2_un;
    ad_fp_cmp k6 (.a(yb), .b(lo), .lt(b1_lt), .eq(b1_eq), .un(b1_un));
    ad_fp_cmp k7 (.a(hi), .b(yb), .lt(b2_lt), .eq(b2_eq), .un(b2_un));
    wire x1_lt, x1_eq, x1_un, x2_lt, x2_eq, x2_un;     // x < lo, hi < x
    ad_fp_cmp k8 (.a(x), .b(lo), .lt(x1_lt), .eq(x1_eq), .un(x1_un));
    ad_fp_cmp k9 (.a(hi), .b(x), .lt(x2_lt), .eq(x2_eq), .un(x2_un));
    wire xnan = (x[30:23] == 8'hFF) && (x[22:0] != 0);

    always @(*) begin
        // clamp01
        a01_rng:  assert (!y01[31] && !c1_lt && !c1_un);          // +0 <= y <= 1, ordered
        if (!x[31] && !xnan && !c2_lt) a01_id: assert (y01 == x);
        if (x[31] || xnan) a01_neg: assert (y01 == 32'd0);
        if (c2_lt) a01_one: assert (y01 == ONE);
        a_off:    assert (yn == x);
        // [lo, hi], given lo <= hi ordered
        if (!lh_lt && !lh_un) begin
            amm_rng: assert (!m1_lt && !m2_lt && !m1_un);
            if (!xnan && !x1_lt && !x2_lt) amm_id: assert (ymm == x);
            if (xnan) amm_nan: assert (ymm == lo);
            ab_rng:  assert (!b1_lt && !b2_lt && !b1_un);
        end
    end
endmodule
