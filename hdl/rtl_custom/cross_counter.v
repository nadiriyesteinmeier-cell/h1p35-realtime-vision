// cross_counter.v - counts how often the target centre crosses a vertical line (one decision per frame)
//
// Input is one sample per frame, e.g. frame_bbox: upd = frame_done, valid = res_valid, cx = res_cx.
// Everything else on the input side (valid / cx / line_x) is ignored while upd = 0.
//
// Zone of a frame (13-bit arithmetic, no wrap):
//   N  : valid = 0                          (target not found in this frame)
//   L  : cx + HYST <  line_x                (clearly left of the line)
//   R  : cx        >  line_x + HYST         (clearly right of the line)
//   M  : otherwise                          (dead band around the line, |cx - line_x| <= HYST)
//
// State: side (U = unknown, L, R) = side the target was last CONFIRMED on; cand/ccnt = candidate for a side change
// and for how many consecutive frames it has been seen; lcnt = consecutive frames without target (saturating).
// Per sample (upd = 1):
//   z = N : lcnt++ (saturates at LOST_MAX+1); cand cleared; if lcnt > LOST_MAX the side is forgotten (side = U)
//   z = M : lcnt = 0; cand cleared; side unchanged
//   z = L or R : lcnt = 0
//       z == side : cand cleared
//       z != side : n = (cand == z) ? ccnt + 1 : 1
//                   n >= CONFIRM : side = z; if the old side was not U a crossing is counted (L->R or R->L); cand cleared
//                   otherwise    : cand = z, ccnt = n
// So a crossing needs the target to be seen CONFIRM frames IN A ROW clearly on the other side (jitter inside the dead
// band, one-frame spikes and a lost-and-found target on the same side do not count). A target that stays away longer
// than LOST_MAX frames is forgotten: when it re-appears (on either side) the new side is only learned, nothing is
// counted. line_x is looked at once per sample; keep it constant (moving the line moves the zones).
//
// Outputs (all registered, change one clock after upd):
//   evt       : 1-clock pulse for a counted crossing; evt_dir = 0 for left-to-right, 1 for right-to-left (it holds the
//               direction of the LAST counted crossing, only meaningful together with evt)
//   cnt_lr, cnt_rl : crossings per direction, cnt_total : both, each saturating at 2^CNT_W-1
//   side      : 0 unknown, 1 left, 2 right
// Reset: active-low asynchronous (release must be synchronized by the integrator) clears everything.
// Latency from the upd cycle to the registered outputs: 1 clock. No stall, no ready.

module cross_counter #(
    parameter integer HYST     = 12,
    parameter integer CONFIRM  = 2,
    parameter integer LOST_MAX = 5,
    parameter integer CNT_W    = 16
)(
    input  wire             clk,
    input  wire             rst_n,

    input  wire             upd,
    input  wire             valid,
    input  wire [11:0]      cx,
    input  wire [11:0]      line_x,

    output reg              evt,
    output reg              evt_dir,
    output reg  [CNT_W-1:0] cnt_lr,
    output reg  [CNT_W-1:0] cnt_rl,
    output reg  [CNT_W-1:0] cnt_total,
    output reg  [1:0]       side
);

    localparam [1:0] S_U = 2'd0;
    localparam [1:0] S_L = 2'd1;
    localparam [1:0] S_R = 2'd2;
    localparam [CNT_W-1:0] CNT_MAX = {CNT_W{1'b1}};

    wire [12:0] hyst13 = HYST;
    wire [12:0] cx13   = {1'b0, cx};
    wire [12:0] ln13   = {1'b0, line_x};

    // zone of the incoming sample
    wire z_none  = ~valid;
    wire z_left  = valid & ((cx13 + hyst13) <  ln13);
    wire z_right = valid & (cx13 > (ln13 + hyst13));
    wire [1:0] z = z_left ? S_L : (z_right ? S_R : S_U);          // S_U doubles as "no clear side" for M / N

    reg  [1:0]  cand;
    reg  [15:0] ccnt;
    reg  [15:0] lcnt;

    // next-state values (computed from the current state and the sample)
    reg  [1:0]  n_side;
    reg  [1:0]  n_cand;
    reg  [15:0] n_ccnt;
    reg  [15:0] n_lcnt;
    reg  [15:0] seen;
    reg         n_evt;
    reg         n_dir;

    always @(*) begin
        n_side = side;
        n_cand = cand;
        n_ccnt = ccnt;
        n_lcnt = lcnt;
        seen   = 16'd0;
        n_evt  = 1'b0;
        n_dir  = 1'b0;
        if (z_none) begin
            n_lcnt = (lcnt > LOST_MAX) ? lcnt : (lcnt + 16'd1);
            n_cand = S_U;
            n_ccnt = 16'd0;
            if (n_lcnt > LOST_MAX) n_side = S_U;
        end
        else begin
            n_lcnt = 16'd0;
            if (z == S_U) begin                                    // dead band
                n_cand = S_U;
                n_ccnt = 16'd0;
            end
            else if (z == side) begin
                n_cand = S_U;
                n_ccnt = 16'd0;
            end
            else begin
                seen = (cand == z) ? (ccnt + 16'd1) : 16'd1;
                if (seen >= CONFIRM) begin
                    n_side = z;
                    n_cand = S_U;
                    n_ccnt = 16'd0;
                    if (side != S_U) begin
                        n_evt = 1'b1;
                        n_dir = (side == S_R);                     // 0: L->R, 1: R->L
                    end
                end
                else begin
                    n_cand = z;
                    n_ccnt = seen;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            side      <= S_U;
            cand      <= S_U;
            ccnt      <= 16'd0;
            lcnt      <= 16'd0;
            evt       <= 1'b0;
            evt_dir   <= 1'b0;
            cnt_lr    <= {CNT_W{1'b0}};
            cnt_rl    <= {CNT_W{1'b0}};
            cnt_total <= {CNT_W{1'b0}};
        end
        else begin
            evt <= 1'b0;
            if (upd) begin
                side <= n_side;
                cand <= n_cand;
                ccnt <= n_ccnt;
                lcnt <= n_lcnt;
                evt  <= n_evt;
                if (n_evt) begin
                    evt_dir <= n_dir;
                    cnt_total <= (cnt_total == CNT_MAX) ? cnt_total : (cnt_total + 1'b1);
                    if (n_dir) cnt_rl <= (cnt_rl == CNT_MAX) ? cnt_rl : (cnt_rl + 1'b1);
                    else       cnt_lr <= (cnt_lr == CNT_MAX) ? cnt_lr : (cnt_lr + 1'b1);
                end
            end
        end
    end

endmodule
