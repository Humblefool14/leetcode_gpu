// ad_vf_fmt_info -- byte size, component count and kind of a vertex attribute format
// (spec/gpu/vf/ad_vf_fetch.md §4, the `ad_fmt_info` of the spec text).
//
// vkfmt = ATTR_DST[31:24] (VkFormat, 0 = none), legacy = ATTR_DESC[19:16] (AD_LF_*).
// Exactly tools/fmtmodel.py info():
//   vkfmt != 0 : the VkFormat's entry, or (4, 0, SFLOAT) for a value without one;
//   vkfmt == 0 : the legacy entry, or (4, 0, SFLOAT) for the reserved codes 10..15.
// kind: 0 SFLOAT, 1 UNORM, 2 SNORM, 3 UINT, 4 SINT (fmtmodel.K_*).
// Combinational.  Proven equal to a table generated from fmtmodel.py (formal/ad_vf_fmt_info).
`include "ad_vf_state.vh"
module ad_vf_fmt_info (
    input  wire [7:0] vkfmt,
    input  wire [3:0] legacy,
    output reg  [4:0] size,      // 1..16 bytes
    output reg  [2:0] ncomp,     // 0..4 data components
    output reg  [2:0] kind
);
    localparam K_FLOAT = 3'd0, K_UNORM = 3'd1, K_SNORM = 3'd2, K_UINT = 3'd3, K_SINT = 3'd4;

    always @(*) begin
        size = 5'd4; ncomp = 3'd0; kind = K_FLOAT;        // no entry
        if (vkfmt != 8'd0) begin
            case (vkfmt)
                // 8-bit R / RG / RGBA: UNORM, SNORM, (USCALED, SSCALED: no entry), UINT, SINT
                8'd9,  8'd10, 8'd13, 8'd14: begin size = 5'd1; ncomp = 3'd1; end
                8'd16, 8'd17, 8'd20, 8'd21: begin size = 5'd2; ncomp = 3'd2; end
                8'd37, 8'd38, 8'd41, 8'd42,
                8'd44,                                         // B8G8R8A8_UNORM
                8'd51, 8'd52, 8'd55, 8'd56,                    // A8B8G8R8_*_PACK32
                8'd64:                       begin size = 5'd4; ncomp = 3'd4; end // A2B10G10R10_UNORM
                // 16-bit: R 70.., RG 77.., RGB 84.., RGBA 91.. (+0 UN, +1 SN, +4 UI, +5 SI, +6 SF)
                8'd70, 8'd71, 8'd74, 8'd75, 8'd76: begin size = 5'd2;  ncomp = 3'd1; end
                8'd77, 8'd78, 8'd81, 8'd82, 8'd83: begin size = 5'd4;  ncomp = 3'd2; end
                8'd84, 8'd85, 8'd88, 8'd89, 8'd90: begin size = 5'd6;  ncomp = 3'd3; end
                8'd91, 8'd92, 8'd95, 8'd96, 8'd97: begin size = 5'd8;  ncomp = 3'd4; end
                // 32-bit: R 98.., RG 101.., RGB 104.., RGBA 107.. (+0 UI, +1 SI, +2 SF)
                8'd98,  8'd99,  8'd100: begin size = 5'd4;  ncomp = 3'd1; end
                8'd101, 8'd102, 8'd103: begin size = 5'd8;  ncomp = 3'd2; end
                8'd104, 8'd105, 8'd106: begin size = 5'd12; ncomp = 3'd3; end
                8'd107, 8'd108, 8'd109: begin size = 5'd16; ncomp = 3'd4; end
                default: ;
            endcase
            case (vkfmt)
                8'd9,  8'd16, 8'd37, 8'd44, 8'd51, 8'd64,
                8'd70, 8'd77, 8'd84, 8'd91:                       kind = K_UNORM;
                8'd10, 8'd17, 8'd38, 8'd52,
                8'd71, 8'd78, 8'd85, 8'd92:                       kind = K_SNORM;
                8'd13, 8'd20, 8'd41, 8'd55,
                8'd74, 8'd81, 8'd88, 8'd95,
                8'd98, 8'd101, 8'd104, 8'd107:                    kind = K_UINT;
                8'd14, 8'd21, 8'd42, 8'd56,
                8'd75, 8'd82, 8'd89, 8'd96,
                8'd99, 8'd102, 8'd105, 8'd108:                    kind = K_SINT;
                default:                                          kind = K_FLOAT;
            endcase
        end else begin
            case (legacy)
                `AD_LF_R32F:    begin size = 5'd4;  ncomp = 3'd1; kind = K_FLOAT; end
                `AD_LF_RG32F:   begin size = 5'd8;  ncomp = 3'd2; kind = K_FLOAT; end
                `AD_LF_RGB32F:  begin size = 5'd12; ncomp = 3'd3; kind = K_FLOAT; end
                `AD_LF_RGBA32F: begin size = 5'd16; ncomp = 3'd4; kind = K_FLOAT; end
                `AD_LF_R32UI:   begin size = 5'd4;  ncomp = 3'd1; kind = K_UINT;  end
                `AD_LF_RG32UI:  begin size = 5'd8;  ncomp = 3'd2; kind = K_UINT;  end
                `AD_LF_RG16F:   begin size = 5'd4;  ncomp = 3'd2; kind = K_FLOAT; end
                `AD_LF_RGBA16F: begin size = 5'd8;  ncomp = 3'd4; kind = K_FLOAT; end
                `AD_LF_RGBA8UN: begin size = 5'd4;  ncomp = 3'd4; kind = K_UNORM; end
                `AD_LF_RGBA8UI: begin size = 5'd4;  ncomp = 3'd4; kind = K_UINT;  end
                default: ;
            endcase
        end
    end
endmodule
