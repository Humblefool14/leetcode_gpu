// ad_ms_a2c: the table is exact for the five bands (reference by unsigned
// compares of the bits, valid for non-negative non-NaN values), the 0.5 rule,
// monotonic in alpha (a <= b by fp order gives mask(a) a subset of mask(b)) and
// the masks nested.
module fv_ad_ms_a2c;
    (* anyconst *) reg [31:0] a;
    (* anyconst *) reg [31:0] b;
    wire [3:0] ma, mb; wire ha, hb;
    ad_ms_a2c u_a (.alpha(a), .mask(ma), .half(ha));
    ad_ms_a2c u_b (.alpha(b), .mask(mb), .half(hb));
    wire lt_ab, eq_ab, un_ab;
    ad_fp_cmp u_c (.a(a), .b(b), .lt(lt_ab), .eq(eq_ab), .un(un_ab));

    wire a_nan = (a[30:23] == 8'hFF) && (a[22:0] != 0);
    wire a_pos = !a[31] && !a_nan;                 // +0 .. +inf
    wire [2:0] n = !a_pos ? 3'd0 :
                   (a >= 32'h3F60_0000) ? 3'd4 :
                   (a >= 32'h3F20_0000) ? 3'd3 :
                   (a >= 32'h3EC0_0000) ? 3'd2 :
                   (a >= 32'h3E00_0000) ? 3'd1 : 3'd0;
    reg [3:0] tbl;
    always @(*) case (n)
        3'd0: tbl = 4'b0000;
        3'd1: tbl = 4'b0001;
        3'd2: tbl = 4'b1001;
        3'd3: tbl = 4'b1011;
        default: tbl = 4'b1111;
    endcase
    always @(*) begin
        a_table: assert (ma == tbl);
        a_half:  assert (ha == (a_pos && a >= 32'h3F00_0000));
        if (lt_ab || eq_ab) begin
            a_mono:  assert ((ma & ~mb) == 4'd0);
            a_monoh: assert (!ha || hb);
        end
        a_nest: assert ((ma & ~mb) == 4'd0 || (mb & ~ma) == 4'd0);
    end
endmodule
