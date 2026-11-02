// frame_commit.v - request / effective settings with an atomic commit at a frame boundary
//
// A bundle of run-time settings (view mode, page, recognition / adaptive-threshold flags, counting-line position, ...) comes from
// switches and push buttons, i.e. it can change at ANY clock, also in the middle of a frame. The picture path must see a new value only
// BETWEEN two frames, otherwise one output frame is made of two modes (the upper rows of the old view, the lower rows of the new one).
// This module keeps the two apart:
//
//   req      the REQUEST: whatever the controls say right now (synchronized by the integrator)
//   eff      the EFFECTIVE value used by the pipeline; it changes only on a clock with commit = 1
//   pending  1 while req differs from eff (a request is waiting for the next boundary)
//   changed  1-clock pulse, one clock after a commit that actually changed eff;  gen = number of such commits (wraps at 256)
//
// 'commit' must fall into the vertical blanking, at a moment when no pixel of the previous frame is left in the pipeline and the next
// frame has not started (contest_vision_v2.v: the falling edge of the baseline vsync, 20 lines before the first active pixel of the next
// frame; the processed pipeline is only SKEW + 15 clocks deep). A request that appears and goes away again between two commits has no
// effect. A level that stays high for several clocks is allowed (every clock then copies req); the integrator uses it for the bypass
// switch, where it is high while both video streams are inside their vsync pulse.
// Before the FIRST commit after reset eff simply follows req (there is no previous frame to keep consistent: the first frame after the
// PLL lock is whatever the switches say).
// Reset: active-low asynchronous; eff = INIT.

module frame_commit #(
    parameter integer     W    = 18,
    parameter [W-1:0]     INIT = {W{1'b0}}
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         commit,
    input  wire [W-1:0] req,
    output reg  [W-1:0] eff,
    output wire         pending,
    output reg          changed,
    output reg  [7:0]   gen
);

    reg seeded;
    assign pending = (req != eff);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eff     <= INIT;
            seeded  <= 1'b0;
            changed <= 1'b0;
            gen     <= 8'd0;
        end
        else begin
            changed <= 1'b0;
            if (!seeded) begin
                eff <= req;
                if (commit) seeded <= 1'b1;
            end
            else if (commit) begin
                eff <= req;
                if (req != eff) begin
                    changed <= 1'b1;
                    gen     <= gen + 8'd1;
                end
            end
        end
    end

endmodule
