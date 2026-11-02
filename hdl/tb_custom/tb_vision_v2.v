// tb_vision_v2.v - integration test of rtl_custom/contest_vision_v2.v at the real 1280x720 timing
//
// Environment (what the v2 top level provides): the UNMODIFIED lab1 uivtc.v (1650x750) -> vtc_*; rd_rgb = scene colour of
// the pixel whose de was ACT_SKEW = 2 clocks earlier (the suspected frame-buffer lag); base_* = stand-in of the hdmi_mixer
// output (vs / de delayed 3, constant data that lags de by 2 clocks, as in the real baseline) for the bypass; push buttons driven like a user; three clocks (pixel 100 MHz-style
// 10 ns, 50 MHz-style 20 ns reference, 16 ns "camera") so the frame-rate meter has real clock-domain crossings.
// The DUT keeps its default geometry / OSD layout; only the human-time constants (debounce, UART baud, report period,
// frame-rate window, scan tick, beep length) are shortened.
//
// Scene (a coloured-paper stand-in): grey background (60,60,60); a RED rectangle 60x60 that moves left (x 520..579)
// <-> right (x 720..779) of the counting line x = 640; a GREEN disc (centre 640,450, radius 30; bounding box 610..670 x
// 420..480, centre ON the line: a negative test for the crossing counter); a BLUE triangle (bounding box 900..959 x
// 400..459, always right of the line). All are away from the logo / text block / panel of the OSD.
// 'br' scales the colours (100 % normal light, 30 % dim light).
//
// Frame plan (a parameter set is applied at the vsync of the previous frame; results of frame k are compared at the vsync
// after it, when frame_bbox / shape_classify / cross_counter have settled):
//   f0,f1  red LEFT          normal light, fixed thresholds, SW1 on        -> all three targets found, shapes RECT / CIRC / TRI
//   f2,f3  red RIGHT                                                         -> crossing counted at the end of f3 (red = 1)
//   f4,f5  red LEFT                                                          -> second crossing at the end of f5 (red = 2), buzzer, 7-segment
//   f6     KEY1 pressed in the middle of the frame                           -> recognition mode on
//   f7     SW4 on: boxes / crosses / counting line must be drawn at the exact pixels, the panel text must appear
//   f8     DIM light, fixed thresholds                                       -> nothing found (the fixed red floor 80 is above the dim colours)
//   f9     KEY2 pressed in the middle of the frame                           -> adaptive thresholds on
//   f10    DIM light, adaptive                                               -> all three found again (previous-frame brightness lowers the floor)
//   f11    normal light, adaptive                                            -> still found
//   f12    KEY1+KEY2 chord                                                   -> counters cleared, modes unchanged
//   f13    KEY4 once, then KEY3 held                                         -> counting line moves (single step, then auto-repeat)
//   f14    KEY2 held (long press)                                            -> view page 1 (style views), thresholds unchanged
//   f15    page 1, view 00 SKETCH      f16  CARTOON      f17  EDGE+      f18  THERMAL   (colours checked at fixed pixels, edges by census)
//   f19    SW1 off (bypass)                                                  -> tx_data = base_data, tx_vs / tx_de = base_vs / base_de delayed by BYPASS_ALIGN = 2
//   f20..f23  frame-boundary commit of settings (the requests are made in the MIDDLE of a frame, row 150..500):
//              f20 SW1 back on (bypass -> processed at the boundary), view SKETCH, request THERMAL at row 360 -> f20 stays SKETCH top AND bottom
//              f21 THERMAL top and bottom, a SW2 request at row 150 that is withdrawn at row 500 must not change anything (f22 still THERMAL)
//              f22 SW1-off request at row 360: the frame stays processed to its last row, f23 is bypassed from its first pixel to its last;
//              f23 SW1-on request at row 360: f23 stays bypassed, f24 processed
//   f24..f25  KEY1 (recognition) pressed in the middle of the frame: the boxes are drawn in the whole of f24, in none of f25; f25 presses again
//   f20..f23  tracker: red moves by 1 px (jitter, box held), by 6 px (smoothed), by 3 px, then by 200 px (box jumps to the measurement)
//   f26..f33  short occlusion (TRK_COAST = 2): visible 26, hidden 27 (HOLD), visible 28 (re-acquired), hidden 29 30 31 (HOLD, HOLD, LOST),
//              visible 32 (acquired), 33: solid box / dashed held box / no box exactly as the tracker state of the PREVIOUS frame says,
//              the red crossing counter does not change during the whole sequence
// Everything is also checked on every clock: tx_de / tx_vs equal the uivtc output delayed SKEW+15 = 17 clocks (while the bypass switch is
// off (committed at the frame boundary, see proc_exp) the bypass check below applies instead).
//
// Build/run, from F:\fpga_s2\tb_custom (ModelSim: run_modelsim.do; Icarus Verilog is correct but needs well over an hour):
//   iverilog -g2005 -o sim_v2.vvp tb_vision_v2.v <all rtl_custom files of contest_vision_v2> ../lab1/user_source/hdl_source/vtc/uivtc.v
// Final line: "TB_RESULT: PASS tb_vision_v2" or "TB_RESULT: FAIL tb_vision_v2 errors=N".

