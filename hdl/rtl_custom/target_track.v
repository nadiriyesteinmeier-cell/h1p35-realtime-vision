// target_track.v - frame-level tracker of ONE coloured target: jitter suppression, short-occlusion hold, lost / re-acquired state
//
// Input: one sample per frame from frame_bbox (upd = frame_done; valid / xmin / xmax / ymin / ymax = res_*). Output: the tracked
// bounding box and a state, registered, one clock after upd. It is NOT a multi-target associator: there is exactly one target per
// colour, "the" bounding box of all pixels of that colour (frame_bbox), so a re-appearing target of the colour is by definition the
// same target. No Kalman filter, no velocity model.
//
// State (after the sample of frame N):
//   S_TRACK (1)  the target was found in frame N
//   S_HOLD  (2)  not found, but found in one of the last COAST_MAX frames: the last tracked box is kept (short occlusion)
//   S_LOST  (0)  not found for more than COAST_MAX frames (or never found): no box
// age = frames since the last measurement (0 in S_TRACK, saturates at 255). The box registers keep their last value in S_HOLD and
// S_LOST, but a consumer must only use them in S_TRACK / S_HOLD.
//
// Box update in S_TRACK for a new measurement m (per coordinate, cur = tracked value):
//   |m - cur| <= JIT        keep cur           (pixel noise / sub-pixel shimmer does not move the drawn box)
//   otherwise               cur += (m - cur) / 2, rounded towards cur  (|m - cur| >> 1; first-order smoothing, one-frame time constant)
//   if ANY of the four coordinates differs by more than SNAP the whole box jumps to the measurement (fast motion, or the target
//   re-appeared somewhere else): no smoothing over large steps, so the box never lags by more than SNAP / 2 pixels per coordinate.
// A measurement in S_HOLD or S_LOST is taken over unchanged (acquisition / re-acquisition).
//
// Counters (saturating, cleared by clr_stats): n_acq  S_LOST -> S_TRACK       n_hold  S_TRACK -> S_HOLD (an occlusion began)
//   n_reacq  S_HOLD -> S_TRACK (the target came back within COAST_MAX)      n_lost  gave up (S_HOLD -> S_LOST, or S_TRACK -> S_LOST when COAST_MAX = 0)
//   n_jit    frames in which the measurement differed from the box by 1..JIT pixels in every coordinate (all of it absorbed as jitter)
//
// What this is NOT: the crossing counter (cross_counter.v) keeps using the raw sample (valid, cx) and never sees the held box, so a
// held box does not add counts; this module only decides what is DRAWN.
// Reset: active-low asynchronous (state S_LOST, box 0, age 255, counters 0).

