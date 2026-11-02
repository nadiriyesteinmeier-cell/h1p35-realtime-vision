// div_seq.v - sequential restoring divider, one quotient bit per clock (unsigned)
//
//   start (1 clock, ignored while busy) loads num / den; after NW + 2 clocks done pulses for 1 clock and quo = floor(num / den),
//   rem = num mod den stay valid until the next start. den = 0 is not allowed (the result is undefined; the caller must avoid it).
//   busy = 1 from the start request until the clock before done.
// Cost: about 2*NW + WD flip-flops and one WD+1 bit subtractor, no DSP, no RAM. This replaces the fully pipelined 50-stage vendor divider
// (about 4000 flip-flops each) wherever a result is needed only once per frame.
// Reset: active-low asynchronous.

module div_seq #(
    parameter integer NW = 44,
    parameter integer WD = 32
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire          start,
    input  wire [NW-1:0] num,
    input  wire [WD-1:0] den,
    output reg           busy,
    output reg           done,
    output reg  [NW-1:0] quo,
    output reg  [WD-1:0] rem
);

    reg [NW-1:0] n_sh;                   // dividend, shifted left; its MSB is the next bit
    reg [WD-1:0] d_q;
    reg [WD:0]   r;                      // partial remainder, one bit wider than the divisor
    reg [7:0]    cnt;

    wire [WD:0] r_sh = {r[WD-1:0], n_sh[NW-1]};
    wire [WD:0] r_sub = r_sh - {1'b0, d_q};
    wire        ge = ~r_sub[WD];         // r_sh >= d  (no borrow)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0; done <= 1'b0; quo <= {NW{1'b0}}; rem <= {WD{1'b0}};
            n_sh <= {NW{1'b0}}; d_q <= {WD{1'b0}}; r <= {(WD+1){1'b0}}; cnt <= 8'd0;
        end
        else begin
            done <= 1'b0;
            if (!busy) begin
                if (start) begin
                    busy <= 1'b1;
                    n_sh <= num;
                    d_q  <= den;
                    r    <= {(WD+1){1'b0}};
                    quo  <= {NW{1'b0}};
                    cnt  <= NW;
                end
            end
            else begin
                if (cnt != 8'd0) begin
                    r    <= ge ? r_sub : r_sh;
                    quo  <= {quo[NW-2:0], ge};
                    n_sh <= {n_sh[NW-2:0], 1'b0};
                    cnt  <= cnt - 8'd1;
                end
                else begin
                    rem  <= r[WD-1:0];
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end

endmodule
