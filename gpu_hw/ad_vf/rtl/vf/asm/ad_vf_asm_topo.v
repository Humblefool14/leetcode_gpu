// ad_vf_asm_topo -- topology classifier of ad_vf_asm (spec/gpu/vf/ad_vf_asm.md section 4).
// TOPOLOGY[2:0] (Vulkan VkPrimitiveTopology) -> assembly class, primitive kind (prim_vtx[25:24]),
// list flag and list primitive size.  6 and 7 (reserved) assemble as points.
// Classes: 0 point list, 1 line list, 2 line strip, 3 triangle list, 4 triangle strip, 5 fan.
module ad_vf_asm_topo (
    input  wire [2:0] topo,
    output reg  [2:0] cls,      // assembly class
    output reg  [1:0] kind,     // 0 point, 1 line, 2 triangle
    output reg        is_list,  // line list or triangle list (warp fit rule)
    output reg  [1:0] psize     // vertices of a list primitive (1 for the others)
);
    always @(*) begin
        case (topo)
            3'd0:    begin cls = 3'd0; kind = 2'd0; is_list = 1'b0; psize = 2'd1; end
            3'd1:    begin cls = 3'd1; kind = 2'd1; is_list = 1'b1; psize = 2'd2; end
            3'd2:    begin cls = 3'd2; kind = 2'd1; is_list = 1'b0; psize = 2'd1; end
            3'd3:    begin cls = 3'd3; kind = 2'd2; is_list = 1'b1; psize = 2'd3; end
            3'd4:    begin cls = 3'd4; kind = 2'd2; is_list = 1'b0; psize = 2'd1; end
            3'd5:    begin cls = 3'd5; kind = 2'd2; is_list = 1'b0; psize = 2'd1; end
            default: begin cls = 3'd0; kind = 2'd0; is_list = 1'b0; psize = 2'd1; end
        endcase
    end
endmodule
