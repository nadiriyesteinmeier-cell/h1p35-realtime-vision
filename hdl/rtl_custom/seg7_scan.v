// seg7_scan.v - dynamic scan driver for the board's 8-digit seven-segment display (common anode, 8 digits multiplexed)
//
//   digits[4*i+3 : 4*i]  code of digit i, i = 0 is the LEFT-most digit (SEL0). Codes: 0..9 digits, 10 = 'F', 11 = '-',
//                        anything else = blank
//   seg[7:0]  = DIG0..DIG7 = segments a b c d e f g h(dp), ACTIVE LOW (0 lights the segment)
//   sel[7:0]  = SEL0..SEL7, one-cold, ACTIVE LOW at the FPGA pin (PNP9012 high-side digit drivers).
// The common anode is powered high, but its PNP base must be driven LOW to select that digit.
// One digit is lit for TICK clocks, so all eight are refreshed every 8*TICK clocks (default TICK = 9375: 125 us per digit at
// 75 MHz, 1 kHz refresh, no visible flicker). The same 16 FPGA pins drive the 8 two-colour LEDs when the board switch
// SW6 is down (pin multiplexing on the board, see the board manual): leave SW6 up to see the digits.
// Reset: active-low asynchronous (all digits off).

module seg7_scan #(
    parameter integer TICK = 9375
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] digits,
    output reg  [7:0]  seg,
    output reg  [7:0]  sel
);

    reg [31:0] cnt;
    reg [2:0]  idx;

    reg [3:0] code;
    reg [7:0] pat;                      // active high a..g in bits 0..6
    always @* begin
        case (idx)
            3'd0: code = digits[3:0];
            3'd1: code = digits[7:4];
            3'd2: code = digits[11:8];
            3'd3: code = digits[15:12];
            3'd4: code = digits[19:16];
            3'd5: code = digits[23:20];
            3'd6: code = digits[27:24];
            default: code = digits[31:28];
        endcase
        case (code)
            4'd0:  pat = 8'h3F;
            4'd1:  pat = 8'h06;
            4'd2:  pat = 8'h5B;
            4'd3:  pat = 8'h4F;
            4'd4:  pat = 8'h66;
            4'd5:  pat = 8'h6D;
            4'd6:  pat = 8'h7D;
            4'd7:  pat = 8'h07;
            4'd8:  pat = 8'h7F;
            4'd9:  pat = 8'h6F;
            4'd10: pat = 8'h71;         // F
            4'd11: pat = 8'h40;         // -
            default: pat = 8'h00;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 32'd0; idx <= 3'd0; seg <= 8'hFF; sel <= 8'hFF;
        end
        else begin
            if (cnt >= TICK - 1) begin
                cnt <= 32'd0;
                idx <= idx + 3'd1;
            end
            else cnt <= cnt + 32'd1;
            seg <= ~pat;
            sel <= ~(8'd1 << idx);
        end
    end

endmodule
