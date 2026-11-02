// video_pos_adapter.v
//
// Turns the baseline-style stream (de + user + last + rgb) into the normalized
// pixel stream of this project (de, rgb, x, y, sof, eol, eof).
//
// Input contract (read from lab1/uivtc.v, NOT yet proven on hardware):
//   vid_de   : pixel valid
//   vid_user : 1 on the FIRST valid pixel of a frame (same clock as vid_de)
//   vid_last : 1 on the LAST valid pixel of every line (same clock as vid_de)
//   vid_rgb  : colour of the pixel whose vid_de was SYNC_DELAY clocks earlier.
//              Use SYNC_DELAY = 0 if rgb is aligned with de. If the colour data
//              lags de by N clocks (suspected 2 in the baseline mixer path,
//              unverified) set SYNC_DELAY = N: de/user/last are then delayed by N
//              clocks inside this module so that they meet the colour again.
//   There is no frame-end input. EOF is derived: last pixel of line HEIGHT-1.
//
// Counting (the baseline hdmi_mixer counters are NOT reused, they are one clock
// late on the first line of each frame):
//   x_cur = user ? 0 : x_nxt ;  y_cur = user ? 0 : y_nxt     (combinational)
//   on a passed pixel:  last ? (x_nxt<=0, y_nxt<=y_cur+1) : (x_nxt<=x_cur+1, y_nxt<=y_cur)
//
// Per valid pixel (priority top to bottom):
//   1. A pixel belongs to a frame if vid_user = 1 (starts one) or a frame is
//      running. Pixels with no running frame (after reset, after EOF, after a
//      geometry error) are DROPPED: out_de = 0 and every output 0.
//   2. Geometry check of a pixel inside a frame, either of
//        x_cur >= WIDTH                      (line longer than WIDTH)
//        vid_last && x_cur != WIDTH-1        (line shorter / last misplaced)
//      is a violation: the pixel is dropped, the frame is aborted (no EOF is
//      invented), everything is dropped until the next vid_user, geom_err pulses.
//      There is no "too many lines" check: the frame ends (active cleared) at the
//      last pixel of line HEIGHT-1, so a running frame can never reach y = HEIGHT.
//      Extra lines after that are stray pixels (no running frame) and are dropped
//      silently, exactly like the pixels before the first vid_user after reset.
//   3. Otherwise the pixel passes with x_cur/y_cur and
//        out_sof = vid_user, out_eol = vid_last,
//        out_eof = vid_last && y_cur == HEIGHT-1   (this ends the frame).
//   A vid_user while a frame is running restarts the frame at this pixel (the old
//   frame never gets an EOF) and also pulses geom_err once.
//   vid_user / vid_last with vid_de = 0 are ignored.
//   WIDTH = 1 or HEIGHT = 1 are allowed (sof/eol/eof can share a pixel).
//
// Outputs are registered. Latency from vid_de to out_de = SYNC_DELAY + 1 clocks,
// from vid_rgb to out_rgb = 1 clock. Throughput 1 pixel/clock, no stall.
// When out_de = 0 all payload/sideband outputs are 0.
//   frame_active : a frame is running after the pixel just output (diagnostic)
//   geom_err     : 1-clock pulse (visible 1 clock after the offending pixel)
//
// WIDTH/HEIGHT up to 4096 (13-bit compares, 12-bit coordinates).
// Reset: active-low asynchronous, release must be synchronized by the integrator.

module video_pos_adapter #(
    parameter WIDTH      = 1280,
    parameter HEIGHT     = 720,
    parameter SYNC_DELAY = 0
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        vid_de,
    input  wire        vid_user,
    input  wire        vid_last,
    input  wire [23:0] vid_rgb,

    output reg         out_de,
    output reg  [23:0] out_rgb,
    output reg  [11:0] out_x,
    output reg  [11:0] out_y,
    output reg         out_sof,
    output reg         out_eol,
    output reg         out_eof,
    output wire        frame_active,
    output reg         geom_err
);

    localparam [12:0] W_C    = WIDTH;
    localparam [12:0] W_LAST = WIDTH - 1;
    localparam [12:0] H_LAST = HEIGHT - 1;

    // ---------------- optional delay of de/user/last
    wire s_de;
    wire s_user;
    wire s_last;

    generate
        if (SYNC_DELAY == 0) begin : g_d0
            assign s_de   = vid_de;
            assign s_user = vid_user;
            assign s_last = vid_last;
        end
        else if (SYNC_DELAY == 1) begin : g_d1
            reg [2:0] sr;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) sr <= 3'b000;
                else        sr <= {vid_de, vid_user, vid_last};
            end
            assign {s_de, s_user, s_last} = sr;
        end
        else begin : g_dn
            reg [3*SYNC_DELAY-1:0] sr;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) sr <= {(3*SYNC_DELAY){1'b0}};
                else        sr <= {sr[3*SYNC_DELAY-4:0], vid_de, vid_user, vid_last};
            end
            assign {s_de, s_user, s_last} = sr[3*SYNC_DELAY-1:3*SYNC_DELAY-3];
        end
    endgenerate

    // ---------------- position counters
    reg  [11:0] x_nxt;
    reg  [11:0] y_nxt;
    reg         active;

    wire        start  = s_de & s_user;
    wire [11:0] x_cur  = start ? 12'd0 : x_nxt;
    wire [11:0] y_cur  = start ? 12'd0 : y_nxt;
    wire        run    = s_de & (s_user | active);

    wire        v_wide  = ({1'b0, x_cur} >= W_C);
    wire        v_short = s_last & ({1'b0, x_cur} != W_LAST);
    wire        viol    = run & (v_wide | v_short);
    wire        pass    = run & ~viol;
    wire        last_ln = ({1'b0, y_cur} == H_LAST);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_nxt        <= 12'd0;
            y_nxt        <= 12'd0;
            active       <= 1'b0;
            out_de       <= 1'b0;
            out_rgb      <= 24'd0;
            out_x        <= 12'd0;
            out_y        <= 12'd0;
            out_sof      <= 1'b0;
            out_eol      <= 1'b0;
            out_eof      <= 1'b0;
            geom_err     <= 1'b0;
        end
        else begin
            out_de   <= pass;
            out_rgb  <= pass ? vid_rgb : 24'd0;
            out_x    <= pass ? x_cur   : 12'd0;
            out_y    <= pass ? y_cur   : 12'd0;
            out_sof  <= pass & s_user;
            out_eol  <= pass & s_last;
            out_eof  <= pass & s_last & last_ln;
            geom_err <= (start & active) | viol;

            if (viol) begin
                active <= 1'b0;
            end
            else if (pass) begin
                if (s_last) begin
                    x_nxt  <= 12'd0;
                    y_nxt  <= y_cur + 12'd1;
                    active <= ~last_ln;
                end
                else begin
                    x_nxt  <= x_cur + 12'd1;
                    y_nxt  <= y_cur;            // after a frame start y_cur is 0, y_nxt must follow
                    active <= 1'b1;
                end
            end
        end
    end

    // 'active' is updated on the same clock edge as the output registers
    assign frame_active = active;

endmodule
