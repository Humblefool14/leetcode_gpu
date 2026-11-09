// ad_vf_fmt_comp -- one 32-bit word (component i) of an attribute, combinational.
// Given the descriptor of ad_vf_fmt_desc and the raw bytes (byte 0 in [7:0]), produces word i of
// tools/fmtmodel.py convert(): the converted field (swizzled for B8G8R8A8), or the fill
// (0, 0, 0, 1) when i >= ncomp or oob (1 = 1.0 for SFLOAT/UNORM/SNORM, integer 1 for UINT/SINT).
// One component per cycle: one instance of each converter.
module ad_vf_fmt_comp (
    input  wire [127:0] raw,
    input  wire [2:0]   ncomp,
    input  wire [2:0]   kind,
    input  wire [1:0]   bw,
    input  wire         bgra,
    input  wire         oob,
    input  wire [1:0]   i,
    output reg  [31:0]  word
);
    localparam K_FLOAT = 3'd0, K_UNORM = 3'd1, K_SNORM = 3'd2, K_UINT = 3'd3, K_SINT = 3'd4;

`ifdef MUT_CONV_SWZ
    wire [1:0]  j   = i;                                       // mutation: B8G8R8A8 not swizzled
`else
    wire [1:0]  j   = (bgra && !i[0]) ? {~i[1], 1'b0} : i;     // 0 <-> 2
`endif
    wire [7:0]  f8  = raw[8*j  +: 8];
    wire [15:0] f16 = raw[16*j +: 16];
    wire [31:0] f32 = raw[32*j +: 32];
    wire [9:0]  f10 = (i == 2'd0) ? raw[9:0] : (i == 2'd1) ? raw[19:10] : raw[29:20];
    wire [1:0]  f2  = raw[31:30];

    wire [31:0] h_f, un8, un16, un10, un2, sn8, sn16;
    ad_vf_fmt_h2f                u_h2f  (.h(f16), .f(h_f));
    ad_vf_fmt_unorm #(.N(8))     u_un8  (.c(f8),  .f(un8));
    ad_vf_fmt_unorm #(.N(16))    u_un16 (.c(f16), .f(un16));
    ad_vf_fmt_unorm #(.N(10))    u_un10 (.c(f10), .f(un10));
    ad_vf_fmt_unorm #(.N(2))     u_un2  (.c(f2),  .f(un2));
    ad_vf_fmt_snorm #(.N(8))     u_sn8  (.c(f8),  .f(sn8));
    ad_vf_fmt_snorm #(.N(16))    u_sn16 (.c(f16), .f(sn16));

    wire is_int = (kind == K_UINT) || (kind == K_SINT);

    reg [31:0] cv;
    always @(*) begin
        case (kind)
            K_UNORM: cv = (bw == 2'd3) ? ((i == 2'd3) ? un2 : un10) : (bw == 2'd1) ? un16 : un8;
            K_SNORM: cv = (bw == 2'd1) ? sn16 : sn8;
            K_UINT:  cv = (bw == 2'd0) ? {24'd0, f8} : (bw == 2'd1) ? {16'd0, f16} : f32;
            K_SINT:  cv = (bw == 2'd0) ? {{24{f8[7]}}, f8} : (bw == 2'd1) ? {{16{f16[15]}}, f16} : f32;
            default: cv = (bw == 2'd1) ? h_f : f32;   // SFLOAT
        endcase
        if (oob || {1'b0, i} >= ncomp)
            word = (i != 2'd3) ? 32'd0 : is_int ? 32'd1 : 32'h3F80_0000;
        else
            word = cv;
    end
endmodule
