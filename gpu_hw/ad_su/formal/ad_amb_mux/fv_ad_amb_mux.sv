// fv_ad_amb_mux -- ad_amb_mux with N = 2 clients.  Reduction: ADDR_W = 8, LINE_SHIFT = 0,
// LINE_BYTES = 1 (the payload is only multiplexed), TBL_LOG2 = TL (2 for prove, 4 for bmc16).
// Clients are assumed to obey AMB (hold until ready).  The memory side may answer any
// outstanding internal tag, in any order, once, at least one cycle after the request.
// Downstream: ad_amb_client_props (hold-until-ready) + no internal tag reused while
// outstanding.  Upstream (memory-side view of each client): a response goes only to the
// requester of that request, with its original tag, once; a client with nothing outstanding
// never gets a response; payload of a forwarded request equals the granted client's.
module fv_ad_amb_mux #(
    parameter TL = 2
) (
    input wire        clk,
    input wire        rst_n,
    input wire [1:0]  c_req_valid,
    input wire [1:0]  c_req_write,
    input wire [15:0] c_req_line,
    input wire [1:0]  c_req_be,
    input wire [15:0] c_req_wdata,
    input wire [15:0] c_req_tag,
    input wire        m_req_ready,
    input wire        m_rsp_valid,
    input wire        m_rsp_write,
    input wire [7:0]  m_rsp_tag,
    input wire [7:0]  m_rsp_rdata,
    input wire        m_rsp_error
);
    localparam T = 1 << TL;
`ifdef AD_FV_MUX
    wire [T-1:0] f_v, f_req; wire [T*8-1:0] f_tag; wire f_lock, f_lreq; wire [TL-1:0] f_lidx;
`endif
    wire [1:0] c_req_ready, c_rsp_valid; wire c_rsp_write, c_rsp_error; wire [7:0] c_rsp_tag, c_rsp_rdata;
    wire m_req_valid, m_req_write; wire [7:0] m_req_line, m_req_wdata, m_req_tag; wire m_req_be;
    ad_amb_mux #(.ADDR_W(8), .LINE_BYTES(1), .LINE_SHIFT(0), .N(2), .TBL_LOG2(TL)) dut (.clk(clk), .rst_n(rst_n),
        .c_req_valid(c_req_valid), .c_req_ready(c_req_ready), .c_req_write(c_req_write), .c_req_line(c_req_line),
        .c_req_be(c_req_be), .c_req_wdata(c_req_wdata), .c_req_tag(c_req_tag), .c_rsp_valid(c_rsp_valid),
        .c_rsp_write(c_rsp_write), .c_rsp_tag(c_rsp_tag), .c_rsp_rdata(c_rsp_rdata), .c_rsp_error(c_rsp_error),
        .m_req_valid(m_req_valid), .m_req_ready(m_req_ready), .m_req_write(m_req_write), .m_req_line(m_req_line),
        .m_req_be(m_req_be), .m_req_wdata(m_req_wdata), .m_req_tag(m_req_tag), .m_rsp_valid(m_rsp_valid),
        .m_rsp_write(m_rsp_write), .m_rsp_tag(m_rsp_tag), .m_rsp_rdata(m_rsp_rdata), .m_rsp_error(m_rsp_error)
