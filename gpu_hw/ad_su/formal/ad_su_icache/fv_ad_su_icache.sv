// fv_ad_su_icache -- formal harness of ad_su_icache, reduced: IC_BYTES 32,
// LINE_BYTES 8 (4 lines of one instruction).  The AMB side is free within
// ad_amb_client_props (one response per request); for a symbolic line L the
// memory always answers the symbolic value D without error.  Checks:
// the AMB client properties (payload held until ready, reads only); every
// answer to a request in line L is D (hits equal a shadow of memory; in the
// RTL under AD_IC_FV with its helper invariants, L and D anyconst there);
// after inv, no request is a hit until a line requested after the inv has
// been filled (in the RTL under AD_IC_FV, a_inv_miss); one answer per taken
// request, the cycle after.
module fv_ad_su_icache (
    input wire        clk,
    input wire        ic_req,
    input wire [31:0] ic_addr,
    input wire        inv,
    input wire        req_ready,
    input wire        rsp_valid,
    input wire [63:0] rsp_rdata,
    input wire        rsp_error
);
    reg init = 1'b1; always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    wire ic_ready, ic_rvalid, req_valid, req_write;
    wire [63:0] ic_rdata;
    wire [28:0] req_line;
    wire [7:0] req_be, req_tag;
    wire [63:0] req_wdata;
    ad_su_icache #(.ADDR_W(32), .LINE_BYTES(8), .LINE_SHIFT(3), .IC_BYTES(32)) dut (
        .clk(clk), .rst_n(rst_n), .ic_req(ic_req), .ic_ready(ic_ready), .ic_addr(ic_addr), .ic_rvalid(ic_rvalid),
        .ic_rdata(ic_rdata), .inv(inv), .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
        .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .rsp_write(1'b0), .rsp_tag(8'd0), .rsp_rdata(rsp_rdata), .rsp_error(rsp_error));
    wire [4:0] outstanding;
    ad_amb_client_props #(.LINE_BYTES(8), .LINE_W(29), .CNT_W(5)) amb (
        .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
        .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .outstanding(outstanding));

    // requester: holds its request until taken
    reg p_req, p_rdy; reg [31:0] p_addr;
    always @(posedge clk) begin p_req <= rst_n && ic_req; p_rdy <= ic_ready; p_addr <= ic_addr; end
    always @(*) if (rst_n && p_req && !p_rdy) assume (ic_req && ic_addr == p_addr);

    // memory: line L answers D
    reg [28:0] mline; reg after_inv; reg since_inv; reg p_rsp;
    always @(posedge clk) begin
        if (!rst_n) begin since_inv <= 1'b0; after_inv <= 1'b0; p_rsp <= 1'b0; end
        else begin
            p_rsp <= rsp_valid;
            if (req_valid && req_ready) begin mline <= req_line; after_inv <= !inv; end
            else if (inv) after_inv <= 1'b0;
            if (inv) since_inv <= 1'b1;
            else if (rsp_valid && after_inv) since_inv <= 1'b0;
        end
    end

    // answers
    reg tk; reg [31:0] tk_addr;
    always @(posedge clk) begin tk <= rst_n && ic_req && ic_ready; tk_addr <= ic_addr; end
    always @(*) if (rst_n) begin
        a_one: assert (ic_rvalid == tk);
        a_read: assert (!req_valid || !req_write);
    end
endmodule
