// contest_vision_v2.v - everything of this project that sits between the baseline video timing / frame-buffer read-out
// and hdmi_tx (plus the external indicators), behind ONE bypass switch. Successor of contest_vision_path.v; the v1 block
// and the v1 bitstream are not touched by this file.
//
//   uivtc de/user/last + frame-buffer RGB --> video_pos_adapter --+--> rgb_to_gray --> edge_style (Sobel) --+--> view_mux_style --> osd_overlay --> osd_ext --> tx
//                                                                 |       |  luma_mean --> thr_adapt (previous-frame brightness)
//                                                                 |       v                          ^
//                                                                 +--> color_seg_rt x3 (R, G, B via channel permutation, runtime thresholds)
//                                                                         |--> frame_bbox x3 --> shape_classify x3, cross_counter x3
//                                                                         +--> hits for the coloured views
//   result of frame N is drawn in frame N+1 (fixed one-frame lag), as in v1.
//
// Board controls (SW = toggle switches, up = 1; KEY = push buttons, low = pressed)
//   SW1  1 = processed picture, 0 = BASELINE picture (hdmi_mixer output untouched)
//   SW2/SW3  view {SW3,SW2}, two pages (page toggled by a long press of KEY2, power-on page 0):
//              page 0: 00 original, 01 gray, 10 colour-coded mask (R/G/B), 11 original with targets painted
//              page 1: 00 SKETCH (edges on shaded paper), 01 CARTOON (8-level colours + black edges), 10 EDGE+ (edges on dimmed video), 11 THERMAL (pseudo-colour)
//   SW4  1 = draw graphics: counting line (+ boxes / crosses of the recognised targets)
//   KEY1 (release)  toggle recognition mode: three coloured boxes + recognition panel (RED / GRN / BLU, shape, position, crossing count)
//   KEY2 (release)  toggle adaptive thresholds (channel-ratio rule + brightness-dependent noise floor) <-> fixed thresholds
//                   (the same switch also scales the edge threshold with the scene brightness)
//   KEY2 (hold >= 1 s)  switch the view page (see above)
//   KEY1+KEY2 together   clear the crossing counters
//   KEY3 / KEY4     move the counting line left / right (16 px per press, auto-repeat while held)
// Power-on state of KEY-controlled modes: recognition off, fixed thresholds, line at LINE_INIT.
//
// REQUEST / EFFECTIVE (frame_commit.v): the controls above are only REQUESTS. view mode, page, SW4 graphics, recognition mode,
// adaptive thresholds and the counting-line position are copied into the effective settings that the pipeline uses at the falling
// edge of the baseline vsync (the 20 lines before the next frame; the pipeline holds no pixel then), so a frame is always drawn with
// ONE set of settings and the OSD text of that frame shows exactly the settings that made the picture. The bypass switch SW1 is
// committed when both video streams (baseline and processed, 12 clocks apart) are inside their vsync pulse, so the HDMI transmitter
// never gets half a frame of each. A request that comes and goes between two boundaries has no effect. Before the first boundary
// after reset the effective settings follow the requests. Outputs req_pending / mode_gen show a waiting request / the number of
// committed changes. KEY1+KEY2 (clear counters) is not a setting and acts at once.
//
// TARGET HOLD (target_track.v, one per colour): the boxes of the OSD are drawn from a tracker, not from the raw per-frame bounding
// box: pixel jitter is absorbed, a target that disappears for up to TRK_COAST frames keeps a dashed box (panel: HOLD), then it is
// LOST (no box, panel: LOST); a returning target is taken over at once. The crossing counters, the UART line and the LED keep using
// the raw measurement, so a held box never adds counts. Result of frame N is drawn in frame N+1, as before.
// LEDs (high = on): led[0] any target found, led[1] sticky adapter geometry error (cleared by SW1 = 0),
// led[2] heartbeat (red frame counter bit 4), led[3] processed path active.
// Other outputs: buzzer_n (low = sound) beeps on every counted line crossing; uart_tx sends one text line every 0.2 s
// (uart_report.v); seg / sel drive the 8-digit seven-segment display: left four digits = total crossings, then 'F' and the
// measured camera frame rate.
//
// Noise filter: every colour's hit stream goes through hit_open (runs of fewer than OPEN_RUN hit pixels in a line are removed)
// before frame_bbox and before the coloured views; that adds 5 clocks to the hit path, and the edge / gray stream is delayed by
// 2 clocks to stay aligned with it.
// Bypass: the baseline hdmi_mixer output has the pixel data 2 clocks BEHIND its de (video_out reads the FIFO 2 clocks after
// rd_en = de; tb_baseline_readout.v shows it on the unmodified lab1 sources): the first two pixels of every line are black
// (0) and the last two pixels of the frame-buffer line never reach the screen. In the bypass path vs / de are therefore
// delayed by BYPASS_ALIGN = 2 clocks (data untouched), which shows the complete line; set BYPASS_ALIGN = 0 for the original
// baseline behaviour.
// Latency uivtc de -> tx_de: SKEW + 1 (adapter) + 2 (gray) + 3 (edge_style) + 2 (alignment) + 1 (view_mux_style) + 3 (osd_overlay)
// + 3 (osd_ext) = SKEW + 15. SKEW is the number of clocks the frame-buffer RGB lags the uivtc de (inferred as 2 from reading the
// baseline, NOT confirmed on hardware). In bypass the baseline latency (3) applies.
//
// Clocks: clk = pixel clock (S_hdmi_pixel_clk). ref_clk = 50 MHz crystal (frame-rate time base), cam_clk = MIPI byte clock
// domain of the camera frame start (cam_start). The three domains only meet in toggle synchronizers / byte_cdc.
// Reset: rst_n_async is the PLL lock of the baseline; it is synchronized here (asynchronous assertion, synchronous release).

