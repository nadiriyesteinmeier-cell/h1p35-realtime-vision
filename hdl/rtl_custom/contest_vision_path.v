// contest_vision_path.v - everything of this project that sits between the baseline video-timing /
// frame-buffer read-out and hdmi_tx, behind ONE bypass switch.
//
//   uivtc de/user/last + frame-buffer RGB --> video_pos_adapter --+--> rgb_to_gray ----+
//                                                                  |                   +--> view_mux --> osd_overlay --> tx
//                                                                  +--> color_segment -+        ^  (orig RGB delayed 2)
//                                                                         |                      |
//                                                                         +--> frame_bbox -- res_* (box, centre, count)
//
// Switches (board SW1..SW4 are toggle switches, up = 1, down = 0; they are async, sampled by 2 flip-flops):
//   sw[0]    1 = processed path (this module's picture), 0 = BASELINE picture (hdmi_mixer output, untouched)
//   sw[2:1]  view: 00 original, 01 gray, 10 colour mask, 11 original with the detected target painted
//   sw[3]    1 = also draw target box, crosshair and counting line, 0 = only logo and text
// LEDs (high = on): led[0] target found, led[1] sticky 'row/column geometry error' of the position adapter
// (cleared by sw[0] = 0), led[2] blinks every 16 processed frames, led[3] processed path active.
//
// Timing: hdmi_tx must see vsync/de delayed by exactly the latency of the RGB path, otherwise the
// picture is shifted. Latency from the uivtc de to the OSD output = SKEW + 1 (adapter) + 2 (gray / segment)
// + 1 (view_mux) + 3 (osd) = SKEW + 7. SKEW is the number of clocks by which the frame-buffer RGB
// lags the uivtc de at rd_rgb; reading hdmi_mixer / video_out suggests 2, NOT yet confirmed on hardware.
// A wrong SKEW only shifts the picture / OSD coordinates by that many pixels (the statistics and the
// frame structure do not depend on it).
//
// Reset: rst_n_async is the PLL lock level of the baseline; it is synchronized to clk here (asynchronous
// assertion, synchronous release) before it reaches any of the new modules.

