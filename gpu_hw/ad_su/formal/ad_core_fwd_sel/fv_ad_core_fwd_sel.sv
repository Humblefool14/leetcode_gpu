// fv_ad_core_fwd_sel -- ad_su_fwd_sel (NPHYS 2, 2-bit words): per lane the output is
// the word of the first matching writer in the order ALU EX4, FPU EX4, ALU EX5, FPU
// EX5, WB, bypass whose lane bit is set, else the RF word; a writer matches only when
// valid, same warp and group, rd == {0, reg} and rd < 63; en 0 passes the RF word.
module fv_ad_core_fwd_sel (input wire clk);
    localparam N = 2, LW = 2;
    (* anyconst *) reg en; (* anyconst *) reg [1:0] warp; (* anyconst *) reg grp; (* anyconst *) reg [5:0] rn;
    (* anyconst *) reg [N*LW-1:0] base; (* anyconst *) reg [5:0] fv; (* anyconst *) reg [11:0] fw;
    (* anyconst *) reg [5:0] fg; (* anyconst *) reg [41:0] fr; (* anyconst *) reg [6*N*LW-1:0] fd; (* anyconst *) reg [6*N-1:0] fl;
    wire [N*LW-1:0] out; wire [5:0] match;
    ad_su_fwd_sel #(.NPHYS(N), .WARP_W(2), .GRP_W(1), .LW(LW)) dut (.en(en), .warp(warp), .grp(grp), .reg_n(rn),
        .base(base), .f_valid(fv), .f_warp(fw), .f_grp(fg), .f_rd(fr), .f_data(fd), .f_lanes(fl), .out(out), .match(match));
    integer k, i; reg [LW-1:0] e; reg hit; reg mk;
    always @(*) begin
        for (k = 0; k < 6; k = k + 1) begin
            mk = en && fv[k] && fw[2*k +: 2] == warp && fg[k] == grp && fr[7*k +: 7] == {1'b0, rn} && rn != 6'd63;
            assert (match[k] == mk);
        end
        for (i = 0; i < N; i = i + 1) begin
            hit = 0; e = base[LW*i +: LW];
            for (k = 0; k < 6; k = k + 1)
                if (!hit && match[k] && fl[N*k + i]) begin hit = 1; e = fd[N*LW*k + LW*i +: LW]; end
            assert (out[LW*i +: LW] == e);
        end
    end
endmodule
