// ad_fp_add -- fp32 add/subtract, round to nearest even, denormals flushed
// (inputs and results; the sign of a flushed result is kept).
// NaN results are the canonical quiet NaN 0x7FC00000.  x + (-x) = +0.
// sub = 1 computes a - b.  Combinational.
module ad_fp_add (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        sub,
    output wire [31:0] y
);
    // ---- unpack (flush denormal inputs to zero) ----
    wire        sa = a[31];
    wire        sb = b[31] ^ sub;
    wire [7:0]  ea = a[30:23];
    wire [7:0]  eb = b[30:23];
    wire        za = (ea == 8'd0);
    wire        zb = (eb == 8'd0);
    wire        ia = (ea == 8'hFF) && (a[22:0] == 0);
    wire        ib = (eb == 8'hFF) && (b[22:0] == 0);
    wire        na = (ea == 8'hFF) && (a[22:0] != 0);
    wire        nb = (eb == 8'hFF) && (b[22:0] != 0);
    wire [23:0] ma = za ? 24'd0 : {1'b1, a[22:0]};
    wire [23:0] mb = zb ? 24'd0 : {1'b1, b[22:0]};

    // ---- order by magnitude: X is the larger ----
    wire        swap = {eb, mb} > {ea, ma};
    wire        sx = swap ? sb : sa;
    wire        sy = swap ? sa : sb;
    wire [7:0]  ex = swap ? eb : ea;
    wire [7:0]  ey = swap ? ea : eb;
    wire [23:0] mx = swap ? mb : ma;
    wire [23:0] my = swap ? ma : mb;

    // ---- align: 27 bits = mantissa, guard, round, sticky ----
    wire [7:0]  d  = ex - ey;
    wire [49:0] yw = {my, 26'd0} >> ((d > 8'd26) ? 8'd26 : d);  // keep shifted-out bits
    wire        dbig = (d > 8'd26);
    wire [26:0] yal = dbig ? {26'd0, (my != 0)}
                           : {yw[49:24], (|yw[23:0])};
    wire [26:0] xal = {mx, 3'b000};
    wire        eff_sub = sx ^ sy;

    // ---- add or subtract ----
    wire [27:0] sum  = {1'b0, xal} + {1'b0, yal};
    wire [27:0] dif  = {1'b0, xal} - {1'b0, yal};
    wire [27:0] r0   = eff_sub ? dif : sum;

    // ---- normalise ----
    // carry out (add): shift right 1, keep sticky
    wire        cout = r0[27];
    wire [26:0] rc   = cout ? {r0[27:2], r0[1] | r0[0]} : r0[26:0];
    // leading zeros of rc (subtract can cancel)
    reg  [4:0]  lz;
    integer     i;
    always @(*) begin
        lz = 5'd27;
        for (i = 0; i <= 26; i = i + 1)
            if (rc[i]) lz = 5'd26 - i[4:0];
    end
    wire        rzero = (rc == 27'd0);
    wire [26:0] rn    = rc << lz;
    wire signed [10:0] en = $signed({3'b000, ex}) + (cout ? 11'sd1 : 11'sd0) - $signed({6'd0, lz});

    // ---- round to nearest even ----
    wire        lsb = rn[3];
    wire        g   = rn[2];
    wire        rs  = rn[1] | rn[0];
    wire        up  = g & (rs | lsb);
    wire [24:0] mr  = {1'b0, rn[26:3]} + {24'd0, up};
    wire        mo  = mr[24];                     // rounding carried to 2.0
    wire signed [10:0] ef = en + (mo ? 11'sd1 : 11'sd0);
    wire [22:0] frac = mo ? mr[23:1] : mr[22:0];

    // ---- specials ----
    wire        res_nan = na | nb | (ia & ib & (sa != sb));
    wire        res_inf = ia | ib;
    wire        res_inf_s = ia ? sa : sb;
    wire        ovf  = (ef >= 11'sd255);
    wire        unf  = (ef <= 11'sd0);

    assign y = res_nan            ? 32'h7FC0_0000 :
               res_inf            ? {res_inf_s, 8'hFF, 23'd0} :
               (za & zb)          ? {sa & sb, 31'd0} :          // -0 + -0 = -0, else +0
               rzero              ? 32'd0 :                     // exact cancellation -> +0
               ovf                ? {sx, 8'hFF, 23'd0} :
               unf                ? {sx, 31'd0} :
                                    {sx, ef[7:0], frac};
endmodule
