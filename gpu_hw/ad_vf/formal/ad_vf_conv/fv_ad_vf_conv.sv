// fv_ad_vf_conv -- ad_vf_conv against a cycle model of spec sections 4-7, written from the spec:
//  * af_ready is high iff idle or in the last slot of the current af;
//  * an af taken in cycle T occupies cycles T+1 .. T+max(n,1), n = ATTR_DST count (0 if the whole
//    ATTR_DST word is 0); vl_we is high exactly in T+1 .. T+n with vl_reg = ATTR_DST[5:0] + c (mod 64)
//    and the af's lane; the number of vl_we per af is n (counted, a_count);
//  * conv_done is high exactly in the cycle after the last slot of an af with af_last (one pulse per
//    af_last: counters a_done_le / a_done_eq);
//  * words (cheap formats): legacy R32F..RGBA32F / R32UI / RG32UI words are the raw 32-bit fields,
//    components beyond the format and the reserved codes 10..15 fill (0,0,0,1 / 1.0), and af_oob
//    fills (0,0,0,1 / 1.0) for every legacy code (VkFormat afs: timing/count only).  Only with
//    FV_DATA (tasks *_data): the word check pulls the converters into the cone of influence.
// The harness keeps its own shadow of ATTR_DST / ATTR_DESC[19:16] from the STATE broadcast.  All
// inputs are free every cycle (STATE writes are allowed even while busy: the block latches at take).
`include "ad_vf_state.vh"
module fv_ad_vf_conv (
    input wire         clk,
    input wire         rst_n,
    input wire         st_we,
    input wire [8:0]   st_idx,
    input wire [31:0]  st_wdata,
    input wire         af_valid,
    input wire [3:0]   af_attr,
    input wire [4:0]   af_lane,
    input wire [127:0] af_raw,
    input wire         af_oob,
    input wire         af_last
);
    wire af_ready, vl_we, conv_done; wire [5:0] vl_reg; wire [4:0] vl_lane; wire [31:0] vl_data;
    ad_vf_conv dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .af_valid(af_valid), .af_ready(af_ready), .af_attr(af_attr), .af_lane(af_lane), .af_raw(af_raw),
        .af_oob(af_oob), .af_last(af_last), .vl_we(vl_we), .vl_reg(vl_reg), .vl_lane(vl_lane),
        .vl_data(vl_data), .conv_done(conv_done));

    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);

    // shadow STATE: {en, vk==0, cnt, reg} of ATTR_DST, legacy format of ATTR_DESC
    reg [9:0] sd [0:15]; reg [3:0] sl [0:15];
    integer x;
    always @(posedge clk)
        for (x = 0; x < 16; x = x + 1)
            if (!rst_n) begin sd[x] <= 10'd0 | 10'h100; sl[x] <= 4'd0; end
            else if (st_we) begin
                if (st_idx == `AD_S_ATTR_DST(x))  sd[x] <= {st_wdata != 32'd0, st_wdata[31:24] == 8'd0, st_wdata[7:0]};
                if (st_idx == `AD_S_ATTR_DESC(x)) sl[x] <= st_wdata[19:16];
            end

    // cycle model
    reg m_act, m_en, m_last, m_done, m_oob, m_vk0; reg [1:0] m_c, m_n; reg [5:0] m_reg; reg [4:0] m_lane;
    reg [3:0] m_lf; reg [127:0] m_raw; reg [2:0] m_seen;
    reg [3:0] n_lastin, n_done;
    wire m_lslot = m_act && (m_c == m_n);
    wire take = af_valid && af_ready;
    wire [9:0] a_sd = sd[af_attr];
    always @(posedge clk) begin
        if (!rst_n) begin
            m_act <= 1'b0; m_done <= 1'b0; m_c <= 2'd0; m_n <= 2'd0; m_seen <= 3'd0;
            n_lastin <= 4'd0; n_done <= 4'd0;
        end else begin
            m_done <= m_lslot && m_last;
            n_done <= n_done + {3'd0, conv_done};
            if (take) begin
                m_act <= 1'b1; m_c <= 2'd0; m_n <= a_sd[9] ? a_sd[7:6] : 2'd0; m_en <= a_sd[9];
                m_reg <= a_sd[5:0]; m_vk0 <= a_sd[8]; m_lf <= sl[af_attr];
                m_lane <= af_lane; m_raw <= af_raw; m_oob <= af_oob; m_last <= af_last;
                m_seen <= 3'd0;
                n_lastin <= n_lastin + {3'd0, af_last};
            end else if (m_act && m_c != m_n) m_c <= m_c + 2'd1;
            else m_act <= 1'b0;
            if (vl_we && !take) m_seen <= m_seen + 3'd1;
        end
    end

    // expected word of the cheap legacy formats (vk == 0)
    reg chk; reg [31:0] ew; reg [2:0] nc; reg isint;
    always @(*) begin
        nc = 3'd0; isint = 1'b0;
        case (m_lf)
            4'd0, 4'd1, 4'd2, 4'd3: nc = {1'b0, m_lf[1:0]} + 3'd1;
            4'd4, 4'd5: begin nc = {2'b0, m_lf[0]} + 3'd1; isint = 1'b1; end
            4'd6: nc = 3'd2;
            4'd7, 4'd8: nc = 3'd4;
            4'd9: begin nc = 3'd4; isint = 1'b1; end
            default: nc = 3'd0;
        endcase
        chk = m_vk0 && (m_oob || m_lf <= 4'd5 || m_lf >= 4'd10 || {1'b0, m_c} >= nc);
        if (m_oob || {1'b0, m_c} >= nc) ew = (m_c != 2'd3) ? 32'd0 : isint ? 32'd1 : 32'h3F80_0000;
        else ew = m_raw[32*m_c +: 32];
    end

    always @(*) if (!init && rst_n) begin
        a_ready: assert (af_ready == (!m_act || m_lslot));
        a_we:    assert (vl_we == (m_act && m_en));
        if (vl_we) begin
            a_reg:  assert (vl_reg == m_reg + {4'd0, m_c});
            a_lane: assert (vl_lane == m_lane);
`ifdef FV_DATA
            if (chk) a_data: assert (vl_data == ew);
`endif
        end
        a_done: assert (conv_done == m_done);
        // words per af: at the last slot, the af has had exactly n (ATTR_DST count, 0 disabled) words
        if (m_lslot) a_count: assert (m_seen + {2'd0, vl_we} == (m_en ? {1'b0, m_n} + 3'd1 : 3'd0));
        // one conv_done per af_last: never more dones than af_last afs, at most two pending (one in its slot, one done due)
        a_done_le: assert (n_lastin - n_done <= 4'd2);
        if (!m_act && !m_done) a_done_eq: assert (n_lastin == n_done);
    end

    // covers: back-to-back afs with 4 words, a disabled af, conv_done
    reg p_lslot; always @(posedge clk) p_lslot <= m_lslot && m_n == 2'd3;
    always @(*) if (!init && rst_n) begin
        c_b2b:  cover (p_lslot && take && a_sd[9] && a_sd[7:6] == 2'd3);
        c_dis:  cover (m_act && !m_en && m_last);
        c_done: cover (conv_done && n_done == 4'd2);
    end
endmodule