`timescale 1ns / 1ps

module tb_vision_v2;

    localparam integer ACT_SKEW = 2;
    localparam integer N        = 17;           // contract: SKEW + 15
    localparam integer NFR      = 34;

    // ---------------- clocks
    reg clk, ref_clk, cam_clk;
    initial begin clk = 1'b0; ref_clk = 1'b0; cam_clk = 1'b0; end
    always #5  clk     = ~clk;
    always #10 ref_clk = ~ref_clk;
    always #8  cam_clk = ~cam_clk;

    reg  rst_n;
    reg  check_en;

    // ---------------- baseline timing generator (unmodified source)
    wire vvs, vhs, vde, vuser, vlast;
    uivtc #(.H_ActiveSize(1280), .H_FrameSize(1650), .H_SyncStart(1390), .H_SyncEnd(1430),
            .V_ActiveSize(720),  .V_FrameSize(750),  .V_SyncStart(725),  .V_SyncEnd(730)) u_vtc (
        .I_vtc_rstn(rst_n), .I_vtc_clk(clk),
        .O_vtc_vs(vvs), .O_vtc_hs(vhs), .O_vtc_de_valid(vde), .O_vtc_user(vuser), .O_vtc_last(vlast)
    );

    reg [11:0] hq1, hq2, vq1, vq2;
    always @(posedge clk) begin
        hq1 <= u_vtc.hcnt; hq2 <= hq1;
        vq1 <= u_vtc.vcnt; vq2 <= vq1;
    end

    reg        vde_h  [1:24];
    reg        vvs_h  [1:24];
    reg        vuser_h[1:24];
    reg [11:0] px_h   [1:24];
    reg [11:0] py_h   [1:24];
    integer k;
    always @(posedge clk) begin
        vde_h[1] <= vde;  vvs_h[1] <= vvs;  vuser_h[1] <= vuser;  px_h[1] <= hq2;  py_h[1] <= vq2;
        for (k = 2; k <= 24; k = k + 1) begin
            vde_h[k] <= vde_h[k-1];  vvs_h[k] <= vvs_h[k-1];  vuser_h[k] <= vuser_h[k-1];
            px_h[k] <= px_h[k-1];    py_h[k] <= py_h[k-1];
        end
    end

    // ---------------- scene
    integer rx;          // left edge of the red rectangle
    integer rvis;        // 0 = the red rectangle is absent from the scene
    initial rvis = 1;
    integer br;          // brightness in percent

    function integer memb;           // 0 background, 1 red, 2 green, 3 blue
        input integer x;
        input integer y;
        input integer rxx;
        integer dy, half;
        begin
            memb = 0;
            if (rvis != 0 && x >= rxx && x < rxx + 60 && y >= 300 && y < 360) memb = 1;
            else if ((x - 640) * (x - 640) + (y - 450) * (y - 450) <= 900) memb = 2;
            else if (y >= 400 && y < 460) begin
                dy = y - 400;
                half = dy / 2;
                if (x >= 929 - half && x <= 930 + half) memb = 3;
            end
        end
    endfunction

    function [23:0] scene;
        input integer x;
        input integer y;
        input integer rxx;
        input integer bri;
        integer m, r, g, b;
        begin
            m = memb(x, y, rxx);
            case (m)
                1:       begin r = 200; g = 40;  b = 40;  end
                2:       begin r = 40;  g = 200; b = 40;  end
                3:       begin r = 40;  g = 40;  b = 200; end
                default: begin r = 60;  g = 60;  b = 60;  end
            endcase
            r = r * bri / 100; g = g * bri / 100; b = b * bri / 100;
            scene = {r[7:0], g[7:0], b[7:0]};
        end
    endfunction

    reg [23:0] gcnt;
    initial gcnt = 24'd0;
    always @(posedge clk) gcnt <= gcnt + 24'h010101;
    wire [23:0] rd_rgb = vde_h[ACT_SKEW] ? scene(px_h[ACT_SKEW], py_h[ACT_SKEW], rx, br) : (24'hC0FFEE ^ gcnt);

    wire        base_vs   = vvs_h[3];
    wire        base_de   = vde_h[3];
    wire [23:0] base_data = vde_h[5] ? 24'hABCDEF : 24'd0;     // like the real baseline: the data lags its de by 2 clocks

    // ---------------- camera frame start pulses (own clock domain, own period: 13 ms)
    reg cam_start;
    initial cam_start = 1'b0;
    always begin
        #13000000;
        @(posedge cam_clk); cam_start = 1'b1;
        @(posedge cam_clk); cam_start = 1'b0;
    end

    // ---------------- DUT
    reg  [3:0]  sw;
    reg  [3:0]  key_n;
    wire        tx_vs, tx_de, buzzer_n, uart_tx;
    wire [23:0] tx_data;
    wire [3:0]  led;
    wire [7:0]  seg, sel;
    wire        req_pending;
    wire [7:0]  mode_gen;

    contest_vision_v2 #(
        .KEY_DEB(20), .KEY_HOLD0(300), .KEY_REP(60), .KEY_LONG(1000),
        .REF_HZ(2000000),
        .UART_CLKDIV(4), .UART_PERIOD(16000),
        .SEG_TICK(20), .BEEP_CLKS(40000), .BEEP_HALF(50), .TRK_COAST(2)
    ) dut (
        .clk(clk), .rst_n_async(rst_n),
        .vtc_vs(vvs), .vtc_de(vde), .vtc_user(vuser), .vtc_last(vlast), .rd_rgb(rd_rgb), .blue_rd_rgb(rd_rgb),
        .base_vs(base_vs), .base_de(base_de), .base_data(base_data),
        .sw(sw), .key_n(key_n),
        .ref_clk(ref_clk), .cam_clk(cam_clk), .cam_start(cam_start),
        .tx_vs(tx_vs), .tx_de(tx_de), .tx_data(tx_data), .led(led),
        .buzzer_n(buzzer_n), .uart_tx(uart_tx), .seg(seg), .sel(sel),
        .req_pending(req_pending), .mode_gen(mode_gen)
    );

    // ---------------- frame sequencing
    integer fr;
    reg     seen_user;
    reg     vvs_q;
    integer errors, chk, line_chk;
    initial begin fr = 0; seen_user = 1'b0; vvs_q = 1'b0; end

    task bad;
        input [8*64-1:0] what;
        input integer e;
        input integer a;
        begin
            errors = errors + 1;
            if (errors <= 25)
                $display("MISMATCH t=%0t frame=%0d %0s expected=%0d(0x%0h) actual=%0d(0x%0h)", $time, fr, what, e, e, a, a);
            if (errors >= 200) begin
                $display("TB_RESULT: FAIL tb_vision_v2 aborted after %0d mismatches", errors);
                $finish;
            end
        end
    endtask

    // the DUT removes horizontal runs shorter than 5 pixels (hit_open): membership as seen by the statistics
    function integer rowrun;
        input integer x;
        input integer y;
        input integer rxx;
        integer m, xx, n;
        begin
            m = memb(x, y, rxx);
            n = 1;
            if (m == 0) n = 0;
            else begin
                xx = x - 1;
                while (xx > x - 70 && memb(xx, y, rxx) == m) begin n = n + 1; xx = xx - 1; end
                xx = x + 1;
                while (xx < x + 70 && memb(xx, y, rxx) == m) begin n = n + 1; xx = xx + 1; end
            end
            rowrun = n;
        end
    endfunction

    // expected statistics of target t (1 red, 2 green, 3 blue) for the red position rxx, by brute force over its window
    integer e_xmin, e_xmax, e_ymin, e_ymax, e_cnt;
    task calc;
        input integer t;
        input integer rxx;
        integer x, y, x0, x1, y0, y1;
        begin
            case (t)
                1:       begin x0 = 480; x1 = 820; y0 = 280; y1 = 380; end
                2:       begin x0 = 600; x1 = 680; y0 = 410; y1 = 490; end
                default: begin x0 = 890; x1 = 970; y0 = 390; y1 = 470; end
            endcase
            e_xmin = 4095; e_xmax = 0; e_ymin = 4095; e_ymax = 0; e_cnt = 0;
            for (y = y0; y <= y1; y = y + 1)
                for (x = x0; x <= x1; x = x + 1)
                    if (memb(x, y, rxx) == t && rowrun(x, y, rxx) >= 5) begin
                        e_cnt = e_cnt + 1;
                        if (x < e_xmin) e_xmin = x;
                        if (x > e_xmax) e_xmax = x;
                        if (y < e_ymin) e_ymin = y;
                        if (y > e_ymax) e_ymax = y;
                    end
        end
    endtask

    // compare the DUT statistics of one target with the expectation (valid = 1) or with "not found" (valid = 0)
    task check_target;
        input integer t;
        input integer rxx;
        input integer valid;
        integer sv, sc, sx0, sx1, sy0, sy1, scx, scy, sshape;
        begin
            case (t)
                1: begin sv = dut.rv[0]; sc = dut.cnt0; sx0 = dut.xmin0; sx1 = dut.xmax0; sy0 = dut.ymin0; sy1 = dut.ymax0; scx = dut.cx0; scy = dut.cy0; sshape = dut.sh0; end
                2: begin sv = dut.rv[1]; sc = dut.cnt1; sx0 = dut.xmin1; sx1 = dut.xmax1; sy0 = dut.ymin1; sy1 = dut.ymax1; scx = dut.cx1; scy = dut.cy1; sshape = dut.sh1; end
                default: begin sv = dut.rv[2]; sc = dut.cnt2; sx0 = dut.xmin2; sx1 = dut.xmax2; sy0 = dut.ymin2; sy1 = dut.ymax2; scx = dut.cx2; scy = dut.cy2; sshape = dut.sh2; end
            endcase
            if (sv !== valid) bad("target valid", valid, sv);
            if (valid) begin
                calc(t, rxx);
                if (sc !== e_cnt)  bad("target count", e_cnt, sc);
                if (sx0 !== e_xmin) bad("target xmin", e_xmin, sx0);
                if (sx1 !== e_xmax) bad("target xmax", e_xmax, sx1);
                if (sy0 !== e_ymin) bad("target ymin", e_ymin, sy0);
                if (sy1 !== e_ymax) bad("target ymax", e_ymax, sy1);
                if (scx !== ((e_xmin + e_xmax) >> 1)) bad("target cx", (e_xmin + e_xmax) >> 1, scx);
                if (scy !== ((e_ymin + e_ymax) >> 1)) bad("target cy", (e_ymin + e_ymax) >> 1, scy);
                if (sshape !== t) bad("target shape (1 RECT 2 CIRC 3 TRI)", t, sshape);
            end
            else if (sshape !== 0) bad("shape of a missing target", 0, sshape);
        end
    endtask

    // ---------------- seven-segment observation: PNP drivers select a digit when its FPGA pin is LOW
    reg [3:0] dseen [0:7];
    integer   di;
    integer   dcode;
    initial for (di = 0; di < 8; di = di + 1) dseen[di] = 4'hF;
    always @(posedge clk) begin
        for (di = 0; di < 8; di = di + 1)
            if (!sel[di]) begin
                case (~seg)
                    8'h3F: dcode = 0;  8'h06: dcode = 1;  8'h5B: dcode = 2;  8'h4F: dcode = 3;  8'h66: dcode = 4;
                    8'h6D: dcode = 5;  8'h7D: dcode = 6;  8'h07: dcode = 7;  8'h7F: dcode = 8;  8'h6F: dcode = 9;
                    8'h71: dcode = 10; 8'h40: dcode = 11; default: dcode = 15;
                endcase
                dseen[di] <= dcode[3:0];
            end
    end

    // ---------------- UART receiver (8N1, CLKDIV = 4 clocks per bit); the last complete line of every frame is kept
    reg [8*128-1:0] rxline;
    integer         rxn;
    reg [8*128-1:0] frame_line [0:NFR];
    integer         frame_line_len [0:NFR];
    integer         ulines;
    reg [7:0]       rxb;
    integer         bi;
    initial begin rxn = 0; ulines = 0; rxline = 0; for (bi = 0; bi <= NFR; bi = bi + 1) frame_line_len[bi] = 0; end
    always begin
        @(negedge uart_tx);
        repeat (6) @(posedge clk);                    // middle of the start bit (4 clocks per bit): 1.5 bits = 6 clocks after the edge
        for (bi = 0; bi < 8; bi = bi + 1) begin
            rxb[bi] = uart_tx;
            repeat (4) @(posedge clk);
        end
        if (rxb == 8'h0A) begin
            frame_line[fr]     = rxline;
            frame_line_len[fr] = rxn;
            ulines = ulines + 1;
            rxn = 0; rxline = 0;
        end
        else if (rxb != 8'h0D) begin
            rxline = {rxline[8*127-1:0], rxb};
            rxn = rxn + 1;
        end
    end

    // ---------------- panel colour census: glyph pixels of every row colour inside the panel rectangle, per frame
    integer cnt_hdr, cnt_r, cnt_g, cnt_b, cnt_fps, cnt_mw, cnt_mb, cnt_dark, cnt_gedge, cnt_trk;
    reg [39:0] stat_snap;

    // ---------------- models of the committed settings: the contract says that the bypass switch is taken while both streams are inside
    // their vsync pulse (the baseline stream delayed by 5 and the processed stream delayed by N), the view / recognition requests at the falling
    // edge of the baseline vsync. Until the first commit after reset they just follow the controls.
    reg        proc_exp, seeded_exp;
    reg [1:0]  vm_exp;
    reg        rg_exp, vq_exp;
    initial begin proc_exp = 1'b0; seeded_exp = 1'b0; vm_exp = 2'd0; rg_exp = 1'b0; vq_exp = 1'b0; end
    always @(posedge clk) begin
        vq_exp <= vvs;
        if (!seeded_exp) begin proc_exp <= sw[0]; vm_exp <= sw[2:1]; rg_exp <= dut.req_recog; end
        if (vvs_h[N] === 1'b1 && vvs_h[5] === 1'b1 && vde_h[N] === 1'b0 && vde_h[5] === 1'b0) begin
            proc_exp <= sw[0];
            seeded_exp <= 1'b1;
        end
        if (vq_exp && !vvs) begin vm_exp <= sw[2:1]; rg_exp <= dut.req_recog; end
    end

    // colour of the plain background far from every object in the four views of page 1 (gray 60)
    function [31:0] exp_view_col;
        input [1:0] vm;
        begin
            case (vm)
                2'd0:    exp_view_col = 32'h007E7E7E;      // SKETCH: shaded paper
                2'd1:    exp_view_col = 32'h00303030;      // CARTOON
                2'd2:    exp_view_col = 32'h001E1E1E;      // EDGE+
                default: exp_view_col = 32'h0000F0FF;      // THERMAL
            endcase
        end
    endfunction

    // tracker state the TB expects to be DRAWN in frame f (= the state after frame f-1): 1 TRACK, 2 HOLD, 0 LOST
    function integer drawn_state;
        input integer f;
        begin
            case (f)
                28, 30, 31: drawn_state = 2;
                32:         drawn_state = 0;
                default:    drawn_state = 1;
            endcase
        end
    endfunction

    // ---------------- per-clock output checks
    reg [23:0] exp_c;
    reg        data_en;
    integer    box_chk, box_bad, line_seen, line_expect;
    integer    xo, yo;
    integer    buzz_low_seen;
    initial begin box_chk = 0; box_bad = 0; buzz_low_seen = 0; data_en = 1'b0; end

    // expected colour of an output pixel in frame 7 (recognition on, SW4 on, original view), or 0xFFFFFFFF = "not checked"
    function [31:0] exp_pixel_f7;
        input integer x;
        input integer y;
        begin
            exp_pixel_f7 = 32'hFFFFFFFF;
            // red box (bounding box 520..579 x 300..359 of frame 6): 2 px frame outside
            if ((x == 518 || x == 519 || x == 580 || x == 581) && y >= 302 && y <= 357) exp_pixel_f7 = 32'h00FF3030;
            if ((y == 298 || y == 299 || y == 360 || y == 361) && x >= 522 && x <= 577) exp_pixel_f7 = 32'h00FF3030;
            // centre cross of the red target (centre 549, 329): arm pixel
            if (x == 549 && y == 329) exp_pixel_f7 = 32'h00FF3030;
            // red target interior away from the cross: the original red
            if (x == 530 && y == 310) exp_pixel_f7 = 32'h00C82828;
            // green box (bounding box 610..670 x 420..480)
            if ((x == 608 || x == 609 || x == 671 || x == 672) && y == 450) exp_pixel_f7 = 32'h0030FF30;
            // blue box (bounding box 900..959 x 400..459)
            if ((x == 898 || x == 899 || x == 960 || x == 961) && y == 430) exp_pixel_f7 = 32'h003070FF;
            // counting line x = 640, 641 (cyan) where no target is
            if ((x == 640 || x == 641) && y == 100) exp_pixel_f7 = 32'h0000E5FF;
            // plain background far from everything
            if (x == 1100 && y == 600) exp_pixel_f7 = 32'h003C3C3C;
        end
    endfunction

    // expected colour of a few interior / background pixels in the style views (frames 15..18), or 0xFFFFFFFF = not checked
    function [31:0] exp_pixel_sty;
        input integer f;
        input integer x;
        input integer y;
        begin
            exp_pixel_sty = 32'hFFFFFFFF;
            case (f)
                15: begin                                                   // SKETCH: shaded paper (gray 88 and 60)
                        if (x == 530 && y == 310)  exp_pixel_sty = 32'h008C8C8C;
                        if (x == 1100 && y == 600) exp_pixel_sty = 32'h007E7E7E;
                    end
                16: begin                                                   // CARTOON: posterized interiors
                        if (x == 530 && y == 310)  exp_pixel_sty = 32'h00D03030;
                        if (x == 630 && y == 450)  exp_pixel_sty = 32'h0030D030;
                        if (x == 929 && y == 440)  exp_pixel_sty = 32'h003030D0;
                        if (x == 1100 && y == 600) exp_pixel_sty = 32'h00303030;
                    end
                17: begin                                                   // EDGE+: dimmed background
                        if (x == 530 && y == 310)  exp_pixel_sty = 32'h00641414;
                        if (x == 1100 && y == 600) exp_pixel_sty = 32'h001E1E1E;
                    end
                18: begin                                                   // THERMAL of gray 88 (red target) and gray 60 (background)
                        if (x == 530 && y == 310)  exp_pixel_sty = 32'h0000FF9F;
                        if (x == 1100 && y == 600) exp_pixel_sty = 32'h0000F0FF;
                    end
                default: ;
            endcase
        end
    endfunction

    always @(negedge clk) begin
        if (check_en) begin
            chk = chk + 1;
            if (vuser_h[N] === 1'b1) data_en = 1'b1;
            if (!buzzer_n) buzz_low_seen = buzz_low_seen + 1;
            if (proc_exp) begin
                if (tx_de !== vde_h[N]) bad("tx_de", vde_h[N], tx_de);
                if (tx_vs !== vvs_h[N]) bad("tx_vs", vvs_h[N], tx_vs);
                if (vde_h[N] !== 1'b1 && tx_data !== 24'd0) bad("tx_data in blanking", 0, tx_data);
                if (data_en && vde_h[N] === 1'b1) begin
                    xo = px_h[N]; yo = py_h[N];
                    // panel colour census (rectangle of the panel: 16..463 x 520..679)
                    if (xo >= 16 && xo < 464 && yo >= 520 && yo < 680) begin
                        if (tx_data === 24'hFFE060) cnt_hdr = cnt_hdr + 1;
                        if (tx_data === 24'hFF7070) cnt_r   = cnt_r + 1;
                        if (tx_data === 24'h70FF70) cnt_g   = cnt_g + 1;
                        if (tx_data === 24'h80A0FF) cnt_b   = cnt_b + 1;
                        if (tx_data === 24'hE0E0E0) cnt_fps = cnt_fps + 1;
                    end
                    // tracker statistics row (panel row 5, y 680..711): light-aqua glyph pixels
                    if (xo >= 16 && xo < 464 && yo >= 680 && yo < 712 && tx_data === 24'hA0F0E0) cnt_trk = cnt_trk + 1;
                    // mode strip (row 1 of the v1 text block): white glyph pixels and the opaque dark backing
                    if (xo >= 200 && xo < 552 && yo >= 48 && yo < 80) begin
                        if (tx_data === 24'hFFFFFF) cnt_mw = cnt_mw + 1;
                        if (tx_data === 24'h181818) cnt_mb = cnt_mb + 1;
                    end
                    // edge census around the red rectangle
                    if (xo >= 500 && xo < 800 && yo >= 280 && yo < 380) begin
                        if (tx_data === 24'h101010) cnt_dark  = cnt_dark + 1;
                        if (tx_data === 24'h00FF80) cnt_gedge = cnt_gedge + 1;
                    end
                    if (fr == 11) begin                                         // MASK view: hit boundary pixels (alignment of the filtered hits)
                        if ((xo == 520 && yo == 310) || (xo == 579 && yo == 310) || (xo == 530 && yo == 310)) begin
                            box_chk = box_chk + 1;
                            if (tx_data !== 24'hFF0000) begin box_bad = box_bad + 1; bad("mask pixel inside the red rectangle", xo * 10000 + yo, tx_data); end
                        end
                        if ((xo == 630 && yo == 450) || (xo == 610 && yo == 450)) begin
                            box_chk = box_chk + 1;
                            if (tx_data !== 24'h00FF00) begin box_bad = box_bad + 1; bad("mask pixel inside the green disc", xo * 10000 + yo, tx_data); end
                        end
                        if (xo == 1100 && yo == 600) begin
                            box_chk = box_chk + 1;
                            if (tx_data !== 24'h000000) begin box_bad = box_bad + 1; bad("mask background", xo * 10000 + yo, tx_data); end
                        end
                    end
                    if (fr >= 15 && fr <= 18) begin
                        if (exp_pixel_sty(fr, xo, yo) !== 32'hFFFFFFFF) begin
                            box_chk = box_chk + 1;
                            if ({8'd0, tx_data} !== exp_pixel_sty(fr, xo, yo)) begin
                                box_bad = box_bad + 1;
                                bad("style pixel (x*10000+y shown as expected)", xo * 10000 + yo, tx_data);
                            end
                        end
                    end
                    if (fr >= 20 && fr <= 33) begin
                        // settings commit probes: the plain background at the top and at the bottom of the frame has ONE view
                        if ((xo == 1100 && yo == 100) || (xo == 1100 && yo == 650)) begin
                            box_chk = box_chk + 1;
                            if ({8'd0, tx_data} !== exp_view_col(vm_exp)) begin box_bad = box_bad + 1; bad("view of the whole frame (x*10000+y)", xo * 10000 + yo, tx_data); end
                        end
                    end
                    if (fr >= 24 && fr <= 33) begin
                        // tracker box probes on the left edge of the red box (tracked box 720..779 x 300..359, 2 px frame at x = 718, 719):
                        // (718,312) and (718,348) are dash-on pixels, (718,305) and (718,340) dash-off pixels
                        if (xo == 718 && (yo == 312 || yo == 348 || yo == 305 || yo == 340)) begin
                            box_chk = box_chk + 1;
                            if (rg_exp && (drawn_state(fr) == 1 || (drawn_state(fr) == 2 && (yo == 312 || yo == 348)))) begin
                                if ({8'd0, tx_data} !== 32'h00FF3030) begin box_bad = box_bad + 1; bad("box pixel expected (x*10000+y)", xo * 10000 + yo, tx_data); end
                            end
                            else if (!rg_exp && drawn_state(fr) == 1) begin
                                // recognition off, SW4 on: the single-target box of the v1 overlay (green, same 2 px frame, drawn only while TRACKed)
                                if ({8'd0, tx_data} !== 32'h0000FF40) begin box_bad = box_bad + 1; bad("v1 box pixel expected (x*10000+y)", xo * 10000 + yo, tx_data); end
                            end
                            else begin
                                if ({8'd0, tx_data} !== exp_view_col(vm_exp)) begin box_bad = box_bad + 1; bad("no box pixel expected (x*10000+y)", xo * 10000 + yo, tx_data); end
                            end
                        end
                        // centre cross: only for a really tracked target
                        if (xo == 749 && yo == 329) begin
                            box_chk = box_chk + 1;
                            if (drawn_state(fr) == 1) begin          // v2 cross (recognition on) or v1 crosshair (off): both FF3030
                                if ({8'd0, tx_data} !== 32'h00FF3030) begin box_bad = box_bad + 1; bad("centre cross expected", xo * 10000 + yo, tx_data); end
                            end
                            else if ({8'd0, tx_data} !== ((rvis != 0) ? 32'h0000FF9F : exp_view_col(vm_exp))) begin
                                box_bad = box_bad + 1; bad("no centre cross expected", xo * 10000 + yo, tx_data);
                            end
                        end
                    end
                    if (fr == 7) begin
                        if (exp_pixel_f7(xo, yo) !== 32'hFFFFFFFF) begin
                            box_chk = box_chk + 1;
                            if ({8'd0, tx_data} !== exp_pixel_f7(xo, yo)) begin
                                box_bad = box_bad + 1;
                                bad("pixel in frame 7 (x*10000+y shown as expected)", xo * 10000 + yo, tx_data);
                            end
                        end
                    end
                end
            end
            else begin
                if (tx_vs !== vvs_h[5] || tx_de !== vde_h[5] || tx_data !== base_data) bad("bypass", {vvs_h[5], vde_h[5], base_data[22:0]}, {tx_vs, tx_de, tx_data[22:0]});
            end
        end
    end

    // ---------------- keys as a user presses them
    task press;                        // press key i for n clocks
        input integer i;
        input integer n;
        begin
            key_n[i] = 1'b0;
            repeat (n) @(posedge clk);
            key_n[i] = 1'b1;
            repeat (60) @(posedge clk);
        end
    endtask

    // scripted key actions (each waits for its frame, then a fixed delay into the frame)
    integer line_after_k4, line_after_k3;
    initial begin
        key_n = 4'b1111;
        wait (fr == 6);   repeat (200000) @(posedge clk);  press(0, 200);                                   // KEY1: recognition mode
        wait (fr == 9);   repeat (200000) @(posedge clk);  press(1, 200);                                   // KEY2: adaptive thresholds
        wait (fr == 12);  repeat (200000) @(posedge clk);                                                   // KEY1+KEY2 chord: clear counters
        key_n[0] = 1'b0; repeat (5) @(posedge clk); key_n[1] = 1'b0; repeat (200) @(posedge clk);
        key_n[0] = 1'b1; key_n[1] = 1'b1; repeat (60) @(posedge clk);
        wait (fr == 13);  repeat (100000) @(posedge clk);
        press(3, 100);                                                                                      // KEY4 once: +16
        line_after_k4 = dut.req_line_x;
        key_n[2] = 1'b0; repeat (1500) @(posedge clk); key_n[2] = 1'b1;                                     // KEY3 held: -16, then auto-repeat
        repeat (60) @(posedge clk);
        line_after_k3 = dut.req_line_x;
        wait (fr == 14);  repeat (200000) @(posedge clk);
        key_n[1] = 1'b0; repeat (1500) @(posedge clk); key_n[1] = 1'b1;                                   // KEY2 held: style page
    end

    // requests in the MIDDLE of a frame (row r of frame f = (25 + r) lines after the vsync rising edge before it, 1650 clocks per line)
    initial begin
        wait (fr == 20);  repeat ((25 + 360) * 1650) @(posedge clk);  sw = 4'b1111;                          // view SKETCH -> THERMAL
        wait (fr == 21);  repeat ((25 + 150) * 1650) @(posedge clk);  sw = 4'b1011;                          // request CARTOON ...
                          repeat ((500 - 150) * 1650) @(posedge clk); sw = 4'b1111;                          // ... withdrawn again before the boundary
        wait (fr == 22);  repeat ((25 + 360) * 1650) @(posedge clk);  sw = 4'b1110;                          // SW1 off
        wait (fr == 23);  repeat ((25 + 360) * 1650) @(posedge clk);  sw = 4'b1111;                          // SW1 on
        wait (fr == 24);  repeat ((25 + 330) * 1650) @(posedge clk);  press(0, 200);                         // KEY1: recognition off
        wait (fr == 25);  repeat ((25 + 330) * 1650) @(posedge clk);  press(0, 200);                         // KEY1: recognition on
    end

    // ---------------- parameter sets and result checks at every vsync rising edge (blanking)
    integer kdone;
    reg [15:0] jit_ref, hold_ref, reacq_ref, lost_ref, acq_ref, cc_ref;
    reg [8*128-1:0] expl, utmp, umask;
    integer a_r, a_g, a_b;
    function [47:0] dec6;             // n as exactly six decimal digits (the $sformat zero-fill flag is not portable)
        input integer n;
        integer q, d;
        begin
            q = n;
            d = q % 10; dec6[7:0]   = 8'h30 + d; q = q / 10;
            d = q % 10; dec6[15:8]  = 8'h30 + d; q = q / 10;
            d = q % 10; dec6[23:16] = 8'h30 + d; q = q / 10;
            d = q % 10; dec6[31:24] = 8'h30 + d; q = q / 10;
            d = q % 10; dec6[39:32] = 8'h30 + d; q = q / 10;
            d = q % 10; dec6[47:40] = 8'h30 + d;
        end
    endfunction

    function [31:0] dec4;             // n as exactly four decimal digits
        input integer n;
        integer q, d;
        begin
            q = n;
            d = q % 10; dec4[7:0]   = 8'h30 + d; q = q / 10;
            d = q % 10; dec4[15:8]  = 8'h30 + d; q = q / 10;
            d = q % 10; dec4[23:16] = 8'h30 + d; q = q / 10;
            d = q % 10; dec4[31:24] = 8'h30 + d;
        end
    endfunction

    integer lx0, lx1, lx2, ly0, ly1, ly2;
    task expected_line;               // line of frame 1 (statistics of frame 0)
        begin
            calc(1, 520); a_r = e_cnt; lx0 = (e_xmin + e_xmax) >> 1; ly0 = (e_ymin + e_ymax) >> 1;
            calc(2, 520); a_g = e_cnt; lx1 = (e_xmin + e_xmax) >> 1; ly1 = (e_ymin + e_ymax) >> 1;
            calc(3, 520); a_b = e_cnt; lx2 = (e_xmin + e_xmax) >> 1; ly2 = (e_ymin + e_ymax) >> 1;
            $sformat(expl, "R:RECT,X%0s,Y%0s,A%0s,N00000;G:CIRC,X%0s,Y%0s,A%0s,N00000;B:TRIA,X%0s,Y%0s,A%0s,N00000;",
                     dec4(lx0), dec4(ly0), dec6(a_r), dec4(lx1), dec4(ly1), dec6(a_g), dec4(lx2), dec4(ly2), dec6(a_b));
        end
    endtask

    task set_params;                  // parameters of frame f
        input integer f;
        begin
            case (f)
                0, 1:   begin rx = 520; br = 100; end
                2, 3:   begin rx = 720; br = 100; end
                4, 5:   begin rx = 520; br = 100; end
                6, 7:   begin rx = 520; br = 100; end
                8, 9, 10: begin rx = 520; br = 30;  end
                20:      begin rx = 521; br = 100; end
                21, 22:  begin rx = 526; br = 100; end
                default: begin rx = 520; br = 100; end
            endcase
            if (f >= 23) rx = 720;
            rvis = (f == 27 || f == 29 || f == 30 || f == 31) ? 0 : 1;
            case (f)
                0, 1, 2, 3, 4, 5, 6: sw = 4'b0001;
                7:                   sw = 4'b1001;
                15:                  sw = 4'b1001;
                16:                  sw = 4'b1011;
                17:                  sw = 4'b1101;
                18:                  sw = 4'b1111;
                11:                  sw = 4'b1101;
                19:                  sw = 4'b0000;
                20:                  sw = 4'b1001;
                21, 22:              sw = 4'b1111;
                23:                  sw = 4'b1110;
                24, 25, 26, 27, 28, 29, 30, 31, 32, 33: sw = 4'b1111;
                default:             sw = 4'b1001;
            endcase
        end
    endtask

    integer i;
    always @(posedge clk) begin
        vvs_q <= vvs;
        if (vuser) seen_user <= 1'b1;
        if (seen_user && vvs && !vvs_q) begin
            kdone = fr;                                   // the frame that just ended
            if (check_en) begin
                // ---------------- results of frame kdone
                case (kdone)
                    0: begin
                        check_target(1, 520, 1); check_target(2, 520, 1); check_target(3, 520, 1);
                        if (led[3] !== 1'b1) bad("led3 processed", 1, led[3]);
                        if (led[0] !== 1'b1) bad("led0 found", 1, led[0]);
                        if (led[1] !== 1'b0) bad("LED2 geometry error", 0, led[1]);
                    end
                    1: begin check_target(1, 520, 1); check_target(2, 520, 1); check_target(3, 520, 1); end
                    2: begin check_target(1, 720, 1); check_target(2, 720, 1); check_target(3, 720, 1);
                         if (dut.cc_k0 !== 16'd0) bad("red crossings after one right frame", 0, dut.cc_k0); end
                    3: begin check_target(1, 720, 1);
                         if (dut.cc_k0 !== 16'd1) bad("red crossings after two right frames", 1, dut.cc_k0); end
                    4: begin check_target(1, 520, 1);
                         if (dut.cc_k0 !== 16'd1) bad("red crossings after one left frame", 1, dut.cc_k0); end
                    5: begin
                        check_target(1, 520, 1); check_target(2, 520, 1); check_target(3, 520, 1);
                        if (dut.cc_k0 !== 16'd2) bad("red crossings after the second crossing", 2, dut.cc_k0);
                        if (dut.cc_k1 !== 16'd0) bad("green crossings (centre on the line)", 0, dut.cc_k1);
                        if (dut.cc_k2 !== 16'd0) bad("blue crossings (always right)", 0, dut.cc_k2);
                        if (buzz_low_seen == 0) bad("buzzer never sounded", 1, 0);
                        // seven-segment: total crossings 0002, then F
                        if (dseen[0] !== 4'd0 || dseen[1] !== 4'd0 || dseen[2] !== 4'd0 || dseen[3] !== 4'd2) bad("7-seg total digits (0002)", 2, {dseen[0], dseen[1], dseen[2], dseen[3]});
                        if (dseen[4] !== 4'd10) bad("7-seg F", 10, dseen[4]);
                        // frame-rate meter: camera ~13 ms per frame, display 12.4 ms per frame, 40 ms window -> 3..4
                        if (dut.fps_disp < 8'd2 || dut.fps_disp > 8'd5) bad("measured display frame rate (window 40 ms, 12.4 ms frames)", 3, dut.fps_disp);
                        if (dut.fps_cam  < 8'd2 || dut.fps_cam  > 8'd5) bad("measured camera frame rate (window 40 ms, 13 ms frames)", 3, dut.fps_cam);
                        if (cnt_r !== 0 || cnt_g !== 0 || cnt_b !== 0 || cnt_trk !== 0) bad("panel text although recognition mode is off", 0, cnt_r + cnt_g + cnt_b + cnt_trk);
                        if (cnt_mw < 60 || cnt_mb < 3000) bad("mode strip (white glyph pixels / dark backing)", 60, cnt_mw);
                    end
                    6: begin
                        if (dut.req_recog !== 1'b1) bad("recognition REQUEST after KEY1", 1, dut.req_recog);
                        if (dut.recog_en !== 1'b0)  bad("recognition EFFECTIVE must wait for the frame boundary", 0, dut.recog_en);
                        if (req_pending !== 1'b1)   bad("a request is waiting", 1, req_pending);
                        if (dut.adapt_en !== 1'b0) bad("adaptive thresholds must still be off", 0, dut.adapt_en);
                    end
                    7: begin
                        if (dut.recog_en !== 1'b1) bad("recognition mode effective in the next frame", 1, dut.recog_en);
                        if (box_chk < 20) bad("too few box pixels checked", 20, box_chk);
                        if (cnt_hdr < 100 || cnt_r < 100 || cnt_g < 100 || cnt_b < 100 || cnt_fps < 100) bad("panel glyph pixels (hdr r g b fps)", 100, cnt_hdr + cnt_r + cnt_g + cnt_b + cnt_fps);
                        if (cnt_trk < 100) bad("tracker statistics row glyph pixels", 100, cnt_trk);
                        $display("tb_vision_v2: frame 7 box/line pixels checked=%0d bad=%0d, panel glyph pixels hdr=%0d red=%0d green=%0d blue=%0d fps=%0d",
                                 box_chk, box_bad, cnt_hdr, cnt_r, cnt_g, cnt_b, cnt_fps);
                    end
                    8: begin
                        check_target(1, 520, 0); check_target(2, 520, 0); check_target(3, 520, 0);
                        if (led[0] !== 1'b0) bad("led0 must be off in dim light with fixed thresholds", 0, led[0]);
                    end
                    9: begin
                        if (dut.req_adapt !== 1'b1) bad("adaptive thresholds REQUEST after KEY2", 1, dut.req_adapt);
                        if (dut.adapt_en !== 1'b0)  bad("adaptive thresholds EFFECTIVE only at the boundary", 0, dut.adapt_en);
                        if (dut.recog_en !== 1'b1) bad("recognition mode must stay on", 1, dut.recog_en);
                    end
                    10: begin
                        if (dut.adapt_en !== 1'b1) bad("adaptive thresholds effective in the next frame", 1, dut.adapt_en);
                        check_target(1, 520, 1); check_target(2, 520, 1); check_target(3, 520, 1);
                        if (dut.ymean_valid !== 1'b1) bad("mean luminance valid", 1, dut.ymean_valid);
                        $display("tb_vision_v2: dim light, adaptive: mean luminance %0d, red floor %0d, found %b", dut.ymean, dut.thr_rmin, dut.rv);
                    end
                    11: begin check_target(1, 520, 1); check_target(2, 520, 1); check_target(3, 520, 1); end
                    12: begin
                        if (dut.cc_k0 !== 16'd0 || dut.cc_k1 !== 16'd0 || dut.cc_k2 !== 16'd0) bad("counters after the KEY1+KEY2 chord", 0, dut.cc_k0 + dut.cc_k1 + dut.cc_k2);
                        if (dut.recog_en !== 1'b1 || dut.adapt_en !== 1'b1) bad("chord must not toggle the modes", 3, {dut.recog_en, dut.adapt_en});
                    end
                    13: begin
                        if (line_after_k4 !== 656) bad("line after KEY4", 656, line_after_k4);
                        if (line_after_k3 > 600 || line_after_k3 < 32 || ((line_after_k3 - 32) % 16) != 0) bad("line after KEY3 hold (auto-repeat)", 400, line_after_k3);
                        $display("tb_vision_v2: counting line after KEY4: %0d, after KEY3 held: %0d", line_after_k4, line_after_k3);
                    end
                    14: begin
                        if (dut.req_page !== 1'b1) bad("style page REQUEST after the long KEY2 press", 1, dut.req_page);
                        if (dut.style_page !== 1'b0) bad("style page EFFECTIVE only at the boundary", 0, dut.style_page);
                        if (dut.adapt_en !== 1'b1)   bad("a long KEY2 press must not toggle the thresholds", 1, dut.adapt_en);
                    end
                    15: begin
                        if (dut.style_page !== 1'b1) bad("style page effective in the next frame", 1, dut.style_page);
                        if (dut.line_x !== dut.req_line_x) bad("counting line committed", dut.req_line_x, dut.line_x);
                        if (req_pending !== 1'b0) bad("no request may be left waiting", 0, req_pending);
                        check_target(1, 520, 1); check_target(2, 520, 1); check_target(3, 520, 1);
                        if (cnt_dark < 100) bad("SKETCH: dark edge pixels around the red rectangle", 100, cnt_dark);
                        $display("tb_vision_v2: SKETCH edge pixels around the red rectangle: %0d", cnt_dark);
                    end
                    19: jit_ref = dut.tk_jit0;
                    20: begin
                        if (dut.proc_en !== 1'b1) bad("bypass -> processed committed at the frame boundary", 1, dut.proc_en);
                        if (dut.xmin0 !== 521) bad("raw red xmin (the target moved by 1 px)", 521, dut.xmin0);
                        if (dut.tk_state0 !== 2'd1) bad("tracker state", 1, dut.tk_state0);
                        if (dut.tk_xmin0 !== 520 || dut.tk_xmax0 !== 579 || dut.tk_ymin0 !== 300 || dut.tk_ymax0 !== 359) bad("jitter: tracked box must stay", 520, dut.tk_xmin0);
                        if (dut.tk_jit0 !== jit_ref + 16'd1) bad("jitter counter", jit_ref + 1, dut.tk_jit0);
                    end
                    21: begin
                        if (dut.xmin0 !== 526) bad("raw red xmin (+6)", 526, dut.xmin0);
                        if (dut.tk_xmin0 !== 523 || dut.tk_xmax0 !== 582) bad("smoothing: tracked xmin after a 6 px step", 523, dut.tk_xmin0);
                        if (dut.view_mode !== 2'b11) bad("view committed (THERMAL)", 3, dut.view_mode);
                    end
                    22: begin
                        if (dut.tk_xmin0 !== 524 || dut.tk_xmax0 !== 583) bad("smoothing: tracked xmin after a 3 px step", 524, dut.tk_xmin0);
                        if (dut.view_mode !== 2'b11) bad("a withdrawn request must not change the view", 3, dut.view_mode);
                        if (dut.proc_en !== 1'b1) bad("SW1-off request must wait for the boundary", 1, dut.proc_en);
                        if (dut.proc_pending !== 1'b1) bad("SW1 request pending", 1, dut.proc_pending);
                    end
                    23: begin
                        if (dut.proc_en !== 1'b0) bad("bypass committed at the frame boundary", 0, dut.proc_en);
                        if (dut.tk_xmin0 !== 720 || dut.tk_xmax0 !== 779 || dut.tk_ymin0 !== 300 || dut.tk_ymax0 !== 359) bad("jump: tracked box takes the measurement", 720, dut.tk_xmin0);
                    end
                    24: begin
                        if (dut.proc_en !== 1'b1) bad("processed again at the boundary", 1, dut.proc_en);
                        if (dut.recog_en !== 1'b1) bad("recognition still effective in the frame of the request", 1, dut.recog_en);
                        if (dut.req_recog !== 1'b0) bad("recognition request (off)", 0, dut.req_recog);
                    end
                    25: begin
                        if (dut.recog_en !== 1'b0) bad("recognition effective off in the next frame", 0, dut.recog_en);
                        if (dut.req_recog !== 1'b1) bad("recognition request (on)", 1, dut.req_recog);
                    end
                    26: begin
                        if (dut.recog_en !== 1'b1) bad("recognition effective on again", 1, dut.recog_en);
                        if (dut.tk_state0 !== 2'd1) bad("tracker TRACK before the occlusion", 1, dut.tk_state0);
                        cc_ref = dut.cc_k0; hold_ref = dut.tk_hold0; reacq_ref = dut.tk_reacq0; lost_ref = dut.tk_lost0; acq_ref = dut.tk_acq0;
                    end
                    27: begin
                        if (dut.tk_state0 !== 2'd2 || dut.tk_age0 !== 8'd1) bad("HOLD, age 1 after one hidden frame", 2, dut.tk_state0);
                        if (dut.tk_xmin0 !== 720 || dut.tk_xmax0 !== 779) bad("held box", 720, dut.tk_xmin0);
                        if (dut.tk_hold0 !== hold_ref + 16'd1) bad("occlusion counter", hold_ref + 1, dut.tk_hold0);
                        if (dut.rv[0] !== 1'b0) bad("raw target absent", 0, dut.rv[0]);
                    end
                    28: begin
                        if (dut.tk_state0 !== 2'd1 || dut.tk_age0 !== 8'd0) bad("re-acquired after one hidden frame", 1, dut.tk_state0);
                        if (dut.tk_reacq0 !== reacq_ref + 16'd1) bad("re-acquisition counter", reacq_ref + 1, dut.tk_reacq0);
                    end
                    29: begin
                        if (dut.tk_state0 !== 2'd2 || dut.tk_age0 !== 8'd1) bad("HOLD again (age 1)", 2, dut.tk_state0);
                    end
                    30: begin
                        if (dut.tk_state0 !== 2'd2 || dut.tk_age0 !== 8'd2) bad("HOLD (age 2 = TRK_COAST)", 2, dut.tk_state0);
                    end
                    31: begin
                        if (dut.tk_state0 !== 2'd0 || dut.tk_age0 !== 8'd3) bad("LOST after more than TRK_COAST hidden frames", 0, dut.tk_state0);
                        if (dut.tk_lost0 !== lost_ref + 16'd1) bad("lost counter", lost_ref + 1, dut.tk_lost0);
                    end
                    32: begin
                        stat_snap = dut.tk_stat0;
                        if (dut.tk_state0 !== 2'd1) bad("target acquired again", 1, dut.tk_state0);
                        if (dut.tk_acq0 !== acq_ref + 16'd1) bad("acquisition counter", acq_ref + 1, dut.tk_acq0);
                    end
                    33: begin
                        if (dut.u_ext.r_stat !== stat_snap) bad("panel row 5 shows the statistics of the previous frame", stat_snap[31:0], dut.u_ext.r_stat[31:0]);
                        if (cnt_trk < 100) bad("tracker statistics row glyph pixels in frame 33", 100, cnt_trk);
                        if (dut.tk_state0 !== 2'd1) bad("TRACK", 1, dut.tk_state0);
                        if (dut.cc_k0 !== cc_ref) bad("the red crossing counter must not change during the occlusion sequence", cc_ref, dut.cc_k0);
                        if (dut.tk_hold0 !== hold_ref + 16'd2) bad("occlusion counter (2 occlusions began)", hold_ref + 2, dut.tk_hold0);
                        $display("tb_vision_v2: settings/tracker probes checked=%0d bad=%0d, tracker counters: acq=%0d hold=%0d reacq=%0d lost=%0d jit=%0d, mode_gen=%0d",
                                 box_chk, box_bad, dut.tk_acq0, dut.tk_hold0, dut.tk_reacq0, dut.tk_lost0, dut.tk_jit0, mode_gen);
                    end
                    17: begin
                        if (cnt_gedge < 100) bad("EDGE+: green edge pixels around the red rectangle", 100, cnt_gedge);
                        $display("tb_vision_v2: EDGE+ edge pixels around the red rectangle: %0d", cnt_gedge);
                    end
                    default: ;
                endcase
                // UART line captured in frame 1 (statistics of frame 0): the first 102 characters are the three colour blocks
                if (kdone == 1) begin
                    expected_line;
                    if (frame_line_len[1] != 115) bad("UART line length in frame 1 (115 without CR LF)", 115, frame_line_len[1]);
                    else begin
                        umask = ({{(8*128-1){1'b0}}, 1'b1} << (8*102)) - 1;
                        utmp  = frame_line[1] >> (8*(115-102));
                        if ((utmp & umask) !== (expl & umask)) begin
                            errors = errors + 1;
                            $display("MISMATCH UART line in frame 1: got '%0s' expected '%0s'", utmp & umask, expl & umask);
                        end
                        else $display("tb_vision_v2: UART line of frame 1 matches: %0s", expl & umask);
                    end
                end
                cnt_hdr = 0; cnt_r = 0; cnt_g = 0; cnt_b = 0; cnt_fps = 0; cnt_mw = 0; cnt_mb = 0; cnt_dark = 0; cnt_gedge = 0; cnt_trk = 0;
            end
            fr <= fr + 1;
            set_params(fr + 1);
        end
    end

    // ---------------- main
    integer guard, total_err;
    initial begin
        errors = 0; chk = 0; line_chk = 0; guard = 0; kdone = -1; ulines = 0;
        cnt_hdr = 0; cnt_r = 0; cnt_g = 0; cnt_b = 0; cnt_fps = 0; cnt_mw = 0; cnt_mb = 0; cnt_dark = 0; cnt_gedge = 0; cnt_trk = 0;
        check_en = 1'b0;
        set_params(0);
        rst_n = 1'b0;
        $display("tb_vision_v2: uivtc 1280x720 -> contest_vision_v2 (default SKEW=2, N=%0d), %0d frames", N, NFR);
        repeat (4) @(negedge clk);
        #2 rst_n = 1'b1;
        repeat (60) @(negedge clk);
        check_en = 1'b1;
        while (fr < NFR && guard < 60000000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        repeat (20) @(negedge clk);
        check_en = 1'b0;
        total_err = errors;
        $display("tb_vision_v2: clocks checked=%0d uart lines=%0d buzzer-low clocks=%0d errors=%0d", chk, ulines, buzz_low_seen, errors);
        if (guard >= 60000000 || ulines < 20 || buzz_low_seen < 1000) begin
            total_err = total_err + 1;
            $display("COVERAGE too low (or timeout): test would be vacuous");
        end
        if (total_err == 0) $display("TB_RESULT: PASS tb_vision_v2");
        else                $display("TB_RESULT: FAIL tb_vision_v2 errors=%0d", total_err);
        $finish;
    end

endmodule
