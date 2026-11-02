// sync_delay.v - delay a W-bit vector by exactly N clocks
//
// Purpose: when the video data path gets N extra clocks of latency (adapter, view_mux, osd_overlay ...),
// the display timing signals (vsync, hsync, de) must be delayed by the same N clocks so that
// data and timing stay aligned. N = 0 is a plain wire.
//
// Reset: active-low asynchronous, clears the delay line to 0.

module sync_delay #(
    parameter integer N = 3,
    parameter integer W = 3
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire [W-1:0] din,
    output wire [W-1:0] dout
);

    generate
        if (N == 0) begin : g_wire
            assign dout = din;
        end
        else if (N == 1) begin : g_one
            reg [W-1:0] q;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) q <= {W{1'b0}};
                else        q <= din;
            end
            assign dout = q;
        end
        else begin : g_many
            reg [W*N-1:0] sr;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) sr <= {(W*N){1'b0}};
                else        sr <= {sr[W*(N-1)-1:0], din};
            end
            assign dout = sr[W*N-1:W*(N-1)];
        end
    endgenerate

endmodule
