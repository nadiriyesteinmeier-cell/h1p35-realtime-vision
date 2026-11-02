// frame_bbox.v
//
// Per-frame statistics of "hit" pixels: count, bounding box, integer box
// centre and a valid flag. The result of frame N is latched at the end of
// frame N and then held, unchanged, until the end of frame N+1.
//
// Inputs (normalized pixel interface, all in one clock domain):
//   in_de   : coordinates/hit/sof/eol/eof are only looked at while in_de = 1
//   in_hit  : this pixel belongs to the target (e.g. color_segment.out_hit)
//   in_x/y  : valid-pixel coordinates (0..WIDTH-1 / 0..HEIGHT-1)
//   in_sof  : first valid pixel of a frame; this pixel IS counted
//   in_eol  : accepted for interface uniformity, NOT used (never an EOF)
//   in_eof  : last valid pixel of a frame; this pixel IS counted
//
// Frame protocol (per valid pixel, priority from top to bottom):
//   1. in_sof            : start a new frame, accumulators are re-initialized
//                          and this pixel is accumulated. If a frame was
//                          already running it is discarded (no result) and
//                          frame_abort pulses for one clock.
//   2. frame running     : accumulate this pixel if in_hit.
//   3. no frame running  : pixel is ignored (e.g. rest of a frame after a
//                          reset, or stray pixels). Nothing is invented.
//   in_eof (with a running frame, same pixel as 1. or 2.) : the pixel is
//   accumulated first, then the frame is finished and published.
//   A pixel can carry sof and eof together (1x1 frame).
//
// Outputs:
//   frame_done   : 1-clock pulse. It is visible in the clock cycle right after
//                  the cycle in which the EOF pixel was presented (latency 1).
//                  All res_* below change on the same edge and then hold.
//   frame_abort  : 1-clock pulse, one clock after an SOF that interrupted a
//                  running frame.
//   res_frame_id : number of completed frames since reset (wraps at 65536);
//                  lets the consumer see freshness.
//   res_count    : number of hit pixels of the finished frame. Saturates at
//                  2^CNT_W-1 (sticky flag res_sat). Always the real count
//                  (<= saturation), also when res_valid = 0.
//   res_valid    : res_count != 0 && res_count >= MIN_PIXELS.
//   res_x/ymin/max, res_cx, res_cy : bounding box and integer centre
//                  cx = (xmin+xmax)>>1, cy = (ymin+ymax)>>1 (13-bit sum before
//                  the shift). It is the centre of the box, not a centroid.
//                  These are forced to 0 when res_valid = 0 and must only be
//                  used while res_valid = 1.
//   After reset everything is 0 and res_frame_id = 0 until the first EOF.
//
// Parameters:
//   CNT_W       default 20: covers 1280*720 = 921600 (< 1048576). Other frame
//               sizes need CNT_W >= ceil(log2(WIDTH*HEIGHT+1)); if it is too
//               small the count saturates and res_sat = 1.
//   MIN_PIXELS  default 16 (compile-time).
//
// Reset: active-low asynchronous, release must be synchronized to clk by the
// integrator. Reset discards the unfinished frame and clears all results.
//
// Throughput: one pixel per clock, no stall. Result timing: see frame_done.

