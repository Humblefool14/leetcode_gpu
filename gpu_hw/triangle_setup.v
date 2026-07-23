module triangle_setup #(
    parameter WIDTH = 32  // Fixed-point width (e.g., 16.16)
)(
    input  wire              clk,
    input  wire              rst_n,
    
    // From Host Interface
    input  wire              start,
    input  wire [WIDTH-1:0]  v0_x, v0_y,
    input  wire [WIDTH-1:0]  v1_x, v1_y,
    input  wire [WIDTH-1:0]  v2_x, v2_y,
    
    // To Rasterizer Core
    output reg               setup_done,
    output reg  [WIDTH-1:0]  x_min, x_max,
    output reg  [WIDTH-1:0]  y_min, y_max,
    output reg  [WIDTH-1:0]  e0_init, e1_init, e2_init,
    output reg  [WIDTH-1:0]  dX0, dY0,
    output reg  [WIDTH-1:0]  dX1, dY1,
    output reg  [WIDTH-1:0]  dX2, dY2
);

// State machine
localparam IDLE  = 2'd0;
localparam CALC  = 2'd1;
localparam DONE  = 2'd2;

reg [1:0] state;

// Internal signals
wire [WIDTH-1:0] dx0 = v1_x - v0_x;
wire [WIDTH-1:0] dy0 = v1_y - v0_y;
wire [WIDTH-1:0] dx1 = v2_x - v1_x;
wire [WIDTH-1:0] dy1 = v2_y - v1_y;
wire [WIDTH-1:0] dx2 = v0_x - v2_x;
wire [WIDTH-1:0] dy2 = v0_y - v2_y;

// Bounding box (integer portion only for screen coords)
// Assuming lower 16 bits are fractional
wire [WIDTH-1:0] x_min_tmp = (v0_x < v1_x) ? ((v0_x < v2_x) ? v0_x : v2_x) : ((v1_x < v2_x) ? v1_x : v2_x);
wire [WIDTH-1:0] x_max_tmp = (v0_x > v1_x) ? ((v0_x > v2_x) ? v0_x : v2_x) : ((v1_x > v2_x) ? v1_x : v2_x);
wire [WIDTH-1:0] y_min_tmp = (v0_y < v1_y) ? ((v0_y < v2_y) ? v0_y : v2_y) : ((v1_y < v2_y) ? v1_y : v2_y);
wire [WIDTH-1:0] y_max_tmp = (v0_y > v1_y) ? ((v0_y > v2_y) ? v0_y : v2_y) : ((v1_y > v2_y) ? v1_y : v2_y);

// Edge function at (x_min, y_min)
// E(x,y) = (x - Xi) * dY - (y - Yi) * dX
// E(x_min, y_min) for edge 0 (v0 to v1):
// = (x_min - v0_x) * dy0 - (y_min - v0_y) * dx0

// Pipelined multiplication - one cycle
reg [2*WIDTH-1:0] mul0_a, mul0_b, mul1_a, mul1_b, mul2_a, mul2_b;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE;
        setup_done <= 1'b0;
    end else begin
        setup_done <= 1'b0;
        
        case (state)
            IDLE: begin
                if (start) begin
                    state <= CALC;
                    // Latch inputs
                    dX0 <= dx0; dY0 <= dy0;
                    dX1 <= dx1; dY1 <= dy1;
                    dX2 <= dx2; dY2 <= dy2;
                    x_min <= x_min_tmp;
                    x_max <= x_max_tmp;
                    y_min <= y_min_tmp;
                    y_max <= y_max_tmp;
                    
                    // Setup multiplies for edge init
                    mul0_a <= (x_min_tmp - v0_x) * dy0;
                    mul0_b <= (y_min_tmp - v0_y) * dx0;
                    mul1_a <= (x_min_tmp - v1_x) * dy1;
                    mul1_b <= (y_min_tmp - v1_y) * dx1;
                    mul2_a <= (x_min_tmp - v2_x) * dy2;
                    mul2_b <= (y_min_tmp - v2_y) * dx2;
                end
            end
            
            CALC: begin
                // Multiplication results ready
                e0_init <= mul0_a - mul0_b;
                e1_init <= mul1_a - mul1_b;
                e2_init <= mul2_a - mul2_b;
                state <= DONE;
            end
            
            DONE: begin
                setup_done <= 1'b1;
                state <= IDLE;
            end
        endcase
    end
end

endmodule
