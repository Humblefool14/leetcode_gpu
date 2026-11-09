// fv_ad_vf_asm_topo -- the classifier against the topology table of spec section 4 and
// ad_vf_state.vh (Vulkan 0 point list .. 5 triangle fan; 6, 7 reserved -> points).
module fv_ad_vf_asm_topo (input wire clk);
    (* anyconst *) reg [2:0] topo;
    wire [2:0] cls; wire [1:0] kind, psize; wire is_list;
    ad_vf_asm_topo dut (.topo(topo), .cls(cls), .kind(kind), .is_list(is_list), .psize(psize));
    always @(*) begin
        // class: the topology itself, points for 6 and 7
        a_cls:  assert (cls == (topo >= 3'd6 ? 3'd0 : topo));
        // kind: 0 point lists, 1 the line topologies, 2 the triangle topologies (prim_vtx[25:24])
        a_kind: assert (kind == ((topo == 3'd1 || topo == 3'd2) ? 2'd1 :
                                 (topo == 3'd3 || topo == 3'd4 || topo == 3'd5) ? 2'd2 : 2'd0));
        a_list: assert (is_list == (topo == 3'd1 || topo == 3'd3));
        a_size: assert (psize == (topo == 3'd1 ? 2'd2 : topo == 3'd3 ? 2'd3 : 2'd1));
    end
endmodule
