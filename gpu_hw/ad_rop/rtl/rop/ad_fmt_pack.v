// ad_fmt_pack -- path-2 packing ("no conversion") of one pixel
// (spec/gpu/rop/ad_rop_wpix.md §4).  Combinational.
// Each channel takes the low bits of its source channel's 32-bit word (the shader
// exports integer bit patterns); R lowest, then G, B, A, each the format's width.
// A2B10G10R10_UINT_PACK32: R[9:0] G[19:10] B[29:20] A[31:30].
// o_keep: 1 = keep the stored bit (channel masked by i_wm, or a bit beyond the pixel).
// Formats outside path 2: o_raw = 0, o_keep = all ones.
module ad_fmt_pack (
    input  wire [127:0] i_src,      // 4 x fp32/int words, R in [31:0]
    input  wire [7:0]   i_fmt,
    input  wire [3:0]   i_wm,       // bit 0 R .. bit 3 A
    output reg  [127:0] o_raw,
    output reg  [127:0] o_keep
);
    // w: 0 none, 1 8-bit, 2 16-bit, 3 32-bit channels; n: channel count; a2: A2B10G10R10
    reg [1:0] w;
    reg [2:0] n;
    reg       a2;
    always @(*) begin
        a2 = 1'b0;
        case (i_fmt)
            8'd13, 8'd14:               begin w = 2'd1; n = 3'd1; end
            8'd20, 8'd21:               begin w = 2'd1; n = 3'd2; end
            8'd41, 8'd42, 8'd55, 8'd56: begin w = 2'd1; n = 3'd4; end
            8'd68:                      begin w = 2'd0; n = 3'd4; a2 = 1'b1; end
            8'd74, 8'd75:               begin w = 2'd2; n = 3'd1; end
            8'd81, 8'd82:               begin w = 2'd2; n = 3'd2; end
            8'd95, 8'd96:               begin w = 2'd2; n = 3'd4; end
            8'd98, 8'd99, 8'd100:       begin w = 2'd3; n = 3'd1; end
            8'd101, 8'd102, 8'd103:     begin w = 2'd3; n = 3'd2; end
            8'd107, 8'd108, 8'd109:     begin w = 2'd3; n = 3'd4; end
            default:                    begin w = 2'd0; n = 3'd0; end
        endcase
    end

    // per channel: written = present and enabled
    wire [3:0] wr;
    genvar c;
    generate for (c = 0; c < 4; c = c + 1) begin : g_wr
        assign wr[c] = (c < n) && i_wm[c];
    end endgenerate

    integer i;
    always @(*) begin
        o_raw  = 128'd0;
        o_keep = {128{1'b1}};
        if (a2) begin
            o_raw[31:0]   = {i_src[97:96], i_src[73:64], i_src[41:32], i_src[9:0]};
            o_keep[31:0]  = {{2{!wr[3]}}, {10{!wr[2]}}, {10{!wr[1]}}, {10{!wr[0]}}};
        end else begin
            for (i = 0; i < 4; i = i + 1) begin
                if (i < n) begin
                    case (w)
                        2'd1: begin o_raw[8*i +: 8]   = i_src[32*i +: 8];  o_keep[8*i +: 8]   = {8{!wr[i]}};  end
                        2'd2: begin o_raw[16*i +: 16] = i_src[32*i +: 16]; o_keep[16*i +: 16] = {16{!wr[i]}}; end
                        2'd3: begin o_raw[32*i +: 32] = i_src[32*i +: 32]; o_keep[32*i +: 32] = {32{!wr[i]}}; end
                        default: ;
                    endcase
                end
            end
        end
    end
endmodule
