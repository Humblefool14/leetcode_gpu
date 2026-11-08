// fv_ad_ctl_wsel -- the fetch selector picks a candidate only; GTO: the
// greedy warp when it is a candidate, else a candidate of the largest age
// (lowest index on a tie); round-robin: the first candidate after last.
module fv_ad_ctl_wsel (input wire clk);
    (* anyconst *) reg [3:0] cand;
    (* anyconst *) reg gv;
    (* anyconst *) reg [1:0] gw, last;
    (* anyconst *) reg [15:0] age;      // 4 bits each
    wire v1, v0; wire [1:0] w1, w0;
    ad_ctl_wsel #(.NWARPS(4), .WARP_W(2), .AGE_W(4), .GTO(1)) g (.cand(cand), .gv(gv), .gw(gw), .age(age), .last(last), .sel_v(v1), .sel_w(w1));
    ad_ctl_wsel #(.NWARPS(4), .WARP_W(2), .AGE_W(4), .GTO(0)) r (.cand(cand), .gv(gv), .gw(gw), .age(age), .last(last), .sel_v(v0), .sel_w(w0));
    integer i;
    always @(*) begin
        a_v: assert (v1 == (cand != 0) && v0 == (cand != 0));
        if (cand != 0) begin
            a_c1: assert (cand[w1]);
            a_c0: assert (cand[w0]);
            if (gv && cand[gw]) a_greedy: assert (w1 == gw);
            else for (i = 0; i < 4; i = i + 1) begin
                if (cand[i]) assert (age[4*w1 +: 4] >= age[4*i +: 4]);
                if (cand[i] && age[4*i +: 4] == age[4*w1 +: 4]) assert (w1 <= i);
            end
            // round-robin: the pick is the nearest candidate after last (distance 1..4)
            for (i = 0; i < 4; i = i + 1)
                if (cand[i]) assert ((((w0 - last - 1) & 3) + 1) <= (((i - last - 1) & 3) + 1));
        end
    end
endmodule
