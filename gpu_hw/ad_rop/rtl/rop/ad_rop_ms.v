// ad_rop_ms -- multisample coverage (spec/gpu/rop/ad_rop_ms.md): the samples of
// a quad that go on, the depth of every sample, alpha to coverage, alpha to one.
// One quad (beat) at a time: IDLE -> (four samples) Z -> OUT -> IDLE, or
// IDLE -> OUT (one sample, or a later beat), or dropped in IDLE.
// Four-sample depths: 16 adds through one ad_fp_add, one per cycle, its result
// registered once before the clamps: Z lasts 17 cycles.
`include "ad_rop_state.vh"
module ad_rop_ms (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         st_we,
    input  wire [8:0]   st_idx,
    input  wire [31:0]  st_wdata,
    input  wire         i_valid,
    output wire         i_ready,
    input  wire [31:0]  i_xy,
    input  wire [3:0]   i_mask,
    input  wire [511:0] i_color,
    input  wire [127:0] i_depth,
    input  wire         i_dbg,
    input  wire [153:0] i_aux,
    output wire         o_valid,
    input  wire         o_ready,
    output reg  [31:0]  o_xy,
    output reg  [15:0]  o_smask,
    output reg  [511:0] o_color,
    output reg  [511:0] o_sdepth,
    output reg          o_dbg,
    output reg          o_front,
    output reg  [3:0]   o_beat,
    output wire         busy
);
    localparam [1:0] S_IDLE = 2'd0, S_Z = 2'd1, S_OUT = 2'd2;
    localparam [31:0] ONE = 32'h3F80_0000;

    // ---------------- STATE ----------------
    reg        ms_four, ms_a2c, ms_a21;   // MS_CTRL [3:0]==2, [8], [9]
    reg        dc_mm, dc_rx;              // DEPTH_CLAMP [0], [1]
    reg [31:0] vp_scale, vp_n, vp_f;      // z scale, n = z offset, f = n + scale
    reg        vp_upd;
    wire [31:0] vp_sum;
    // the viewport's f: its own adder, so a STATE write never competes with Z
    ad_fp_add u_vpadd (.a(vp_n), .b(vp_scale), .sub(1'b0), .y(vp_sum));
    wire nf_lt, nf_eq, nf_un;
    ad_fp_cmp u_nf (.a(vp_f), .b(vp_n), .lt(nf_lt), .eq(nf_eq), .un(nf_un));   // f < n
    wire [31:0] z_lo = nf_lt ? vp_f : vp_n;   // min(n, f)  (NaN: n)
    wire [31:0] z_hi = nf_lt ? vp_n : vp_f;   // max(n, f)  (NaN in f: f)

    always @(posedge clk) begin
        if (!rst_n) begin
            ms_four <= 1'b0; ms_a2c <= 1'b0; ms_a21 <= 1'b0;
            dc_mm <= 1'b0; dc_rx <= 1'b0;
            vp_scale <= 32'd0; vp_n <= 32'd0; vp_f <= 32'd0; vp_upd <= 1'b0;
        end else begin
            vp_upd <= st_we && (st_idx == `AD_S_VP_ZSCALE || st_idx == `AD_S_VP_ZOFFSET);
            if (vp_upd) vp_f <= vp_sum;
            if (st_we) begin
                if (st_idx == `AD_S_MS_CTRL) begin
                    ms_four <= (st_wdata[3:0] == 4'd2);
                    ms_a2c  <= st_wdata[8];
                    ms_a21  <= st_wdata[9];
                end
                if (st_idx == `AD_S_DEPTH_CLAMP) begin
                    dc_mm <= st_wdata[0];
                    dc_rx <= st_wdata[1];
                end
                if (st_idx == `AD_S_VP_ZSCALE)  vp_scale <= st_wdata;
                if (st_idx == `AD_S_VP_ZOFFSET) vp_n     <= st_wdata;
            end
        end
    end

    // ---------------- input side (IDLE) ----------------
    reg  [1:0] st;
    assign i_ready = (st == S_IDLE);
    wire fire  = i_valid && i_ready;
    wire first = i_aux[150];

    // alpha to coverage per lane (COLOR0 alpha = channel 3)
    wire [15:0] a2c_m;
    wire [3:0]  a2c_h;
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_lane
            ad_ms_a2c u_a2c (.alpha(i_color[128*g + 96 +: 32]), .mask(a2c_m[4*g +: 4]), .half(a2c_h[g]));
        end
    endgenerate
    wire [15:0] cov;
    ad_ms_cov u_cov (.four(ms_four), .a2c(ms_a2c && !i_dbg), .sin(i_aux[15:0]), .lanes(i_mask),
                     .a2c_m(a2c_m), .a2c_h(a2c_h), .smask(cov));

    // alpha to one (every beat, not the direct path)
    reg [511:0] col_in;
    integer l;
    always @(*) begin
        col_in = i_color;
        if (ms_a21 && !i_dbg)
            for (l = 0; l < 4; l = l + 1) col_in[128*l + 96 +: 32] = ONE;
    end

    // one sample: the depth as given, then DEPTH_CLAMP[0]; sample words 4l
    wire [511:0] sd1;
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_one
            ad_ms_zclamp u_zc1 (.x(i_depth[32*g +: 32]), .en01(1'b0), .enmm(dc_mm),
                                .lo(z_lo), .hi(z_hi), .y(sd1[128*g +: 32]));
            assign sd1[128*g + 32 +: 96] = 96'd0;
        end
    endgenerate

    // ---------------- Z: 16 adds through one adder ----------------
    reg [127:0] z_r, ds_r;
    reg [3:0]   zx_r;
    reg [4:0]   k;              // issue index 0..16
    reg         p_v, p_en01;
    reg [3:0]   p_k;
    reg [31:0]  p_x;
    wire [1:0]  k_l = k[3:2];
    wire [1:0]  k_s = k[1:0];
    wire [31:0] z_sel = z_r[32*k_l +: 32];
    wire [31:0] d_sel = ds_r[32*k_s +: 32];   // sample offset s, shared by the lanes
    wire [31:0] z_sum, z_cl;
    ad_fp_add    u_zadd (.a(z_sel), .b(d_sel), .sub(1'b0), .y(z_sum));
    ad_ms_zclamp u_zc4  (.x(p_x), .en01(p_en01), .enmm(dc_mm), .lo(z_lo), .hi(z_hi), .y(z_cl));

    // ---------------- control ----------------
    reg drop;   // the last first beat was dropped (its later beats go too)
    always @(posedge clk) begin
        if (!rst_n) begin
            st   <= S_IDLE;
            drop <= 1'b1;
            k    <= 5'd0;
            p_v  <= 1'b0;
        end else begin
            p_v <= 1'b0;
            case (st)
            S_IDLE: if (fire) begin
                if (first) begin
                    if (cov == 16'd0) drop <= 1'b1;
                    else begin
                        drop <= 1'b0;
                        k    <= 5'd0;
                        st   <= ms_four ? S_Z : S_OUT;
                    end
                end else if (!drop)
                    st <= S_OUT;
            end
            S_Z: begin
                p_v <= !k[4];
                k   <= k + 5'd1;
                if (k[4]) st <= S_OUT;
            end
            default: if (o_ready) st <= S_IDLE;   // S_OUT
            endcase
        end
    end

    // ---------------- datapath registers ----------------
    always @(posedge clk) begin
        if (st == S_IDLE && fire && !(first ? (cov == 16'd0) : drop)) begin
            o_xy    <= i_xy;
            o_color <= col_in;
            o_dbg   <= i_dbg;
            o_front <= i_aux[148];
            o_beat  <= {i_aux[153:152], i_aux[149], i_aux[150]};
            if (first) begin
                o_smask <= cov;
                if (ms_four) begin
                    z_r  <= i_depth;
                    ds_r <= i_aux[147:20];
                    zx_r <= i_aux[19:16];
                end else
                    o_sdepth <= sd1;
            end
        end
        if (st == S_Z) begin
            p_x    <= zx_r[k_l] ? z_sel : z_sum;
            p_en01 <= !zx_r[k_l] && !dc_rx;
            p_k    <= k[3:0];
        end
        if (p_v) o_sdepth[32*p_k +: 32] <= z_cl;
    end

    assign o_valid = (st == S_OUT);
    assign busy    = (st != S_IDLE);
endmodule
