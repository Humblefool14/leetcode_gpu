// ad_vf_conv -- VF format conversion (spec/gpu/vf/ad_vf_conv.md).
//
// An af is taken whole (af_valid && af_ready) with ATTR_DESC[k][19:16] and ATTR_DST[k] as they are
// then.  Its words come out one per cycle on the registered vl_* outputs, starting the cycle after
// it is taken: word c to register ATTR_DST[5:0] + c (mod 64), c = 0 .. ATTR_DST[7:6].  Word 0 is
// converted from the af_* inputs in the take cycle; words 1.. from the held copy.  The cycle in
// which the af's last word is on vl_* (or, for a disabled attribute that writes nothing, the one
// cycle it occupies) is its last slot: af_ready is high then and whenever idle, so back-to-back
// afs give one word per cycle.  conv_done pulses the cycle after the last slot of an af with
// af_last: one cycle after its last word, or two cycles after taking it when it writes nothing.
//
// Leaves: ad_vf_fmt_desc (format -> descriptor), ad_vf_fmt_comp (one component per cycle, with
// ad_vf_fmt_h2f / _unorm / _snorm).  Bit-exact reference: tools/fmtmodel.py words().
`include "ad_vf_state.vh"
module ad_vf_conv (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         st_we,
    input  wire [8:0]   st_idx,
    input  wire [31:0]  st_wdata,
    input  wire         af_valid,
    output wire         af_ready,
    input  wire [3:0]   af_attr,
    input  wire [4:0]   af_lane,
    input  wire [127:0] af_raw,
    input  wire         af_oob,
    input  wire         af_last,
    output reg          vl_we,
    output reg  [5:0]   vl_reg,
    output reg  [4:0]   vl_lane,
    output reg  [31:0]  vl_data,
    output reg          conv_done
);
    // ---------------- STATE snoop: ATTR_DESC[k][19:16] and ATTR_DST[k] ----------------
    reg [3:0]  lfmt [0:15];
    reg [31:0] dst  [0:15];
    genvar g;
    generate for (g = 0; g < 16; g = g + 1) begin : g_st
        always @(posedge clk) begin
            if (!rst_n) begin
                lfmt[g] <= 4'd0;
                dst[g]  <= 32'd0;
            end else if (st_we) begin
                if (st_idx == `AD_S_ATTR_DESC(g)) lfmt[g] <= st_wdata[`AD_DESC_FMT];
                if (st_idx == `AD_S_ATTR_DST(g))  dst[g]  <= st_wdata;
            end
        end
    end endgenerate

    // ---------------- slot state ----------------
    reg         s_act;          // an af occupies this cycle (its word s_c is on vl_*)
    reg [1:0]   s_c;            // index of the word on vl_*
    reg [1:0]   s_n;            // index of its last word (0 for a disabled attribute)
    reg         s_last;         // af_last of the af
    // held af for words 1..3 (datapath, qualified by s_act)
    reg [127:0] h_raw;
    reg [4:0]   h_lane;
    reg         h_oob;
    reg [5:0]   h_reg;
    reg [2:0]   h_ncomp, h_kind;
    reg [1:0]   h_bw;
    reg         h_bgra;

    wire last_slot = s_act && (s_c == s_n);
    assign af_ready = !s_act || last_slot;
    wire take = af_valid && af_ready;

    // descriptor of the incoming af
    wire [31:0] a_dst = dst[af_attr];
    wire        a_en  = (a_dst != 32'd0);
    wire [2:0]  a_ncomp, a_kind; wire [1:0] a_bw; wire a_bgra;
    ad_vf_fmt_desc u_desc (.vkfmt(a_dst[`AD_DST_VKFMT]), .legacy(lfmt[af_attr]),
        .ncomp(a_ncomp), .kind(a_kind), .bw(a_bw), .bgra(a_bgra));

    // the one component of the cycle: word 0 of a taken af, else word s_c + 1 of the held one
    wire [1:0]  nxt_c = s_c + 2'd1;
    wire        more  = s_act && (s_c != s_n);
    wire [31:0] cw;
    ad_vf_fmt_comp u_comp (
        .raw  (take ? af_raw : h_raw),
        .ncomp(take ? a_ncomp : h_ncomp),
        .kind (take ? a_kind : h_kind),
        .bw   (take ? a_bw : h_bw),
        .bgra (take ? a_bgra : h_bgra),
        .oob  (take ? af_oob : h_oob),
        .i    (take ? 2'd0 : nxt_c),
        .word (cw));

    always @(posedge clk) begin
        if (!rst_n) begin
            s_act <= 1'b0; s_c <= 2'd0; s_n <= 2'd0; s_last <= 1'b0;
            vl_we <= 1'b0; conv_done <= 1'b0;
        end else begin
            conv_done <= last_slot && s_last;
            if (take) begin
                s_act  <= 1'b1;
                s_c    <= 2'd0;
`ifdef MUT_CONV_CNT
                s_n    <= a_en ? a_dst[`AD_DST_CNT] - 2'd1 : 2'd0;   // mutation: one word short
`else
                s_n    <= a_en ? a_dst[`AD_DST_CNT] : 2'd0;
`endif
                s_last <= af_last;
                vl_we  <= a_en;
            end else if (more) begin
                s_c    <= nxt_c;
                vl_we  <= 1'b1;
            end else begin
                s_act  <= 1'b0;
                vl_we  <= 1'b0;
            end
        end
    end

    // datapath registers (no reset: qualified by s_act / vl_we)
    always @(posedge clk) begin
        if (take) begin
            h_raw <= af_raw; h_lane <= af_lane; h_oob <= af_oob; h_reg <= a_dst[`AD_DST_REG];
            h_ncomp <= a_ncomp; h_kind <= a_kind; h_bw <= a_bw; h_bgra <= a_bgra;
            vl_reg  <= a_dst[`AD_DST_REG];
            vl_lane <= af_lane;
            vl_data <= cw;
        end else if (more) begin
            vl_reg  <= h_reg + {4'd0, nxt_c};
            vl_lane <= h_lane;
            vl_data <= cw;
        end
    end
endmodule
