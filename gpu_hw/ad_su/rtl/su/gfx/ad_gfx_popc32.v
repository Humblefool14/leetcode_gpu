// ad_gfx_popc32 -- the number of ones of a 32-bit word (the lanes returned at vl_go,
// ad_gfx_pt_alloc), as a tree of adders.
module ad_gfx_popc32 (
    input  wire [31:0] m,
    output wire [5:0]  n
);
    wire [1:0] s1 [0:15];
    wire [2:0] s2 [0:7];
    wire [3:0] s3 [0:3];
    wire [4:0] s4 [0:1];
    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : l1
            assign s1[i] = {1'b0, m[2*i]} + {1'b0, m[2*i+1]};
        end
        for (i = 0; i < 8; i = i + 1) begin : l2
            assign s2[i] = {1'b0, s1[2*i]} + {1'b0, s1[2*i+1]};
        end
        for (i = 0; i < 4; i = i + 1) begin : l3
            assign s3[i] = {1'b0, s2[2*i]} + {1'b0, s2[2*i+1]};
        end
        for (i = 0; i < 2; i = i + 1) begin : l4
            assign s4[i] = {1'b0, s3[2*i]} + {1'b0, s3[2*i+1]};
        end
    endgenerate
    assign n = {1'b0, s4[0]} + {1'b0, s4[1]};
endmodule
