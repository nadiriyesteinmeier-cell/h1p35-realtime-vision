// byte_cdc.v - reads a slowly changing multi-bit value that belongs to another clock domain
//
// din is sampled by two flip-flop stages of the destination clock; q is only updated when two consecutive samples are
// equal. For a value that changes once per second (fps_meter) this removes both metastability (two stages) and torn
// values (a read during the change differs from the next one and is rejected). Not for fast-changing buses.
// Reset: active-low asynchronous (q = 0).

module byte_cdc #(
    parameter integer W = 8
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire [W-1:0] din,
    output reg  [W-1:0] q
);

    reg [W-1:0] a, b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a <= {W{1'b0}}; b <= {W{1'b0}}; q <= {W{1'b0}};
        end
        else begin
            a <= din;
            b <= a;
            if (a == b) q <= b;
        end
    end

endmodule
