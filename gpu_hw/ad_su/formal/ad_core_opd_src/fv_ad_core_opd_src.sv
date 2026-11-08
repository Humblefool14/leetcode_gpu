// fv_ad_core_opd_src -- ad_su_opd_src (NPHYS 2, WARP_BASE 4): every operand number
// against the table of tools/gsi1model.py opv() / design §3.2 (GPR, rq, c0-c31, the
// specials from q_info / q_exec / q_killed, 0 for 110, 111, 113, 120-127).
module fv_ad_core_opd_src (input wire clk);
    localparam N = 2;
    (* anyconst *) reg [6:0] n; (* anyconst *) reg [63:0] gpr, rq; (* anyconst *) reg [31:0] cw;
    (* anyconst *) reg [1:0] warp; (* anyconst *) reg [3:0] grp; (* anyconst *) reg [159:0] qi;
    (* anyconst *) reg [31:0] qe, qk;
    wire [63:0] v;
    ad_su_opd_src #(.NPHYS(N), .WARP_W(2), .GRP_W(4), .WARP_BASE(4)) dut (.n(n), .gpr(gpr), .rq(rq), .cw(cw),
        .warp(warp), .grp(grp), .q_info(qi), .q_exec(qe), .q_killed(qk), .v(v));
    integer i; reg [31:0] e; reg [4:0] ln;
    always @(*) begin
        assume (grp < 16);
        for (i = 0; i < N; i = i + 1) begin
            ln = grp * 2 + i;
            if (n < 63) e = gpr[32*i +: 32];
            else if (n == 63) e = rq[32*i +: 32];
            else if (n < 96) e = cw;
            else case (n)
                96: e = 0; 97: e = 32'h3F800000; 98: e = 1; 99: e = 32'h3F000000; 100: e = 32'h40000000;
                101: e = 32'hBF800000; 102: e = ln; 103: e = 4 + warp; 104: e = qe; 105: e = qk[ln] ? 32'hFFFFFFFF : 0;
                106: e = qi[15:0]; 107: e = qi[31:16]; 108: e = qi[47:32]; 109: e = qi[103:96] + ln;
                112: e = qi[103:96] + ln; 114: e = qi[106] ? 32'hFFFFFFFF : 0;
                115: e = qi[63:48]; 116: e = qi[79:64]; 117: e = qi[95:80]; 118: e = 32'h3C003C00; 119: e = qi[159:128];
                default: e = 0;
            endcase
            assert (v[32*i +: 32] == e);
        end
    end
endmodule
