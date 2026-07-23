module framebuffer_controller #(
    parameter DATA_WIDTH = 24,  // RGB888
    parameter ADDR_WIDTH = 19,  // 640*480 = 307,200 addresses
    parameter SCREEN_W   = 640,
    parameter SCREEN_H   = 480
)(
    input  wire                  clk,
    input  wire                  rst_n,
    
    // Port A: Write (from Rasterizer)
    input  wire                  wr_en,
    input  wire [ADDR_WIDTH-1:0] wr_addr,
    input  wire [DATA_WIDTH-1:0] wr_data,
    
    // Port B: Read (from Display Controller)
    input  wire [ADDR_WIDTH-1:0] rd_addr,
    output reg  [DATA_WIDTH-1:0] rd_data
);

// Infer dual-port BRAM
// Xilinx/Intel tools will map this to Block RAM automatically
reg [DATA_WIDTH-1:0] mem [0:(SCREEN_W*SCREEN_H)-1];

// Port A: Synchronous Write
always @(posedge clk) begin
    if (wr_en) begin
        mem[wr_addr] <= wr_data;
    end
end

// Port B: Synchronous Read
always @(posedge clk) begin
    rd_data <= mem[rd_addr];
end

endmodule
