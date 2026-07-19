
//------------------------------------------------------------------------------
// Module: async_fifo
// Description: General-Purpose Asynchronous FIFO with Gray Code CDC
//              - Parameterized depth, width, and pointer width
//              - Dual-clock: independent write and read clocks
//              - Gray code pointers for safe clock domain crossing
//              - Full/Empty flags with proper CDC
//              - Optional almost-full and almost-empty flags
//------------------------------------------------------------------------------

module async_fifo #(
    parameter  DATA_WIDTH = 32,          // Width of FIFO data
    parameter  DEPTH      = 16,          // FIFO depth (must be power of 2)
    parameter  AF_LEVEL   = 2,           // Almost-full threshold
    parameter  AE_LEVEL   = 2,           // Almost-empty threshold
    parameter  SYNC_STAGES = 2           // CDC synchronizer stages (>=2)
) (
    // Write Clock Domain
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,
    input  wire [DATA_WIDTH-1:0] wr_data,
    input  wire                  wr_en,
    output wire                  wr_full,
    output wire                  wr_almost_full,
    output wire [$clog2(DEPTH):0] wr_count,

    // Read Clock Domain
    input  wire                  rd_clk,
    input  wire                  rd_rst_n,
    output wire [DATA_WIDTH-1:0] rd_data,
    input  wire                  rd_en,
    output wire                  rd_empty,
    output wire                  rd_almost_empty,
    output wire [$clog2(DEPTH):0] rd_count
);

    //==========================================================================
    // Local Parameters
    //==========================================================================

    localparam ADDR_WIDTH = $clog2(DEPTH);
    localparam PTR_WIDTH  = ADDR_WIDTH + 1;  // Extra bit for full/empty detection

    //==========================================================================
    // Memory Array
    //==========================================================================

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    //==========================================================================
    // Write Pointer (wr_clk domain)
    //==========================================================================

    reg [PTR_WIDTH-1:0] wr_ptr_bin;
    reg [PTR_WIDTH-1:0] wr_ptr_gray;

    wire [PTR_WIDTH-1:0] wr_ptr_bin_next;
    wire [PTR_WIDTH-1:0] wr_ptr_gray_next;

    assign wr_ptr_bin_next  = wr_ptr_bin + (wr_en && !wr_full);
    assign wr_ptr_gray_next = bin_to_gray(wr_ptr_bin_next);

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr_bin  <= {PTR_WIDTH{1'b0}};
            wr_ptr_gray <= {PTR_WIDTH{1'b0}};
        end else begin
            wr_ptr_bin  <= wr_ptr_bin_next;
            wr_ptr_gray <= wr_ptr_gray_next;
            if (wr_en && !wr_full) begin
                mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= wr_data;
            end
        end
    end

    //==========================================================================
    // Read Pointer (rd_clk domain)
    //==========================================================================

    reg [PTR_WIDTH-1:0] rd_ptr_bin;
    reg [PTR_WIDTH-1:0] rd_ptr_gray;

    wire [PTR_WIDTH-1:0] rd_ptr_bin_next;
    wire [PTR_WIDTH-1:0] rd_ptr_gray_next;

    assign rd_ptr_bin_next  = rd_ptr_bin + (rd_en && !rd_empty);
    assign rd_ptr_gray_next = bin_to_gray(rd_ptr_bin_next);

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr_bin  <= {PTR_WIDTH{1'b0}};
            rd_ptr_gray <= {PTR_WIDTH{1'b0}};
        end else begin
            rd_ptr_bin  <= rd_ptr_bin_next;
            rd_ptr_gray <= rd_ptr_gray_next;
        end
    end

    //==========================================================================
    // Synchronizers: Read pointer -> Write clock domain
    //==========================================================================

    reg [PTR_WIDTH-1:0] rd_ptr_gray_sync [0:SYNC_STAGES-1];

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            integer i;
            for (i = 0; i < SYNC_STAGES; i = i + 1)
                rd_ptr_gray_sync[i] <= {PTR_WIDTH{1'b0}};
        end else begin
            integer i;
            rd_ptr_gray_sync[0] <= rd_ptr_gray;
            for (i = 1; i < SYNC_STAGES; i = i + 1)
                rd_ptr_gray_sync[i] <= rd_ptr_gray_sync[i-1];
        end
    end

    wire [PTR_WIDTH-1:0] rd_ptr_gray_sync_out;
    assign rd_ptr_gray_sync_out = rd_ptr_gray_sync[SYNC_STAGES-1];

    //==========================================================================
    // Synchronizers: Write pointer -> Read clock domain
    //==========================================================================

    reg [PTR_WIDTH-1:0] wr_ptr_gray_sync [0:SYNC_STAGES-1];

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            integer i;
            for (i = 0; i < SYNC_STAGES; i = i + 1)
                wr_ptr_gray_sync[i] <= {PTR_WIDTH{1'b0}};
        end else begin
            integer i;
            wr_ptr_gray_sync[0] <= wr_ptr_gray;
            for (i = 1; i < SYNC_STAGES; i = i + 1)
                wr_ptr_gray_sync[i] <= wr_ptr_gray_sync[i-1];
        end
    end

    wire [PTR_WIDTH-1:0] wr_ptr_gray_sync_out;
    assign wr_ptr_gray_sync_out = wr_ptr_gray_sync[SYNC_STAGES-1];

    //==========================================================================
    // Gray Code Conversion Functions
    //==========================================================================

    function [PTR_WIDTH-1:0] bin_to_gray;
        input [PTR_WIDTH-1:0] bin;
        begin
            bin_to_gray = (bin >> 1) ^ bin;
        end
    endfunction

    function [PTR_WIDTH-1:0] gray_to_bin;
        input [PTR_WIDTH-1:0] gray;
        reg [PTR_WIDTH-1:0] bin;
        integer i;
        begin
            bin[PTR_WIDTH-1] = gray[PTR_WIDTH-1];
            for (i = PTR_WIDTH-2; i >= 0; i = i - 1)
                bin[i] = bin[i+1] ^ gray[i];
            gray_to_bin = bin;
        end
    endfunction

    //==========================================================================
    // Full and Empty Detection
    //==========================================================================

    // Full: MSB differs, rest are same (wr_ptr is one ahead of rd_ptr)
    assign wr_full = (wr_ptr_gray == {~rd_ptr_gray_sync_out[PTR_WIDTH-1],
                                       rd_ptr_gray_sync_out[PTR_WIDTH-2:0]});

    // Empty: All bits match
    assign rd_empty = (rd_ptr_gray == wr_ptr_gray_sync_out);

    //==========================================================================
    // Occupancy Counts
    //==========================================================================

    wire [PTR_WIDTH-1:0] rd_ptr_bin_sync;
    wire [PTR_WIDTH-1:0] wr_ptr_bin_sync;

    assign rd_ptr_bin_sync = gray_to_bin(rd_ptr_gray_sync_out);
    assign wr_ptr_bin_sync = gray_to_bin(wr_ptr_gray_sync_out);

    // Write-side count (may be pessimistic due to CDC latency)
    assign wr_count = wr_ptr_bin - rd_ptr_bin_sync;

    // Read-side count (may be optimistic due to CDC latency)
    assign rd_count = wr_ptr_bin_sync - rd_ptr_bin;

    //==========================================================================
    // Almost-Full and Almost-Empty
    //==========================================================================

    assign wr_almost_full  = (wr_count >= (DEPTH - AF_LEVEL));
    assign rd_almost_empty = (rd_count <= AE_LEVEL);

    //==========================================================================
    // Read Data Output (registered)
    //==========================================================================

    reg [DATA_WIDTH-1:0] rd_data_reg;

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_data_reg <= {DATA_WIDTH{1'b0}};
        end else if (rd_en && !rd_empty) begin
            rd_data_reg <= mem[rd_ptr_bin[ADDR_WIDTH-1:0]];
        end
    end

    assign rd_data = rd_data_reg;

    //==========================================================================
    // Assertions (Simulation Only)
    //==========================================================================

    // synthesis translate_off
    always @(posedge wr_clk) begin
        if (wr_en && wr_full)
            $error("[%0t] ASYNC_FIFO: Write to full FIFO!", $time);
    end

    always @(posedge rd_clk) begin
        if (rd_en && rd_empty)
            $error("[%0t] ASYNC_FIFO: Read from empty FIFO!", $time);
    end
    // synthesis translate_on

endmodule


//------------------------------------------------------------------------------
// Wrapper: apb_to_dfi_async_fifo using the general async_fifo module
//------------------------------------------------------------------------------

module apb_to_dfi_async_fifo_wrapper (
    // APB Interface (200 MHz)
    input  wire        apb_clk,
    input  wire        apb_rst_n,
    input  wire        apb_psel,
    input  wire        apb_penable,
    input  wire        apb_pwrite,
    input  wire [15:0] apb_paddr,
    input  wire [27:0] apb_pwdata,
    output wire        apb_pready,
    output wire [27:0] apb_prdata,
    output wire        apb_pslverr,

    // DFI Interface (800 MHz)
    input  wire        dfi_clk,
    input  wire        dfi_rst_n,
    output wire [27:0] dfi_cmd_data,
    output wire        dfi_cmd_valid,
    input  wire        dfi_cmd_ready
);

    // APB command encoding: {pwrite, paddr[15:0], pwdata[10:0]} = 28 bits
    wire [27:0] fifo_wr_data = {apb_pwrite, apb_paddr[15:0], apb_pwdata[10:0]};
    wire        fifo_wr_en   = apb_psel && apb_penable;
    wire        fifo_full;

    // APB backpressure
    assign apb_pready  = apb_psel && apb_penable && !fifo_full;
    assign apb_pslverr = 1'b0;
    assign apb_prdata  = 28'd0; // Placeholder for read response path

    // DFI interface
    wire fifo_empty;

    assign dfi_cmd_valid = !fifo_empty;

    // Instantiate the general async FIFO
    async_fifo #(
        .DATA_WIDTH  (28),
        .DEPTH       (8),
        .AF_LEVEL    (1),
        .AE_LEVEL    (1),
        .SYNC_STAGES (2)
    ) u_async_fifo (
        .wr_clk         (apb_clk),
        .wr_rst_n       (apb_rst_n),
        .wr_data        (fifo_wr_data),
        .wr_en          (fifo_wr_en),
        .wr_full        (fifo_full),
        .wr_almost_full (),
        .wr_count       (),

        .rd_clk         (dfi_clk),
        .rd_rst_n       (dfi_rst_n),
        .rd_data        (dfi_cmd_data),
        .rd_en          (dfi_cmd_ready),
        .rd_empty       (fifo_empty),
        .rd_almost_empty(),
        .rd_count       ()
    );

endmodule
