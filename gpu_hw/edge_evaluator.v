module edge_evaluator #(
    parameter WIDTH = 32
)(
    input  wire              clk,
    input  wire              rst_n,
    
    // Initial value from setup
    input  wire [WIDTH-1:0]  e_init,
    input  wire              load_init,  // Pulse from rasterizer_core
    
    // Deltas from setup (constant for this triangle)
    input  wire [WIDTH-1:0]  dX,         // Subtracted when stepping right
    input  wire [WIDTH-1:0]  dY,         // Added when stepping down
    
    // Step commands from rasterizer_core
    input  wire              step_right,
    input  wire              step_down,
    
    // Current edge value
    output reg  [WIDTH-1:0]  e_value,
    
    // Inside test
    output wire              is_inside   // e_value >= 0
);

assign is_inside = ~e_value[WIDTH-1]; // Sign bit check

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        e_value <= {WIDTH{1'b0}};
    end else begin
        if (load_init) begin
            e_value <= e_init;
        end else if (step_right) begin
            e_value <= e_value - dX;  // E += dY for edge function step right
        end else if (step_down) begin
            e_value <= e_value + dY;  // E -= dX for edge function step down
        end
    end
end

endmodule
