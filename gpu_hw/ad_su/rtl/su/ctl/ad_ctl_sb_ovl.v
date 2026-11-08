// ad_ctl_sb_ovl -- the scoreboard's operand-range overlap check (ad_su_sb).
// Sources: up to five operand numbers (7 bits, with a use bit each; the
// parent passes rs1, rs2, rs3, rs1+1 for PAIR and rs3+1 for a texture .3
// form with Dref, the last two as 8-bit sums so 127+1 does not wrap).  A
// source is a GPR when it is below 63 (63 is rq, 64-127 constants and
// specials).  dst: the instruction's destination range [dst, dst+4) or
// [dst, dst+1) (dst_use only for rd < 63).  Entries: valid, base (rd of a
// long writer, < 63) and width (1, or 4 when w4).  src_hit: some GPR source
// lies in some valid entry's range; dst_hit: the destination range overlaps
// some valid entry's range.  Combinational.
module ad_ctl_sb_ovl #(
    parameter NE = 4
) (
    input  wire [4:0]    src_use,
    input  wire [39:0]   src,          // 5 x 8 bits
    input  wire          dst_use,
    input  wire [5:0]    dst,
    input  wire          dst_w4,
    input  wire [NE-1:0] e_valid,
    input  wire [NE*6-1:0] e_base,
    input  wire [NE-1:0] e_w4,
    output reg           src_hit,
    output reg           dst_hit
);
    integer e, s;
    reg [7:0] lo, hi, n, dlo, dhi;     // ranges [lo, hi)
    always @(*) begin
        src_hit = 1'b0;
        dst_hit = 1'b0;
        n = 8'd0;
        dlo = {2'b00, dst};
        dhi = dlo + (dst_w4 ? 8'd4 : 8'd1);
        for (e = 0; e < NE; e = e + 1) begin
            lo = {2'b00, e_base[6*e +: 6]};
            hi = lo + (e_w4[e] ? 8'd4 : 8'd1);
            if (e_valid[e]) begin
                for (s = 0; s < 5; s = s + 1) begin
                    n = src[8*s +: 8];
                    if (src_use[s] && n < 8'd63 && n >= lo && n < hi) src_hit = 1'b1;
                end
                if (dst_use && dlo < hi && lo < dhi) dst_hit = 1'b1;
            end
        end
    end
endmodule
