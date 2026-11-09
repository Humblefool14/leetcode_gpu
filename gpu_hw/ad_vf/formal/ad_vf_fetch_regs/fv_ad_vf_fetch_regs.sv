// fv_ad_vf_fetch_regs -- STATE snoop: for a symbolic attribute kk (anyconst), shadow registers
// updated by the STATE writes of its four indices (ad_vf_state.vh macros, recomputed here from
// the macro values) must equal the words the leaf outputs when k = kk; en[kk] must equal
// (ATTR_DST[kk] != 0); FIRST_INSTANCE likewise.  All reset to 0.
`include "ad_vf_state.vh"
module fv_ad_vf_fetch_regs (
    input wire        clk,
    input wire        rst_n,
    input wire        st_we,
    input wire [8:0]  st_idx,
    input wire [31:0] st_wdata,
    input wire [3:0]  k
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);
    (* anyconst *) reg [3:0] kk;
    wire [15:0] en; wire [31:0] base, desc, dst, limit, first;
    ad_vf_fetch_regs dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata), .k(k),
        .en(en), .base(base), .desc(desc), .dst(dst), .limit(limit), .first_inst(first));
    reg [31:0] s_b, s_d, s_t, s_l, s_f;
    wire [8:0] i_b = 9'h030 + {4'd0, kk, 1'b0}, i_d = 9'h031 + {4'd0, kk, 1'b0};
    wire [8:0] i_t = 9'h1C0 + {5'd0, kk},       i_l = 9'h1D0 + {5'd0, kk};
    always @(posedge clk) begin
        if (!rst_n) begin s_b <= 0; s_d <= 0; s_t <= 0; s_l <= 0; s_f <= 0; end
        else if (st_we) begin
            if (st_idx == i_b) s_b <= st_wdata;
            if (st_idx == i_d) s_d <= st_wdata;
            if (st_idx == i_t) s_t <= st_wdata;
            if (st_idx == i_l) s_l <= st_wdata;
            if (st_idx == 9'h025) s_f <= st_wdata;
        end
    end
    always @(*) if (!init) begin
        a_macro: assert (`AD_S_ATTR_BASE(kk) == i_b && `AD_S_ATTR_DESC(kk) == i_d &&
                         `AD_S_ATTR_DST(kk) == i_t && `AD_S_ATTR_LIMIT(kk) == i_l && `AD_S_FIRST_INSTANCE == 9'h025);
        if (k == kk) begin
            a_b: assert (base  == s_b);
            a_d: assert (desc  == s_d);
            a_t: assert (dst   == s_t);
            a_l: assert (limit == s_l);
        end
        a_en: assert (en[kk] == (s_t != 32'd0));
        a_f:  assert (first == s_f);
    end
endmodule
