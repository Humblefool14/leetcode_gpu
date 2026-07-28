module bump_map_sampler #(
    parameter int TEX_WIDTH  = 256,
    parameter int TEX_HEIGHT = 256,
    parameter int UV_W       = 16
)(
    input  logic              clk,
    input  logic              rst_n,

    // UV coordinates
    input  logic              tex_valid,
    input  logic [UV_W-1:0]   tex_u, tex_v,

    // Bump map BRAM (separate from albedo texture)
    output logic [15:0]       bump_rd_addr,
    input  logic [23:0]       bump_rd_data,  // RGB = normal XYZ

    // Output: perturbed normal in tangent space
    output logic              bump_valid,
    output logic signed [15:0] normal_x, normal_y, normal_z
);

    // Same UV→address logic as texture_sampler
    logic [UV_W-1:0] u_scaled, v_scaled;
    logic [7:0] u_int, v_int;

    assign u_scaled = tex_u * TEX_WIDTH;
    assign v_scaled = tex_v * TEX_HEIGHT;
    assign u_int = u_scaled[UV_W-1:UV_W-8];
    assign v_int = v_scaled[UV_W-1:UV_W-8];

    assign bump_rd_addr = (v_int * TEX_WIDTH) + u_int;

    // Convert [0,255] to [-1,1] in fixed-point Q1.14
    // X: (R - 128) / 128
    // Y: (G - 128) / 128
    // Z: B / 255 (always positive, roughly [0,1])

    always_ff @(posedge clk) begin
        bump_valid <= tex_valid;
        if (tex_valid) begin
            normal_x <= (bump_rd_data[23:16] - 8'd128) <<< 6;  // Q1.14
            normal_y <= (bump_rd_data[15:8]  - 8'd128) <<< 6;
            normal_z <= bump_rd_data[7:0] <<< 6;  // Approximate [0,1]
        end
    end

endmodule
