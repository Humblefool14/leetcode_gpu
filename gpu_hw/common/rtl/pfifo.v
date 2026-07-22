// =============================================================================
// sparse_align_lsb
// Compacts a sparse one-hot/multi-hot command vector to a contiguous LSB
// "thermometer" vector, and routes the associated data lanes along with it.
// Property relied on downstream: cmd_out is always of the form (2^popcount-1),
// i.e. bits [popcount-1:0] are set and nothing above that.
// =============================================================================
module sparse_align_lsb
#(
    parameter int NUMCMDS = 4,
    parameter int BITDATA = 8,
    parameter int BITCCNT = $clog2(NUMCMDS + 1)
)(
    input  logic [NUMCMDS-1:0]         cmd_in,
    input  logic [NUMCMDS*BITDATA-1:0] din,
    output logic [NUMCMDS-1:0]         cmd_out,
    output logic [NUMCMDS*BITDATA-1:0] dout
);
    always_comb begin
        cmd_out = NUMCMDS'(0);
        dout    = '0;
        automatic logic [BITCCNT-1:0] cmdcnt = BITCCNT'(0);
        for (int i = 0; i < NUMCMDS; i++) begin
            if (cmd_in[i]) begin
                cmd_out[cmdcnt] = 1'b1;
                dout[cmdcnt*BITDATA +: BITDATA] = din[i*BITDATA +: BITDATA];
                cmdcnt = cmdcnt + BITCCNT'(1);
            end
        end
    end
endmodule


