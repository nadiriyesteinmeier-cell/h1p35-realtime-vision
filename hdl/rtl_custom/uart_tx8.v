// uart_tx8.v - minimal UART transmitter, 8N1, LSB first
//
//   start : 1-clock request, accepted only while busy = 0 (the caller must check busy; a request while busy is ignored)
//   data  : byte to send, sampled in the clock of an accepted start
//   busy  : 1 from the clock after an accepted start until the end of the stop bit; tx idles high
// Bit time = CLKDIV clocks (115200 baud at 75 MHz: 651). Reset: active-low asynchronous.

module uart_tx8 #(
    parameter integer CLKDIV = 651
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] data,
    output reg        busy,
    output reg        tx
);

    reg [9:0]  sh;                        // {stop, data[7:0], start}
    reg [3:0]  bitn;                      // index of the bit that is on the wire now
    reg [15:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            tx   <= 1'b1;
            sh   <= 10'h3FF;
            bitn <= 4'd0;
            cnt  <= 16'd0;
        end
        else if (!busy) begin
            if (start) begin
                busy <= 1'b1;
                sh   <= {1'b1, data, 1'b0};
                tx   <= 1'b0;             // start bit
                bitn <= 4'd0;
                cnt  <= CLKDIV - 1;
            end
        end
        else begin
            if (cnt == 16'd0) begin
                cnt <= CLKDIV - 1;
                if (bitn == 4'd9) begin
                    busy <= 1'b0;
                    tx   <= 1'b1;
                end
                else begin
                    bitn <= bitn + 4'd1;
                    tx   <= sh[bitn + 4'd1];
                end
            end
            else cnt <= cnt - 16'd1;
        end
    end

endmodule
