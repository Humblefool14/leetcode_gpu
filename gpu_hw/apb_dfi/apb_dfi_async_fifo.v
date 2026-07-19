//------------------------------------------------------------------------------
// Module: apb_to_dfi_async_fifo
// Description: APB to DFI Async FIFO Bridge
//              - APB clock domain: 200 MHz
//              - DFI clock domain: 800 MHz
//              - FIFO depth: 8 commands
//              - Command width: 28 bits
//              - Uses Gray code pointers for CDC
//------------------------------------------------------------------------------

module apb_to_dfi_async_fifo (
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

    //==========================================================================
    // Internal Signals
    //==========================================================================

    // FIFO memory (8 entries x 28 bits)
    reg [27:0] fifo_mem [0:7];

    // Write pointer (APB domain) - 4 bits for 8 entries (1 extra for full/empty)
    reg [3:0] wr_ptr_bin;
    reg [3:0] wr_ptr_gray;
    reg [3:0] wr_ptr_gray_sync1, wr_ptr_gray_sync2;

    // Read pointer (DFI domain) - 4 bits for 8 entries (1 extra for full/empty)
    reg [3:0] rd_ptr_bin;
    reg [3:0] rd_ptr_gray;
    reg [3:0] rd_ptr_gray_sync1, rd_ptr_gray_sync2;

    // FIFO status
    wire fifo_full;
    wire fifo_empty;

    // Write and read enables
    wire fifo_wr_en;
    wire fifo_rd_en;

    // Command encoding
    wire [27:0] fifo_wr_data;

    //==========================================================================
    // Gray Code Conversion Functions
    //==========================================================================

    // Binary to Gray code conversion
    function [3:0] bin_to_gray;
        input [3:0] bin;
        begin
            bin_to_gray = (bin >> 1) ^ bin;
        end
    endfunction

    // Gray code to binary conversion
    function [3:0] gray_to_bin;
        input [3:0] gray;
        reg [3:0] bin;
        begin
            bin[3] = gray[3];
            bin[2] = gray[3] ^ gray[2];
            bin[1] = gray[3] ^ gray[2] ^ gray[1];
            bin[0] = gray[3] ^ gray[2] ^ gray[1] ^ gray[0];
            gray_to_bin = bin;
        end
    endfunction

    //==========================================================================
    // APB Interface Logic (Write Domain - 200 MHz)
    //==========================================================================

    // APB command packet encoding:
    // Bit [27]    : Command type (1 = Write, 0 = Read)
    // Bit [26:11] : Address (16 bits)
    // Bit [10:0]  : Data (11 bits) - or use full 28-bit data
    // 
    // For this design:
    // Bit [27]    : pwrite (1 = write, 0 = read)
    // Bit [26:11] : apb_paddr[15:0]
    // Bit [10:0]  : apb_pwdata[10:0] (or adjust as needed)
    //
    // Adjust bit mapping based on actual requirements

    assign fifo_wr_data = {apb_pwrite, apb_paddr[15:0], apb_pwdata[10:0]};

    // APB write enable: valid APB transaction (PSel && PEnable && PWrite)
    // For reads, we also queue the command but data comes back later
    assign fifo_wr_en = apb_psel && apb_penable && !fifo_full;

    // APB ready with backpressure
    assign apb_pready = apb_psel && apb_penable && !fifo_full;

    // APB error (not used in this basic implementation)
    assign apb_pslverr = 1'b0;

    // APB read data (would need a return path for reads - simplified here)
    assign apb_prdata = 28'd0; // Placeholder - needs read response path

    //==========================================================================
    // FIFO Write Pointer (APB Clock Domain)
    //==========================================================================

    always @(posedge apb_clk or negedge apb_rst_n) begin
        if (!apb_rst_n) begin
            wr_ptr_bin  <= 4'd0;
            wr_ptr_gray <= 4'd0;
        end else begin
            if (fifo_wr_en) begin
                wr_ptr_bin  <= wr_ptr_bin + 4'd1;
                wr_ptr_gray <= bin_to_gray(wr_ptr_bin + 4'd1);
                fifo_mem[wr_ptr_bin[2:0]] <= fifo_wr_data;
            end
        end
    end

    //==========================================================================
    // Read Pointer Synchronization (APB -> DFI)
    //==========================================================================

    always @(posedge apb_clk or negedge apb_rst_n) begin
        if (!apb_rst_n) begin
            rd_ptr_gray_sync1 <= 4'd0;
            rd_ptr_gray_sync2 <= 4'd0;
        end else begin
            rd_ptr_gray_sync1 <= rd_ptr_gray;
            rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
        end
    end

    //==========================================================================
    // FIFO Full Condition (in APB domain)
    // Full when write pointer is one ahead of read pointer (MSB differ, rest same)
    //==========================================================================

    wire [3:0] rd_ptr_bin_sync;
    assign rd_ptr_bin_sync = gray_to_bin(rd_ptr_gray_sync2);

    assign fifo_full = (wr_ptr_gray == {~rd_ptr_gray_sync2[3:2], rd_ptr_gray_sync2[1:0]});
    // Alternative full check using binary:
    // assign fifo_full = (wr_ptr_bin[2:0] == rd_ptr_bin_sync[2:0]) && 
    //                    (wr_ptr_bin[3] != rd_ptr_bin_sync[3]);

    //==========================================================================
    // DFI Interface Logic (Read Domain - 800 MHz)
    //==========================================================================

    // DFI command valid when FIFO not empty
    assign dfi_cmd_valid = !fifo_empty;

    // DFI read enable when valid and ready
    assign fifo_rd_en = dfi_cmd_valid && dfi_cmd_ready;

    // DFI command data output
    assign dfi_cmd_data = fifo_mem[rd_ptr_bin[2:0]];

    //==========================================================================
    // FIFO Read Pointer (DFI Clock Domain)
    //==========================================================================

    always @(posedge dfi_clk or negedge dfi_rst_n) begin
        if (!dfi_rst_n) begin
            rd_ptr_bin  <= 4'd0;
            rd_ptr_gray <= 4'd0;
        end else begin
            if (fifo_rd_en) begin
                rd_ptr_bin  <= rd_ptr_bin + 4'd1;
                rd_ptr_gray <= bin_to_gray(rd_ptr_bin + 4'd1);
            end
        end
    end

    //==========================================================================
    // Write Pointer Synchronization (DFI -> APB)
    //==========================================================================

    always @(posedge dfi_clk or negedge dfi_rst_n) begin
        if (!dfi_rst_n) begin
            wr_ptr_gray_sync1 <= 4'd0;
            wr_ptr_gray_sync2 <= 4'd0;
        end else begin
            wr_ptr_gray_sync1 <= wr_ptr_gray;
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
        end
    end

    //==========================================================================
    // FIFO Empty Condition (in DFI domain)
    // Empty when read pointer equals write pointer
    //==========================================================================

    wire [3:0] wr_ptr_bin_sync;
    assign wr_ptr_bin_sync = gray_to_bin(wr_ptr_gray_sync2);

    assign fifo_empty = (rd_ptr_gray == wr_ptr_gray_sync2);
    // Alternative empty check using binary:
    // assign fifo_empty = (rd_ptr_bin == wr_ptr_bin_sync);

    //==========================================================================
    // Assertions (for simulation only)
    //==========================================================================

    // synthesis translate_off
    // Check for FIFO overflow
    always @(posedge apb_clk) begin
        if (apb_psel && apb_penable && fifo_full)
            $error("APB_TO_DFI_FIFO: FIFO overflow detected!");
    end

    // Check for FIFO underflow
    always @(posedge dfi_clk) begin
        if (dfi_cmd_ready && fifo_empty)
            $error("APB_TO_DFI_FIFO: FIFO underflow detected!");
    end
    // synthesis translate_on

endmodule
