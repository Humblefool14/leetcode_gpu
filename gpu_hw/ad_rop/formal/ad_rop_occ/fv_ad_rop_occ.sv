// fv_ad_rop_occ -- count equals a reference model register; clear+inc leaves inc;
// ROP_CTRL[0]=0 never increments.
`include "ad_rop_state.vh"
module fv_ad_rop_occ (
    input wire clk,
    input wire rst_n,
    input wire st_we,
    input wire [8:0] st_idx,
    input wire [31:0] st_wdata,
    input wire inc_valid,
    input wire [4:0] inc_n,
    input wire clear
);
    wire [39:0] count;
    ad_rop_occ dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
                    .inc_valid(inc_valid), .inc_n(inc_n), .clear(clear), .count(count));
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);

    reg [39:0] m_count; reg m_en;
    reg p_clear, p_inc, p_en, p_rst; reg [4:0] p_n; reg [39:0] p_count;
    always @(posedge clk) begin
        if (!rst_n) begin m_count <= 0; m_en <= 0; end
        else begin
            m_count <= (clear ? 40'd0 : m_count) + ((inc_valid && m_en) ? {35'd0, inc_n} : 40'd0);
            if (st_we && st_idx == `AD_S_ROP_CTRL) m_en <= st_wdata[`AD_ROPC_OCC];
        end
        p_clear <= clear; p_inc <= inc_valid; p_en <= m_en; p_n <= inc_n; p_count <= count; p_rst <= rst_n;
    end
    always @(*) if (!init) begin
        a_model: assert (count == m_count);
    end
    always @(posedge clk) if (!init && p_rst) begin
        if (p_clear && p_inc && p_en) a_clr_inc: assert (count == {35'd0, p_n});
        if (!p_en && !p_clear)        a_no_inc:  assert (count == p_count);
        if (!p_en && p_clear)         a_clr:     assert (count == 0);
    end
endmodule