module contest_vision_path #(
    parameter integer SKEW       = 2,
    parameter integer R_MIN      = 80,
    parameter integer DELTA      = 30,
    parameter integer MIN_PIXELS = 400,
    parameter integer LINE_X     = 640
)(
    input  wire        clk,
    input  wire        rst_n_async,

    // baseline timing source (uivtc outputs, NOT delayed) and frame-buffer RGB
    input  wire        vtc_vs,
    input  wire        vtc_de,
    input  wire        vtc_user,
    input  wire        vtc_last,
    input  wire [23:0] rd_rgb,

    // baseline output of hdmi_mixer, used while bypassed
    input  wire        base_vs,
    input  wire        base_de,
    input  wire [23:0] base_data,

    input  wire [3:0]  sw,

    output wire        tx_vs,
    output wire        tx_de,
    output wire [23:0] tx_data,
    output wire [3:0]  led
);

    localparam [11:0] LINE_X_C = LINE_X;

    // ---------------- reset and switch synchronizers
    reg [1:0] rs;
    always @(posedge clk or negedge rst_n_async) begin
        if (!rst_n_async) rs <= 2'b00;
        else              rs <= {rs[0], 1'b1};
    end
    wire rst_n = rs[1];

    reg [3:0] sw_a, sw_b;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin sw_a <= 4'd0; sw_b <= 4'd0; end
        else        begin sw_a <= sw;   sw_b <= sw_a; end
    end
    wire proc_en = sw_b[0];
    wire [1:0] view_mode = sw_b[2:1];
    wire draw_extra = sw_b[3];

    // ---------------- position adapter: de/user/last -> x, y, sof, eol, eof
    wire        a_de, a_sof, a_eol, a_eof, a_err, a_active;
    wire [23:0] a_rgb;
    wire [11:0] a_x, a_y;

    video_pos_adapter #(.WIDTH(1280), .HEIGHT(720), .SYNC_DELAY(SKEW)) u_adapter (
        .clk(clk), .rst_n(rst_n),
        .vid_de(vtc_de), .vid_user(vtc_user), .vid_last(vtc_last), .vid_rgb(rd_rgb),
        .out_de(a_de), .out_rgb(a_rgb), .out_x(a_x), .out_y(a_y),
        .out_sof(a_sof), .out_eol(a_eol), .out_eof(a_eof),
        .frame_active(a_active), .geom_err(a_err)
    );

    // ---------------- gray and colour segmentation (both latency 2)
    wire        g_de, g_sof, g_eol, g_eof;
    wire [23:0] g_rgb;
    wire [11:0] g_x, g_y;
    rgb_to_gray u_gray (
        .clk(clk), .rst_n(rst_n),
        .in_de(a_de), .in_rgb(a_rgb), .in_x(a_x), .in_y(a_y), .in_sof(a_sof), .in_eol(a_eol), .in_eof(a_eof),
        .out_de(g_de), .out_gray(), .out_rgb(g_rgb), .out_x(g_x), .out_y(g_y),
        .out_sof(g_sof), .out_eol(g_eol), .out_eof(g_eof)
    );

    wire        s_de, s_hit, s_sof, s_eol, s_eof;
    wire [23:0] s_mask;
    wire [11:0] s_x, s_y;
    color_segment #(.R_MIN(R_MIN), .DELTA(DELTA), .X0(0), .X1(1280), .Y0(0), .Y1(720)) u_seg (
        .clk(clk), .rst_n(rst_n),
        .in_de(a_de), .in_rgb(a_rgb), .in_x(a_x), .in_y(a_y), .in_sof(a_sof), .in_eol(a_eol), .in_eof(a_eof),
        .out_de(s_de), .out_hit(s_hit), .out_rgb(), .out_mask(s_mask), .out_x(s_x), .out_y(s_y),
        .out_sof(s_sof), .out_eol(s_eol), .out_eof(s_eof)
    );

    // ---------------- statistics of the target (result of frame N is shown in frame N+1)
    wire        frame_done, frame_abort, res_valid, res_sat;
    wire [15:0] res_frame_id;
    wire [19:0] res_count;
    wire [11:0] res_xmin, res_xmax, res_ymin, res_ymax, res_cx, res_cy;
    frame_bbox #(.CNT_W(20), .MIN_PIXELS(MIN_PIXELS)) u_bbox (
        .clk(clk), .rst_n(rst_n),
        .in_de(s_de), .in_hit(s_hit), .in_x(s_x), .in_y(s_y), .in_sof(s_sof), .in_eol(s_eol), .in_eof(s_eof),
        .frame_done(frame_done), .frame_abort(frame_abort),
        .res_frame_id(res_frame_id), .res_valid(res_valid), .res_count(res_count), .res_sat(res_sat),
        .res_xmin(res_xmin), .res_xmax(res_xmax), .res_ymin(res_ymin), .res_ymax(res_ymax),
        .res_cx(res_cx), .res_cy(res_cy)
    );

    // ---------------- display path: view select, then OSD
    wire [23:0] orig2;
    sync_delay #(.N(2), .W(24)) u_orig_dly (.clk(clk), .rst_n(rst_n), .din(a_rgb), .dout(orig2));

    wire        v_de, v_sof, v_eol, v_eof;
    wire [23:0] v_rgb;
    wire [11:0] v_x, v_y;
    view_mux #(.TINT_COLOR(24'hFF00FF)) u_view (
        .clk(clk), .rst_n(rst_n),
        .in_de(g_de), .in_x(g_x), .in_y(g_y), .in_sof(g_sof), .in_eol(g_eol), .in_eof(g_eof),
        .rgb_orig(orig2), .rgb_gray(g_rgb), .rgb_mask(s_mask), .hit(s_hit), .mode(view_mode),
        .out_de(v_de), .out_rgb(v_rgb), .out_x(v_x), .out_y(v_y),
        .out_sof(v_sof), .out_eol(v_eol), .out_eof(v_eof)
    );

    wire        o_de;
    wire [23:0] o_rgb;
    osd_overlay u_osd (
        .clk(clk), .rst_n(rst_n),
        .in_de(v_de), .in_rgb(v_rgb), .in_x(v_x), .in_y(v_y), .in_sof(v_sof), .in_eol(v_eol), .in_eof(v_eof),
        .cfg_flags({1'b1, draw_extra, draw_extra, draw_extra, 1'b1}),
        .cfg_mode(view_mode), .tgt_valid(res_valid),
        .tgt_xmin(res_xmin), .tgt_xmax(res_xmax), .tgt_ymin(res_ymin), .tgt_ymax(res_ymax),
        .tgt_cx(res_cx), .tgt_cy(res_cy), .tgt_count(res_count), .line_x(LINE_X_C), .cross_cnt(16'd0),
        .out_de(o_de), .out_rgb(o_rgb), .out_x(), .out_y(), .out_sof(), .out_eol(), .out_eof()
    );

    // ---------------- timing for the processed picture: vsync/de delayed by the RGB path latency
    wire [1:0] vd;
    sync_delay #(.N(SKEW + 7), .W(2)) u_tim_dly (.clk(clk), .rst_n(rst_n), .din({vtc_vs, vtc_de}), .dout(vd));

    assign tx_vs   = proc_en ? vd[1] : base_vs;
    assign tx_de   = proc_en ? vd[0] : base_de;
    assign tx_data = proc_en ? o_rgb : base_data;

    // ---------------- status LEDs
    reg err_sticky;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)         err_sticky <= 1'b0;
        else if (!proc_en)  err_sticky <= 1'b0;
        else if (a_err)     err_sticky <= 1'b1;
    end
    assign led = {proc_en, res_frame_id[4], err_sticky, res_valid};

endmodule
