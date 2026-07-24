module host_interface #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 8
)(
    input  wire                  clk,
    input  wire                  rst_n,
    
    // UART Interface
    input  wire                  uart_rx,
    output wire                  uart_tx,
    input  wire                  uart_rx_valid,
    input  wire [DATA_WIDTH-1:0] uart_rx_data,
    
    // Control Outputs to Pipeline
    output reg                   reg_start,
    output reg  [DATA_WIDTH-1:0] reg_v0_x, reg_v0_y,
    output reg  [DATA_WIDTH-1:0] reg_v1_x, reg_v1_y,
    output reg  [DATA_WIDTH-1:0] reg_v2_x, reg_v2_y,
    output reg  [DATA_WIDTH-1:0] reg_color,
    
    // Status Input from Pipeline
    input  wire                  pipeline_busy,
    output reg  [DATA_WIDTH-1:0] reg_status
);

// Register Map (byte addresses)
localparam REG_START  = 8'h00;
localparam REG_STATUS = 8'h04;
localparam REG_V0_X   = 8'h08;
localparam REG_V0_Y   = 8'h0C;
localparam REG_V1_X   = 8'h10;
localparam REG_V1_Y   = 8'h14;
localparam REG_V2_X   = 8'h18;
localparam REG_V2_Y   = 8'h1C;
localparam REG_COLOR  = 8'h20;

// Simple UART command decoder
// Format: [ADDR (1 byte)] [DATA (4 bytes)]
// Write-only for now

reg [ADDR_WIDTH-1:0] rx_addr;
reg [2:0]            rx_byte_cnt;
reg [DATA_WIDTH-1:0] rx_shift_reg;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        reg_start  <= 1'b0;
        reg_v0_x   <= 32'd0; reg_v0_y <= 32'd0;
        reg_v1_x   <= 32'd0; reg_v1_y <= 32'd0;
        reg_v2_x   <= 32'd0; reg_v2_y <= 32'd0;
        reg_color  <= 32'd0;
        reg_status <= 32'd0;
        rx_byte_cnt <= 3'd0;
    end else begin
        reg_start <= 1'b0; // Pulse for one cycle
        
        if (uart_rx_valid) begin
            if (rx_byte_cnt == 3'd0) begin
                rx_addr <= uart_rx_data[ADDR_WIDTH-1:0];
                rx_byte_cnt <= rx_byte_cnt + 1'b1;
            end else begin
                rx_shift_reg <= {uart_rx_data, rx_shift_reg[DATA_WIDTH-1:8]};
                if (rx_byte_cnt == 3'd4) begin
                    rx_byte_cnt <= 3'd0;
                    // Write to register
                    case (rx_addr)
                        REG_START: reg_start <= 1'b1;
                        REG_V0_X:  reg_v0_x  <= {uart_rx_data, rx_shift_reg[DATA_WIDTH-1:8]};
                        REG_V0_Y:  reg_v0_y  <= {uart_rx_data, rx_shift_reg[DATA_WIDTH-1:8]};
                        REG_V1_X:  reg_v1_x  <= {uart_rx_data, rx_shift_reg[DATA_WIDTH-1:8]};
                        REG_V1_Y:  reg_v1_y  <= {uart_rx_data, rx_shift_reg[DATA_WIDTH-1:8]};
                        REG_V2_X:  reg_v2_x  <= {uart_rx_data, rx_shift_reg[DATA_WIDTH-1:8]};
                        REG_V2_Y:  reg_v2_y  <= {uart_rx_data, rx_shift_reg[DATA_WIDTH-1:8]};
                        REG_COLOR: reg_color <= {uart_rx_data, rx_shift_reg[DATA_WIDTH-1:8]};
                    endcase
                end else begin
                    rx_byte_cnt <= rx_byte_cnt + 1'b1;
                end
            end
        end
        
        reg_status <= {31'd0, pipeline_busy};
    end
end

endmodule
