// osd_bin2bcd.v - free-running binary -> BCD converter (shift-and-add-3, one bit per clock)
//
//   bin  : BITS-bit unsigned value (typically changes once per frame)
//   bcd  : DIGITS decimal digits, 4 bits each, [4*DIGITS-1:4*DIGITS-4] is the most significant
//
// Behaviour
//   - Values above 10^DIGITS - 1 are clamped to 10^DIGITS - 1 (display saturates, e.g. 999999).
//   - A conversion takes BITS + 1 clocks (1 clock to capture 'bin', BITS clocks to shift) and the next
//     one starts immediately with the then-current 'bin'. 'bcd' only changes when a conversion has
//     finished, so it always holds a complete, valid BCD result.
//   - If 'bin' changes while a conversion is running, that conversion finishes with the OLD value and
//     the next one picks up the new value. A new value is therefore visible after at most
//     2*(BITS+1) clocks, and 'bcd' is guaranteed to be the decimal form of 'bin' once 'bin' has been
//     stable for 2*BITS + 3 clocks.
//   - No division, no multiplier. Reset (async, active low) clears bcd to 0.
//
// Used by osd_overlay: the result is sampled at the first pixel of each frame, so the inputs
// must be stable at least 2*BITS + 3 clocks (<= 43 for the 20-bit counter) before it. They change
// right after the last pixel of the previous frame, a whole vertical blanking (tens of thousands of
// clocks) earlier.

module osd_bin2bcd #(
    parameter integer BITS   = 20,
    parameter integer DIGITS = 6
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [BITS-1:0]      bin,
    output reg  [4*DIGITS-1:0]  bcd
);

    localparam integer MAXI = (10 ** DIGITS) - 1;

    reg  [4*DIGITS-1:0] acc;
    reg  [BITS-1:0]     sh;
    reg  [7:0]          cnt;
    reg                 busy;

    wire [31:0]         bin32 = {{(32-BITS){1'b0}}, bin};
    wire [31:0]         cap   = (bin32 > MAXI) ? MAXI : bin32;

    // add 3 to every digit that is >= 5 (digit-wise, no carry between digits possible)
    reg  [4*DIGITS-1:0] adj;
    integer             d;
    always @* begin
        adj = acc;
        for (d = 0; d < DIGITS; d = d + 1) begin
            if (acc[4*d +: 4] >= 4'd5)
                adj[4*d +: 4] = acc[4*d +: 4] + 4'd3;
        end
    end

    wire [4*DIGITS-1:0] acc_next = {adj[4*DIGITS-2:0], sh[BITS-1]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc  <= {(4*DIGITS){1'b0}};
            sh   <= {BITS{1'b0}};
            cnt  <= 8'd0;
            busy <= 1'b0;
            bcd  <= {(4*DIGITS){1'b0}};
        end
        else if (!busy) begin
            acc  <= {(4*DIGITS){1'b0}};
            sh   <= cap[BITS-1:0];
            cnt  <= 8'd0;
            busy <= 1'b1;
        end
        else begin
            acc <= acc_next;
            sh  <= {sh[BITS-2:0], 1'b0};
            cnt <= cnt + 8'd1;
            if (cnt == BITS - 1) begin
                bcd  <= acc_next;
                busy <= 1'b0;
            end
        end
    end

endmodule
