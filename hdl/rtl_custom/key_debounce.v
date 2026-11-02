// key_debounce.v - 2-flop synchronizer + counter debouncer for one active-low push button
//   raw_n : the button pin, asynchronous (low = pressed)
//   down  : 1 while the button is held, changes only after the synchronized input has been stable for DEB clocks
// DEB = 1_500_000 is 20 ms at 75 MHz. Reset: active-low asynchronous (state = released).

module key_debounce #(
    parameter integer DEB = 1500000
)(
    input  wire clk,
    input  wire rst_n,
    input  wire raw_n,
    output wire down
);

    reg [1:0]  sy;
    reg        st;          // debounced level of raw_n (1 = released)
    reg [31:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sy  <= 2'b11;
            st  <= 1'b1;
            cnt <= 32'd0;
        end
        else begin
            sy <= {sy[0], raw_n};
            if (sy[1] == st) cnt <= 32'd0;
            else if (cnt >= DEB - 1) begin
                st  <= sy[1];
                cnt <= 32'd0;
            end
            else cnt <= cnt + 32'd1;
        end
    end

    assign down = ~st;

endmodule
