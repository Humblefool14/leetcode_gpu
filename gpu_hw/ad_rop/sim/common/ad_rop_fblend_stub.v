// ad_rop_fblend (STUB for the ad_rop_wb / ad_rop_wpix / ad_rop_mrt testbenches) -- same
// ports as spec/gpu/rop/ad_rop_fblend.md §3, 5-cycle streaming pipeline with the same
// handshake (stall = o_valid && !o_ready freezes the pipe; i_ready = !stall), but
// blend-disabled behaviour for one format only:
//   64 A2B10G10R10_UNORM_PACK32: R = f2unorm10(r) [9:0], G [19:10], B [29:20], A = f2unorm2(a) [31:30]
// Every other format (and inactive lanes): o_keep all ones.  i_blend / i_const ignored.
// Listed in the .f files only while the real rtl/rop/ad_rop_fblend.v is not used.
module ad_rop_fblend (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         i_valid,
    output wire         i_ready,
    input  wire [3:0]   i_lanes,
    input  wire [511:0] i_src,
    input  wire [255:0] i_dst,
    input  wire [7:0]   i_fmt,
    input  wire [22:0]  i_blend,
    input  wire [127:0] i_const,
    input  wire [3:0]   i_wm,
    output wire         o_valid,
    input  wire         o_ready,
    output wire [255:0] o_raw,
    output wire [255:0] o_keep
);
    wire stall = o_valid && !o_ready;
    assign i_ready = !stall;

    reg [255:0] raw0, keep0;
    integer k;
    wire [9:0] r10 [0:3], g10 [0:3], b10 [0:3];
    wire [1:0] a2 [0:3];
    genvar g;
    generate for (g = 0; g < 4; g = g + 1) begin : g_cv
        ad_f2unorm #(.N(10)) u_r (.f(i_src[128*g +: 32]),      .u(r10[g]));
        ad_f2unorm #(.N(10)) u_g (.f(i_src[128*g + 32 +: 32]), .u(g10[g]));
        ad_f2unorm #(.N(10)) u_b (.f(i_src[128*g + 64 +: 32]), .u(b10[g]));
        ad_f2unorm #(.N(2))  u_a (.f(i_src[128*g + 96 +: 32]), .u(a2[g]));
    end endgenerate
    always @(*) begin
        raw0 = 256'd0; keep0 = {256{1'b1}};
        for (k = 0; k < 4; k = k + 1)
            if (i_fmt == 8'd64 && i_lanes[k]) begin
                raw0[64*k +: 32]  = {a2[k], b10[k], g10[k], r10[k]};
                keep0[64*k +: 32] = {{2{!i_wm[3]}}, {10{!i_wm[2]}}, {10{!i_wm[1]}}, {10{!i_wm[0]}}};
            end
    end

    reg [4:0]   v;
    reg [255:0] raw [0:4];
    reg [255:0] keep [0:4];
    always @(posedge clk) begin
        if (!rst_n) v <= 5'd0;
        else if (!stall) begin
            v <= {v[3:0], i_valid};
            raw[0] <= raw0; keep[0] <= keep0;
            for (k = 1; k < 5; k = k + 1) begin raw[k] <= raw[k-1]; keep[k] <= keep[k-1]; end
        end
    end
    assign o_valid = v[4];
    assign o_raw   = raw[4];
    assign o_keep  = keep[4];
endmodule
