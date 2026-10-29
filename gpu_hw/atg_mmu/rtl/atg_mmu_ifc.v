// ============================================================================
// atg_mmu_ifc -- in-flight transaction tracker, two epochs per client
// ----------------------------------------------------------------------------
// Every successful translation handed to a client is one memory transaction
// "in flight" until the client pulses cmp with the epoch it was given.
// Counts are thermometer codes (shift in a 1 / shift out a 1), so the tracker
// needs no adders: zero = ~cnt[0], "nearly full" = cnt[OSD-2].
//   ful[c]  : client c may not start another request (one slot of margin,
//             because a request accepted now is counted one cycle later).
//   obz     : some transaction of the *old* epoch (~epo) is still in flight.
//             After a TLB flush the epoch flips; the CP waits for obz = 0.
//   nzr[c]  : client c has anything in flight (STATUS register, debug).
// ============================================================================
`include "atg_mmu_pkg.vh"
module atg_mmu_ifc #(
    parameter NCL = `AMU_NCL,
    parameter OSD = `AMU_OSD
) (
    input  wire           clk,
    input  wire           rst_n,
    input  wire           epo,       // current epoch
    input  wire [NCL-1:0] inc,       // translation delivered (counted in epoch epo)
    input  wire [NCL-1:0] cmp,       // transaction completed
    input  wire [NCL-1:0] cmp_epo,   // epoch that completed transaction was issued in
    output reg  [NCL-1:0] ful,
    output reg  [NCL-1:0] nzr,
    output reg            obz
`ifdef FORMAL
   ,output reg  [NCL-1:0] f_top           // formal-only: current-epoch count == OSD
`endif
);
    reg [OSD-1:0] ct0 [0:NCL-1];     // epoch 0 thermometer
    reg [OSD-1:0] ct1 [0:NCL-1];     // epoch 1 thermometer

    integer c;
    reg     up0, dn0, up1, dn1;
    always @(posedge clk) begin
        for (c = 0; c < NCL; c = c + 1) begin
            up0 = inc[c] & ~epo;
            up1 = inc[c] &  epo;
            dn0 = cmp[c] & ~cmp_epo[c];
            dn1 = cmp[c] &  cmp_epo[c];
            if (!rst_n) begin
                ct0[c] <= {OSD{1'b0}};
                ct1[c] <= {OSD{1'b0}};
            end else begin
                if (up0 & ~dn0) ct0[c] <= {ct0[c][OSD-2:0], 1'b1};
                if (dn0 & ~up0) ct0[c] <= {1'b0, ct0[c][OSD-1:1]};
                if (up1 & ~dn1) ct1[c] <= {ct1[c][OSD-2:0], 1'b1};
                if (dn1 & ~up1) ct1[c] <= {1'b0, ct1[c][OSD-1:1]};
            end
        end
    end

    integer n;
    always @(*) begin
        obz = 1'b0;
        for (n = 0; n < NCL; n = n + 1) begin
            ful[n] = epo ? ct1[n][OSD-2] : ct0[n][OSD-2];
            nzr[n] = ct0[n][0] | ct1[n][0];
            obz    = obz | (epo ? ct0[n][0] : ct1[n][0]);
        end
    end

`ifdef FORMAL
    // Reference model: plain integer counts per client and epoch.
    reg f_pv = 1'b0;
    always @(posedge clk) f_pv <= 1'b1;
    reg [7:0] f_s0 [0:NCL-1];
    reg [7:0] f_s1 [0:NCL-1];
    integer f, g, h;
    always @(posedge clk)
        for (g = 0; g < NCL; g = g + 1)
            if (!rst_n) begin
                f_s0[g] <= 0; f_s1[g] <= 0;
            end else begin
                f_s0[g] <= f_s0[g] + (inc[g] & ~epo) - (cmp[g] & ~cmp_epo[g]);
                f_s1[g] <= f_s1[g] + (inc[g] &  epo) - (cmp[g] &  cmp_epo[g]);
            end
    always @(*)
        for (f = 0; f < NCL; f = f + 1)
            if (f_pv && rst_n) begin
                // usage rules: never complete what is not in flight, never
                // exceed OSD (environment standalone, checked inside atg_mmu)
                // cmp comes from the clients (top-level inputs) in every
                // context, so "complete only what is in flight" is always an
                // environment rule; inc comes from the L1s and is checked.
                assume (!cmp[f] || (cmp_epo[f] ? f_s1[f] : f_s0[f]) != 0);
`ifdef AMU_FVI
                assume (!inc[f] || (epo ? f_s1[f] : f_s0[f]) < OSD);
`else
                assert (!inc[f] || (epo ? f_s1[f] : f_s0[f]) < OSD);
`endif
                assert (f_s0[f] <= OSD && f_s1[f] <= OSD);
                assert (ct0[f] == ({OSD{1'b1}} >> (OSD - f_s0[f])) || (f_s0[f] == 0 && ct0[f] == 0));
                assert (ct1[f] == ({OSD{1'b1}} >> (OSD - f_s1[f])) || (f_s1[f] == 0 && ct1[f] == 0));
                assert (ful[f] == ((epo ? f_s1[f] : f_s0[f]) >= OSD - 1));
                assert (nzr[f] == (f_s0[f] != 0 || f_s1[f] != 0));
            end
    always @(*)
        for (f = 0; f < NCL; f = f + 1)
            f_top[f] = (epo ? f_s1[f] : f_s0[f]) == OSD;
    reg f_ob;
    always @(*) begin
        f_ob = 1'b0;
        for (h = 0; h < NCL; h = h + 1) f_ob = f_ob | ((epo ? f_s0[h] : f_s1[h]) != 0);
        if (f_pv && rst_n) assert (obz == f_ob);
    end
`endif
endmodule
