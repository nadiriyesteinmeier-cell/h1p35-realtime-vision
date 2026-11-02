// pulse_to_toggle.v - turns a 1-clock pulse into a level that toggles on every pulse (clock-domain-crossing helper)
// The consumer in another clock domain synchronizes 'tog' with two flip-flops and detects its edges; a pulse of
// one source clock can never be missed this way. Reset: active-low asynchronous (tog = 0).

module pulse_to_toggle (
    input  wire clk,
    input  wire rst_n,
    input  wire pulse,
    output reg  tog
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      tog <= 1'b0;
        else if (pulse)  tog <= ~tog;
    end

endmodule