module contest_vision_v2 #(
    parameter integer SKEW       = 2,
    parameter integer WIDTH      = 1280,
    parameter integer HEIGHT     = 720,
    parameter integer R_MIN      = 80,
    parameter integer DELTA      = 30,
    parameter integer MIN_PIXELS = 400,
    parameter integer OPEN_RUN   = 5,
    parameter integer TRK_COAST  = 15,            // frames a vanished target keeps its (dashed) box
    parameter integer TRK_JIT    = 2,             // box edges that move by <= this many pixels are not redrawn
    parameter integer TRK_SNAP   = 24,            // an edge that moves by more than this makes the box jump (no smoothing)
    parameter integer BYPASS_ALIGN = 2,           // clocks by which the bypass vs / de are delayed to meet the lagging frame-buffer data
    parameter [10:0] EDGE_FIXED_THR = 11'd50,  // Lower for weak contours; raise if camera noise creates false edges.
    parameter integer LINE_INIT  = 640,
    parameter integer LOGO_EN    = 1,             // 0: no logo here (contest_work_v3_adv draws it on every page in top_osd.v)
    parameter integer BORDER     = 0,             // hits in the outer BORDER lines / columns are ignored (frame-buffer edge artefact, see below)
    // timing parameters (defaults for a 75 MHz pixel clock and a 50 MHz reference; override for fast simulation)
    parameter integer KEY_DEB    = 1500000,
    parameter integer KEY_HOLD0  = 30000000,
    parameter integer KEY_REP    = 7500000,
    parameter integer KEY_LONG   = 75000000,
    parameter integer REF_HZ     = 50000000,
    parameter integer UART_CLKDIV = 651,
    parameter integer UART_PERIOD = 15000000,
    parameter integer SEG_TICK   = 9375,
    parameter integer BEEP_CLKS  = 11250000,
    parameter integer BEEP_HALF  = 18750
)(
    input  wire        clk,
    input  wire        rst_n_async,

    // baseline timing source (uivtc outputs, NOT delayed) and frame-buffer RGB
    input  wire        vtc_vs,
    input  wire        vtc_de,
    input  wire        vtc_user,
    input  wire        vtc_last,
    input  wire [23:0] rd_rgb,
    input  wire [23:0] blue_rd_rgb, // same pixel phase as rd_rgb, before display gains/lift/saturation

    // baseline output of hdmi_mixer, used while bypassed
    input  wire        base_vs,
    input  wire        base_de,
    input  wire [23:0] base_data,

    input  wire [3:0]  sw,
    input  wire [3:0]  key_n,

    // frame-rate measurement
    input  wire        ref_clk,
    input  wire        cam_clk,
    input  wire        cam_start,

    output wire        tx_vs,
    output wire        tx_de,
    output wire [23:0] tx_data,
    output wire [3:0]  led,
    output wire        buzzer_n,
    output wire        uart_tx,
    output wire [7:0]  seg,
    output wire [7:0]  sel,

    // settings status (for observation / tests): a request is waiting for the next frame boundary / number of committed changes
    output wire        req_pending,
    output wire [7:0]  mode_gen
);

    // ---------------- reset and switch synchronizers
    reg [1:0] rs;
    always @(posedge clk or negedge rst_n_async) begin
        if (!rst_n_async) rs <= 2'b00;
        else              rs <= {rs[0], 1'b1};
    end
    // The design has ~4400 flip-flops with an asynchronous reset: a single reset net would have a fanout of that size and
    // its delay would eat the whole clock period (the first v2 build had 12.8 ns on this net). The synchronized reset is
    // therefore copied into six registers (kept apart by 'preserve'), each driving one group of modules.
    (* preserve = "true" *) reg [5:0] rst_cp;
    always @(posedge clk) rst_cp <= {6{rs[1]}};
    wire rst_n  = rst_cp[0];     // group 0: switches, keys, adapter, gray / mean, segmentation, noise filter
    wire rst_n1 = rst_cp[1];     // group 1: statistics, shapes, crossing counters
    wire rst_n2 = rst_cp[2];     // group 2: edge, views, OSD v1, output timing
    wire rst_n3 = rst_cp[3];     // group 3: OSD v2 (pipeline and per-frame registers)
    wire rst_n4 = rst_cp[4];     // group 4: UART, seven-segment, beeper, frame-rate read-back
    wire rst_n5 = rst_cp[5];     // group 5: OSD v2 decimal converters

    reg [3:0] sw_a, sw_b;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin sw_a <= 4'd0; sw_b <= 4'd0; end
        else        begin sw_a <= sw;   sw_b <= sw_a; end
    end
    wire       proc_req   = sw_b[0];            // request of the bypass switch (committed below, after the output streams are known)

    // ---------------- keys: recognition mode, adaptive thresholds, counting line
    wire        req_recog, req_adapt, req_page, clear_pulse;
    wire [11:0] req_line_x;
    ui_ctrl #(.DEB(KEY_DEB), .HOLD0(KEY_HOLD0), .REP(KEY_REP), .LONG(KEY_LONG), .LINE_INIT(LINE_INIT)) u_ui (
        .clk(clk), .rst_n(rst_n), .key_n(key_n),
        .recog_en(req_recog), .adaptive_en(req_adapt), .style_page(req_page), .line_x(req_line_x), .clear_pulse(clear_pulse)
    );

    // ---------------- request -> effective settings at the falling edge of the baseline vsync (blanking, pipeline empty)
    wire       cm_pending;
    wire [7:0] cm_gen;
    reg cm_vs_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cm_vs_q <= 1'b0;
        else        cm_vs_q <= vtc_vs;
    end
    wire        cm_pulse = cm_vs_q & ~vtc_vs;

    wire [1:0]  view_mode;
    wire        draw_extra, recog_en, adapt_en, style_page;
    wire [11:0] line_x;
    wire        cm_changed;
    frame_commit #(.W(18), .INIT({12'd0, 6'd0} | (LINE_INIT << 6))) u_commit (
        .clk(clk), .rst_n(rst_n), .commit(cm_pulse),
        .req({req_line_x, sw_b[2:1], sw_b[3], req_recog, req_adapt, req_page}),
        .eff({line_x, view_mode, draw_extra, recog_en, adapt_en, style_page}),
        .pending(cm_pending), .changed(cm_changed), .gen(cm_gen)
    );

    // ---------------- position adapter
    wire        a_de, a_sof, a_eol, a_eof, a_err, a_active;
    wire [23:0] a_rgb;
    // Display enhancement can turn cool neutral light into a blue hit. Classify
    // blue from the pre-tone RGB, registered once to match u_adapter.out_rgb.
    // No added video latency; red/green keep their existing input and thresholds.
    wire [23:0] a_blue_rgb;
    sync_delay #(.N(1), .W(24)) u_blue_raw (
        .clk(clk), .rst_n(rst_n), .din(blue_rd_rgb), .dout(a_blue_rgb)
    );
    wire [11:0] a_x, a_y;
    video_pos_adapter #(.WIDTH(WIDTH), .HEIGHT(HEIGHT), .SYNC_DELAY(SKEW)) u_adapter (
        .clk(clk), .rst_n(rst_n),
        .vid_de(vtc_de), .vid_user(vtc_user), .vid_last(vtc_last), .vid_rgb(rd_rgb),
        .out_de(a_de), .out_rgb(a_rgb), .out_x(a_x), .out_y(a_y),
        .out_sof(a_sof), .out_eol(a_eol), .out_eof(a_eof),
        .frame_active(a_active), .geom_err(a_err)
    );

    // ---------------- gray (also the brightness measurement)
    wire        g_de, g_sof, g_eol, g_eof;
    wire [7:0]  g_gray;
    wire [23:0] g_rgb;
    wire [11:0] g_x, g_y;
    rgb_to_gray u_gray (
        .clk(clk), .rst_n(rst_n),
        .in_de(a_de), .in_rgb(a_rgb), .in_x(a_x), .in_y(a_y), .in_sof(a_sof), .in_eol(a_eol), .in_eof(a_eof),
        .out_de(g_de), .out_gray(g_gray), .out_rgb(g_rgb), .out_x(g_x), .out_y(g_y),
        .out_sof(g_sof), .out_eol(g_eol), .out_eof(g_eof)
    );

    wire [7:0] ymean;
    wire       ymean_valid, ymean_done;
    luma_mean u_mean (
        .clk(clk), .rst_n(rst_n),
        .in_de(g_de), .in_gray(g_gray), .in_x(g_x), .in_y(g_y), .in_sof(g_sof), .in_eof(g_eof),
        .mean(ymean), .mean_valid(ymean_valid), .done(ymean_done)
    );

    wire [7:0] thr_rmin, thr_delta;
    thr_adapt u_thr (
        .mean(ymean), .mean_valid(ymean_valid), .adaptive(adapt_en),
        .fixed_rmin(R_MIN[7:0]), .fixed_delta(DELTA[7:0]),
        .thr_rmin(thr_rmin), .thr_delta(thr_delta)
    );

    // ---------------- three colours: the dominant-colour detector sees the wanted channel in its "R" slot
    wire [23:0] rgb_c0 = a_rgb;                                        // red
    wire [23:0] rgb_c1 = {a_rgb[15:8], a_rgb[23:16], a_rgb[7:0]};      // green
    wire [23:0] rgb_c2 = {a_blue_rgb[7:0], a_blue_rgb[15:8], a_blue_rgb[23:16]}; // blue before display enhancement

    wire [2:0]  s_de, s_hit, s_sof, s_eol, s_eof;
    wire [11:0] s_x0, s_y0, s_x1, s_y1, s_x2, s_y2;

    color_seg_rt u_seg0 (
        .clk(clk), .rst_n(rst_n),
        .in_de(a_de), .in_rgb(rgb_c0), .in_x(a_x), .in_y(a_y), .in_sof(a_sof), .in_eol(a_eol), .in_eof(a_eof),
        .thr_rmin(thr_rmin), .thr_delta(thr_delta), .adaptive(adapt_en),
        .out_de(s_de[0]), .out_hit(s_hit[0]), .out_x(s_x0), .out_y(s_y0), .out_sof(s_sof[0]), .out_eol(s_eol[0]), .out_eof(s_eof[0])
    );
    color_seg_rt u_seg1 (
        .clk(clk), .rst_n(rst_n),
        .in_de(a_de), .in_rgb(rgb_c1), .in_x(a_x), .in_y(a_y), .in_sof(a_sof), .in_eol(a_eol), .in_eof(a_eof),
        .thr_rmin(thr_rmin), .thr_delta(thr_delta), .adaptive(adapt_en),
        .out_de(s_de[1]), .out_hit(s_hit[1]), .out_x(s_x1), .out_y(s_y1), .out_sof(s_sof[1]), .out_eol(s_eol[1]), .out_eof(s_eof[1])
    );
    color_seg_rt u_seg2 (
        .clk(clk), .rst_n(rst_n),
        .in_de(a_de), .in_rgb(rgb_c2), .in_x(a_x), .in_y(a_y), .in_sof(a_sof), .in_eol(a_eol), .in_eof(a_eof),
        .thr_rmin(thr_rmin), .thr_delta(thr_delta), .adaptive(adapt_en),
        .out_de(s_de[2]), .out_hit(s_hit[2]), .out_x(s_x2), .out_y(s_y2), .out_sof(s_sof[2]), .out_eol(s_eol[2]), .out_eof(s_eof[2])
    );

    // ---------------- horizontal noise filter on every hit stream (output latency 5)
    wire [2:0]  f_de, f_hit, f_sof, f_eol, f_eof;
    wire [11:0] f_x0, f_y0, f_x1, f_y1, f_x2, f_y2;
    hit_open #(.RUN(OPEN_RUN)) u_open0 (
        .clk(clk), .rst_n(rst_n),
        .in_de(s_de[0]), .in_hit(s_hit[0]), .in_x(s_x0), .in_y(s_y0), .in_sof(s_sof[0]), .in_eol(s_eol[0]), .in_eof(s_eof[0]),
        .out_de(f_de[0]), .out_hit(f_hit[0]), .out_x(f_x0), .out_y(f_y0), .out_sof(f_sof[0]), .out_eol(f_eol[0]), .out_eof(f_eof[0])
    );
    hit_open #(.RUN(OPEN_RUN)) u_open1 (
        .clk(clk), .rst_n(rst_n),
        .in_de(s_de[1]), .in_hit(s_hit[1]), .in_x(s_x1), .in_y(s_y1), .in_sof(s_sof[1]), .in_eol(s_eol[1]), .in_eof(s_eof[1]),
        .out_de(f_de[1]), .out_hit(f_hit[1]), .out_x(f_x1), .out_y(f_y1), .out_sof(f_sof[1]), .out_eol(f_eol[1]), .out_eof(f_eof[1])
    );
    hit_open #(.RUN(OPEN_RUN)) u_open2 (
        .clk(clk), .rst_n(rst_n),
        .in_de(s_de[2]), .in_hit(s_hit[2]), .in_x(s_x2), .in_y(s_y2), .in_sof(s_sof[2]), .in_eol(s_eol[2]), .in_eof(s_eof[2]),
        .out_de(f_de[2]), .out_hit(f_hit[2]), .out_x(f_x2), .out_y(f_y2), .out_sof(f_sof[2]), .out_eol(f_eol[2]), .out_eof(f_eof[2])
    );

    // ---------------- border mask: the first lines of the frame-buffer read-out carry a coloured edge artefact (demosaic border); on the board it
    // was a permanent ~1900-pixel red "target" at X 640 / Y 0 (rows 0..1, whole width) that also pulled the ymin of every real target to 0.
    // Hits closer than BORDER pixels to an edge are dropped before the statistics and the mask view (BORDER = 0: nothing dropped).
    function in_core;
        input [11:0] xx, yy;
        begin
            in_core = (xx >= BORDER) && (xx < WIDTH - BORDER) && (yy >= BORDER) && (yy < HEIGHT - BORDER);
        end
    endfunction
    wire [2:0]  m_hit = f_hit & {in_core(f_x2, f_y2), in_core(f_x1, f_y1), in_core(f_x0, f_y0)};

    // ---------------- per-colour statistics, shape, crossing counters
    wire [2:0]  fd, fa, rv, rsat;
    wire [15:0] fid0, fid1, fid2;
    wire [19:0] cnt0, cnt1, cnt2;
    wire [11:0] xmin0, xmax0, ymin0, ymax0, cx0, cy0;
    wire [11:0] xmin1, xmax1, ymin1, ymax1, cx1, cy1;
    wire [11:0] xmin2, xmax2, ymin2, ymax2, cx2, cy2;

    frame_bbox #(.CNT_W(20), .MIN_PIXELS(MIN_PIXELS)) u_bb0 (
        .clk(clk), .rst_n(rst_n1),
        .in_de(f_de[0]), .in_hit(m_hit[0]), .in_x(f_x0), .in_y(f_y0), .in_sof(f_sof[0]), .in_eol(f_eol[0]), .in_eof(f_eof[0]),
        .frame_done(fd[0]), .frame_abort(fa[0]), .res_frame_id(fid0), .res_valid(rv[0]), .res_count(cnt0), .res_sat(rsat[0]),
        .res_xmin(xmin0), .res_xmax(xmax0), .res_ymin(ymin0), .res_ymax(ymax0), .res_cx(cx0), .res_cy(cy0)
    );
    frame_bbox #(.CNT_W(20), .MIN_PIXELS(MIN_PIXELS)) u_bb1 (
        .clk(clk), .rst_n(rst_n1),
        .in_de(f_de[1]), .in_hit(m_hit[1]), .in_x(f_x1), .in_y(f_y1), .in_sof(f_sof[1]), .in_eol(f_eol[1]), .in_eof(f_eof[1]),
        .frame_done(fd[1]), .frame_abort(fa[1]), .res_frame_id(fid1), .res_valid(rv[1]), .res_count(cnt1), .res_sat(rsat[1]),
        .res_xmin(xmin1), .res_xmax(xmax1), .res_ymin(ymin1), .res_ymax(ymax1), .res_cx(cx1), .res_cy(cy1)
    );
    frame_bbox #(.CNT_W(20), .MIN_PIXELS(MIN_PIXELS)) u_bb2 (
        .clk(clk), .rst_n(rst_n1),
        .in_de(f_de[2]), .in_hit(m_hit[2]), .in_x(f_x2), .in_y(f_y2), .in_sof(f_sof[2]), .in_eol(f_eol[2]), .in_eof(f_eof[2]),
        .frame_done(fd[2]), .frame_abort(fa[2]), .res_frame_id(fid2), .res_valid(rv[2]), .res_count(cnt2), .res_sat(rsat[2]),
        .res_xmin(xmin2), .res_xmax(xmax2), .res_ymin(ymin2), .res_ymax(ymax2), .res_cx(cx2), .res_cy(cy2)
    );

    wire [2:0] sh0, sh1, sh2;
    shape_classify u_sh0 (.clk(clk), .rst_n(rst_n1), .valid(rv[0]), .count(cnt0), .xmin(xmin0), .xmax(xmax0), .ymin(ymin0), .ymax(ymax0), .shape(sh0));
    shape_classify u_sh1 (.clk(clk), .rst_n(rst_n1), .valid(rv[1]), .count(cnt1), .xmin(xmin1), .xmax(xmax1), .ymin(ymin1), .ymax(ymax1), .shape(sh1));
    shape_classify u_sh2 (.clk(clk), .rst_n(rst_n1), .valid(rv[2]), .count(cnt2), .xmin(xmin2), .xmax(xmax2), .ymin(ymin2), .ymax(ymax2), .shape(sh2));

    // crossing counters: the clear chord resets them (a registered pulse into the asynchronous reset)
    reg clr_r;
    always @(posedge clk or negedge rst_n1) begin
        if (!rst_n1) clr_r <= 1'b0;
        else         clr_r <= clear_pulse;
    end
    wire cc_rst_n = rst_n1 & ~clr_r;

    wire [2:0]  cc_evt;
    wire [15:0] cc_k0, cc_k1, cc_k2;
    cross_counter #(.HYST(12), .CONFIRM(2), .LOST_MAX(5), .CNT_W(16)) u_cc0 (
        .clk(clk), .rst_n(cc_rst_n), .upd(fd[0]), .valid(rv[0]), .cx(cx0), .line_x(line_x),
        .evt(cc_evt[0]), .evt_dir(), .cnt_lr(), .cnt_rl(), .cnt_total(cc_k0), .side()
    );
    cross_counter #(.HYST(12), .CONFIRM(2), .LOST_MAX(5), .CNT_W(16)) u_cc1 (
        .clk(clk), .rst_n(cc_rst_n), .upd(fd[1]), .valid(rv[1]), .cx(cx1), .line_x(line_x),
        .evt(cc_evt[1]), .evt_dir(), .cnt_lr(), .cnt_rl(), .cnt_total(cc_k1), .side()
    );
    cross_counter #(.HYST(12), .CONFIRM(2), .LOST_MAX(5), .CNT_W(16)) u_cc2 (
        .clk(clk), .rst_n(cc_rst_n), .upd(fd[2]), .valid(rv[2]), .cx(cx2), .line_x(line_x),
        .evt(cc_evt[2]), .evt_dir(), .cnt_lr(), .cnt_rl(), .cnt_total(cc_k2), .side()
    );

    // ---------------- target trackers: what is DRAWN (the crossing counters above use the raw sample)
    wire [1:0]  tk_state0, tk_state1, tk_state2;
    wire [11:0] tk_xmin0, tk_xmax0, tk_ymin0, tk_ymax0, tk_cx0, tk_cy0;
    wire [11:0] tk_xmin1, tk_xmax1, tk_ymin1, tk_ymax1;
    wire [11:0] tk_xmin2, tk_xmax2, tk_ymin2, tk_ymax2;
    wire [7:0]  tk_age0, tk_age1, tk_age2;
    wire [15:0] tk_acq0, tk_hold0, tk_reacq0, tk_lost0, tk_jit0;
    wire [15:0] tk_acq1, tk_hold1, tk_reacq1, tk_lost1, tk_jit1;
    wire [15:0] tk_acq2, tk_hold2, tk_reacq2, tk_lost2, tk_jit2;
    target_track #(.COAST_MAX(TRK_COAST), .JIT(TRK_JIT), .SNAP(TRK_SNAP)) u_tk0 (
        .clk(clk), .rst_n(rst_n1), .clr_stats(clr_r), .upd(fd[0]), .valid(rv[0]), .xmin(xmin0), .xmax(xmax0), .ymin(ymin0), .ymax(ymax0),
        .state(tk_state0), .t_xmin(tk_xmin0), .t_xmax(tk_xmax0), .t_ymin(tk_ymin0), .t_ymax(tk_ymax0), .t_cx(tk_cx0), .t_cy(tk_cy0),
        .age(tk_age0), .n_acq(tk_acq0), .n_hold(tk_hold0), .n_reacq(tk_reacq0), .n_lost(tk_lost0), .n_jit(tk_jit0)
    );
    target_track #(.COAST_MAX(TRK_COAST), .JIT(TRK_JIT), .SNAP(TRK_SNAP)) u_tk1 (
        .clk(clk), .rst_n(rst_n1), .clr_stats(clr_r), .upd(fd[1]), .valid(rv[1]), .xmin(xmin1), .xmax(xmax1), .ymin(ymin1), .ymax(ymax1),
        .state(tk_state1), .t_xmin(tk_xmin1), .t_xmax(tk_xmax1), .t_ymin(tk_ymin1), .t_ymax(tk_ymax1), .t_cx(), .t_cy(),
        .age(tk_age1), .n_acq(tk_acq1), .n_hold(tk_hold1), .n_reacq(tk_reacq1), .n_lost(tk_lost1), .n_jit(tk_jit1)
    );
    target_track #(.COAST_MAX(TRK_COAST), .JIT(TRK_JIT), .SNAP(TRK_SNAP)) u_tk2 (
        .clk(clk), .rst_n(rst_n1), .clr_stats(clr_r), .upd(fd[2]), .valid(rv[2]), .xmin(xmin2), .xmax(xmax2), .ymin(ymin2), .ymax(ymax2),
        .state(tk_state2), .t_xmin(tk_xmin2), .t_xmax(tk_xmax2), .t_ymin(tk_ymin2), .t_ymax(tk_ymax2), .t_cx(), .t_cy(),
        .age(tk_age2), .n_acq(tk_acq2), .n_hold(tk_hold2), .n_reacq(tk_reacq2), .n_lost(tk_lost2), .n_jit(tk_jit2)
    );
    wire [2:0] tk_show = {tk_state2 != 2'd0, tk_state1 != 2'd0, tk_state0 != 2'd0};      // S_TRACK or S_HOLD: a box is drawn
    wire [2:0] tk_hold = {tk_state2 == 2'd2, tk_state1 == 2'd2, tk_state0 == 2'd2};      // S_HOLD: dashed box, "HOLD"
    wire       tk0_track = (tk_state0 == 2'd1);
    // 8-bit saturated statistics of the RED tracker for panel row 5 (cleared with the KEY1+KEY2 chord, like the crossing counters)
    wire [39:0] tk_stat0 = {(|tk_jit0[15:8])   ? 8'hFF : tk_jit0[7:0],   (|tk_lost0[15:8]) ? 8'hFF : tk_lost0[7:0],
                            (|tk_reacq0[15:8]) ? 8'hFF : tk_reacq0[7:0], (|tk_hold0[15:8]) ? 8'hFF : tk_hold0[7:0],
                            (|tk_acq0[15:8])   ? 8'hFF : tk_acq0[7:0]};

    // ---------------- display path: views, v1 OSD (logo, text, line), v2 OSD (boxes, panel)
    wire [23:0] orig2;
    sync_delay #(.N(2), .W(24)) u_orig_dly (.clk(clk), .rst_n(rst_n), .din(a_rgb), .dout(orig2));

    // edge detection on the gray stream (its outputs carry the delayed rgb / gray / sideband)
    wire [10:0] thr_edge = adapt_en ? (11'd20 + {4'd0, ymean[7:1]}) : EDGE_FIXED_THR;
    wire        e2_de, e2_edge, e2_sof, e2_eol, e2_eof;
    wire [7:0]  e2_gray;
    wire [23:0] e2_rgb;
    wire [11:0] e2_x, e2_y;
    edge_style u_edge (
        .clk(clk), .rst_n(rst_n2),
        .in_de(g_de), .in_gray(g_gray), .in_rgb(orig2), .in_x(g_x), .in_y(g_y), .in_sof(g_sof), .in_eol(g_eol), .in_eof(g_eof),
        .thr(thr_edge),
        .out_de(e2_de), .out_edge(e2_edge), .out_gray(e2_gray), .out_rgb(e2_rgb), .out_x(e2_x), .out_y(e2_y),
        .out_sof(e2_sof), .out_eol(e2_eol), .out_eof(e2_eof)
    );
    // filtered hits are 2 clocks later than the edge stream: delay the edge stream bundle by 2
    wire [60:0] eb_in  = {e2_de, e2_edge, e2_gray, e2_rgb, e2_x, e2_y, e2_sof, e2_eol, e2_eof};
    wire [60:0] eb_out;
    sync_delay #(.N(2), .W(61)) u_edge_dly (.clk(clk), .rst_n(rst_n2), .din(eb_in), .dout(eb_out));
    wire        d_de   = eb_out[60];
    wire        d_edge = eb_out[59];
    wire [7:0]  d_gray = eb_out[58:51];
    wire [23:0] d_rgb  = eb_out[50:27];
    wire [11:0] d_x    = eb_out[26:15];
    wire [11:0] d_y    = eb_out[14:3];
    wire        d_sof  = eb_out[2];
    wire        d_eol  = eb_out[1];
    wire        d_eof  = eb_out[0];

    wire        v_de, v_sof, v_eol, v_eof;
    wire [23:0] v_rgb;
    wire [11:0] v_x, v_y;
    view_mux_style u_view (
        .clk(clk), .rst_n(rst_n2),
        .in_de(d_de), .in_x(d_x), .in_y(d_y), .in_sof(d_sof), .in_eol(d_eol), .in_eof(d_eof),
        .rgb_orig(d_rgb), .gray(d_gray), .edge_px(d_edge), .hit_r(m_hit[0]), .hit_g(m_hit[1]), .hit_b(m_hit[2]),
        .page(style_page), .mode(view_mode),
        .out_de(v_de), .out_rgb(v_rgb), .out_x(v_x), .out_y(v_y), .out_sof(v_sof), .out_eol(v_eol), .out_eof(v_eof)
    );

    wire        o_de, o_sof, o_eol, o_eof;
    wire [23:0] o_rgb;
    wire [11:0] o_x, o_y;
    osd_overlay u_osd (
        .clk(clk), .rst_n(rst_n2),
        .in_de(v_de), .in_rgb(v_rgb), .in_x(v_x), .in_y(v_y), .in_sof(v_sof), .in_eol(v_eol), .in_eof(v_eof),
        // {logo, line, cross, box, text}: the single-target box / crosshair are replaced by the coloured ones in recognition mode
        .cfg_flags({(LOGO_EN != 0), draw_extra, draw_extra & ~recog_en, draw_extra & ~recog_en, 1'b1}),
        .cfg_mode(view_mode), .tgt_valid(tk0_track),
        .tgt_xmin(tk_xmin0), .tgt_xmax(tk_xmax0), .tgt_ymin(tk_ymin0), .tgt_ymax(tk_ymax0),
        .tgt_cx(tk_cx0), .tgt_cy(tk_cy0), .tgt_count(cnt0), .line_x(line_x), .cross_cnt(cc_k0),
        .out_de(o_de), .out_rgb(o_rgb), .out_x(o_x), .out_y(o_y), .out_sof(o_sof), .out_eol(o_eol), .out_eof(o_eof)
    );

    // frame-rate measurement: camera frame start (cam_clk domain) and display vsync (clk domain) against the 50 MHz crystal
    reg cam_q;
    always @(posedge cam_clk or negedge rst_n_async) begin
        if (!rst_n_async) cam_q <= 1'b0;
        else              cam_q <= cam_start;
    end
    wire cam_pulse = cam_start & ~cam_q;
    wire tog_cam;
    pulse_to_toggle u_tc (.clk(cam_clk), .rst_n(rst_n_async), .pulse(cam_pulse), .tog(tog_cam));

    reg vs_q;
    always @(posedge clk or negedge rst_n2) begin
        if (!rst_n2) vs_q <= 1'b0;
        else         vs_q <= vtc_vs;
    end
    wire tog_disp;
    pulse_to_toggle u_td (.clk(clk), .rst_n(rst_n2), .pulse(vtc_vs & ~vs_q), .tog(tog_disp));

    reg [1:0] ref_rs;
    always @(posedge ref_clk or negedge rst_n_async) begin
        if (!rst_n_async) ref_rs <= 2'b00;
        else              ref_rs <= {ref_rs[0], 1'b1};
    end
    wire [7:0] fps_cam_ref, fps_disp_ref;
    fps_meter #(.REF_HZ(REF_HZ)) u_fps (
        .ref_clk(ref_clk), .ref_rst_n(ref_rs[1]), .tog_cam(tog_cam), .tog_disp(tog_disp),
        .fps_cam(fps_cam_ref), .fps_disp(fps_disp_ref)
    );
    wire [7:0] fps_cam, fps_disp;
    byte_cdc #(.W(8)) u_cdc_c (.clk(clk), .rst_n(rst_n4), .din(fps_cam_ref),  .q(fps_cam));
    byte_cdc #(.W(8)) u_cdc_d (.clk(clk), .rst_n(rst_n4), .din(fps_disp_ref), .q(fps_disp));

    wire        e_de, e_sof, e_eol, e_eof;
    wire [23:0] e_rgb;
    wire [11:0] e_x, e_y;
    wire [47:0] bcd_x, bcd_y;
    wire [59:0] bcd_k;
    wire [11:0] bcd_fc, bcd_fd;
    osd_ext u_ext (
        .clk(clk), .rst_n(rst_n3), .rst_n_b(rst_n5),
        .in_de(o_de), .in_rgb(o_rgb), .in_x(o_x), .in_y(o_y), .in_sof(o_sof), .in_eol(o_eol), .in_eof(o_eof),
        .en_panel(recog_en), .en_boxes(recog_en & draw_extra), .en_mode(1'b1), .view_page(style_page), .view_mode(view_mode), .adaptive(adapt_en),
        .ymean(ymean), .rmin(thr_rmin), .fps_cam(fps_cam), .fps_disp(fps_disp),
        .t_valid(tk_show), .t_hold(tk_hold), .t_shape({sh2, sh1, sh0}),
        .t_xmin({tk_xmin2, tk_xmin1, tk_xmin0}), .t_xmax({tk_xmax2, tk_xmax1, tk_xmax0}),
        .t_ymin({tk_ymin2, tk_ymin1, tk_ymin0}), .t_ymax({tk_ymax2, tk_ymax1, tk_ymax0}),
        .t_cx({cx2, cx1, cx0}), .t_cy({cy2, cy1, cy0}), .t_cross({cc_k2, cc_k1, cc_k0}), .t_stat(tk_stat0),
        .out_de(e_de), .out_rgb(e_rgb), .out_x(e_x), .out_y(e_y), .out_sof(e_sof), .out_eol(e_eol), .out_eof(e_eof),
        .o_bcd_x(bcd_x), .o_bcd_y(bcd_y), .o_bcd_k(bcd_k), .o_bcd_fc(bcd_fc), .o_bcd_fd(bcd_fd)
    );

    // ---------------- timing for the processed picture: vsync / de delayed by the RGB path latency
    wire [1:0] vd;
    sync_delay #(.N(SKEW + 15), .W(2)) u_tim_dly (.clk(clk), .rst_n(rst_n2), .din({vtc_vs, vtc_de}), .dout(vd));

    wire [1:0] bd;
    sync_delay #(.N(BYPASS_ALIGN), .W(2)) u_byp_dly (.clk(clk), .rst_n(rst_n2), .din({base_vs, base_de}), .dout(bd));

    // bypass switch: committed while BOTH streams are inside their vsync pulse with no pixel (a level, high for ~8000 clocks per frame)
    wire proc_en, proc_pending;
    wire [7:0] proc_gen;
    wire proc_changed;
    frame_commit #(.W(1), .INIT(1'b0)) u_commit_sw (
        .clk(clk), .rst_n(rst_n2), .commit(vd[1] & bd[1] & ~vd[0] & ~bd[0]),
        .req(proc_req), .eff(proc_en), .pending(proc_pending), .changed(proc_changed), .gen(proc_gen)
    );
    assign req_pending = cm_pending | proc_pending;
    assign mode_gen    = cm_gen + proc_gen;

    assign tx_vs   = proc_en ? vd[1] : bd[1];
    assign tx_de   = proc_en ? vd[0] : bd[0];
    assign tx_data = proc_en ? e_rgb : base_data;

    // ---------------- external indicators
    reg err_sticky;
    always @(posedge clk or negedge rst_n2) begin
        if (!rst_n2)        err_sticky <= 1'b0;
        else if (!proc_en)  err_sticky <= 1'b0;
        else if (a_err)     err_sticky <= 1'b1;
    end
    assign led = {proc_en, fid0[4], err_sticky, |rv};

    beep_ctrl #(.BEEP_CLKS(BEEP_CLKS), .HALF(BEEP_HALF)) u_beep (.clk(clk), .rst_n(rst_n4), .evt(|cc_evt), .buzzer_n(buzzer_n));

    uart_report #(.CLKDIV(UART_CLKDIV), .PERIOD(UART_PERIOD)) u_uart (
        .clk(clk), .rst_n(rst_n4),
        .t_valid(rv), .t_shape({sh2, sh1, sh0}), .t_count({cnt2, cnt1, cnt0}),
        .bcd_x(bcd_x), .bcd_y(bcd_y), .bcd_k(bcd_k), .bcd_fc(bcd_fc), .bcd_fd(bcd_fd),
        .tx(uart_tx)
    );

    // seven-segment: total crossings (4 digits, saturating at 9999), then 'F' and the camera frame rate
    wire [17:0] cc_total = {2'b00, cc_k0} + {2'b00, cc_k1} + {2'b00, cc_k2};
    wire [15:0] bcd_total;
    osd_bin2bcd #(.BITS(18), .DIGITS(4)) u_btot (.clk(clk), .rst_n(rst_n4), .bin(cc_total), .bcd(bcd_total));
    wire [31:0] seg_digits = {bcd_fc[3:0], bcd_fc[7:4], bcd_fc[11:8], 4'd10,
                              bcd_total[3:0], bcd_total[7:4], bcd_total[11:8], bcd_total[15:12]};
    seg7_scan #(.TICK(SEG_TICK)) u_seg7 (.clk(clk), .rst_n(rst_n4), .digits(seg_digits), .seg(seg), .sel(sel));

endmodule
