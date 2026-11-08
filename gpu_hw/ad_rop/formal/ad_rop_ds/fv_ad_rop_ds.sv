// fv_ad_rop_ds -- formal harness of ad_rop_ds (reduced: ADDR_W 10, LINE_BYTES 32;
// ad_rop_dtest abstracted by fv_dtest_stub.sv).  Free inputs are module ports.
//   - AMB client properties (formal/common/ad_amb_client_props.sv) + legal responses:
//     a response carries the tag of an outstanding request and its kind (tag[1] = write)
//   - one outstanding request per tag
//   - d_* stable while d_valid && !d_ready; q_ready and d_valid never together
//   - every write is to a line read for the same quad (after the quad was taken)
//   - read-after-write: no read of a line while a write of that line is outstanding
//   - busy low -> idle (q_ready), no request, nothing outstanding
//   - passthrough (anyconst pt: DEPTH writes keep every test off) -> no request ever
//   - covers: a tested quad written and sent; a passthrough quad sent
module fv_ad_rop_ds (
    input wire         clk,
    input wire         st_we,
    input wire [8:0]   st_idx,
    input wire [31:0]  st_wdata,
    input wire         q_valid,
    input wire [31:0]  q_xy,
    input wire [15:0]  q_smask,
    input wire [511:0] q_color,
    input wire [511:0] q_sdepth,
    input wire         q_dbg,
    input wire         q_front,
    input wire [3:0]   q_beat,
    input wire         d_ready,
    input wire         req_ready,
    input wire         rsp_valid,
    input wire         rsp_write,
    input wire [7:0]   rsp_tag,
    input wire [255:0] rsp_rdata,
    input wire         rsp_error
);
    localparam AW = 10, LB = 32, LS = 5, LW = AW - LS;
    // two reset cycles: ad_amb_client_props compares with the previous cycle as soon as
    // it has one (its past_ok ignores reset), and the DUT's registers are free during the
    // first reset cycle
    reg [1:0] init = 2'b11;
    always @(posedge clk) init <= {init[0], 1'b0};
    wire rst_n = !init[1];

    wire q_ready, d_valid, busy, req_valid, req_write;
    wire [31:0] d_xy; wire [15:0] d_smask; wire [511:0] d_color; wire [3:0] d_beat;
    wire [LW-1:0] req_line; wire [LB-1:0] req_be; wire [LB*8-1:0] req_wdata; wire [7:0] req_tag;

    ad_rop_ds #(.ADDR_W(AW), .LINE_BYTES(LB), .LINE_SHIFT(LS), .STENCIL(1)) dut (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .q_valid(q_valid), .q_ready(q_ready), .q_xy(q_xy), .q_smask(q_smask), .q_color(q_color),
        .q_sdepth(q_sdepth), .q_dbg(q_dbg), .q_front(q_front), .q_beat(q_beat),
        .d_valid(d_valid), .d_ready(d_ready), .d_xy(d_xy), .d_smask(d_smask), .d_color(d_color),
        .d_beat(d_beat), .busy(busy),
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line),
        .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag), .rsp_valid(rsp_valid),
        .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata), .rsp_error(rsp_error));

    wire [4:0] outstanding;
    ad_amb_client_props #(.LINE_BYTES(LB), .LINE_W(LW), .CNT_W(5)) props (
        .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
        .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .outstanding(outstanding));

    wire acc = req_valid && req_ready;
    // ---- per-tag outstanding (the DUT uses tags 0..3: {write, slot})
    reg [3:0] tout;
    reg [LW-1:0] wline0, wline1;           // line of the outstanding write of slot 0 / 1
    always @(posedge clk) begin
        if (!rst_n) tout <= 4'd0;
        else begin
            if (rsp_valid) tout[rsp_tag[1:0]] <= 1'b0;
            if (acc) tout[req_tag[1:0]] <= 1'b1;
        end
        if (acc && req_write && !req_tag[0]) wline0 <= req_line;
        if (acc && req_write &&  req_tag[0]) wline1 <= req_line;
    end
    always @(*) begin
        if (rsp_valid) begin
            assume (rsp_tag[7:2] == 6'd0);
            assume (tout[rsp_tag[1:0]]);
            assume (rsp_write == rsp_tag[1]);
        end
    end
    always @(posedge clk) if (rst_n) begin
        if (req_valid) a_tag_range: assert (req_tag[7:2] == 6'd0 && req_tag[1] == req_write);
        if (acc)       a_tag_once:  assert (!tout[req_tag[1:0]]);
        a_cnt: assert (outstanding == tout[0] + tout[1] + tout[2] + tout[3]);
    end

    // ---- STATE: passthrough mode
    (* anyconst *) reg pt;
    function tests_on(input [31:0] w);
        reg [2:0] f;
        begin
            f = w[7:5];
            tests_on = (f == 3'b001 || f == 3'b010 || f == 3'b100) && (w[0] || w[9] || (w[8] && f == 3'b001));
        end
    endfunction
    always @(*) if (pt && st_we && st_idx == 9'h076) assume (!tests_on(st_wdata));

    // ---- handshake
    reg p_dv, p_dr; reg [31:0] p_dxy; reg [15:0] p_dsm; reg [511:0] p_dcol; reg [3:0] p_db;
    reg past_ok = 1'b0;
    always @(posedge clk) begin
        past_ok <= rst_n;
        p_dv <= d_valid; p_dr <= d_ready; p_dxy <= d_xy; p_dsm <= d_smask; p_dcol <= d_color; p_db <= d_beat;
    end
    // ---- lines read for the current quad
    reg [1:0] rv; reg [LW-1:0] rl0, rl1;
    always @(posedge clk) begin
        if (!rst_n || (q_valid && q_ready)) rv <= 2'b00;
        else if (acc && !req_write) begin
            if (!rv[0]) begin rv[0] <= 1'b1; rl0 <= req_line; end
            else        begin rv[1] <= 1'b1; rl1 <= req_line; end
        end
    end
    always @(posedge clk) if (rst_n) begin
        if (past_ok && p_dv && !p_dr) begin
            a_d_hold: assert (d_valid && d_xy == p_dxy && d_smask == p_dsm && d_beat == p_db && d_color == p_dcol);
        end
        a_qd_excl: assert (!(q_ready && d_valid));
        if (d_valid) a_d_nonzero: assert (d_smask != 16'd0);
        if (req_valid && req_write) begin
            a_wr_after_rd: assert ((rv[0] && rl0 == req_line) || (rv[1] && rl1 == req_line));
            a_wr_be: assert (req_be != 0);
        end
        if (req_valid && !req_write) begin
            a_raw: assert (!(tout[2] && wline0 == req_line) && !(tout[3] && wline1 == req_line));
        end
        if (!busy) a_idle: assert (q_ready && !req_valid && outstanding == 5'd0);
        if (pt) a_passthru: assert (!req_valid);
    end

    // ---- covers
    reg saw_wr;
    always @(posedge clk) begin
        if (!rst_n || (q_valid && q_ready)) saw_wr <= 1'b0;
        else if (acc && req_write) saw_wr <= 1'b1;
    end
    always @(posedge clk) if (rst_n) begin
        c_tested: cover (d_valid && d_ready && saw_wr);
        c_pass:   cover (pt && d_valid && d_ready);
        c_two:    cover (d_valid && d_ready && saw_wr && rv == 2'b11);
    end
endmodule
