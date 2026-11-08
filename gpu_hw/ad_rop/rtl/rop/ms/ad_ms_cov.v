// ad_ms_cov -- sample-mask assembly of a quad's first beat
// (spec/gpu/rop/ad_rop_ms.md §4).  Bit 4 l + s = sample s of lane l.
//   four = 1: smask = sin & each lane's 4 bits & (a2c ? a2c_m : all).
//   four = 0: bit 4 l = lanes[l] & sin[4 l] & (a2c ? a2c_h[l] : 1); others 0.
// a2c is MS_CTRL[8] and not the direct path (the parent gates it).
// Combinational.
module ad_ms_cov (
    input  wire        four,
    input  wire        a2c,
    input  wire [15:0] sin,
    input  wire [3:0]  lanes,
    input  wire [15:0] a2c_m,     // lane l's alpha-to-coverage mask at [4l+3:4l]
    input  wire [3:0]  a2c_h,     // lane l's alpha >= 0.5
    output reg  [15:0] smask
);
    integer l;
    always @(*) begin
        smask = 16'd0;
        for (l = 0; l < 4; l = l + 1) begin
            if (four)
                smask[4*l +: 4] = sin[4*l +: 4] & {4{lanes[l]}} & (a2c ? a2c_m[4*l +: 4] : 4'hF);
            else
                smask[4*l] = sin[4*l] & lanes[l] & (a2c ? a2c_h[l] : 1'b1);
        end
    end
endmodule
