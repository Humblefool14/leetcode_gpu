// ad_rop_dtest -- per-entry depth bounds -> stencil -> depth test (spec ad_rop_dtest.md).
// Combinational.  The format is the single set bit of depth[7:5] ({D16, D32F, D24S8});
// none or several: no attachment, pass = cov, wbe = 0.
//   bounds (depth[9]): z_a outside [bmin, bmax] -> pass = 0, wbe = 0.
//   stencil (depth[8] and D24S8): face by `front`; written stencil in byte 3, enabled
//            when it differs from s_a = stored[31:24].
//   depth (depth[0]): compare op depth[4:2]; result 1 when off.  Depth bytes written
//            (D16 0-1, D24 0-2, D32F 0-3) when depth[1], the stencil passed and the
//            depth passed (spec §4.3 literally: also without depth[0]).
// MUT_STENCIL_FACE: front and back state swapped (deliberate error for the TB).
module ad_rop_dtest (
    input  wire [9:0]  depth,
    input  wire [26:0] sfront,
    input  wire [26:0] sback,
    input  wire [24:0] sops,
    input  wire [31:0] bmin,
    input  wire [31:0] bmax,
    input  wire        cov,
    input  wire        front,
    input  wire [31:0] zf,
    input  wire [31:0] stored,
    output wire        pass,
    output wire [31:0] wword,
    output wire [3:0]  wbe
);
    wire [2:0] fmt   = depth[7:5];
    wire       d24   = (fmt == 3'b001);
    wire       d32f  = (fmt == 3'b010);
    wire       d16   = (fmt == 3'b100);
    wire       hasfmt = d24 | d32f | d16;

    // ---- depth bounds
    wire [31:0] z_a;
    wire        outside;
    ad_dtest_bounds u_bounds (.fmt(fmt), .stored(stored), .bmin(bmin), .bmax(bmax),
                              .z_a(z_a), .outside(outside));
    wire bfail = depth[9] && outside;

    // ---- depth compare
    wire        dcmp;
    wire [31:0] zword;
    ad_dtest_depth u_depth (.fmt(fmt), .op(depth[4:2]), .zf(zf), .stored(stored),
                            .dpass(dcmp), .zword(zword));
    wire dres = depth[0] ? dcmp : 1'b1;

    // ---- stencil
`ifdef MUT_STENCIL_FACE
    wire [26:0] sst = front ? sback : sfront;
    wire        bk  = front;
`else
    wire [26:0] sst = front ? sfront : sback;
    wire        bk  = !front;
`endif
    wire [8:0]  fops = bk ? sops[24:16] : sops[8:0];
    wire        sten = depth[8] && d24;
    wire        st_pass, st_diff;
    wire [7:0]  st_wr;
    ad_dtest_stencil u_sten (.s_a(stored[31:24]), .sref(sst[7:0]), .cmask(sst[15:8]),
                             .wmask(sst[23:16]), .cop(sst[26:24]),
                             .fail_op(fops[2:0]), .pass_op(fops[5:3]), .zfail_op(fops[8:6]),
                             .dres(dres), .spass(st_pass), .swr(st_wr), .sdiff(st_diff));
    wire spass = sten ? st_pass : 1'b1;

    // ---- result
    wire live = cov && hasfmt && !bfail;          // entry reaches the stencil test
    wire dw   = live && depth[1] && spass && dres; // depth written
    wire sw   = live && sten && st_diff;           // stencil byte written
    assign pass  = cov && (!hasfmt || (!bfail && spass && dres));
    assign wword = d24 ? {st_wr, zword[23:0]} : zword;
    assign wbe   = d32f ? {4{dw}} :
                   d16  ? {2'b00, dw, dw} :
                   d24  ? {sw, dw, dw, dw} : 4'b0000;
endmodule
