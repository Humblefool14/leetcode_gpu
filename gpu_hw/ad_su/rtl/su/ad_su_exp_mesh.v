// ad_su_exp_mesh -- the meshlet export sequencer (spec ad_su_exp_mesh.md).
// A kick (exp 0x200) gives the meshlet's LDS word address.  The sequencer reads the header
// {id[31:16], nvert[15:8], nprim[7:0]}, then per primitive its topology word
// {flags[31:24], i2, i1, i0} (B + 1 + p); a culled one (flags bit 7) costs one cycle and no
// vertex read; otherwise the 21 words of its three vertices (VB + 7 i + w, VB = B + 1 + nprim)
// are read into the package, one per cycle (LDS port B, data one cycle after the read).
// A finished package is held until the next unculled primitive or the meshlet's end decides
// its mesh_last, then pushed through the two-stage skid buffer (ad_gfx_skid).
// Package (702 bits): v0 words 0-6 at [223:0] (word w at 32 w), v1 at [447:224],
// v2 at [671:448], {i2, i1, i0} at [695:672], flags[5:0] at [701:696].
module ad_su_exp_mesh #(
    parameter LDS_AW = 10,
    parameter NVW = 7,               // words per vertex (4 position + 3 varyings); formal: 1
    parameter PW = 3 * NVW * 32 + 30 // package width (702)
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              kick_valid,
    input  wire [LDS_AW-1:0] kick_base,
    output reg               mesh_lds_rd_en,
    output reg  [LDS_AW-1:0] mesh_lds_rd_addr,
    input  wire [31:0]       mesh_lds_rd_data,
    output wire              mesh_valid,
    input  wire              mesh_ready,
    output wire [PW-1:0]     mesh_tri,
    output wire              mesh_last,
    output wire [15:0]       mesh_id,
    output wire              mesh_busy
);
    localparam S_IDLE = 4'd0, S_HREQ = 4'd1, S_HDR = 4'd2, S_PRIM_REQ = 4'd3,
               S_PRIM_LATCH = 4'd4, S_SKID_WAIT = 4'd5, S_VERT = 4'd6, S_END = 4'd7,
               S_DRAIN_WAIT = 4'd8;
    reg [3:0] state;
    reg [LDS_AW-1:0] base, vbase;
    reg [15:0] id;
    reg [7:0] nprim, p;
    reg [23:0] idx;              // the current primitive's indices
    reg [5:0] flags;
    reg [4:0] k;                 // vertex word to read next (0..NW-1)
    reg rcv;                     // a vertex word arrives this cycle
    reg [4:0] rk;                // its number
    reg [3*NVW*32-1:0] vd;       // package being assembled / held
    reg held;                    // vd + idx_h/flags_h form a finished package
    reg [23:0] idx_h;
    reg [5:0] flags_h;

    // skid buffer: {id, last, package}
    localparam SW = 16 + 1 + PW;
    localparam NW = 3 * NVW;          // vertex words per primitive (21)
    reg in_valid;
    reg in_last;
    wire in_ready, sk_empty;
    wire [SW-1:0] out_d;
    ad_skid #(.W(SW)) skid (.clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .in_ready(in_ready), .in_data({id, in_last, flags_h, idx_h, vd}),
        .out_valid(mesh_valid), .out_ready(mesh_ready), .out_data(out_d), .empty(sk_empty));
    assign mesh_tri = out_d[PW-1:0];
    assign mesh_last = out_d[PW];
    assign mesh_id = out_d[PW+16:PW+1];
    assign mesh_busy = (state != S_IDLE);

    wire [31:0] d = mesh_lds_rd_data;     // the data of the previous cycle's read
`ifdef MUT_MESH_CULL
    wire culled = 1'b0;                   // mutation: culled primitives are emitted
`else
    wire culled = d[31];
