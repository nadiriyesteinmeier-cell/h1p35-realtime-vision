// beep_ctrl.v - short beep for every event pulse
//
// evt (any number of pulses, 1 clock each) starts / restarts a beep of BEEP_CLKS clocks (default 0.15 s at 75 MHz).
// While beeping the output is a square wave with a half period of HALF clocks (default 18750 = 2 kHz at 75 MHz), so it
// works with an active buzzer (it simply gets a pulsed drive) as well as with a passive one. The board's buzzer is
// driven through a transistor: output LOW = sounds, HIGH = silent (idle level HIGH); the physical switch SW5 on the
// board enables or disconnects it.
// Reset: active-low asynchronous (silent).

module beep_ctrl #(
    parameter integer BEEP_CLKS = 11250000,
    parameter integer HALF      = 18750
)(
    input  wire clk,
    input  wire rst_n,
    input  wire evt,
    output reg  buzzer_n
);

    reg [31:0] left;
    reg [31:0] ph;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            left <= 32'd0; ph <= 32'd0; buzzer_n <= 1'b1;
        end
        else begin
            if (evt) left <= BEEP_CLKS;
            else if (left != 32'd0) left <= left - 32'd1;

            if (left == 32'd0) begin
                buzzer_n <= 1'b1;
                ph <= 32'd0;
            end
            else if (ph >= HALF - 1) begin
                ph <= 32'd0;
                buzzer_n <= ~buzzer_n;
            end
            else ph <= ph + 32'd1;
        end
    end

endmodule
