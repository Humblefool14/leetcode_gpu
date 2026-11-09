// ad_amb_mem_ooo -- test memory with independent read and write channels (from the
// design review): writes land WLAT cycles after acceptance, reads are served at
// acceptance, so a read can overtake an earlier write to the same line.
// memory with independent read/write channels: a write lands (and is answered) WLAT cycles
// after acceptance; a read is served at acceptance and answered RLAT cycles later.
`timescale 1ns/1ps
module ad_amb_mem_ooo #(parameter LINE_BYTES=32, LINE_SHIFT=5, ADDR_W=32, MEM_LINES=1024, WLAT=30, RLAT=3) (
    input clk, input rst_n, input req_valid, output reg req_ready, input req_write,
    input [ADDR_W-LINE_SHIFT-1:0] req_line, input [LINE_BYTES-1:0] req_be, input [LINE_BYTES*8-1:0] req_wdata,
    input [7:0] req_tag, output reg rsp_valid, output reg rsp_write, output reg [7:0] rsp_tag,
    output reg [LINE_BYTES*8-1:0] rsp_rdata, output reg rsp_error);
    reg [7:0] mem [0:MEM_LINES*LINE_BYTES-1];
    reg [ADDR_W-1:0] wl [0:255]; reg [LINE_BYTES-1:0] wbe [0:255]; reg [LINE_BYTES*8-1:0] wd [0:255];
    reg [7:0] wt [0:255]; integer wdue [0:255];
    reg [LINE_BYTES*8-1:0] rd [0:255]; reg [7:0] rt [0:255]; integer rdue [0:255];
    integer wh=0, wtl=0, rh=0, rtl=0, cyc=0, i, n_reads=0, n_writes=0;
    always @(posedge clk) begin
        cyc <= cyc + 1; rsp_valid <= 0; req_ready <= 1;
        if (rst_n) begin
            if (req_valid && req_ready) begin
                if (req_write) begin wl[wtl%256]=req_line; wbe[wtl%256]=req_be; wd[wtl%256]=req_wdata; wt[wtl%256]=req_tag; wdue[wtl%256]=cyc+WLAT; wtl=wtl+1; n_writes=n_writes+1; end
                else begin for (i=0;i<LINE_BYTES;i=i+1) rd[rtl%256][8*i+:8]=mem[(req_line<<LINE_SHIFT)+i]; rt[rtl%256]=req_tag; rdue[rtl%256]=cyc+RLAT; rtl=rtl+1; n_reads=n_reads+1; end
            end
            if (wh != wtl && wdue[wh%256] <= cyc) begin
                for (i=0;i<LINE_BYTES;i=i+1) if (wbe[wh%256][i]) mem[(wl[wh%256]<<LINE_SHIFT)+i]=wd[wh%256][8*i+:8];
                rsp_valid<=1; rsp_write<=1; rsp_tag<=wt[wh%256]; rsp_error<=0; wh=wh+1;
            end else if (rh != rtl && rdue[rh%256] <= cyc) begin
                rsp_valid<=1; rsp_write<=0; rsp_tag<=rt[rh%256]; rsp_rdata<=rd[rh%256]; rsp_error<=0; rh=rh+1;
            end
        end
    end
endmodule
