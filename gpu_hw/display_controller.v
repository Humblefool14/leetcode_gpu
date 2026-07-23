module display_controller #(
    parameter H_ACTIVE   = 640,
    parameter H_FRONT    = 16,
    parameter H_SYNC     = 96,
    parameter H_BACK     = 48,
    parameter H_TOTAL    = 800,
    
    parameter V_ACTIVE   = 480,
    parameter V_FRONT    = 10,
    parameter V_SYNC     = 2,
    parameter V_BACK     = 33,
    parameter V_TOTAL    = 525,
    
    parameter ADDR_WIDTH = 19,
    parameter DATA_WIDTH = 24
)(
    input  wire                  clk,        // 25.175 MHz
    input  wire                  rst_n,
    
    // To Framebuffer
    output reg  [ADDR_WIDTH-1:0] fb_addr,
    input  wire [DATA_WIDTH-1:0] fb_data,
    
    // VGA Output
    output reg  [7:0]            vga_r,
    output reg  [7:0]            vga_g,
    output reg  [7:0]            vga_b,
    output reg                   vga_hsync,
    output reg                   vga_vsync,
    output reg                   vga_de      // Data enable
);

// Counters
reg [9:0] h_count;
reg [9:0] v_count;

wire h_active = (h_count < H_ACTIVE);
wire v_active = (v_count < V_ACTIVE);
wire pixel_active = h_active & v_active;

// Horizontal counter
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        h_count <= 10'd0;
    end else begin
        if (h_count == H_TOTAL - 1)
            h_count <= 10'd0;
        else
            h_count <= h_count + 1'b1;
    end
end

// Vertical counter
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        v_count <= 10'd0;
    end else begin
        if (h_count == H_TOTAL - 1) begin
            if (v_count == V_TOTAL - 1)
                v_count <= 10'd0;
            else
                v_count <= v_count + 1'b1;
        end
    end
end

// Framebuffer address generation
always @(posedge clk) begin
    if (pixel_active) begin
        fb_addr <= v_count * H_ACTIVE + h_count;
    end
end

// VGA signals (registered for clean timing)
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        vga_hsync <= 1'b1;
        vga_vsync <= 1'b1;
        vga_de    <= 1'b0;
        vga_r     <= 8'd0;
        vga_g     <= 8'd0;
        vga_b     <= 8'd0;
    end else begin
        // HSYNC: active low during sync pulse
        vga_hsync <= ~((h_count >= H_ACTIVE + H_FRONT) && 
                       (h_count < H_ACTIVE + H_FRONT + H_SYNC));
        
        // VSYNC: active low during sync pulse
        vga_vsync <= ~((v_count >= V_ACTIVE + V_FRONT) && 
                       (v_count < V_ACTIVE + V_FRONT + V_SYNC));
        
        // Data enable
        vga_de <= pixel_active;
        
        // RGB output (delayed to match fb_data latency)
        if (pixel_active) begin
            vga_r <= fb_data[23:16];
            vga_g <= fb_data[15:8];
            vga_b <= fb_data[7:0];
        end else begin
            vga_r <= 8'd0;
            vga_g <= 8'd0;
            vga_b <= 8'd0;
        end
    end
end

endmodule
