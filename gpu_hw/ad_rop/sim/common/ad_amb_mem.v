// ad_amb_mem -- behavioural AMB memory for testbenches (design §4.1 client port).
// Requests: valid/ready, payload held until ready; ready is randomised (READY_PCT).
// Responses: in order, one per request, one cycle, no back-pressure, after a
// random latency of LAT_MIN..LAT_MAX cycles.  Byte-addressable backdoor `mem`.
// Lines at or above MEM_LINES answer rsp_error (the line is not accessed).
`timescale 1ns/1ps
module ad_amb_mem #(
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5,
    parameter ADDR_W     = 32,
    parameter MEM_LINES  = 4096,
    parameter LAT_MIN    = 2,
    parameter LAT_MAX    = 12,
    parameter READY_PCT  = 70,
    parameter SEED       = 1
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          req_valid,
    output reg                           req_ready,
    input  wire                          req_write,
    input  wire [ADDR_W-LINE_SHIFT-1:0]  req_line,
    input  wire [LINE_BYTES-1:0]         req_be,
    input  wire [LINE_BYTES*8-1:0]       req_wdata,
    input  wire [7:0]                    req_tag,
    output reg                           rsp_valid,
    output reg                           rsp_write,
    output reg  [7:0]                    rsp_tag,
    output reg  [LINE_BYTES*8-1:0]       rsp_rdata,
    output reg                           rsp_error
);
    reg [7:0] mem [0:MEM_LINES*LINE_BYTES-1];
    integer seed = SEED;
    // pending responses (in order)
    reg [LINE_BYTES*8-1:0] q_data [0:63];
    reg [7:0]  q_tag  [0:63];
    reg        q_wr   [0:63], q_err [0:63];
    integer    q_due  [0:63];
    integer    head, tail, cyc, i, last_due;
    integer    n_reads, n_writes;
    reg [ADDR_W-1:0] base;

    task clear(input [7:0] v); integer k; begin for (k = 0; k < MEM_LINES*LINE_BYTES; k = k + 1) mem[k] = v; end endtask

    initial begin head = 0; tail = 0; cyc = 0; last_due = 0; n_reads = 0; n_writes = 0; end

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (!rst_n) begin
            req_ready <= 1'b0; rsp_valid <= 1'b0; head <= 0; tail <= 0;
        end else begin
            // accept
            if (req_valid && req_ready) begin
                base = req_line << LINE_SHIFT;
                q_tag[tail % 64] = req_tag;
                q_wr[tail % 64]  = req_write;
                q_err[tail % 64] = (req_line >= MEM_LINES);
                if (!q_err[tail % 64]) begin
                    for (i = 0; i < LINE_BYTES; i = i + 1) begin
                        if (req_write && req_be[i]) mem[base + i] = req_wdata[8*i +: 8];
                        q_data[tail % 64][8*i +: 8] = mem[base + i];
                    end
                end else q_data[tail % 64] = {LINE_BYTES*8{1'bx}};
                if (req_write) n_writes = n_writes + 1; else n_reads = n_reads + 1;
                // in-order completion, strictly increasing due cycles
                q_due[tail % 64] = cyc + LAT_MIN + ($unsigned($random(seed)) % (LAT_MAX - LAT_MIN + 1));
                if (q_due[tail % 64] <= last_due) q_due[tail % 64] = last_due + 1;
                last_due = q_due[tail % 64];
                tail = tail + 1;
            end
            req_ready <= (($unsigned($random(seed)) % 100) < READY_PCT) && (tail - head < 60);
            // respond
            rsp_valid <= 1'b0;
            if (head != tail && q_due[head % 64] <= cyc) begin
                rsp_valid <= 1'b1;
                rsp_write <= q_wr[head % 64];
                rsp_tag   <= q_tag[head % 64];
                rsp_rdata <= q_wr[head % 64] ? {LINE_BYTES*8{1'bx}} : q_data[head % 64];
                rsp_error <= q_err[head % 64];
                head = head + 1;
            end
        end
    end
endmodule