`ifdef AD_FV_MUX
        , .fv_ent_v(f_v), .fv_ent_req(f_req), .fv_ent_tag(f_tag), .fv_lock(f_lock), .fv_lock_req(f_lreq), .fv_lock_idx(f_lidx)
`endif
        );

    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);

    // downstream port: shared client properties (hold-until-ready asserted).
    // Work-around: ad_amb_client_props samples req_valid during reset and then checks the
    // hold in the first cycle after reset; we feed it req_valid qualified by rst_n.
    wire [4:0] m_out;
    ad_amb_client_props #(.LINE_BYTES(1), .LINE_W(8), .CNT_W(5)) u_mprops (.clk(clk), .rst_n(rst_n),
        .req_valid(m_req_valid && rst_n), .req_ready(m_req_ready), .req_write(m_req_write), .req_line(m_req_line),
        .req_be(m_req_be), .req_wdata(m_req_wdata), .req_tag(m_req_tag), .rsp_valid(m_rsp_valid), .outstanding(m_out));

    // clients obey AMB: payload held until ready
    reg [1:0] p_cv, p_cr, p_cw; reg [15:0] p_cl, p_cd, p_ct; reg [1:0] p_cb;
    always @(posedge clk) begin
        p_cv <= rst_n ? c_req_valid : 2'b00; p_cr <= c_req_ready; p_cw <= c_req_write; p_cl <= c_req_line;
        p_cd <= c_req_wdata; p_ct <= c_req_tag; p_cb <= c_req_be;
    end
    genvar g;
    generate for (g = 0; g < 2; g = g + 1) begin : g_ca
        always @(*) if (!init && rst_n && p_cv[g] && !p_cr[g]) begin
            assume (c_req_valid[g]);
            assume (c_req_write[g] == p_cw[g]);
            assume (c_req_line[8*g +: 8] == p_cl[8*g +: 8]);
            assume (c_req_wdata[8*g +: 8] == p_cd[8*g +: 8]);
            assume (c_req_tag[8*g +: 8] == p_ct[8*g +: 8]);
            assume (c_req_be[g] == p_cb[g]);
        end
    end endgenerate

    // reference table of outstanding downstream requests
    reg [T-1:0] out_t; reg hcli [0:T-1]; reg [7:0] htag [0:T-1]; reg hw [0:T-1];
    reg [4:0] cnt0, cnt1;
    wire m_fire = m_req_valid && m_req_ready;
    wire gi = c_req_ready[1];                  // granted client at a fire
    wire [TL-1:0] mt = m_req_tag[TL-1:0];
    wire [TL-1:0] rt = m_rsp_tag[TL-1:0];
    // memory side: answer only outstanding internal tags, with the matching type
    always @(*) begin
        if (!rst_n) assume (!m_rsp_valid);
        if (m_rsp_valid) begin
            assume (m_rsp_tag < T);
            assume (out_t[rt]);
            assume (m_rsp_write == hw[rt]);
        end
    end
    always @(posedge clk) begin
        if (!rst_n) begin out_t <= 0; cnt0 <= 0; cnt1 <= 0; end
        else begin
            if (m_rsp_valid) out_t[rt] <= 1'b0;
            if (m_fire) begin out_t[mt] <= 1'b1; hcli[mt] <= gi; htag[mt] <= c_req_tag[8*gi +: 8]; hw[mt] <= m_req_write; end
            cnt0 <= cnt0 + (c_req_valid[0] && c_req_ready[0]) - c_rsp_valid[0];
            cnt1 <= cnt1 + (c_req_valid[1] && c_req_ready[1]) - c_rsp_valid[1];
        end
    end

    always @(*) if (!init && rst_n) begin
        // request side
        a_rdy_onehot: assert (c_req_ready != 2'b11);
        if (c_req_ready[0]) a_rdy0_v: assert (c_req_valid[0]);
        if (c_req_ready[1]) a_rdy1_v: assert (c_req_valid[1]);
        a_fire_eq: assert (m_fire == (|c_req_ready));
        if (m_fire) begin
            a_tag_free: assert (m_req_tag < T && !out_t[mt]);
            a_pl_w: assert (m_req_write == c_req_write[gi]);
            a_pl_l: assert (m_req_line  == c_req_line[8*gi +: 8]);
            a_pl_d: assert (m_req_wdata == c_req_wdata[8*gi +: 8]);
            a_pl_b: assert (m_req_be    == c_req_be[gi]);
        end
        // response side
        if (m_rsp_valid) begin
            a_rsp_route: assert (c_rsp_valid == (hcli[rt] ? 2'b10 : 2'b01));
            a_rsp_tag:   assert (c_rsp_tag == htag[rt]);
        end else a_rsp_none: assert (c_rsp_valid == 2'b00);
        a_rsp_d: assert (c_rsp_rdata == m_rsp_rdata && c_rsp_write == m_rsp_write && c_rsp_error == m_rsp_error);
        if (c_rsp_valid[0]) a_out0: assert (cnt0 != 0);
        if (c_rsp_valid[1]) a_out1: assert (cnt1 != 0);
        a_m_out: assert (m_out <= T);
    end
`ifdef AD_FV_MUX
    // helper invariants (k-induction): the DUT table equals the reference table
    integer x; reg [4:0] pc0, pc1;
    always @(*) begin
        pc0 = 0; pc1 = 0;
        for (x = 0; x < T; x = x + 1) begin
            if (out_t[x] && !hcli[x]) pc0 = pc0 + 1;
            if (out_t[x] &&  hcli[x]) pc1 = pc1 + 1;
        end
        if (!init && rst_n) begin
            h_v:   assert (f_v == out_t);
            for (x = 0; x < T; x = x + 1)
                if (out_t[x]) assert (f_req[x] == hcli[x] && f_tag[8*x +: 8] == htag[x]);
            h_c0:  assert (cnt0 == pc0);
            h_c1:  assert (cnt1 == pc1);
            h_mo:  assert (m_out == pc0 + pc1);
            if (f_lock) begin
                h_l1: assert (!out_t[f_lidx]);
                h_l2: assert (p_cv[f_lreq] && !p_cr[f_lreq]);
            end
        end
    end
`endif
    always @(*) if (!init && rst_n) begin
        c_full:  cover (out_t == {T{1'b1}} && c_req_valid != 0);
        c_both:  cover (m_rsp_valid && c_rsp_valid[1] && cnt0 != 0);
    end
endmodule
