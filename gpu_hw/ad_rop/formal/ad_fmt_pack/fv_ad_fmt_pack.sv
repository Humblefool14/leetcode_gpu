// fv_ad_fmt_pack -- path-2 packing (with ad_fmt_info for ps):
//   keep = 1 and raw = 0 for every bx beyond ps; formats outside path 2 keep everything;
//   write mask 0 keeps everything; the R32 formats' raw bits are the source bits;
//   a full write mask writes every bx of the pixel (keep = 0 below 8 ps);
//   a channel bx is kept exactly when its channel's write-mask bx is 0 (8/16/32-bx formats).
module fv_ad_fmt_pack (input wire clk);
    (* anyconst *) reg [7:0]   fmt;
    (* anyconst *) reg [127:0] src;
    (* anyconst *) reg [3:0]   wm;
    (* anyconst *) reg [6:0]   bx;
    wire [127:0] raw, keep;
    wire sup, bl; wire [4:0] ps; wire [2:0] lps; wire [1:0] path; wire [3:0] chm;
    ad_fmt_info u_i (.i_fmt(fmt), .o_sup(sup), .o_ps(ps), .o_lps(lps), .o_path(path), .o_chm(chm), .o_blendable(bl));
    ad_fmt_pack dut (.i_src(src), .i_fmt(fmt), .i_wm(wm), .o_raw(raw), .o_keep(keep));
    wire [7:0]  nbits = {ps, 3'b000};
    wire        beyond = ({1'b0, bx} >= nbits);
    wire r32  = (fmt == 98)  || (fmt == 99)  || (fmt == 100);
    wire rg32 = (fmt == 101) || (fmt == 102) || (fmt == 103);
    wire rgba32 = (fmt == 107) || (fmt == 108) || (fmt == 109);
    // channel width of the generic formats
    wire [5:0] cw = (path != 2'd2 || fmt == 68) ? 6'd0 :
                    (fmt == 13 || fmt == 14 || fmt == 20 || fmt == 21 || fmt == 41 || fmt == 42 || fmt == 55 || fmt == 56) ? 6'd8 :
                    (fmt == 74 || fmt == 75 || fmt == 81 || fmt == 82 || fmt == 95 || fmt == 96) ? 6'd16 : 6'd32;
    wire [1:0] ch = (cw == 8) ? bx[4:3] : (cw == 16) ? bx[5:4] : bx[6:5];
    always @(*) begin
        if (path == 2'd2 && beyond) begin
            a_keep_beyond: assert (keep[bx]);
            a_raw_beyond:  assert (!raw[bx]);
        end
        if (path != 2'd2) begin
            a_np_keep: assert (keep == {128{1'b1}});
            a_np_raw:  assert (raw == 128'd0);
        end
        if (wm == 4'd0) a_wm0: assert (keep == {128{1'b1}});
        if (r32)    a_r32:    assert (raw == {96'd0, src[31:0]});
        if (rg32)   a_rg32:   assert (raw == {64'd0, src[63:0]});
        if (rgba32) a_rgba32: assert (raw == src);
        if (path == 2'd2 && wm == 4'hF && !beyond) a_full: assert (!keep[bx]);
        if (cw != 0 && !beyond) begin
            a_chan: assert (keep[bx] == !wm[ch]);
            a_src:  assert (raw[bx] == src[{ch, 5'd0} | ({2'd0, bx[4:0]} & ({1'b0, cw} - 7'd1))]);
        end
    end
endmodule
