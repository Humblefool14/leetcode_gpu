// ad_amb_client_props -- properties of an AMB client port (design §4.1).
// Instantiate in a formal harness beside the client.  Asserts what the client
// must do (payload held until ready); assumes what the memory side guarantees
// (one response per request, none unasked).  MAXOUT bounds outstanding requests
// for the assumption counter only.
module ad_amb_client_props #(
    parameter LINE_BYTES = 32,
    parameter LINE_W     = 27,
    parameter CNT_W      = 5
) (
    input wire                   clk,
    input wire                   rst_n,
    input wire                   req_valid,
    input wire                   req_ready,
    input wire                   req_write,
    input wire [LINE_W-1:0]      req_line,
    input wire [LINE_BYTES-1:0]  req_be,
    input wire [LINE_BYTES*8-1:0] req_wdata,
    input wire [7:0]             req_tag,
    input wire                   rsp_valid,
    output reg [CNT_W-1:0]       outstanding
);
    reg past_ok = 1'b0;
    reg              p_valid, p_ready, p_write;
    reg [LINE_W-1:0] p_line;
    reg [LINE_BYTES-1:0] p_be;
    reg [LINE_BYTES*8-1:0] p_wdata;
    reg [7:0]        p_tag;
    initial outstanding = 0;
    always @(posedge clk) begin
        past_ok <= rst_n;          // no past-value checks across the reset cycle
        p_valid <= req_valid; p_ready <= req_ready; p_write <= req_write;
        p_line <= req_line; p_be <= req_be; p_wdata <= req_wdata; p_tag <= req_tag;
        if (!rst_n) outstanding <= 0;
        else outstanding <= outstanding + (req_valid && req_ready) - rsp_valid;
    end
    always @(*) begin
        // memory side: responses only for outstanding requests
        if (outstanding == 0 && !(past_ok && p_valid && p_ready)) assume (!rsp_valid);
        if (!rst_n) assume (!rsp_valid);
    end
    always @(posedge clk) if (past_ok && rst_n) begin
        // client: a request, once raised, keeps its payload until taken
        if (p_valid && !p_ready) begin
            a_hold_v:  assert (req_valid);
            a_hold_w:  assert (req_write == p_write);
            a_hold_l:  assert (req_line  == p_line);
            a_hold_t:  assert (req_tag   == p_tag);
            if (p_write) begin
                a_hold_be: assert (req_be    == p_be);
                a_hold_d:  assert (req_wdata == p_wdata);
            end
        end
    end
endmodule
