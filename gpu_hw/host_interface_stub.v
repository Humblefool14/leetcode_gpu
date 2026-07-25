`timescale 1ns / 1ps

module host_interface_stub #(
    parameter int DATA_WIDTH = 32
)(
    input  logic              clk,
    input  logic              rst_n,

    // Direct register inputs (from testbench or top-level)
    input  logic              wr_en,
    input  logic [7:0]        wr_addr,
    input  logic [DATA_WIDTH-1:0] wr_data,

    // Control outputs
    output logic              reg_start,
    output logic              reg_clear_z,
    output logic [15:0]       reg_v0_x, reg_v0_y,
    output logic [15:0]       reg_v1_x, reg_v1_y,
    output logic [15:0]       reg_v2_x, reg_v2_y,
    output logic [7:0]        reg_v0_r, reg_v0_g, reg_v0_b,
    output logic [7:0]        reg_v1_r, reg_v1_g, reg_v1_b,
    output logic [7:0]        reg_v2_r, reg_v2_g, reg_v2_b,
    output logic [15:0]       reg_v0_z, reg_v1_z, reg_v2_z,
    output logic [15:0]       reg_v0_u, reg_v0_v,
    output logic [15:0]       reg_v1_u, reg_v1_v,
    output logic [15:0]       reg_v2_u, reg_v2_v,
    output logic [31:0]       reg_inv_area,
    output logic [23:0]       reg_flat_color,
    output logic              reg_tex_load,

    // Status
    input  logic              pipeline_busy
);

    // Register map (same addresses as full version for compatibility)
    localparam logic [7:0]
        REG_START      = 8'h00,
        REG_STATUS     = 8'h04,
        REG_CLEAR_Z    = 8'h08,
        REG_V0_X       = 8'h0C,
        REG_V0_Y       = 8'h10,
        REG_V1_X       = 8'h14,
        REG_V1_Y       = 8'h18,
        REG_V2_X       = 8'h1C,
        REG_V2_Y       = 8'h20,
        REG_V0_COLOR   = 8'h24,
        REG_V1_COLOR   = 8'h28,
        REG_V2_COLOR   = 8'h2C,
        REG_V0_Z       = 8'h30,
        REG_V1_Z       = 8'h34,
        REG_V2_Z       = 8'h38,
        REG_V0_UV      = 8'h3C,
        REG_V1_UV      = 8'h40,
        REG_V2_UV      = 8'h44,
        REG_INV_AREA   = 8'h48,
        REG_FLAT_COLOR = 8'h4C,
        REG_TEX_LOAD   = 8'h50;

    // Start/Clear are pulses
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_start   <= 1'b0;
            reg_clear_z <= 1'b0;
            reg_tex_load<= 1'b0;
        end else begin
            reg_start   <= wr_en && (wr_addr == REG_START);
            reg_clear_z <= wr_en && (wr_addr == REG_CLEAR_Z);
            reg_tex_load<= wr_en && (wr_addr == REG_TEX_LOAD);
        end
    end

    // Register file
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_v0_x <= '0; reg_v0_y <= '0;
            reg_v1_x <= '0; reg_v1_y <= '0;
            reg_v2_x <= '0; reg_v2_y <= '0;
            reg_v0_r <= '0; reg_v0_g <= '0; reg_v0_b <= '0;
            reg_v1_r <= '0; reg_v1_g <= '0; reg_v1_b <= '0;
            reg_v2_r <= '0; reg_v2_g <= '0; reg_v2_b <= '0;
            reg_v0_z <= '0; reg_v1_z <= '0; reg_v2_z <= '0;
            reg_v0_u <= '0; reg_v0_v <= '0;
            reg_v1_u <= '0; reg_v1_v <= '0;
            reg_v2_u <= '0; reg_v2_v <= '0;
            reg_inv_area <= '0;
            reg_flat_color <= '0;
        end else if (wr_en) begin
            case (wr_addr)
                REG_V0_X:       reg_v0_x <= wr_data[15:0];
                REG_V0_Y:       reg_v0_y <= wr_data[15:0];
                REG_V1_X:       reg_v1_x <= wr_data[15:0];
                REG_V1_Y:       reg_v1_y <= wr_data[15:0];
                REG_V2_X:       reg_v2_x <= wr_data[15:0];
                REG_V2_Y:       reg_v2_y <= wr_data[15:0];
                REG_V0_COLOR:   {reg_v0_r, reg_v0_g, reg_v0_b} <= wr_data[23:0];
                REG_V1_COLOR:   {reg_v1_r, reg_v1_g, reg_v1_b} <= wr_data[23:0];
                REG_V2_COLOR:   {reg_v2_r, reg_v2_g, reg_v2_b} <= wr_data[23:0];
                REG_V0_Z:       reg_v0_z <= wr_data[15:0];
                REG_V1_Z:       reg_v1_z <= wr_data[15:0];
                REG_V2_Z:       reg_v2_z <= wr_data[15:0];
                REG_V0_UV:      {reg_v0_u, reg_v0_v} <= wr_data[31:0];
                REG_V1_UV:      {reg_v1_u, reg_v1_v} <= wr_data[31:0];
                REG_V2_UV:      {reg_v2_u, reg_v2_v} <= wr_data[31:0];
                REG_INV_AREA:   reg_inv_area <= wr_data;
                REG_FLAT_COLOR: reg_flat_color <= wr_data[23:0];
            endcase
        end
    end

endmodule
