module cmd_data_compress #(
    parameter int NUMCMDS = 4,
    parameter int BITDATA = 8,
    parameter int BITCCNT = $clog2(NUMCMDS+1)
) (
    input  logic [NUMCMDS-1:0]            cmd_in,
    input  logic [NUMCMDS*BITDATA-1:0]    din,
    output logic [NUMCMDS-1:0]            cmd_out,
    output logic [NUMCMDS*BITDATA-1:0]    dout
);

    always_comb begin
        logic [BITCCNT-1:0] cmdcnt;

        cmd_out = NUMCMDS'(0);
        dout    = {(NUMCMDS*BITDATA){1'b0}};
        cmdcnt  = BITCCNT'(0);

        for (int i = 0; i < NUMCMDS; i++) begin
            if (cmd_in[i]) begin
                cmd_out[cmdcnt]                       = 1'b1;
                dout[cmdcnt*BITDATA +: BITDATA]        = din[i*BITDATA +: BITDATA];
                cmdcnt                                 = cmdcnt + BITCCNT'(cmd_in[i]);
            end
        end
    end

endmodule