module frame_bbox #(
    parameter CNT_W      = 20,
    parameter MIN_PIXELS = 16
)(
    input  wire                clk,
    input  wire                rst_n,

    input  wire                in_de,
    input  wire                in_hit,
    input  wire [11:0]         in_x,
    input  wire [11:0]         in_y,
    input  wire                in_sof,
    input  wire                in_eol,
    input  wire                in_eof,

    output reg                 frame_done,
    output reg                 frame_abort,
    output reg  [15:0]         res_frame_id,
    output reg                 res_valid,
    output reg  [CNT_W-1:0]    res_count,
    output reg                 res_sat,
    output reg  [11:0]         res_xmin,
    output reg  [11:0]         res_xmax,
    output reg  [11:0]         res_ymin,
    output reg  [11:0]         res_ymax,
    output reg  [11:0]         res_cx,
    output reg  [11:0]         res_cy
);

    localparam [CNT_W-1:0] MIN_PIX_C = MIN_PIXELS;

    // accumulators of the frame in progress (separate from the res_* latch)
    reg                acc_active;
    reg [CNT_W-1:0]    acc_cnt;
    reg                acc_sat;
    reg [11:0]         acc_xmin;
    reg [11:0]         acc_xmax;
    reg [11:0]         acc_ymin;
    reg [11:0]         acc_ymax;

    // ---------------- combinational next-state (includes the current pixel)
    wire start_new = in_de & in_sof;
    wire consume   = in_de & (in_sof | acc_active);
    wire hit_v     = consume & in_hit;

    wire [CNT_W-1:0] b_cnt  = start_new ? {CNT_W{1'b0}} : acc_cnt;
    wire             b_sat  = start_new ? 1'b0          : acc_sat;
    wire [11:0]      b_xmin = start_new ? 12'hFFF       : acc_xmin;
    wire [11:0]      b_xmax = start_new ? 12'h000       : acc_xmax;
    wire [11:0]      b_ymin = start_new ? 12'hFFF       : acc_ymin;
    wire [11:0]      b_ymax = start_new ? 12'h000       : acc_ymax;

    wire             cnt_full = &b_cnt;

    wire [CNT_W-1:0] n_cnt  = (hit_v & ~cnt_full) ? (b_cnt + {{(CNT_W-1){1'b0}}, 1'b1})
                                                  : b_cnt;
    wire             n_sat  = b_sat | (hit_v & cnt_full);
    wire [11:0]      n_xmin = (hit_v & (in_x < b_xmin)) ? in_x : b_xmin;
    wire [11:0]      n_xmax = (hit_v & (in_x > b_xmax)) ? in_x : b_xmax;
    wire [11:0]      n_ymin = (hit_v & (in_y < b_ymin)) ? in_y : b_ymin;
    wire [11:0]      n_ymax = (hit_v & (in_y > b_ymax)) ? in_y : b_ymax;

    wire             n_valid = (n_cnt != {CNT_W{1'b0}}) & (n_cnt >= MIN_PIX_C);
    wire [12:0]      n_sumx  = {1'b0, n_xmin} + {1'b0, n_xmax};
    wire [12:0]      n_sumy  = {1'b0, n_ymin} + {1'b0, n_ymax};

    // ---------------- sequential
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_active   <= 1'b0;
            acc_cnt      <= {CNT_W{1'b0}};
            acc_sat      <= 1'b0;
            acc_xmin     <= 12'hFFF;
            acc_xmax     <= 12'h000;
            acc_ymin     <= 12'hFFF;
            acc_ymax     <= 12'h000;
            frame_done   <= 1'b0;
            frame_abort  <= 1'b0;
            res_frame_id <= 16'd0;
            res_valid    <= 1'b0;
            res_count    <= {CNT_W{1'b0}};
            res_sat      <= 1'b0;
            res_xmin     <= 12'd0;
            res_xmax     <= 12'd0;
            res_ymin     <= 12'd0;
            res_ymax     <= 12'd0;
            res_cx       <= 12'd0;
            res_cy       <= 12'd0;
        end
        else begin
            frame_done  <= 1'b0;
            frame_abort <= start_new & acc_active;

            if (consume) begin
                acc_cnt  <= n_cnt;
                acc_sat  <= n_sat;
                acc_xmin <= n_xmin;
                acc_xmax <= n_xmax;
                acc_ymin <= n_ymin;
                acc_ymax <= n_ymax;

                if (in_eof) begin
                    acc_active   <= 1'b0;
                    frame_done   <= 1'b1;
                    res_frame_id <= res_frame_id + 16'd1;
                    res_count    <= n_cnt;
                    res_sat      <= n_sat;
                    res_valid    <= n_valid;
                    res_xmin     <= n_valid ? n_xmin       : 12'd0;
                    res_xmax     <= n_valid ? n_xmax       : 12'd0;
                    res_ymin     <= n_valid ? n_ymin       : 12'd0;
                    res_ymax     <= n_valid ? n_ymax       : 12'd0;
                    res_cx       <= n_valid ? n_sumx[12:1] : 12'd0;
                    res_cy       <= n_valid ? n_sumy[12:1] : 12'd0;
                end
                else begin
                    acc_active <= 1'b1;
                end
            end
        end
    end

endmodule
