// ad_blend_op8: equals the reference (ts = round(s*fs/255), td = round(d*fd/255), the 5 ops
// with saturation, 5..7 = ADD) for every s, d, factor and op, plus bound properties.
module fv_ad_blend_op8;
    (* anyconst *) reg [7:0] s, d, fs, fd;
    (* anyconst *) reg [2:0] op;
    wire [15:0] ps = s * fs, pd = d * fd;
    wire [7:0] y, y0;
    ad_blend_op8 dut  (.ps(ps), .pd(pd), .s(s), .d(d), .op(op),   .y(y));
    ad_blend_op8 dut0 (.ps(ps), .pd(pd), .s(s), .d(d), .op(3'd0), .y(y0));
    wire [16:0] ts = ({1'b0, ps} + 17'd127) / 17'd255;
    wire [16:0] td = ({1'b0, pd} + 17'd127) / 17'd255;
    wire [16:0] sum = ts + td;
    reg  [16:0] r;
    always @(*) begin
        case (op)
            3'd1: r = (ts >= td) ? ts - td : 17'd0;
            3'd2: r = (td >= ts) ? td - ts : 17'd0;
            3'd3: r = (s <= d) ? s : d;
            3'd4: r = (s >= d) ? s : d;
            default: r = (sum >= 17'd255) ? 17'd255 : sum;
        endcase
        a_ref: assert ({9'd0, y} == r);
        if (op >= 3'd5) a_add_alias: assert (y == y0);
        if (op == 3'd0) a_add_sat:   assert ((sum >= 17'd255) == (y == 8'd255) || sum == 17'd255);
        if (op == 3'd0) a_add_ge:    assert ({9'd0, y} >= ts && {9'd0, y} >= td);
        if (op == 3'd1) a_sub_le:    assert ({9'd0, y} <= ts);
        if (op == 3'd2) a_rsub_le:   assert ({9'd0, y} <= td);
        if (op == 3'd3) a_min:       assert (y <= s && y <= d && (y == s || y == d));
        if (op == 3'd4) a_max:       assert (y >= s && y >= d && (y == s || y == d));
        if (op == 3'd0 && fs == 8'd255 && fd == 8'd0) a_one_zero: assert (y == s);
        if (fs == 8'd0 && fd == 8'd0 && op <= 3'd2) a_zero: assert (y == 8'd0);
    end
endmodule
