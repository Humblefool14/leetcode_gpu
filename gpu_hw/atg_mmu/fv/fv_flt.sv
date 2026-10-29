// Formal harness: atg_mmu_flt (3 clients, small widths) against a reference model.
module fv_flt (input clk, input rst_n, input [2:0] f_vld, input [11:0] f_knd, input [35:0] f_syn,
               input [5:0] f_sid, input [5:0] f_stg, input [23:0] f_va, input clr);
    localparam NCL = 3, GVW = 8, SIW = 2, STW = 2, FKW = 4, SYW = 12;
    wire vld, ovf; wire [3:0] knd, unt; wire [1:0] sid, stg; wire [11:0] syn; wire [7:0] va;
    atg_mmu_flt #(.NCL(NCL), .GVW(GVW), .SIW(SIW), .STW(STW), .FKW(FKW), .SYW(SYW), .UMP(12'h210)) dut (
        .clk(clk), .rst_n(rst_n), .f_vld(f_vld), .f_knd(f_knd), .f_syn(f_syn), .f_sid(f_sid),
        .f_stg(f_stg), .f_va(f_va), .clr(clr), .vld(vld), .ovf(ovf), .knd(knd), .unt(unt),
        .sid(sid), .stg(stg), .syn(syn), .va(va));

    reg f_pv = 0;
    always @(posedge clk) f_pv <= 1;
    always @(*) if (!f_pv) assume (!rst_n);

    // reference: lowest index wins
    wire [1:0] w = f_vld[0] ? 2'd0 : (f_vld[1] ? 2'd1 : 2'd2);
    wire       any = |f_vld;
    wire       two = (f_vld[0] && f_vld[1]) || (f_vld[0] && f_vld[2]) || (f_vld[1] && f_vld[2]);

    always @(posedge clk) if (f_pv && rst_n && $past(rst_n)) begin
        // capture when free (or freed this cycle)
        if ($past(any) && (!$past(vld) || $past(clr))) begin
            assert (vld);
            assert (knd == $past(f_knd >> (4 * w)) % 16);
            assert (syn == $past(f_syn >> (12 * w)) % 4096);
            assert (va  == $past(f_va  >> (8 * w)) % 256);
            assert (sid == $past(f_sid >> (2 * w)) % 4);
            assert (unt == $past(w));
        end
        // hold until cleared
        if ($past(vld) && !$past(clr)) begin
            assert (vld);
            assert (knd == $past(knd) && syn == $past(syn) && va == $past(va) && sid == $past(sid) && unt == $past(unt));
        end
        // clear without a new fault empties the latch
        if ($past(clr) && !$past(any)) assert (!vld && !ovf);
        // overflow: a fault was dropped
        if ($past(two) || ($past(any) && $past(vld) && !$past(clr))) assert (ovf);
        if (!$past(vld) && !$past(any)) assert (!vld);
    end
    always @(*) if (rst_n) begin
        cover (vld && unt == 2);
        cover (vld && ovf);
    end
endmodule
