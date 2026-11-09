// fv_ad_su_exp_drain -- ad_su_exp_drain (NWARPS 4).  The harness keeps each slot's life: free
// -> running (fl_go: fragment, or the free input vstart: a vertex/compute warp) -> ended (wc_end)
// -> free (xr_valid).  Assumed: fl_go and vstart only for a free slot, wc_end only for a running
// one, ex_next steps only when a beat with ex_last is taken; the drained warp's coverage and
// attachments (d_cov, d_rtw) are per-slot constants.  Properties: beats only for an ended
// fragment warp whose sequence number is ex_next (the slot d_warp); ex_* and d_* stable while
// ex_valid && !ex_ready; a beat's attachment is in d_rtw (nocol exactly when d_rtw is 0);
// exactly one ex_last per fragment warp before its release; xr_valid only for an ended warp
// (so at most once per end), and for a vertex/compute warp exactly the cycle after its wc_end.
module fv_ad_su_exp_drain (
    input wire clk,
    input wire rst_n,
    input wire fl_go,
    input wire [1:0] fl_slot,
    input wire [15:0] fl_seq,
    input wire vstart,
    input wire [1:0] vslot,
    input wire wc_end,
    input wire [1:0] wc_warp,
    input wire ex_ready,
    input wire [15:0] ex_next
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n); else assume (rst_n);

    (* anyconst *) reg [31:0] cov0, cov1, cov2, cov3;
    (* anyconst *) reg [3:0] rtw0, rtw1, rtw2, rtw3;
    wire [1:0] d_warp;
    wire [2:0] d_q;
    wire [1:0] d_rt;
    wire d_first, d_lastb, d_nocol, ex_valid, ex_last, xr_valid;
    wire [15:0] ex_seq;
    wire [1:0] xr_warp;
    wire [31:0] d_cov = (d_warp == 2'd0) ? cov0 : (d_warp == 2'd1) ? cov1 :
                        (d_warp == 2'd2) ? cov2 : cov3;
    wire [3:0] d_rtw = (d_warp == 2'd0) ? rtw0 : (d_warp == 2'd1) ? rtw1 :
                       (d_warp == 2'd2) ? rtw2 : rtw3;
    ad_su_exp_drain #(.NWARPS(4), .WARP_W(2)) dut (
        .clk(clk), .rst_n(rst_n), .fl_go(fl_go), .fl_slot(fl_slot), .fl_seq(fl_seq),
        .wc_end(wc_end), .wc_warp(wc_warp), .d_cov(d_cov), .d_rtw(d_rtw), .d_warp(d_warp),
        .d_q(d_q), .d_rt(d_rt), .d_first(d_first), .d_lastb(d_lastb), .d_nocol(d_nocol),
        .ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_last(ex_last),
        .ex_next(ex_next), .xr_valid(xr_valid), .xr_warp(xr_warp));

    // slot life: 0 free, 1 running, 2 ended
    reg [1:0] st [0:3];
    reg [3:0] frag;
    reg [15:0] sq [0:3];
    reg [1:0] nl [0:3];               // ex_last beats taken for the slot's warp
    integer k, j;
    always @(*) if (rst_n) begin
        if (fl_go) assume (st[fl_slot] == 2'd0);
        if (vstart) assume (st[vslot] == 2'd0 && !(fl_go && fl_slot == vslot));
        if (wc_end) assume (st[wc_warp] == 2'd1);
    end
    reg [15:0] pnext;
    reg ptl, pr;
    always @(posedge clk) begin
        pr <= rst_n;
        pnext <= ex_next;
        ptl <= ex_valid && ex_ready && ex_last;
    end
    always @(*) if (rst_n && pr) assume (ex_next == pnext + {15'd0, ptl});

    always @(posedge clk) begin
        if (!rst_n) begin
            for (k = 0; k < 4; k = k + 1) begin
                st[k] <= 2'd0;
                nl[k] <= 2'd0;
                sq[k] <= 16'd0;
            end
            frag <= 4'd0;
        end else begin
            if (ex_valid && ex_ready && ex_last && nl[d_warp] != 2'd3) nl[d_warp] <= nl[d_warp] + 2'd1;
            if (xr_valid) st[xr_warp] <= 2'd0;
            if (wc_end) st[wc_warp] <= 2'd2;
            if (fl_go) begin
                st[fl_slot] <= 2'd1;
                frag[fl_slot] <= 1'b1;
                sq[fl_slot] <= fl_seq;
                nl[fl_slot] <= 2'd0;
            end
            if (vstart) begin
                st[vslot] <= 2'd1;
                frag[vslot] <= 1'b0;
            end
        end
    end

    reg pv, pwce;
    reg [1:0] pw, pwcw;
    reg [2:0] pq;
    reg [1:0] prt;
    reg [15:0] pseq;
    reg pl, pf, plb, pnc;
    always @(posedge clk) begin
        pv <= rst_n && ex_valid && !ex_ready;
        pw <= d_warp; pq <= d_q; prt <= d_rt; pseq <= ex_seq; pl <= ex_last;
        pf <= d_first; plb <= d_lastb; pnc <= d_nocol;
        pwce <= rst_n && wc_end && !frag[wc_warp];
        pwcw <= wc_warp;
    end
    always @(*) if (rst_n && !init) begin
        if (ex_valid) begin
            assert (st[d_warp] == 2'd2 && frag[d_warp]);
            assert (ex_seq == ex_next && ex_seq == sq[d_warp]);
            assert (d_nocol == (d_rtw == 4'd0));
            if (!d_nocol) assert (d_rtw[d_rt]);
            assert (nl[d_warp] == 2'd0);
        end
        if (pv) assert (ex_valid && d_warp == pw && d_q == pq && d_rt == prt && ex_seq == pseq &&
                        ex_last == pl && d_first == pf && d_lastb == plb && d_nocol == pnc);
        if (xr_valid) begin
            assert (st[xr_warp] == 2'd2);
            if (frag[xr_warp]) assert (nl[xr_warp] == 2'd1);
        end
        for (j = 0; j < 4; j = j + 1) assert (nl[j] <= 2'd1);
        if (pwce) assert (xr_valid && xr_warp == pwcw);
    end
endmodule
