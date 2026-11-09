// ad_su_exp_drain -- the drain of the fragment export buffer (spec ad_su_exp_drain.md).
// Per slot: fragment (fl_go), ended (wc_end of a fragment slot), sequence number; cleared at
// the release.  The ended fragment warp whose number is ex_next is drained: per quad with
// coverage (packed from lane 0, at most 8) one beat per attachment of d_rtw (ascending), or
// one d_nocol beat when d_rtw is 0; ex_last on the last beat of the last quad, then xr_valid.
// Vertex and compute warps (no fl_go): xr_valid the cycle after wc_end; the drain's release
// waits a cycle when both fall together.
// IDLE -(candidate)-> FIRST -> DRAIN (one beat per ex_ready) -(last beat)-> RET -> IDLE.
module ad_su_exp_drain #(
    parameter NWARPS = 4,
    parameter WARP_W = 2
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              fl_go,
    input  wire [WARP_W-1:0] fl_slot,
    input  wire [15:0]       fl_seq,
    input  wire              wc_end,
    input  wire [WARP_W-1:0] wc_warp,
    input  wire [31:0]       d_cov,
    input  wire [3:0]        d_rtw,
    output reg  [WARP_W-1:0] d_warp,
    output reg  [2:0]        d_q,
    output reg  [1:0]        d_rt,
    output reg               d_first,
    output wire              d_lastb,
    output wire              d_nocol,
    output wire              ex_valid,
    input  wire              ex_ready,
    output wire [15:0]       ex_seq,
    output wire              ex_last,
    input  wire [15:0]       ex_next,
    output wire              xr_valid,
    output wire [WARP_W-1:0] xr_warp
);
    localparam S_IDLE = 2'd0, S_FIRST = 2'd1, S_DRAIN = 2'd2, S_RET = 2'd3;
    reg [1:0] state;
    reg [NWARPS-1:0] frag, ended;
    reg [15:0] seq [0:NWARPS-1];
    reg vpend;
    reg [WARP_W-1:0] vwarp;

    // candidate: the lowest ended fragment slot whose number is ex_next
    reg cand;
    reg [WARP_W-1:0] cw;
    integer s;
    always @(*) begin
        cand = 1'b0;
        cw = {WARP_W{1'b0}};
        for (s = NWARPS - 1; s >= 0; s = s - 1)
`ifdef MUT_DRAIN_SEQ
            if (frag[s] && ended[s]) begin           // mutation: any ended fragment warp
`else
            if (frag[s] && ended[s] && seq[s] == ex_next) begin
`endif
                cand = 1'b1;
                cw = s[WARP_W-1:0];
            end
    end

    // attachments: the lowest, the next above d_rt
    function [2:0] lowest;              // {none, index}
        input [3:0] m;
        begin
            lowest = m[0] ? 3'd0 : m[1] ? 3'd1 : m[2] ? 3'd2 : m[3] ? 3'd3 : 3'd4;
        end
    endfunction
    wire [3:0] above = d_rtw & ~((4'd2 << d_rt) - 4'd1);   // attachments above d_rt
    wire [2:0] nxt = lowest(above);
    wire [2:0] low = lowest(d_rtw);
    assign d_nocol = (d_rtw == 4'd0);
    assign d_lastb = nxt[2];
    wire [63:0] covx = {32'd0, d_cov};
    wire [3:0] q1 = {1'b0, d_q} + 4'd1;
    wire [3:0] nib = covx[4*q1 +: 4];          // the next quad's coverage (0 after quad 7)
    wire lastq = (nib == 4'd0);

    assign ex_valid = (state == S_DRAIN);
    assign ex_last = ex_valid && lastq && d_lastb;
    assign ex_seq = seq[d_warp];

    wire ret_go = (state == S_RET) && !vpend;
    assign xr_valid = vpend || ret_go;
    assign xr_warp = vpend ? vwarp : d_warp;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            d_warp <= {WARP_W{1'b0}};
            d_q <= 3'd0;
            d_rt <= 2'd0;
            d_first <= 1'b0;
        end else begin
            case (state)
            S_IDLE:
                if (cand) begin
                    d_warp <= cw;
                    state <= S_FIRST;
                end
            S_FIRST: begin
                d_rt <= low[1:0];
                d_q <= 3'd0;
                d_first <= 1'b1;
                state <= S_DRAIN;
            end
            S_DRAIN:
                if (ex_ready) begin
                    if (!d_lastb) begin
                        d_rt <= nxt[1:0];
                        d_first <= 1'b0;
                    end else if (!lastq) begin
                        d_q <= d_q + 3'd1;
                        d_rt <= low[1:0];
                        d_first <= 1'b1;
                    end else begin
                        state <= S_RET;
                    end
                end
            default:
                if (ret_go) state <= S_IDLE;
            endcase
        end
    end

    // per-slot flags, the vertex release
    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            frag <= {NWARPS{1'b0}};
            ended <= {NWARPS{1'b0}};
            vpend <= 1'b0;
            vwarp <= {WARP_W{1'b0}};
            for (k = 0; k < NWARPS; k = k + 1) seq[k] <= 16'd0;
        end else begin
            vpend <= wc_end && !frag[wc_warp];
            if (wc_end) vwarp <= wc_warp;
            if (wc_end && frag[wc_warp]) ended[wc_warp] <= 1'b1;
            if (ret_go) begin
                frag[d_warp] <= 1'b0;
                ended[d_warp] <= 1'b0;
            end
            if (fl_go) begin
                frag[fl_slot] <= 1'b1;
                ended[fl_slot] <= 1'b0;
                seq[fl_slot] <= fl_seq;
            end
        end
    end
endmodule
