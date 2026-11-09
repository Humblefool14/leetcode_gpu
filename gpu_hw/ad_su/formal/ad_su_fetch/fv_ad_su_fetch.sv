// fv_ad_su_fetch -- formal harness of ad_su_fetch.
// Free inputs: the scheduler's request (held until taken: assumed), ic_ready,
// the I$ answer timing (in order, 1..3 cycles after acceptance), d_ready
// (never low two cycles in a row).  The I$ model answers hash(address); the
// address is assumed to be {pc, warp} so every output can be checked against
// its own warp and pc.  A tagged token (picked by a free input) checks order
// and that it leaves after the instructions ahead of it, within a bound.
module fv_ad_su_fetch (
    input wire        clk,
    input wire        f_valid,
    input wire [0:0]  f_warp,
    input wire [15:0] f_pc,
    input wire        ic_ready,
    input wire        ans,        // the I$ answers now (if it may)
    input wire        d_ready,
    input wire        pick
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;

    wire        f_ready, ic_req, ic_rvalid, d_valid;
    wire [31:0] ic_addr;
    wire [63:0] ic_rdata;
    wire [0:0]  d_warp;
    wire [15:0] d_pc;
    wire [63:0] d_instr;
    wire [31:0] f_addr = {15'd0, f_warp, f_pc};

    ad_su_fetch #(.WARP_W(1)) dut (
        .clk(clk), .rst_n(rst_n), .f_valid(f_valid), .f_ready(f_ready), .f_warp(f_warp), .f_pc(f_pc),
        .f_addr(f_addr), .ic_req(ic_req), .ic_ready(ic_ready), .ic_addr(ic_addr), .ic_rvalid(ic_rvalid),
        .ic_rdata(ic_rdata), .d_valid(d_valid), .d_ready(d_ready), .d_warp(d_warp), .d_pc(d_pc),
        .d_instr(d_instr));

    function [63:0] hash(input [31:0] a);
        hash = {a ^ 32'h5A5A_1234, ~a};
    endfunction

    // ---- I$ model: up to 3 outstanding, in order
    reg [31:0] qa0, qa1, qa2;
    reg [1:0]  qg0, qg1, qg2;     // ages
    reg [1:0]  qn;
    wire acc  = rst_n && ic_req && ic_ready;
    wire resp = rst_n && qn != 0 && qg0 != 0 && (ans || qg0 == 2'd3);
    assign ic_rvalid = resp;
    assign ic_rdata  = hash(qa0);
    always @(posedge clk) begin
        if (!rst_n) qn <= 0;
        else begin
            // age
            qg0 <= (qg0 == 2'd3) ? qg0 : qg0 + 1'b1;
            qg1 <= (qg1 == 2'd3) ? qg1 : qg1 + 1'b1;
            qg2 <= (qg2 == 2'd3) ? qg2 : qg2 + 1'b1;
            if (resp) begin
                qa0 <= qa1; qa1 <= qa2;
                qg0 <= (qg1 == 2'd3) ? qg1 : qg1 + 1'b1;
                qg1 <= (qg2 == 2'd3) ? qg2 : qg2 + 1'b1;
            end
            if (acc) begin
                case (qn - resp)
                2'd0: begin qa0 <= ic_addr; qg0 <= 0; end
                2'd1: begin qa1 <= ic_addr; qg1 <= 0; end
                default: begin qa2 <= ic_addr; qg2 <= 0; end
                endcase
            end
            qn <= qn + acc - resp;
        end
    end

    // ---- environment assumptions
    reg p_fv, p_fr, p_dr;
    reg [0:0] p_w; reg [15:0] p_pc;
    always @(posedge clk) begin
        p_fv <= rst_n && f_valid; p_fr <= f_ready; p_w <= f_warp; p_pc <= f_pc; p_dr <= d_ready;
    end
    always @(*) if (rst_n) begin
        if (p_fv && !p_fr) assume (f_valid && f_warp == p_w && f_pc == p_pc);
        if (!p_dr) assume (d_ready);
    end

    // ---- properties
    reg [2:0] inflight;      // accepted, not yet out
    reg       armed;
    reg [2:0] ahead;
    reg [16:0] tok;
    reg [4:0] age;
    wire push = rst_n && f_valid && f_ready;
    wire pop  = rst_n && d_valid && d_ready;
    always @(posedge clk) begin
        if (!rst_n) begin inflight <= 0; armed <= 0; age <= 0; end
        else begin
            inflight <= inflight + push - pop;
            if (armed) age <= age + 1'b1;
            if (armed && pop) begin
                if (ahead == 0) armed <= 1'b0;
                else ahead <= ahead - 1'b1;
            end
            if (push && pick && !armed) begin
                armed <= 1'b1; tok <= {f_warp, f_pc}; age <= 0;
                ahead <= inflight - pop;
            end
        end
    end
    always @(*) if (rst_n) begin
        a_inflight: assert (inflight <= 2);
        a_icq:      assert (qn <= 2 && qn <= inflight);
        a_ic_hold:  assert (!(ic_req && !f_valid));
        if (d_valid) begin
            a_data:  assert (d_instr == hash({15'd0, d_warp, d_pc}));
        end
        if (pop && armed && ahead == 0) begin
            a_order: assert ({d_warp, d_pc} == tok);
        end
        a_nolos: assert (!armed || age < 5'd14);
        a_ahead: assert (!armed || ahead < inflight);
    end
endmodule
