// ad_vf_fetch_regs -- STATE snoop of ad_vf_fetch: ATTR_BASE/DESC/DST/LIMIT[0..15] and
// FIRST_INSTANCE (reset 0), the enable vector and the words of the selected attribute k.
// Attribute k is enabled when its whole ATTR_DST[k] word is not 0 (spec §4).
`include "ad_vf_state.vh"
module ad_vf_fetch_regs (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        st_we,
    input  wire [8:0]  st_idx,
    input  wire [31:0] st_wdata,
    input  wire [3:0]  k,             // selected attribute
    output wire [15:0] en,            // en[j] = ATTR_DST[j] != 0
    output wire [31:0] base,          // ATTR_BASE[k]
    output wire [31:0] desc,          // ATTR_DESC[k]
    output wire [31:0] dst,           // ATTR_DST[k]
    output wire [31:0] limit,         // ATTR_LIMIT[k]
    output reg  [31:0] first_inst     // FIRST_INSTANCE
);
    reg [31:0] r_base [0:15];
    reg [31:0] r_desc [0:15];
    reg [31:0] r_dst  [0:15];
    reg [31:0] r_lim  [0:15];

    genvar g;
    generate for (g = 0; g < 16; g = g + 1) begin : g_attr
        always @(posedge clk) begin
            if (!rst_n) begin
                r_base[g] <= 32'd0; r_desc[g] <= 32'd0; r_dst[g] <= 32'd0; r_lim[g] <= 32'd0;
            end else if (st_we) begin
                if (st_idx == `AD_S_ATTR_BASE(g))  r_base[g] <= st_wdata;
                if (st_idx == `AD_S_ATTR_DESC(g))  r_desc[g] <= st_wdata;
                if (st_idx == `AD_S_ATTR_DST(g))   r_dst[g]  <= st_wdata;
                if (st_idx == `AD_S_ATTR_LIMIT(g)) r_lim[g]  <= st_wdata;
            end
        end
        assign en[g] = (r_dst[g] != 32'd0);
    end endgenerate

    always @(posedge clk) begin
        if (!rst_n) first_inst <= 32'd0;
        else if (st_we && st_idx == `AD_S_FIRST_INSTANCE) first_inst <= st_wdata;
    end

    assign base  = r_base[k];
    assign desc  = r_desc[k];
    assign dst   = r_dst[k];
    assign limit = r_lim[k];
endmodule
