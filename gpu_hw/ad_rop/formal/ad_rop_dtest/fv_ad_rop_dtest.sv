// ad_rop_dtest structural properties (free state and entry):
//   cov = 0 -> pass = 0, wbe = 0;  no single format -> pass = cov, wbe = 0;
//   bounds failure -> pass = 0, wbe = 0 (z_a recomputed here from the shared IPs);
//   depth bytes only with DEPTH[1];  wbe subset per format (D16 bytes 0-1 together,
//   D24 bytes 0-2 together + stencil byte 3 only with the stencil test, D32F all or none);
//   the depth word written is the format's conversion of zf; pass -> cov.
module fv_ad_rop_dtest;
    (* anyconst *) reg [9:0]  depth;
    (* anyconst *) reg [26:0] sfront, sback;
    (* anyconst *) reg [24:0] sops;
    (* anyconst *) reg [31:0] bmin, bmax, zf, stored;
    (* anyconst *) reg        cov, front;
    wire pass; wire [31:0] wword; wire [3:0] wbe;
    ad_rop_dtest dut (.depth(depth), .sfront(sfront), .sback(sback), .sops(sops), .bmin(bmin),
                      .bmax(bmax), .cov(cov), .front(front), .zf(zf), .stored(stored),
                      .pass(pass), .wword(wword), .wbe(wbe));
    wire d24 = depth[7:5] == 3'b001, d32 = depth[7:5] == 3'b010, d16 = depth[7:5] == 3'b100;
    // independent z_a and bounds
    wire [31:0] u16f, u24f;
    ad_unorm2f #(.N(16)) h16 (.x(stored[15:0]), .f(u16f));
    ad_unorm2f #(.N(24)) h24 (.x(stored[23:0]), .f(u24f));
    wire [31:0] za = d32 ? stored : d16 ? u16f : u24f;
    wire l0, e0, n0, l1, e1, n1;
    ad_fp_cmp hc0 (.a(bmin), .b(za), .lt(l0), .eq(e0), .un(n0));   // bmin <= za
    ad_fp_cmp hc1 (.a(za), .b(bmax), .lt(l1), .eq(e1), .un(n1));   // za <= bmax
    wire outside = !((l0 | e0) && (l1 | e1));
    wire [15:0] c16; wire [23:0] c24;
    ad_f2unorm #(.N(16)) hf16 (.f(zf), .u(c16));
    ad_f2unorm #(.N(24)) hf24 (.f(zf), .u(c24));
    always @(*) begin
        if (!cov) a_cov0: assert (!pass && wbe == 4'd0);
        if (!(d24 | d32 | d16)) a_nofmt: assert (pass == cov && wbe == 4'd0);
        if (depth[9] && (d24 | d32 | d16) && outside) a_bounds: assert (!pass && wbe == 4'd0);
        if (!depth[1]) a_nodw: assert (d24 ? wbe[2:0] == 3'd0 : wbe == 4'd0);
        if (d16) a_d16: assert (wbe == 4'b0000 || wbe == 4'b0011);
        if (d24) a_d24: assert (wbe[2:0] == 3'b000 || wbe[2:0] == 3'b111);
        if (d24 && !depth[8]) a_d24ns: assert (!wbe[3]);
        if (d24 && wbe[3]) a_sdiff: assert (wword[31:24] != stored[31:24]);
        if (d32) a_d32: assert (wbe == 4'b0000 || wbe == 4'b1111);
        if (pass) a_pass_cov: assert (cov);
        if (d32 && wbe[0]) a_w32: assert (wword == zf);
        if (d24 && wbe[0]) a_w24: assert (wword[23:0] == c24);
        if (d16 && wbe[0]) a_w16: assert (wword[15:0] == c16);
        if (wbe[0]) a_wpass: assert (pass);          // depth written only for a passing entry
    end
endmodule
