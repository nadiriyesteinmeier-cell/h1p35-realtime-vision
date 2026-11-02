// luma_mean.v - mean luminance of a frame, measured on a sparse pixel grid, available one frame later
//
// Samples the 8-bit gray value (e.g. rgb_to_gray.out_gray) of every pixel with x mod 2^GX = 0 and y mod 2^GY = 0
// (default: x mod 32 = 0, y mod 16 = 0 -> 40 x 45 = 1800 samples of a 1280 x 720 frame), sums them and, at the last
// pixel of the frame (in_eof), divides the sum by the number of samples with a serial restoring divider
// (SUM_W clocks, done long before the next frame starts: the vertical blanking is tens of thousands of clocks).
//
// mean       : floor(sum / samples), 0..255, holds its value until the next division finishes; the value measured on
//              frame N is therefore valid from the end of frame N on and is used for frame N+1 (fixed one-frame lag,
//              the same lag as every other per-frame statistic of the project)
// mean_valid : 0 after reset until the first division has finished
// done       : 1-clock pulse when 'mean' was updated
// A frame without any sample (e.g. a frame smaller than the grid) leaves 'mean' unchanged.
// in_* are the normalized pixel stream; in_sof / in_eof are only looked at while in_de = 1. A new in_sof restarts the
// accumulation (and aborts a division that is still running, which cannot happen at the normal timing).
// Reset: active-low asynchronous.

module luma_mean #(
    parameter integer GX    = 5,
    parameter integer GY    = 4,
    parameter integer SUM_W = 24
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_de,
    input  wire [7:0]  in_gray,
    input  wire [11:0] in_x,
    input  wire [11:0] in_y,
    input  wire        in_sof,
    input  wire        in_eof,

    output reg  [7:0]  mean,
    output reg         mean_valid,
    output reg         done
);

    reg  [SUM_W-1:0] sum;
    reg  [15:0]      cnt;

    wire [11:0] xmask = (12'd1 << GX) - 12'd1;
    wire [11:0] ymask = (12'd1 << GY) - 12'd1;
    wire        samp  = in_de & ((in_x & xmask) == 12'd0) & ((in_y & ymask) == 12'd0);

    // value of sum / cnt including the current pixel (used when this pixel is the last one)
    wire [SUM_W-1:0] sum_inc = (in_sof ? {SUM_W{1'b0}} : sum) + (samp ? {{(SUM_W-8){1'b0}}, in_gray} : {SUM_W{1'b0}});
    wire [15:0]      cnt_inc = (in_sof ? 16'd0 : cnt)         + (samp ? 16'd1 : 16'd0);

    // serial restoring divider
    reg                run;
    reg                fin;
    reg  [7:0]         step;
    reg  [SUM_W-1:0]   dvd;
    reg  [SUM_W:0]     rem;
    reg  [SUM_W-1:0]   quo;
    reg  [15:0]        dvs;

    wire [SUM_W:0]     rem_sh = {rem[SUM_W-1:0], dvd[SUM_W-1]};
    wire               ge     = (rem_sh >= {{(SUM_W+1-16){1'b0}}, dvs});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum <= {SUM_W{1'b0}}; cnt <= 16'd0;
            run <= 1'b0; fin <= 1'b0; step <= 8'd0; dvd <= {SUM_W{1'b0}}; rem <= {(SUM_W+1){1'b0}};
            quo <= {SUM_W{1'b0}}; dvs <= 16'd0;
            mean <= 8'd0; mean_valid <= 1'b0; done <= 1'b0;
        end
        else begin
            done <= 1'b0;
            fin  <= 1'b0;

            // accumulation
            if (in_de) begin
                sum <= sum_inc;
                cnt <= cnt_inc;
            end

            if (in_de & in_eof) begin
                // start a division with the totals including this pixel
                if (cnt_inc != 16'd0) begin
                    run  <= 1'b1;
                    step <= 8'd0;
                    dvd  <= sum_inc;
                    dvs  <= cnt_inc;
                    rem  <= {(SUM_W+1){1'b0}};
                    quo  <= {SUM_W{1'b0}};
                end
            end
            else if (in_de & in_sof) begin
                run <= 1'b0;                      // a new frame aborts a division that is still running
            end
            else if (run) begin
                // one quotient bit per clock, MSB first
                dvd <= {dvd[SUM_W-2:0], 1'b0};
                if (ge) begin
                    rem <= rem_sh - {{(SUM_W+1-16){1'b0}}, dvs};
                    quo <= {quo[SUM_W-2:0], 1'b1};
                end
                else begin
                    rem <= rem_sh;
                    quo <= {quo[SUM_W-2:0], 1'b0};
                end
                step <= step + 8'd1;
                if (step == SUM_W - 1) begin
                    run <= 1'b0;
                    fin <= 1'b1;
                end
            end

            // publish in the clock after the last quotient bit was shifted in (mean <= 255 always: gray <= 255)
            if (fin) begin
                mean       <= quo[7:0];
                mean_valid <= 1'b1;
                done       <= 1'b1;
            end
        end
    end

endmodule
