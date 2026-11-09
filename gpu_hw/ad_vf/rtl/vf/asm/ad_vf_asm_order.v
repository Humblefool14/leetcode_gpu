// ad_vf_asm_order -- provoking-vertex rotation of ad_vf_asm (spec section 4, prim_vtx).
// Inputs are the primitive's lanes in assembly order:
//   lines (a, b, -), triangle list (A, B, V), strip (v_i, v_i+1, v_i+2) with par = i % 2,
//   fan (v_i+1, v_i+2, v_0), point (p, -, -).
// Outputs slot 0..2 (slot 0 = provoking vertex, Vulkan winding kept by rotation):
//   point (p,p,p); line first (a,b,b) / last (b,a,a); list (A,B,V) / (V,A,B);
//   strip first (i, i+1+i%2, i+2-i%2) / last (i+2, i+i%2, i+1-i%2); fan (i+1,i+2,0) / (i+2,0,i+1).
module ad_vf_asm_order (
    input  wire [2:0] cls,
    input  wire       prov,     // PROVOKING[0]: 0 first, 1 last
    input  wire       par,      // strip triangle parity (i % 2)
    input  wire [4:0] x,
    input  wire [4:0] y,
    input  wire [4:0] z,
    output reg  [4:0] l0,
    output reg  [4:0] l1,
    output reg  [4:0] l2
);
    always @(*) begin
        case (cls)
            3'd1, 3'd2: if (prov) {l0, l1, l2} = {y, x, x}; else {l0, l1, l2} = {x, y, y};
            3'd3:       if (prov) {l0, l1, l2} = {z, x, y}; else {l0, l1, l2} = {x, y, z};
            3'd4: begin
                if (par) begin if (prov) {l0, l1, l2} = {z, y, x}; else {l0, l1, l2} = {x, z, y}; end
                else     begin if (prov) {l0, l1, l2} = {z, x, y}; else {l0, l1, l2} = {x, y, z}; end
            end
            3'd5:       if (prov) {l0, l1, l2} = {y, z, x}; else {l0, l1, l2} = {x, y, z};
            default:    {l0, l1, l2} = {x, x, x};
        endcase
    end
endmodule
