// ad_fblend_combine: en = 0 -> s; ADD (0, 5-7) == ad_fp_add(P, Q); SUBTRACT == P - Q;
// REVERSE_SUBTRACT == Q - P; MIN/MAX == ad_fblend_minmax(s, d) whatever P, Q are,
// and the MIN result is never above the MAX result (cmp order) for non-NaN s, d.
module fv_ad_fblend_combine;
    (* anyconst *) reg [31:0] s;
    (* anyconst *) reg [31:0] d;
    (* anyconst *) reg [31:0] p;
    (* anyconst *) reg [31:0] q;
    (* anyconst *) reg [2:0]  op;
    (* anyconst *) reg        en;
    wire [31:0] y, ymin, ymax, radd, rsub, rrev, rmin, rmax;
    ad_fblend_combine u   (.en(en),   .op(op),   .s(s), .d(d), .p(p), .q(q), .y(y));
    ad_fblend_combine u_n (.en(1'b1), .op(3'd3), .s(s), .d(d), .p(p), .q(q), .y(ymin));
    ad_fblend_combine u_x (.en(1'b1), .op(3'd4), .s(s), .d(d), .p(p), .q(q), .y(ymax));
    ad_fp_add r_add (.a(p), .b(q), .sub(1'b0), .y(radd));
    ad_fp_add r_sub (.a(p), .b(q), .sub(1'b1), .y(rsub));
    ad_fp_add r_rev (.a(q), .b(p), .sub(1'b1), .y(rrev));
    ad_fblend_minmax r_mn (.a(s), .b(d), .is_max(1'b0), .y(rmin));
    ad_fblend_minmax r_mx (.a(s), .b(d), .is_max(1'b1), .y(rmax));
    wire lt, eq, un;
    ad_fp_cmp c (.a(ymin), .b(ymax), .lt(lt), .eq(eq), .un(un));
    wire ns = (s[30:23] == 8'hFF) && (s[22:0] != 0);
    wire nd = (d[30:23] == 8'hFF) && (d[22:0] != 0);
    always @(*) begin
        if (!en) a_off: assert (y == s);
        if (en && (op == 3'd0 || op >= 3'd5)) a_add: assert (y == radd);
        if (en && op == 3'd1) a_sub: assert (y == rsub);
        if (en && op == 3'd2) a_rev: assert (y == rrev);
        if (en && op == 3'd3) a_min: assert (y == rmin);
        if (en && op == 3'd4) a_max: assert (y == rmax);
        if (!ns && !nd) a_order: assert (lt || eq);
        if (!ns && !nd) a_set: assert ((ymin == s && ymax == d) || (ymin == d && ymax == s));
    end
endmodule
