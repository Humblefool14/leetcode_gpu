// fv_ad_lane_qd: quad partner selection, NPHYS 8, the subtract replaced by
// ad_lane_fsub_stub (a non-commutative function; the subtract is checked bit
// for bit in simulation): lane l of a quad gets qdx = f(v[l|1], v[l&~1]),
// qdy = f(v[l|2], v[l&~2]), qswap1/2/3 = v[l^1/2/3], qbcast = v[l&~3].
module fv_ad_lane_qd #(parameter NPHYS = 8);
    (* anyconst *) reg [4:0] sub;
    (* anyconst *) reg [NPHYS*32-1:0] v;
    always @(*) assume (sub <= 5'd5);
    wire [NPHYS*32-1:0] y;
    ad_lane_qd #(.NPHYS(NPHYS)) dut (.sub(sub), .v(v), .y(y));
    genvar l;
    generate
    for (l = 0; l < NPHYS; l = l + 1) begin : g_l
        wire [31:0] fx, fy;
        ad_lane_fsub rx (.a(v[(l | 1)*32 +: 32]), .b(v[(l & ~1)*32 +: 32]), .y(fx));
        ad_lane_fsub ry (.a(v[(l | 2)*32 +: 32]), .b(v[(l & ~2)*32 +: 32]), .y(fy));
        reg [31:0] want;
        always @(*) begin
            case (sub)
            5'd0: want = fx;
            5'd1: want = fy;
            5'd2: want = v[(l ^ 1)*32 +: 32];
            5'd3: want = v[(l ^ 2)*32 +: 32];
            5'd4: want = v[(l ^ 3)*32 +: 32];
            default: want = v[(l & ~3)*32 +: 32];
            endcase
            assert (y[l*32 +: 32] == want);
        end
    end
    endgenerate
endmodule