module target_track #(
    parameter integer COAST_MAX = 15,
    parameter integer JIT       = 2,
    parameter integer SNAP      = 24,
    parameter integer CNT_W     = 16
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             clr_stats,

    input  wire             upd,
    input  wire             valid,
    input  wire [11:0]      xmin,
    input  wire [11:0]      xmax,
    input  wire [11:0]      ymin,
    input  wire [11:0]      ymax,

    output reg  [1:0]       state,
    output reg  [11:0]      t_xmin,
    output reg  [11:0]      t_xmax,
    output reg  [11:0]      t_ymin,
    output reg  [11:0]      t_ymax,
    output wire [11:0]      t_cx,
    output wire [11:0]      t_cy,
    output reg  [7:0]       age,
    output reg  [CNT_W-1:0] n_acq,
    output reg  [CNT_W-1:0] n_hold,
    output reg  [CNT_W-1:0] n_reacq,
    output reg  [CNT_W-1:0] n_lost,
    output reg  [CNT_W-1:0] n_jit
);

    localparam [1:0] S_LOST  = 2'd0;
    localparam [1:0] S_TRACK = 2'd1;
    localparam [1:0] S_HOLD  = 2'd2;
    localparam [CNT_W-1:0] CNT_MAX = {CNT_W{1'b1}};

    // centre of the tracked box, the same formula as frame_bbox
    wire [12:0] sx = {1'b0, t_xmin} + {1'b0, t_xmax};
    wire [12:0] sy = {1'b0, t_ymin} + {1'b0, t_ymax};
    assign t_cx = sx[12:1];
    assign t_cy = sy[12:1];

    function [12:0] adiff;
        input [11:0] a;
        input [11:0] b;
        begin
            adiff = (a > b) ? ({1'b0, a} - {1'b0, b}) : ({1'b0, b} - {1'b0, a});
        end
    endfunction

    function [11:0] follow;                    // next tracked value of one coordinate
        input [11:0] cur;
        input [11:0] meas;
        reg   [12:0] ad;
        begin
            ad = adiff(cur, meas);
            if (ad <= JIT)       follow = cur;
            else if (meas > cur) follow = cur + ad[12:1];
            else                 follow = cur - ad[12:1];
        end
    endfunction

    wire [12:0] d_xmin = adiff(t_xmin, xmin);
    wire [12:0] d_xmax = adiff(t_xmax, xmax);
    wire [12:0] d_ymin = adiff(t_ymin, ymin);
    wire [12:0] d_ymax = adiff(t_ymax, ymax);
    wire        snap   = (d_xmin > SNAP) | (d_xmax > SNAP) | (d_ymin > SNAP) | (d_ymax > SNAP);
    wire        any_d  = (d_xmin != 13'd0) | (d_xmax != 13'd0) | (d_ymin != 13'd0) | (d_ymax != 13'd0);
    wire        all_j  = (d_xmin <= JIT) & (d_xmax <= JIT) & (d_ymin <= JIT) & (d_ymax <= JIT);
    wire [8:0]  age_n  = {1'b0, age} + 9'd1;       // age after one more missing frame (9 bits: no wrap before the compare)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= S_LOST;
            t_xmin <= 12'd0; t_xmax <= 12'd0; t_ymin <= 12'd0; t_ymax <= 12'd0;
            age    <= 8'd255;
            n_acq  <= {CNT_W{1'b0}}; n_hold <= {CNT_W{1'b0}}; n_reacq <= {CNT_W{1'b0}};
            n_lost <= {CNT_W{1'b0}}; n_jit  <= {CNT_W{1'b0}};
        end
        else begin
            if (clr_stats) begin
                n_acq  <= {CNT_W{1'b0}}; n_hold <= {CNT_W{1'b0}}; n_reacq <= {CNT_W{1'b0}};
                n_lost <= {CNT_W{1'b0}}; n_jit  <= {CNT_W{1'b0}};
            end
            if (upd) begin
                if (valid) begin
                    age <= 8'd0;
                    if (state == S_TRACK) begin
                        if (snap) begin
                            t_xmin <= xmin; t_xmax <= xmax; t_ymin <= ymin; t_ymax <= ymax;
                        end
                        else begin
                            t_xmin <= follow(t_xmin, xmin); t_xmax <= follow(t_xmax, xmax);
                            t_ymin <= follow(t_ymin, ymin); t_ymax <= follow(t_ymax, ymax);
                            if (any_d && all_j && !clr_stats && n_jit != CNT_MAX) n_jit <= n_jit + 1'b1;
                        end
                    end
                    else begin
                        t_xmin <= xmin; t_xmax <= xmax; t_ymin <= ymin; t_ymax <= ymax;
                        state  <= S_TRACK;
                        if (!clr_stats) begin
                            if (state == S_HOLD) begin if (n_reacq != CNT_MAX) n_reacq <= n_reacq + 1'b1; end
                            else                 begin if (n_acq   != CNT_MAX) n_acq   <= n_acq   + 1'b1; end
                        end
                    end
                end
                else begin
                    case (state)
                        S_TRACK: begin
                            age <= 8'd1;
                            if (COAST_MAX >= 1) begin
                                state <= S_HOLD;
                                if (!clr_stats && n_hold != CNT_MAX) n_hold <= n_hold + 1'b1;
                            end
                            else begin
                                state <= S_LOST;
                                if (!clr_stats && n_lost != CNT_MAX) n_lost <= n_lost + 1'b1;
                            end
                        end
                        S_HOLD: begin
                            if (age != 8'd255) age <= age[7:0] + 8'd1;
                            if (age_n > COAST_MAX) begin
                                state <= S_LOST;
                                if (!clr_stats && n_lost != CNT_MAX) n_lost <= n_lost + 1'b1;
                            end
                        end
                        default: begin
                            if (age != 8'd255) age <= age + 8'd1;
                        end
                    endcase
                end
            end
        end
    end

endmodule
