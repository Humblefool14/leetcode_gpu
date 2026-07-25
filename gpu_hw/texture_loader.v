`timescale 1ns / 1ps

module texture_loader #(
    parameter int TEX_WIDTH     = 256,
    parameter int TEX_HEIGHT    = 256,
    parameter int TEX_DATA_W    = 24,   // RGB888
    parameter int ADDR_W        = $clog2(TEX_WIDTH * TEX_HEIGHT)
)(
    input  logic              clk,
    input  logic              rst_n,

    // UART interface from host
    input  logic              uart_rx_valid,
    input  logic [7:0]        uart_rx_data,

    // Control from host_interface
    input  logic              tex_load_start,   // Pulse to begin loading
    output logic              tex_load_busy,    // HIGH while loading
    output logic              tex_load_done,    // Pulse when complete

    // BRAM Port A: Write-only (loader owns this)
    output logic              tex_we,
    output logic [ADDR_W-1:0] tex_waddr,
    output logic [TEX_DATA_W-1:0] tex_wdata
);

    localparam int TEX_SIZE = TEX_WIDTH * TEX_HEIGHT;
    localparam int BYTES_PER_PIXEL = TEX_DATA_W / 8;  // 3 bytes for RGB888

    // State machine
    typedef enum logic [2:0] {
        IDLE,
        LOAD_R,      // Receive Red byte
        LOAD_G,      // Receive Green byte
        LOAD_B,      // Receive Blue byte
        WRITE_MEM,   // Write assembled pixel to BRAM
        DONE
    } state_t;

    state_t state;
    logic [ADDR_W-1:0] pixel_count;
    logic [7:0] r_byte, g_byte, b_byte;

    // Status outputs
    assign tex_load_busy = (state != IDLE) && (state != DONE);
    assign tex_load_done = (state == DONE);

    // tex_we is now purely combinational on state, so it is HIGH
    // for exactly the cycle(s) the FSM is in WRITE_MEM -- no lag.
    assign tex_we = (state == WRITE_MEM);

    // Sequential logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            pixel_count <= '0;
            r_byte      <= '0;
            g_byte      <= '0;
            b_byte      <= '0;
            tex_waddr   <= '0;
            tex_wdata   <= '0;
        end else begin
            case (state)
                IDLE: begin
                    pixel_count <= '0;
                    if (tex_load_start) begin
                        state <= LOAD_R;
                    end
                end

                LOAD_R: begin
                    if (uart_rx_valid) begin
                        r_byte <= uart_rx_data;
                        state  <= LOAD_G;
                    end
                end

                LOAD_G: begin
                    if (uart_rx_valid) begin
                        g_byte <= uart_rx_data;
                        state  <= LOAD_B;
                    end
                end

                LOAD_B: begin
                    if (uart_rx_valid) begin
                        b_byte <= uart_rx_data;

                        // Register the write address/data NOW, on the
                        // transition into WRITE_MEM, so they are already
                        // valid on the very cycle tex_we goes high.
                        tex_waddr <= pixel_count;
                        tex_wdata <= {r_byte, g_byte, uart_rx_data};

                        state <= WRITE_MEM;
                    end
                end

                WRITE_MEM: begin
                    // tex_we/tex_waddr/tex_wdata are already correct
                    // combinationally/from last cycle; just advance.
                    if (pixel_count < TEX_SIZE - 1) begin
                        pixel_count <= pixel_count + 1'b1;
                        state       <= LOAD_R;  // Next pixel
                    end else begin
                        state <= DONE;  // All pixels loaded
                    end
                end

                DONE: begin
                    state <= IDLE;  // Auto-return, ready for next load
                end

                default: state <= IDLE;
            endcase
        end
    end

    // =====================================================================
    // ASSERTIONS
    // =====================================================================

    // Safety: tex_we only in WRITE_MEM state
    // (now trivially/structurally true since tex_we is assign'd from state,
    //  but kept as a regression guard against future edits)
    property p_we_only_in_write;
        @(posedge clk) disable iff (!rst_n)
        tex_we |-> (state == WRITE_MEM);
    endproperty
    a_we_only_in_write: assert property (p_we_only_in_write);

    // Safety: pixel_count never exceeds TEX_SIZE
    property p_addr_in_range;
        @(posedge clk) disable iff (!rst_n)
        tex_we |-> (tex_waddr < TEX_SIZE);
    endproperty
    a_addr_in_range: assert property (p_addr_in_range);

    // Safety: done is single-cycle pulse
    property p_done_pulse;
        @(posedge clk) disable iff (!rst_n)
        tex_load_done |=> !tex_load_done;
    endproperty
    a_done_pulse: assert property (p_done_pulse);

    // Safety: waddr/wdata must be stable and valid for the full duration
    // that tex_we is asserted (new check, now meaningful since we changed
    // the timing of when these registers are loaded)
    property p_wdata_stable_during_we;
        @(posedge clk) disable iff (!rst_n)
        tex_we |-> $stable(tex_waddr) && $stable(tex_wdata);
    endproperty
    a_wdata_stable_during_we: assert property (p_wdata_stable_during_we);

    // Coverage: full texture loaded
`ifdef FPV
    cover property (
        @(posedge clk) disable iff (!rst_n)
        (state == WRITE_MEM) && (pixel_count == TEX_SIZE - 1)
    );

    // Coverage: first pixel write happens correctly
    cover property (
        @(posedge clk) disable iff (!rst_n)
        tex_we && (pixel_count == 0)
    );
`endif

endmodule