`endif
    wire more = (p + 8'd1 < nprim);
    // vertex word k's address: vbase + 7 * index of vertex k/7 + k%7
    localparam [4:0] NVW5 = NVW, NVW10 = 2 * NVW, NWL = NW - 1;
    wire [1:0] kv = (k < NVW5) ? 2'd0 : (k < NVW10) ? 2'd1 : 2'd2;
    wire [4:0] kw = (kv == 2'd0) ? k : (kv == 2'd1) ? k - NVW5 : k - NVW10;   // k - NVW kv
    wire [7:0] vi = (kv == 2'd0) ? idx[7:0] : (kv == 2'd1) ? idx[15:8] : idx[23:16];
    localparam [15:0] NVW16 = NVW;
    wire [15:0] voff = {8'd0, vi} * NVW16 + {11'd0, kw};
    wire [LDS_AW-1:0] vaddr = vbase + voff[LDS_AW-1:0];
    wire [15:0] p1 = {8'd0, p} + 16'd1;
    wire [15:0] p2 = {8'd0, p} + 16'd2;
    wire [15:0] n1 = {8'd0, d[7:0]} + 16'd1;
    wire vrd = (state == S_VERT) && k <= NWL;
    wire vdone = rcv && rk == NWL;        // the last vertex word arrives

    // the LDS read of this cycle (its data arrive in the next)
    always @(*) begin
        mesh_lds_rd_en = 1'b0;
        mesh_lds_rd_addr = vaddr;
        case (state)
        S_HREQ: begin
            mesh_lds_rd_en = 1'b1;
            mesh_lds_rd_addr = base;
        end
        S_HDR: begin
            mesh_lds_rd_en = d[7:0] != 8'd0;
            mesh_lds_rd_addr = base + {{(LDS_AW-1){1'b0}}, 1'b1};
        end
        S_PRIM_REQ: begin
            mesh_lds_rd_en = 1'b1;
            mesh_lds_rd_addr = base + p1[LDS_AW-1:0];
        end
        S_PRIM_LATCH: begin
            mesh_lds_rd_en = culled && more;
            mesh_lds_rd_addr = base + p2[LDS_AW-1:0];
        end
        S_VERT: mesh_lds_rd_en = vrd;
        default: ;
        endcase
    end

    // the push of the held package
    always @(*) begin
        in_valid = 1'b0;
        in_last = 1'b0;
        if (state == S_PRIM_LATCH && !culled && held) in_valid = 1'b1;
        if (state == S_SKID_WAIT) in_valid = 1'b1;
        if (state == S_END && held) begin
            in_valid = 1'b1;
            in_last = 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            held <= 1'b0;
            rcv <= 1'b0;
            p <= 8'd0;
            k <= 5'd0;
            base <= {LDS_AW{1'b0}};
        end else begin
            rcv <= vrd;
            if (vrd) begin
                rk <= k;
                k <= k + 5'd1;
            end
            case (state)
            S_IDLE:
                if (kick_valid) begin
                    base <= kick_base;
                    held <= 1'b0;
                    state <= S_HREQ;
                end
            S_HREQ:
                state <= S_HDR;
            S_HDR: begin                       // header data
                id <= d[31:16];
                nprim <= d[7:0];
                vbase <= base + n1[LDS_AW-1:0];
                p <= 8'd0;
                state <= (d[7:0] == 8'd0) ? S_DRAIN_WAIT : S_PRIM_LATCH;
            end
            S_PRIM_REQ:
                state <= S_PRIM_LATCH;
            S_PRIM_LATCH:                      // topology word of primitive p
                if (culled) begin
                    if (more) p <= p + 8'd1;
                    else state <= S_END;
                end else begin
                    idx <= d[23:0];
                    flags <= d[29:24];
                    k <= 5'd0;
                    if (held && !in_ready) state <= S_SKID_WAIT;
                    else begin
                        held <= 1'b0;
                        state <= S_VERT;
                    end
                end
            S_SKID_WAIT:
                if (in_ready) begin
                    held <= 1'b0;
                    state <= S_VERT;
                end
            S_VERT:
                if (vdone) begin
                    held <= 1'b1;
                    idx_h <= idx;
                    flags_h <= flags;
                    if (more) begin
                        p <= p + 8'd1;
                        state <= S_PRIM_REQ;
                    end else begin
                        state <= S_END;
                    end
                end
            S_END:
                if (!held || in_ready) begin
                    held <= 1'b0;
                    state <= S_DRAIN_WAIT;
                end
            default:                            // S_DRAIN_WAIT
                if (sk_empty) state <= S_IDLE;
            endcase
        end
    end

    integer wi;
    always @(posedge clk) begin
        for (wi = 0; wi < NW; wi = wi + 1)
            if (rcv && {27'd0, rk} == wi) vd[32*wi +: 32] <= d;
    end

endmodule
