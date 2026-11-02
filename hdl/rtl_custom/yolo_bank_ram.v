// yolo_bank_ram.v - one activation bank of the detector: simple dual-port byte RAM, 1 write port + 1 read port, synchronous read (1 clock)
//
// Read-during-write at the same address returns the OLD byte (the fused max-pool of yolo_conv_core.v reads the byte it is about to overwrite two
// clocks later, never in the same clock, so either behaviour would work, but the testbenches model the old-data behaviour).
// No initial contents: nothing in the engine relies on the power-up state, the borders of the padded maps are written by the host (input map) or by
// the fill descriptors (yolo_aux_core.v mode 4). In simulation an unwritten byte reads as X, so a read of data that nobody produced shows up as a mismatch.
// ram_style "bram": TD maps this to ERAM20K (8-bit data, 2048 bytes per block).

module yolo_bank_ram #(
    parameter integer DEPTH = 4096,
    parameter integer AW    = 20
)(
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [7:0]    wdata,
    input  wire [AW-1:0] raddr,
    output reg  [7:0]    rdata
);

    // TD maps the array to ERAM only if the index has exactly ceil(log2(DEPTH)) bits (an index port wider than the depth needs makes it fall back to LUT RAM:
    // SYN-5105 "read address have no register", measured with tools/td_exp/ram_probe_m.v); the upper address bits are ignored here
    function integer clog2;
        input integer v;
        integer i;
        begin
            clog2 = 0;
            for (i = v - 1; i > 0; i = i >> 1) clog2 = clog2 + 1;
        end
    endfunction
    localparam integer ABITS = clog2(DEPTH);

    (* ram_style = "bram" *) reg [7:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) mem[waddr[ABITS-1:0]] <= wdata;
        rdata <= mem[raddr[ABITS-1:0]];
    end

endmodule
