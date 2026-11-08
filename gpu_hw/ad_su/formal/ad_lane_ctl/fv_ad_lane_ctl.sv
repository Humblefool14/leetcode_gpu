// fv_ad_lane_ctl: the shfl/vote/ballot sequencer with G = 4 (GRP_W 2).
// The bus (free) holds the last group of a subgroup op while x_ready is 0
// (as ad_su_opd).  Asserted: on the last group x_ready is 0 for exactly G
// cycles and 1 in the next; elsewhere x_ready is 1; the last group is
// staged in its first cycle only (stage_we, go_emit), every other bus group
// of a subgroup op is staged when it passes; group e's result is emitted in
// cycle first + 1 + e, e = 0..G-1, and nothing is emitted otherwise.
module fv_ad_lane_ctl #(parameter G = 4, parameter GRP_W = 2) (
    input wire clk,
    input wire bus_sub_free,
    input wire bus_last_free
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    reg hold = 1'b0;
    reg [3:0] hc = 4'd0;
    wire bus_sub = hold ? 1'b1 : bus_sub_free;
    wire bus_last = hold ? 1'b1 : bus_last_free;
    wire x_ready, stage_we, go_emit, emit;
    wire [GRP_W-1:0] e;
    ad_lane_ctl #(.G(G), .GRP_W(GRP_W)) dut (.clk(clk), .rst_n(rst_n), .bus_sub(bus_sub),
        .bus_last(bus_last), .x_ready(x_ready), .stage_we(stage_we), .go_emit(go_emit),
        .emit(emit), .e(e));
    wire onlast = bus_sub && bus_last;
    always @(posedge clk) begin
        if (init) begin
            hold <= 1'b0;
            hc <= 4'd0;
        end else if (onlast && !x_ready) begin
            hold <= 1'b1;
            if (hc != 4'hF) hc <= hc + 1'b1;
        end else begin
            hold <= 1'b0;
            hc <= 4'd0;
        end
    end
    always @(*) begin
        if (!init) begin
            if (onlast)
                assert (x_ready == (hc == G));
            else
                assert (x_ready);
            assert (stage_we == (bus_sub && hc == 0));
            assert (go_emit == (onlast && hc == 0));
            assert (emit == (onlast && hc >= 1 && hc <= G));
            if (emit)
                assert (e == hc - 1);
        end
    end
endmodule
