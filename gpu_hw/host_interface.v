`timescale 1ns / 1ps

module host_interface #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH   = 8
)(
    input  logic                  clk,
    input  logic                  rst_n,

    // UART Interface (from external UART receiver)
    input  logic                  uart_rx_valid,
    input  logic [DATA_WIDTH-1:0] uart_rx_data,

    // Control Outputs to Pipeline
    output logic                  reg_start,
    output logic                  reg_clear_z,
    output logic [DATA_WIDTH-1:0] reg_status,

    // Vertex Positions (16-bit screen coordinates, packed in 32-bit)
    output logic [15:0]           reg_v0_x, reg_v0_y,
    output logic [15:0]           reg_v1_x, reg_v1_y,
    output logic [15:0]           reg_v2_x, reg_v2_y,

    // Vertex Colors (8-bit per channel)
    output logic [7:0]            reg_v0_r, reg_v0_g, reg_v0_b,
    output logic [7:0]            reg_v1_r, reg_v1_g, reg_v1_b,
    output logic [7:0]            reg_v2_r, reg_v2_g, reg_v2_b,

    // Vertex Z (16-bit depth)
    output logic [15:0]           reg_v0_z,
    output logic [15:0]           reg_v1_z,
    output logic [15:0]           reg_v2_z,

    // Triangle constant: 1/area in 0.32 fixed-point
    output logic [31:0]           reg_inv_area,

    // Flat color fallback (for debug / flat shading mode)
    output logic [23:0]           reg_flat_color,

    // Status Input from Pipeline
    input  logic                  pipeline_busy
);

    // =====================================================================
    // REGISTER MAP (byte addresses)
    // =====================================================================
    localparam logic [ADDR_WIDTH-1:0]
        REG_START     = 8'h00,  // W: Pulse to start rasterization
        REG_STATUS    = 8'h04,  // R: Pipeline busy bit
        REG_CLEAR_Z   = 8'h08,  // W: Trigger Z-buffer clear
        REG_V0_X      = 8'h0C,  // W: Vertex 0 X
        REG_V0_Y      = 8'h10,  // W: Vertex 0 Y
        REG_V1_X      = 8'h14,  // W: Vertex 1 X
        REG_V1_Y      = 8'h18,  // W: Vertex 1 Y
        REG_V2_X      = 8'h1C,  // W: Vertex 2 X
        REG_V2_Y      = 8'h20,  // W: Vertex 2 Y
        REG_V0_COLOR  = 8'h24,  // W: {8'b0, v0_r, v0_g, v0_b}
        REG_V1_COLOR  = 8'h28,  // W: {8'b0, v1_r, v1_g, v1_b}
        REG_V2_COLOR  = 8'h2C,  // W: {8'b0, v2_r, v2_g, v2_b}
        REG_V0_Z      = 8'h30,  // W: Vertex 0 Z
        REG_V1_Z      = 8'h34,  // W: Vertex 1 Z
        REG_V2_Z      = 8'h38,  // W: Vertex 2 Z
        REG_INV_AREA  = 8'h3C,  // W: 1/area (0.32 fixed-point)
        REG_FLAT_COLOR= 8'h40;  // W: {8'b0, R, G, B} fallback

    // =====================================================================
    // UART PROTOCOL
    // Format per write: [ADDR (1 byte)] [DATA (4 bytes, little-endian)]
    // =====================================================================

    typedef enum logic [2:0] {
        RX_IDLE,
        RX_ADDR,
        RX_DATA0,
        RX_DATA1,
        RX_DATA2,
        RX_DATA3
    } rx_state_t;

    rx_state_t rx_state;
    logic [ADDR_WIDTH-1:0] rx_addr;
    logic [DATA_WIDTH-1:0] rx_data;
    logic [7:0]              rx_byte [0:3];  // Little-endian assembly

    // =====================================================================
    // UART Receive State Machine
    // =====================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state <= RX_IDLE;
            rx_addr  <= '0;
            rx_data  <= '0;
            rx_byte[0] <= '0; rx_byte[1] <= '0;
            rx_byte[2] <= '0; rx_byte[3] <= '0;
        end else begin
            if (uart_rx_valid) begin
                case (rx_state)
                    RX_IDLE: begin
                        rx_addr  <= uart_rx_data[ADDR_WIDTH-1:0];
                        rx_state <= RX_DATA0;
                    end

                    RX_DATA0: begin rx_byte[0] <= uart_rx_data[7:0]; rx_state <= RX_DATA1; end
                    RX_DATA1: begin rx_byte[1] <= uart_rx_data[7:0]; rx_state <= RX_DATA2; end
                    RX_DATA2: begin rx_byte[2] <= uart_rx_data[7:0]; rx_state <= RX_DATA3; end
                    RX_DATA3: begin
                        rx_byte[3] <= uart_rx_data[7:0];
                        rx_data <= {rx_byte[2], rx_byte[1], rx_byte[0], uart_rx_data[7:0]};
                        rx_state <= RX_IDLE;
                    end
                endcase
            end
        end
    end

    // =====================================================================
    // REGISTER WRITE (combinational decode, registered outputs)
    // =====================================================================
    logic        wr_en;
    logic [ADDR_WIDTH-1:0] wr_addr;
    logic [DATA_WIDTH-1:0] wr_data;

    assign wr_en  = (rx_state == RX_DATA3) && uart_rx_valid;
    assign wr_addr = rx_addr;
    assign wr_data = {rx_byte[2], rx_byte[1], rx_byte[0], uart_rx_data[7:0]};

    // Start/Clear are single-cycle pulses
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_start   <= 1'b0;
            reg_clear_z <= 1'b0;
        end else begin
            reg_start   <= wr_en && (wr_addr == REG_START);
            reg_clear_z <= wr_en && (wr_addr == REG_CLEAR_Z);
        end
    end

    // Register file (write-only from host)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_v0_x <= '0; reg_v0_y <= '0;
            reg_v1_x <= '0; reg_v1_y <= '0;
            reg_v2_x <= '0; reg_v2_y <= '0;
            reg_v0_r <= '0; reg_v0_g <= '0; reg_v0_b <= '0;
            reg_v1_r <= '0; reg_v1_g <= '0; reg_v1_b <= '0;
            reg_v2_r <= '0; reg_v2_g <= '0; reg_v2_b <= '0;
            reg_v0_z <= '0; reg_v1_z <= '0; reg_v2_z <= '0;
            reg_inv_area  <= '0;
            reg_flat_color<= '0;
            reg_status    <= '0;
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

                REG_INV_AREA:   reg_inv_area <= wr_data;
                REG_FLAT_COLOR: reg_flat_color <= wr_data[23:0];
            endcase
        end

        // Status is read-only, updated every cycle
        reg_status <= {31'd0, pipeline_busy};
    end

    // =====================================================================
    // ASSERTIONS
    // =====================================================================

    // Safety: start is single-cycle pulse
    property p_start_pulse;
        @(posedge clk) disable iff (!rst_n)
        reg_start |=> !reg_start;
    endproperty
    a_start_pulse: assert property (p_start_pulse);

    // Safety: clear_z is single-cycle pulse
    property p_clear_pulse;
        @(posedge clk) disable iff (!rst_n)
        reg_clear_z |=> !reg_clear_z;
    endproperty
    a_clear_pulse: assert property (p_clear_pulse);

    // Safety: start ignored when busy
    property p_start_ignored_busy;
        @(posedge clk) disable iff (!rst_n)
        (pipeline_busy && reg_start) |=> (pipeline_busy);
    endproperty
    a_start_ignored_busy: assert property (p_start_ignored_busy);

endmodule
