// ad_vf_fmt_desc -- conversion descriptor of an attribute format, combinational.
// vkfmt = ATTR_DST[31:24] (0: use the legacy code ATTR_DESC[19:16]).  Outputs what
// ad_vf_fmt_comp needs: component count (0 = no data components: reserved legacy codes and
// VkFormats without the vertex-buffer feature, which read (0, 0, 0, 1.0)), kind (K_* of
// tools/fmtmodel.py), field width and the B8G8R8A8 swizzle.  Table: tools/fmtmodel.py VK / LEGACY.
// (Byte sizes are ad_vf_fmt_info's job; this leaf is the conversion side only.)
module ad_vf_fmt_desc (
    input  wire [7:0] vkfmt,
    input  wire [3:0] legacy,
    output reg  [2:0] ncomp,     // 0..4
    output reg  [2:0] kind,      // 0 SFLOAT, 1 UNORM, 2 SNORM, 3 UINT, 4 SINT
    output reg  [1:0] bw,        // field width: 0 8-bit, 1 16-bit, 2 32-bit, 3 packed 10/10/10/2
    output reg        bgra       // components 0 and 2 swapped (B8G8R8A8)
);
    localparam K_FLOAT = 3'd0, K_UNORM = 3'd1, K_SNORM = 3'd2, K_UINT = 3'd3, K_SINT = 3'd4;

    // offset within an 8-/16-bit group: 0 UNORM, 1 SNORM, 4 UINT, 5 SINT, 6 SFLOAT (16-bit only)
    function [3:0] grp_kind;              // {valid, kind}
        input [2:0] o; input f16;
        case (o)
            3'd0: grp_kind = {1'b1, K_UNORM};
            3'd1: grp_kind = {1'b1, K_SNORM};
            3'd4: grp_kind = {1'b1, K_UINT};
            3'd5: grp_kind = {1'b1, K_SINT};
            3'd6: grp_kind = {f16, K_FLOAT};
            default: grp_kind = {1'b0, K_FLOAT};   // USCALED / SSCALED: no entry
        endcase
    endfunction

    reg [3:0] gk;
    reg [7:0] o;
    always @(*) begin
        ncomp = 3'd0; kind = K_FLOAT; bw = 2'd2; bgra = 1'b0; gk = 4'd0; o = 8'd0;
        if (vkfmt != 8'd0) begin
            if (vkfmt >= 8'd9 && vkfmt <= 8'd14 || vkfmt >= 8'd16 && vkfmt <= 8'd21 ||
                vkfmt >= 8'd37 && vkfmt <= 8'd42 || vkfmt >= 8'd51 && vkfmt <= 8'd56) begin
                o  = (vkfmt <= 8'd14) ? vkfmt - 8'd9 : (vkfmt <= 8'd21) ? vkfmt - 8'd16 :
                     (vkfmt <= 8'd42) ? vkfmt - 8'd37 : vkfmt - 8'd51;
                gk = grp_kind(o[2:0], 1'b0);
                if (gk[3]) begin
                    ncomp = (vkfmt <= 8'd14) ? 3'd1 : (vkfmt <= 8'd21) ? 3'd2 : 3'd4;
                    kind = gk[2:0]; bw = 2'd0;
                end
            end else if (vkfmt == 8'd44) begin
                ncomp = 3'd4; kind = K_UNORM; bw = 2'd0; bgra = 1'b1;
            end else if (vkfmt == 8'd64) begin
                ncomp = 3'd4; kind = K_UNORM; bw = 2'd3;
            end else if (vkfmt >= 8'd70 && vkfmt <= 8'd97) begin
                o  = vkfmt - 8'd70;                    // 4 groups of 7
                gk = grp_kind(o % 7, 1'b1);
                if (gk[3]) begin
                    ncomp = o / 7 + 1; kind = gk[2:0]; bw = 2'd1;
                end
            end else if (vkfmt >= 8'd98 && vkfmt <= 8'd109) begin
                o = vkfmt - 8'd98;                     // 4 groups of 3: UINT SINT SFLOAT
                ncomp = o / 3 + 1; bw = 2'd2;
                kind = (o % 3 == 0) ? K_UINT : (o % 3 == 1) ? K_SINT : K_FLOAT;
            end
        end else begin
            case (legacy)
                4'd0, 4'd1, 4'd2, 4'd3: begin ncomp = legacy[1:0] + 3'd1; kind = K_FLOAT; bw = 2'd2; end
                4'd4, 4'd5:             begin ncomp = legacy[0] + 3'd1;   kind = K_UINT;  bw = 2'd2; end
                4'd6:                   begin ncomp = 3'd2; kind = K_FLOAT; bw = 2'd1; end
                4'd7:                   begin ncomp = 3'd4; kind = K_FLOAT; bw = 2'd1; end
                4'd8:                   begin ncomp = 3'd4; kind = K_UNORM; bw = 2'd0; end
                4'd9:                   begin ncomp = 3'd4; kind = K_UINT;  bw = 2'd0; end
                default: ;                             // 10..15 reserved: no data components
            endcase
        end
    end
endmodule
