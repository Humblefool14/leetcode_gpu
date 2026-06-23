`timescale 1ns / 1ps

module axi_to_apb_bridge #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32
)(
    // --- Global Clock and Reset ---
    input  logic                    clk,
    input  logic                    rst_n,

    // --- AXI4-Lite Slave Interface ---
    // Write Address Channel
    input  logic [ADDR_WIDTH-1:0]   s_axi_awaddr,
    input  logic                    s_axi_awvalid,
    output logic                    s_axi_awready,
    // Write Data Channel
    input  logic [DATA_WIDTH-1:0]   s_axi_wdata,
    input  logic [(DATA_WIDTH/8)-1:0] s_axi_wstrb, // Unused here, assumed full 32-bit words
    input  logic                    s_axi_wvalid,
    output logic                    s_axi_wready,
    // Write Response Channel
    output logic [1:0]              s_axi_bresp,
    output logic                    s_axi_bvalid,
    input  logic                    s_axi_bready,
    // Read Address Channel
    input  logic [ADDR_WIDTH-1:0]   s_axi_araddr,
    input  logic                    s_axi_arvalid,
    output logic                    s_axi_arready,
    // Read Data Channel
    output logic [DATA_WIDTH-1:0]   s_axi_rdata,
    output logic [1:0]              s_axi_rresp,
    output logic                    s_axi_rvalid,
    input  logic                    s_axi_rready,

    // --- APB Master Interface ---
    output logic [ADDR_WIDTH-1:0]   m_apb_paddr,
    output logic                    m_apb_psel,
    output logic                    m_apb_penable,
    output logic                    m_apb_pwrite,
    output logic [DATA_WIDTH-1:0]   m_apb_pwdata,
    input  logic [DATA_WIDTH-1:0]   m_apb_prdata,
    input  logic                    m_apb_pready,
    input  logic                    m_apb_pslverr
);

    // --- Finite State Machine States ---
    typedef enum logic [2:0] {
        ST_IDLE      = 3'b000,
        ST_APB_SETUP = 3'b001,
        ST_APB_ACC   = 3'b010,
        ST_AXI_WRESP = 3'b011,
        ST_AXI_RRESP = 3'b100
    } state_t;

    state_t state;

    // Internal capture registers for holding AXI targets during APB setup
    logic [ADDR_WIDTH-1:0]  reg_addr;
    logic [DATA_WIDTH-1:0]  reg_wdata;
    logic                   reg_write;

    // Constant OKAY responses for AXI channels
    assign s_axi_bresp = 2'b00; // OKAY
    assign s_axi_rresp = 2'b00; // OKAY

    // --- Core State Machine & Translation Logic ---
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            s_axi_awready  <= 1'b0;
            s_axi_wready   <= 1'b0;
            s_axi_bvalid   <= 1'b0;
            s_axi_arready  <= 1'b0;
            s_axi_rvalid   <= 1'b0;
            s_axi_rdata    <= '0;
            
            m_apb_paddr    <= '0;
            m_apb_psel     <= 1'b0;
            m_apb_penable  <= 1'b0;
            m_apb_pwrite   <= 1'b0;
            m_apb_pwdata   <= '0;
            reg_write      <= 1'b0;
        end else begin
            // Pulse Clears
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_arready <= 1'b0;

            case (state)
                ST_IDLE: begin
                    m_apb_penable <= 1'b0;
                    m_apb_psel    <= 1'b0;

                    // Prioritize Writes over Reads to avoid starvation
                    if (s_axi_awvalid && s_axi_wvalid) begin
                        s_axi_awready <= 1'b1;
                        s_axi_wready  <= 1'b1;
                        reg_addr      <= s_axi_awaddr;
                        reg_wdata     <= s_axi_wdata;
                        reg_write     <= 1'b1;
                        state         <= ST_APB_SETUP;
                    end 
                    else if (s_axi_arvalid) begin
                        s_axi_arready <= 1'b1;
                        reg_addr      <= s_axi_araddr;
                        reg_write     <= 1'b0;
                        state         <= ST_APB_SETUP;
                    end
                end

                ST_APB_SETUP: begin
                    // Phase 1 of APB: Drive address, data, and assert PSEL
                    m_apb_paddr  <= reg_addr;
                    m_apb_pwrite <= reg_write;
                    m_apb_psel   <= 1'b1;
                    
                    if (reg_write) begin
                        m_apb_pwdata <= reg_wdata;
                    end
                    
                    state <= ST_APB_ACC;
                end

                ST_APB_ACC: begin
                    // Phase 2 of APB: Assert PENABLE alongside PSEL
                    m_apb_penable <= 1'b1;

                    // Wait for register target to assert PREADY response
                    if (m_apb_pready) begin
                        m_apb_penable <= 1'b0;
                        m_apb_psel    <= 1'b0;
                        
                        if (m_apb_pwrite) begin
                            s_axi_bvalid <= 1'b1; // Trigger AXI write response back
                            state        <= ST_AXI_WRESP;
                        end else begin
                            s_axi_rdata  <= m_apb_prdata; // Capture read data
                            s_axi_rvalid <= 1'b1;        // Trigger AXI read data valid
                            state        <= ST_AXI_RRESP;
                        end
                    end
                end

                ST_AXI_WRESP: begin
                    // Wait for host CPU to acknowledge write transaction complete
                    if (s_axi_bready && s_axi_bvalid) begin
                        s_axi_bvalid <= 1'b0;
                        state        <= ST_IDLE;
                    end
                end

                ST_AXI_RRESP: begin
                    // Wait for host CPU to catch read data output
                    if (s_axi_rready && s_axi_rvalid) begin
                        s_axi_rvalid <= 1'b0;
                        state        <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
