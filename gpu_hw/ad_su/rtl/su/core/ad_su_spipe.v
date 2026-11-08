// ad_su_spipe -- the short-result delay line of a short unit (leaf of ad_su_alu,
// also used by the FPU stub).  Stage 1 registers the unit's combinational result;
// stage N drives s_*.  The forwarding taps fw4_* / fw5_* are stages N-2 / N-1
// (they deliver s_* 2 and 1 cycles later), valid only for rd < 63.
// Only the valid bits are reset (the rest is datapath qualified by them).
module ad_su_spipe #(
    parameter NPHYS  = 8,
    parameter WARP_W = 2,
    parameter GRP_W  = 2,
    parameter N      = 6            // SHORT_LAT, at least 3
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  in_valid,
    input  wire [WARP_W-1:0]     in_warp,
    input  wire [GRP_W-1:0]      in_grp,
    input  wire [6:0]            in_rd,
    input  wire [NPHYS*32-1:0]   in_data,
    input  wire [NPHYS-1:0]      in_lanes,
    output wire                  s_valid,
    output wire [WARP_W-1:0]     s_warp,
    output wire [GRP_W-1:0]      s_grp,
    output wire [6:0]            s_rd,
    output wire [NPHYS*32-1:0]   s_data,
    output wire [NPHYS-1:0]      s_lanes,
    output wire                  fw4_valid,
    output wire [WARP_W-1:0]     fw4_warp,
    output wire [GRP_W-1:0]      fw4_grp,
    output wire [6:0]            fw4_rd,
    output wire [NPHYS*32-1:0]   fw4_data,
    output wire [NPHYS-1:0]      fw4_lanes,
    output wire                  fw5_valid,
    output wire [WARP_W-1:0]     fw5_warp,
    output wire [GRP_W-1:0]      fw5_grp,
    output wire [6:0]            fw5_rd,
    output wire [NPHYS*32-1:0]   fw5_data,
    output wire [NPHYS-1:0]      fw5_lanes
);
    localparam W = WARP_W + GRP_W + 7 + NPHYS*32 + NPHYS;
    reg [N-1:0] v;
    reg [W-1:0] p [0:N-1];
    integer k;
    always @(posedge clk) begin
        if (!rst_n) v <= {N{1'b0}};
        else        v <= {v[N-2:0], in_valid};
        p[0] <= {in_warp, in_grp, in_rd, in_data, in_lanes};
        for (k = 1; k < N; k = k + 1) p[k] <= p[k-1];
    end
    wire [W-1:0] pn = p[N-1], p4 = p[N-3], p5 = p[N-2];
    assign s_valid = v[N-1];
    assign {s_warp, s_grp, s_rd, s_data, s_lanes} = pn;
    assign {fw4_warp, fw4_grp, fw4_rd, fw4_data, fw4_lanes} = p4;
    assign {fw5_warp, fw5_grp, fw5_rd, fw5_data, fw5_lanes} = p5;
    assign fw4_valid = v[N-3] && fw4_rd < 7'd63;
    assign fw5_valid = v[N-2] && fw5_rd < 7'd63;
endmodule
