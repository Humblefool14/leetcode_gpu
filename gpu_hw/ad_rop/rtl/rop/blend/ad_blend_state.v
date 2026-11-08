// ad_blend_state -- STATE snooping and per-attachment selection for ad_rop_blend
// (spec ad_rop_blend.md §4 "With CAPS[30]", §10 ASSUMPTIONs).
// Keeps BLEND/BLEND1-3, BLEND_CONST, BLEND_CONST_R-A (as f2u8 of the written fp32), WRITE_MASK,
// RT_FORMATS, RT_FORMAT (decoded to a VkFormat when written), ROP_CTRL[1,2,7], LOGIC_OP.
// Outputs (combinational from the registers) are the state of attachment rt.
`include "ad_rop_state.vh"
module ad_blend_state (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        st_we,
    input  wire [8:0]  st_idx,
    input  wire [31:0] st_wdata,
    input  wire [1:0]  rt,
    output wire [26:0] blend,    // BLEND word of rt
    output wire [7:0]  fmt,      // VkFormat of rt
    output wire [3:0]  wmask,    // {A,B,G,R}
    output wire        lop_en,
    output wire [3:0]  lop_op,
    output wire [31:0] kconst,   // RGBA8 constant, R in [7:0]
    output wire        dual      // ROP_CTRL[7]
);
    reg [26:0] bl0, bl1, bl2, bl3;
    reg [31:0] bconst;
    reg [15:0] wm;
    reg [31:0] rtfmts;
    reg [7:0]  legacy;            // RT_FORMAT decoded to a VkFormat
    reg [7:0]  kf0, kf1, kf2, kf3;
    reg        c_fconst, c_logic, c_dual;
    reg [4:0]  lo0, lo1, lo2, lo3; // LOGIC_OP byte k [4:0]

    wire [7:0] fu;
    ad_rop_f2u8 u_f2u8 (.f(st_wdata), .u(fu));

    // continuous assignment (an always @(*) would not evaluate at time 0 in simulation)
    // ASSUMPTION: codes other than 0..3 -> format 0 (outside the list: not written)
    wire [7:0] legacy_dec = (st_wdata == 32'd0) ? `AD_VK_BGRA8 :
                            (st_wdata == 32'd1) ? `AD_VK_RGBA8 :
                            (st_wdata == 32'd2 || st_wdata == 32'd3) ? `AD_VK_R5G6B5 : 8'd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            bl0 <= 27'd0; bl1 <= 27'd0; bl2 <= 27'd0; bl3 <= 27'd0;
            bconst <= 32'd0; wm <= 16'd0; rtfmts <= 32'd0; legacy <= `AD_VK_BGRA8;
            kf0 <= 8'd0; kf1 <= 8'd0; kf2 <= 8'd0; kf3 <= 8'd0;
            c_fconst <= 1'b0; c_logic <= 1'b0; c_dual <= 1'b0;
            lo0 <= 5'd0; lo1 <= 5'd0; lo2 <= 5'd0; lo3 <= 5'd0;
        end else if (st_we) begin
            case (st_idx)
                `AD_S_BLEND:         bl0 <= st_wdata[26:0];
                `AD_S_BLEND1:        bl1 <= st_wdata[26:0];
                `AD_S_BLEND2:        bl2 <= st_wdata[26:0];
                `AD_S_BLEND3:        bl3 <= st_wdata[26:0];
                `AD_S_BLEND_CONST:   bconst <= st_wdata;
                `AD_S_WRITE_MASK:    wm <= st_wdata[15:0];
                `AD_S_RT_FORMATS:    rtfmts <= st_wdata;
                `AD_S_RT_FORMAT:     legacy <= legacy_dec;
                `AD_S_BLEND_CONST_R: kf0 <= fu;
                `AD_S_BLEND_CONST_G: kf1 <= fu;
                `AD_S_BLEND_CONST_B: kf2 <= fu;
                `AD_S_BLEND_CONST_A: kf3 <= fu;
                `AD_S_ROP_CTRL: begin
                    c_fconst <= st_wdata[`AD_ROPC_FCONST];
                    c_logic  <= st_wdata[`AD_ROPC_LOGIC];
                    c_dual   <= st_wdata[`AD_ROPC_DUALSRC];
                end
                `AD_S_LOGIC_OP: begin
                    lo0 <= st_wdata[4:0];   lo1 <= st_wdata[12:8];
                    lo2 <= st_wdata[20:16]; lo3 <= st_wdata[28:24];
                end
                default: ;
            endcase
        end
    end

    reg [26:0] bl_s; reg [7:0] fmt_s; reg [3:0] wm_s; reg [4:0] lo_s;
    always @(*) begin
        case (rt)
            2'd0: begin bl_s = bl0; wm_s = wm[3:0];   lo_s = lo0;
                        fmt_s = (rtfmts[7:0] == 8'd0) ? legacy : rtfmts[7:0]; end
            2'd1: begin bl_s = bl1; wm_s = wm[7:4];   lo_s = lo1; fmt_s = rtfmts[15:8];  end
            2'd2: begin bl_s = bl2; wm_s = wm[11:8];  lo_s = lo2; fmt_s = rtfmts[23:16]; end
            default: begin bl_s = bl3; wm_s = wm[15:12]; lo_s = lo3; fmt_s = rtfmts[31:24]; end
        endcase
    end
    assign blend  = bl_s;
    assign fmt    = fmt_s;
    assign wmask  = wm_s;
    assign lop_en = c_logic | lo_s[0];
    assign lop_op = lo_s[4:1];
    assign kconst = c_fconst ? {kf3, kf2, kf1, kf0} : bconst;
    assign dual   = c_dual;
endmodule