// =============================================================================
// sparse_fifo_mwmr
// Multi-write / multi-read FIFO.
//
// Micro-architecture (per spec):
//  1. write[] is LSB-aligned via sparse_align_lsb -> write_align / din_align.
//     read[]  is LSB-aligned the same way (data-less) -> read_align.
//     Both aligned vectors are guaranteed thermometer-coded from bit 0.
//  2. cnt_next = ocnt + pushcnt - popcnt (registered into ocnt).
//  3. head_ptr_next = head_ptr + popcnt, wrapped modulo FIFODEPTH.
//  4. Per-lane push qualification: write_align[i] & (ocnt + i < FIFODEPTH)
//     i.e. only push lane i if there is physically room for the i'th queued
//     write this cycle (protects against write[]/wr_cnt over-requesting).
//     Per-lane pop qualification:  read_align[j]  & (j < ocnt)
//     i.e. only pop lane j if there is a valid entry at that relative offset.
//  5. Tail address (this cycle's write target slot) for lane i:
//         tptr[i] = head_ptr + ocnt + i, wrapped modulo FIFODEPTH.
//     Head address (this cycle's read source slot) for lane j:
//         hptr[j] = head_ptr + j, wrapped modulo FIFODEPTH.
//  6. pushcnt/popcnt are countones() of the qualified (post-check) push/pop
//     vectors -- NOT wr_cnt/rd_cnt directly, since those are the requested
//     counts and may exceed what is actually accepted this cycle.
//  7. Storage is double-buffered: dff_nxt defaults to a copy of dff (memory
//     hold-over), then is selectively overwritten at each qualified push's
//     waddr with the aligned write data. dff <= dff_nxt at the clock edge.
//     Reads are combinational off dff (current committed contents), so a
//     same-cycle push is not visible to a same-cycle read (standard
//     synchronous-FIFO ordering).
// =============================================================================
module sparse_fifo_mwmr
#(
    parameter int NUMWRPT   = 4,
    parameter int NUMRDPT   = 4,
    parameter int BITDATA   = 8,
    parameter int FIFODEPTH = 16,

    // Derived widths -- match the caller's port declarations
    parameter int BITWRPT = $clog2(NUMWRPT+1)-1,   // wr_cnt is [BITWRPT:0]
    parameter int BITRDPT = $clog2(NUMRDPT+1)-1,   // rd_cnt is [BITRDPT:0]
    parameter int BITFIFO = $clog2(FIFODEPTH+1)-1, // ocnt   is [BITFIFO:0]
    localparam int BITPTR = (FIFODEPTH > 1) ? $clog2(FIFODEPTH) : 1
)(
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        clear,

    input  logic [NUMWRPT-1:0]          write,
    input  logic [BITWRPT:0]            wr_cnt,
    input  logic [NUMWRPT*BITDATA-1:0]  din,

    input  logic [NUMRDPT-1:0]          read,
    input  logic [BITRDPT:0]            rd_cnt,
    output wire  [NUMRDPT*BITDATA-1:0]  dout,

    output reg   [BITFIFO:0]            ocnt,
    output reg                          mty,
    output reg                          amty,
    output reg                          ful
);

    // -------------------------------------------------------------------
    // Storage (double buffered)
    // -------------------------------------------------------------------
    logic [BITDATA-1:0] dff     [0:FIFODEPTH-1];
    logic [BITDATA-1:0] dff_nxt [0:FIFODEPTH-1];

    // -------------------------------------------------------------------
    // Pointers
    // -------------------------------------------------------------------
    logic [BITPTR-1:0] head_ptr, head_ptr_next;

    // -------------------------------------------------------------------
    // 1. LSB alignment of write & read command vectors
    // -------------------------------------------------------------------
    logic [NUMWRPT-1:0]         write_align;
    logic [NUMWRPT*BITDATA-1:0] din_align;

    sparse_align_lsb #(.NUMCMDS(NUMWRPT), .BITDATA(BITDATA)) u_wr_align (
        .cmd_in  (write),
        .din     (din),
        .cmd_out (write_align),
        .dout    (din_align)
    );

    logic [NUMRDPT-1:0] read_align;
    logic [NUMRDPT-1:0] rd_dummy_dout; // data-less align, width-1 placeholder

    sparse_align_lsb #(.NUMCMDS(NUMRDPT), .BITDATA(1)) u_rd_align (
        .cmd_in  (read),
        .din     ('0),
        .cmd_out (read_align),
        .dout    (rd_dummy_dout)
    );

    // -------------------------------------------------------------------
    // Per-lane qualification (4)
    // -------------------------------------------------------------------
    logic [NUMWRPT-1:0] pushes;
    logic [NUMRDPT-1:0] pops;

    always_comb begin
        for (int i = 0; i < NUMWRPT; i++)
            pushes[i] = write_align[i] & (({1'b0, ocnt} + i) < FIFODEPTH);

        for (int j = 0; j < NUMRDPT; j++)
            pops[j] = read_align[j] & (j < ocnt);
    end
    // (head_ptr itself doesn't factor into push/pop qualification -- only
    //  relative offsets from it do; see tptr[]/hptr[] address arrays below)

    // -------------------------------------------------------------------
    // 6. Actual accepted push/pop counts (post-qualification)
    // -------------------------------------------------------------------
    logic [BITFIFO:0] pushcnt, popcnt;
    always_comb begin
        pushcnt = BITFIFO'(0) + BITFIFO'($countones(pushes));
        popcnt  = BITFIFO'(0) + BITFIFO'($countones(pops));
    end

    // -------------------------------------------------------------------
    // 2. Next occupancy
    // -------------------------------------------------------------------
    logic [BITFIFO+1:0] cnt_next; // extra guard bit against transient overflow
    always_comb cnt_next = {1'b0, ocnt} + {1'b0, pushcnt} - {1'b0, popcnt};

    // -------------------------------------------------------------------
    // 3. Next head pointer (wraps modulo FIFODEPTH)
    // -------------------------------------------------------------------
    logic [BITPTR:0] head_ptr_sum;
    always_comb begin
        head_ptr_sum  = {1'b0, head_ptr} + BITPTR'(popcnt);
        head_ptr_next = (head_ptr_sum >= FIFODEPTH) ? (head_ptr_sum - FIFODEPTH) : head_ptr_sum[BITPTR-1:0];
    end

    // -------------------------------------------------------------------
    // 5. Per-lane tail/head addresses (combinational, relative to current
    //    head_ptr/ocnt):
    //      tptr[i] = write (tail) address for write lane i
    //               = head_ptr + ocnt + i, wrapped modulo FIFODEPTH
    //      hptr[j] = read (head) address for read lane j
    //               = head_ptr + j, wrapped modulo FIFODEPTH
    // -------------------------------------------------------------------
    logic [BITPTR-1:0] tptr [0:NUMWRPT-1];
    logic [BITPTR-1:0] hptr [0:NUMRDPT-1];

    always_comb begin
        for (int i = 0; i < NUMWRPT; i++) begin
            automatic logic [BITPTR:0] sum = {1'b0, head_ptr} + BITPTR'(ocnt) + i;
            tptr[i] = (sum >= FIFODEPTH) ? (sum - FIFODEPTH) : sum[BITPTR-1:0];
        end
        for (int j = 0; j < NUMRDPT; j++) begin
            automatic logic [BITPTR:0] sum = {1'b0, head_ptr} + j;
            hptr[j] = (sum >= FIFODEPTH) ? (sum - FIFODEPTH) : sum[BITPTR-1:0];
        end
    end

    // -------------------------------------------------------------------
    // 7. dff_nxt = copy of dff, then overwrite qualified push slots (4,7)
    // -------------------------------------------------------------------
    always_comb begin
        for (int a = 0; a < FIFODEPTH; a++)
            dff_nxt[a] = dff[a];
        for (int i = 0; i < NUMWRPT; i++) begin
            if (pushes[i])
                dff_nxt[tptr[i]] = din_align[i*BITDATA +: BITDATA];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int a = 0; a < FIFODEPTH; a++)
                dff[a] <= '0;
        end else begin
            dff <= dff_nxt;
        end
    end

    // -------------------------------------------------------------------
    // Read data (combinational, off currently-committed dff)
    // -------------------------------------------------------------------
    genvar gj;
    generate
        for (gj = 0; gj < NUMRDPT; gj++) begin : g_dout
            assign dout[gj*BITDATA +: BITDATA] = dff[hptr[gj]];
        end
    endgenerate

    // -------------------------------------------------------------------
    // Pointer / occupancy state
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_ptr <= '0;
            ocnt     <= '0;
        end else if (clear) begin
            head_ptr <= '0;
            ocnt     <= '0;
        end else begin
            head_ptr <= head_ptr_next;
            ocnt     <= cnt_next[BITFIFO:0];
        end
    end

    // -------------------------------------------------------------------
    // Flags
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear) begin
            mty  <= 1'b1;
            amty <= 1'b0;
            ful  <= 1'b0;
        end else begin
            mty  <= (cnt_next[BITFIFO:0] == '0);
            amty <= (cnt_next[BITFIFO:0] == BITFIFO'(1));
            ful  <= (cnt_next[BITFIFO:0] == FIFODEPTH[BITFIFO:0]);
        end
    end

`ifndef SYNTHESIS
    // =====================================================================
    // Assertions
    // =====================================================================

    // Requested counts sanity: wr_cnt/rd_cnt should match popcount of the
    // raw (pre-alignment) command vectors. If a caller pre-computes these,
    // they must agree with the vectors driving alignment.
    property p_wrcnt_matches;
        @(posedge clk) disable iff (!rst_n)
        wr_cnt == $countones(write);
    endproperty
    a_wrcnt_matches: assert property (p_wrcnt_matches)
        else $error("wr_cnt (%0d) != countones(write) (%0d)", wr_cnt, $countones(write));

    property p_rdcnt_matches;
        @(posedge clk) disable iff (!rst_n)
        rd_cnt == $countones(read);
    endproperty
    a_rdcnt_matches: assert property (p_rdcnt_matches)
        else $error("rd_cnt (%0d) != countones(read) (%0d)", rd_cnt, $countones(read));

    // Aligned vectors must be thermometer-coded from bit 0 (contiguous LSB run)
    a_write_align_thermo: assert property (
        @(posedge clk) disable iff (!rst_n)
        write_align == ((NUMWRPT+1)'(1) << $countones(write_align)) - 1'b1
    ) else $error("write_align not LSB-thermometer coded: %b", write_align);

    a_read_align_thermo: assert property (
        @(posedge clk) disable iff (!rst_n)
        read_align == ((NUMRDPT+1)'(1) << $countones(read_align)) - 1'b1
    ) else $error("read_align not LSB-thermometer coded: %b", read_align);

    // Occupancy never exceeds depth, never underflows
    a_ocnt_in_range: assert property (
        @(posedge clk) disable iff (!rst_n)
        ocnt <= FIFODEPTH
    ) else $error("ocnt (%0d) exceeds FIFODEPTH (%0d)", ocnt, FIFODEPTH);

    a_cnt_next_no_underflow: assert property (
        @(posedge clk) disable iff (!rst_n)
        cnt_next[BITFIFO+1] == 1'b0
    ) else $error("cnt_next underflowed (popcnt > ocnt + pushcnt)");

    // Flags consistent with occupancy
    a_full_flag: assert property (
        @(posedge clk) disable iff (!rst_n)
        ful == (ocnt == FIFODEPTH)
    ) else $error("ful flag inconsistent with ocnt=%0d", ocnt);

    a_empty_flag: assert property (
        @(posedge clk) disable iff (!rst_n)
        mty == (ocnt == 0)
    ) else $error("mty flag inconsistent with ocnt=%0d", ocnt);

    a_no_full_and_empty: assert property (
        @(posedge clk) disable iff (!rst_n)
        !(ful && mty)
    ) else $error("ful and mty asserted simultaneously");

    // No push into a full FIFO lane beyond capacity, no pop from an empty slot
    a_no_overpush: assert property (
        @(posedge clk) disable iff (!rst_n)
        pushcnt <= (FIFODEPTH - ocnt)
    ) else $error("pushcnt (%0d) exceeds free space (%0d)", pushcnt, FIFODEPTH-ocnt);

    a_no_overpop: assert property (
        @(posedge clk) disable iff (!rst_n)
        popcnt <= ocnt
    ) else $error("popcnt (%0d) exceeds ocnt (%0d)", popcnt, ocnt);

    // head_ptr always in bounds
    a_head_ptr_in_range: assert property (
        @(posedge clk) disable iff (!rst_n)
        head_ptr < FIFODEPTH
    ) else $error("head_ptr (%0d) out of range", head_ptr);

    // Occupancy update equation
    a_ocnt_update: assert property (
        @(posedge clk) disable iff (!rst_n)
        (1'b1) |=> (ocnt == $past(cnt_next[BITFIFO:0]))
    ) else $error("ocnt did not update per cnt_next equation");

    // Clear forces empty on the next cycle
    a_clear_empties: assert property (
        @(posedge clk) disable iff (!rst_n)
        clear |=> (ocnt == 0 && head_ptr == 0)
    ) else $error("clear did not reset ocnt/head_ptr to 0");

    // Reset forces known/empty state
    a_reset_state: assert property (
        @(posedge rst_n)
        (ocnt == 0 && head_ptr == 0 && mty == 1'b1 && ful == 1'b0)
    ) else $error("reset did not establish empty state");

    // Coverage
    c_full_reached:  cover property (@(posedge clk) disable iff (!rst_n) ful);
    c_empty_reached: cover property (@(posedge clk) disable iff (!rst_n) mty);
    c_multi_push:    cover property (@(posedge clk) disable iff (!rst_n) pushcnt > 1);
    c_multi_pop:     cover property (@(posedge clk) disable iff (!rst_n) popcnt  > 1);
    c_simul_push_pop:cover property (@(posedge clk) disable iff (!rst_n) (pushcnt > 0) && (popcnt > 0));
    c_wrap_head_ptr: cover property (@(posedge clk) disable iff (!rst_n) head_ptr_next < head_ptr);
`endif

endmodule