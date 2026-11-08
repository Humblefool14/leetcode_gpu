// fv_ad_core_rr_pick -- ad_su_rr_pick (N 6 and N 3): gnt one-hot and inside req, any =
// |req, idx = the granted index, and no request between ptr and the grant (wrapping).
module fv_ad_core_rr_pick (input wire clk);
    (* anyconst *) reg [5:0] req; (* anyconst *) reg [2:0] ptr;
    (* anyconst *) reg [2:0] req3; (* anyconst *) reg [1:0] ptr3;
    wire [5:0] gnt; wire [2:0] idx; wire any; wire [2:0] gnt3; wire [1:0] idx3; wire any3;
    ad_su_rr_pick #(.N(6)) d6 (.req(req), .ptr(ptr), .gnt(gnt), .idx(idx), .any(any));
    ad_su_rr_pick #(.N(3)) d3 (.req(req3), .ptr(ptr3), .gnt(gnt3), .idx(idx3), .any(any3));
    integer k, j;
    always @(*) begin
        assume (ptr < 6); assume (ptr3 < 3);
        assert (any == |req && any3 == |req3);
        assert ((gnt & (gnt - 1)) == 0 && (gnt & ~req) == 0 && (gnt != 0) == any);
        assert ((gnt3 & (gnt3 - 1)) == 0 && (gnt3 & ~req3) == 0 && (gnt3 != 0) == any3);
        if (any) begin
            assert ((gnt >> idx) & 1);
            for (k = 0; k < 6; k = k + 1) begin   // k steps after ptr, before the grant: no request
                j = (ptr + k) % 6;
                if (((idx + 6 - ptr) % 6) > k) assert (((req >> j) & 1) == 0);
            end
        end
        if (any3) begin
            assert ((gnt3 >> idx3) & 1);
            for (k = 0; k < 3; k = k + 1) begin
                j = (ptr3 + k) % 3;
                if (((idx3 + 3 - ptr3) % 3) > k) assert (((req3 >> j) & 1) == 0);
            end
        end
    end
endmodule
