// fv_ad_su_exp_mesh -- ad_su_exp_mesh reduced to NVW 1 (one word a vertex: 3 vertex reads a
// primitive, a 126-bit package; the default is 7 words, 702 bits) and LDS_AW 3 (an 8-word LDS of
// free constant contents, read with one cycle of latency); at most two primitives a meshlet (the
// low byte of every word is assumed <= 2).  kick_valid/kick_base, mesh_ready free.  Properties: LDS reads only while
// mesh_busy; a package held while mesh_valid && !mesh_ready; per meshlet (kicked while idle) the
// packages are exactly its unculled primitives in order: their count, mesh_id = the header's,
// mesh_last on the last one only, the indices and flags of the primitive word, vertex words
// (v0, v1, v2) from VB + i; nothing left when mesh_busy falls.  The prove task (define SIMPLE)
// keeps the first two and "no package while idle": the per-meshlet properties need the LDS
// contents and did not close with abc pdr in 10 minutes (bmc depth 30 covers two primitives).
module fv_ad_su_exp_mesh (
    input wire clk,
    input wire rst_n,
    input wire kick_valid,
    input wire [2:0] kick_base,
    input wire mesh_ready
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n); else assume (rst_n);

    (* anyconst *) reg [255:0] lds;
    function [31:0] rd;
        input [2:0] a;
        rd = lds[32*a +: 32];
    endfunction
    integer j;
    always @(*) for (j = 0; j < 8; j = j + 1) assume (lds[32*j +: 8] <= 8'd2);

    wire en, mesh_valid, mesh_last, mesh_busy;
    wire [2:0] addr;
    reg [31:0] q;
    wire [125:0] tri_;
    wire [15:0] mesh_id;
    always @(posedge clk) if (en) q <= rd(addr);
    ad_su_exp_mesh #(.LDS_AW(3), .NVW(1)) dut (.clk(clk), .rst_n(rst_n), .kick_valid(kick_valid),
        .kick_base(kick_base), .mesh_lds_rd_en(en), .mesh_lds_rd_addr(addr),
        .mesh_lds_rd_data(q), .mesh_valid(mesh_valid), .mesh_ready(mesh_ready),
        .mesh_tri(tri_), .mesh_last(mesh_last), .mesh_id(mesh_id), .mesh_busy(mesh_busy));

    // the kicked meshlet
    reg [2:0] b;
    reg act;
    reg [1:0] n;                          // packages taken
    wire [31:0] hdr = rd(b);
    wire [1:0] np = hdr[1:0];
    wire [2:0] vb = b + 3'd1 + {1'b0, np};
    wire [31:0] p0 = rd(b + 3'd1), p1 = rd(b + 3'd2);
    wire u0 = np >= 2'd1 && !p0[31];
    wire u1 = np >= 2'd2 && !p1[31];
    wire [1:0] ne = {1'b0, u0} + {1'b0, u1};
    wire [31:0] pw = (n == 2'd0 && u0) ? p0 : p1;   // the primitive of the next package
    wire [2:0] i0 = pw[2:0], i1 = pw[10:8], i2 = pw[18:16];
    always @(posedge clk) begin
        if (!rst_n) begin
            act <= 1'b0;
            n <= 2'd0;
        end else begin
            if (!mesh_busy && kick_valid) begin
                act <= 1'b1;
                b <= kick_base;
                n <= 2'd0;
            end
            if (mesh_valid && mesh_ready) n <= n + 2'd1;
        end
    end
    reg pv, pl;
    reg [125:0] pt;
    reg [15:0] pid;
    reg pbusy;
    always @(posedge clk) begin
        pv <= rst_n && mesh_valid && !mesh_ready;
        pt <= tri_; pl <= mesh_last; pid <= mesh_id;
        pbusy <= rst_n && mesh_busy;
    end
    always @(*) if (rst_n && !init) begin
        if (en) assert (mesh_busy);
        if (pv) assert (mesh_valid && tri_ == pt && mesh_last == pl && mesh_id == pid);
`ifndef SIMPLE
        if (mesh_valid) begin
            assert (act && n < ne);
            assert (mesh_id == hdr[31:16]);
            assert (mesh_last == (n + 2'd1 == ne));
            assert (tri_[119:96] == pw[23:0] && tri_[125:120] == pw[29:24]);
            assert (tri_[31:0] == rd(vb + i0));
            assert (tri_[63:32] == rd(vb + i1));
            assert (tri_[95:64] == rd(vb + i2));
        end
        if (pbusy && !mesh_busy) assert (n == ne);
`endif
        if (!mesh_busy) assert (!mesh_valid);
    end
endmodule
