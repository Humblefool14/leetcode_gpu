module ptr_fifo #(
    parameter int DATA_WIDTH = 32,
    parameter int DEPTH      = 8,                     // any value, not just pow2
    parameter int ADDR_WIDTH = $clog2(DEPTH),
    parameter int CNT_WIDTH  = $clog2(DEPTH+1)
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // write / push interface
    input  logic                    write,
    input  logic [DATA_WIDTH-1:0]   din,

    // in-place update interface (updates entry at head, doesn't advance ptr)
    input  logic                    update,
    input  logic [DATA_WIDTH-1:0]   udin,

    // read / pop interface (pipelined output)
    input  logic                    read,
    output logic [DATA_WIDTH-1:0]   dout,

    output logic [CNT_WIDTH-1:0]    FIFOCNT,   // # of FREE entries available
    output logic                    empty,
    output logic                    full
);

    // localparam: DEPTH as a CNT_WIDTH-wide constant, computed once
    // instead of re-casting DEPTH on every use.
    localparam logic [CNT_WIDTH-1:0] DEPTH_C = CNT_WIDTH'(DEPTH);

    // -----------------------------------------------------------------
    // Storage: two copies - dff (registered, "live" copy) and
    // dff_nxt (combinational, "next" copy).
    // -----------------------------------------------------------------
    logic [DATA_WIDTH-1:0] dff      [DEPTH];
    logic [DATA_WIDTH-1:0] dff_nxt  [DEPTH];

    logic [ADDR_WIDTH-1:0] hptr, hptr_nxt;
    logic [ADDR_WIDTH-1:0] tptr, tptr_nxt;
    logic [CNT_WIDTH-1:0]  cnt_q,  cnt_nxt;

    logic wr_en, rd_en;

    assign full    = (cnt_q == DEPTH_C);
    assign empty   = (cnt_q == '0);
    assign FIFOCNT = DEPTH_C - cnt_q;

    assign wr_en = write && !full;
    assign rd_en = read  && !empty;

    // -----------------------------------------------------------------
    // cnt_nxt: pure arithmetic, no branching on wr_en/rd_en.
    // -----------------------------------------------------------------
    assign cnt_nxt = cnt_q + CNT_WIDTH'(wr_en) - CNT_WIDTH'(rd_en);

    // -----------------------------------------------------------------
    // hptr_nxt: head only ever moves on a read. Computed as a sum
    // (hptr + 0/1) followed by a compare-to-DEPTH wrap correction.
    // The wrap check is against the constant DEPTH, not against
    // rd_en/wr_en, so there's no signal-keyed if/case here.
    // -----------------------------------------------------------------
    logic [ADDR_WIDTH:0] hptr_sum;
    assign hptr_sum  = {1'b0, hptr} + (ADDR_WIDTH+1)'(rd_en);
    assign hptr_nxt  = (hptr_sum == (ADDR_WIDTH+1)'(DEPTH)) ?
                         '0 : hptr_sum[ADDR_WIDTH-1:0];

    // -----------------------------------------------------------------
    // tptr_nxt: derived from cnt_nxt instead of an independent
    // wr_en-driven increment. Invariant: tail = (head + occupancy)
    // mod DEPTH. Since hptr_nxt < DEPTH and cnt_nxt <= DEPTH, the sum
    // is < 2*DEPTH, so a single conditional subtract fully wraps it.
    // -----------------------------------------------------------------
    logic [CNT_WIDTH:0] tptr_sum;
    assign tptr_sum  = {1'b0, hptr_nxt} + {1'b0, cnt_nxt};
    assign tptr_nxt  = (tptr_sum >= (CNT_WIDTH+1)'(DEPTH)) ?
                         (tptr_sum - (CNT_WIDTH+1)'(DEPTH))[ADDR_WIDTH-1:0] :
                         tptr_sum[ADDR_WIDTH-1:0];

    // -----------------------------------------------------------------
    // dff_nxt: stage all data-array updates combinationally.
    //   - write     -> dff_nxt[tptr] = din          (push at tail)
    //   - update &  -> dff_nxt[hptr] = udin          (modify head entry
    //     !read                                       in place)
    // -----------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < DEPTH; i++)
            dff_nxt[i] = dff[i];

        if (wr_en)
            dff_nxt[tptr] = din;

        if (update && !read)
            dff_nxt[hptr] = udin;
    end

    // -----------------------------------------------------------------
    // Sequential: dff <= dff_nxt, pointers/cnt update
    // -----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < DEPTH; i++)
                dff[i] <= '0;
            hptr  <= '0;
            tptr  <= '0;
            cnt_q <= '0;
        end else begin
            dff   <= dff_nxt;
            hptr  <= hptr_nxt;
            tptr  <= tptr_nxt;
            cnt_q <= cnt_nxt;
        end
    end

    // -----------------------------------------------------------------
    // Pipelined output stage: dout is a registered copy of the current
    // head entry from dff (dff_nxt -> dff -> dout).
    // -----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            dout <= '0;
        else
            dout <= dff[hptr];
    end

endmodule
