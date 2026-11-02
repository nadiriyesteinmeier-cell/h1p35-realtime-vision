// tb_frame_bbox.v - self-checking testbench for rtl_custom/frame_bbox.v
//
// Oracle: for every frame the testbench owns a hit map (hm). The expected count
// and box are derived by an algorithm that differs from the DUT's incremental
// min/max: column/row occupancy flags are built first, then xmin/xmax/ymin/ymax
// are found by scanning inward from the borders. Center is (min+max)/2 with the
// integer '/' operator.
//
// Cycle-exact expectation: the testbench raises t_expect in the SAME clock in
// which it presents the EOF pixel of a frame that must produce a result (and
// t_abort on the SOF pixel that must interrupt a running frame). The checker's
// model then expects frame_done / frame_abort one clock later and expects every
// res_* output to equal the model every single clock (this also proves "hold
// until next frame_done" and "no stale/early update").
//
// Four DUT instances see the same stimulus:
//   u0  CNT_W=20 MIN_PIXELS=16   (defaults)
//   u1  CNT_W=20 MIN_PIXELS=1
//   u2  CNT_W=4  MIN_PIXELS=2    (count saturates at 15, res_sat)
//   u3  CNT_W=20 MIN_PIXELS=0    (zero hits must still give valid = 0)
//
// Build/run (Icarus Verilog):
//   iverilog -g2005 -Wall -o sim_bbox.vvp tb_frame_bbox.v ../rtl_custom/frame_bbox.v
//   vvp sim_bbox.vvp
// Final line is "TB_RESULT: PASS ..." or "TB_RESULT: FAIL ...".

`timescale 1ns / 1ps

module bbox_chk #(
    parameter [31:0] NAME       = "?",
    parameter integer CNT_W      = 20,
    parameter integer MIN_PIXELS = 16
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_de,
    input  wire        in_hit,
    input  wire [11:0] in_x,
    input  wire [11:0] in_y,
    input  wire        in_sof,
    input  wire        in_eol,
    input  wire        in_eof,
    input  wire        t_expect,
    input  wire        t_abort,
    input  wire [31:0] t_cnt,
    input  wire [31:0] t_xmin,
    input  wire [31:0] t_xmax,
    input  wire [31:0] t_ymin,
    input  wire [31:0] t_ymax,
    input  wire        check_en
);

    localparam integer MAXC = (1 << CNT_W) - 1;

    wire                frame_done;
    wire                frame_abort;
    wire [15:0]         res_frame_id;
    wire                res_valid;
    wire [CNT_W-1:0]    res_count;
    wire                res_sat;
    wire [11:0]         res_xmin, res_xmax, res_ymin, res_ymax, res_cx, res_cy;

    frame_bbox #(.CNT_W(CNT_W), .MIN_PIXELS(MIN_PIXELS)) dut (
        .clk(clk), .rst_n(rst_n),
        .in_de(in_de), .in_hit(in_hit), .in_x(in_x), .in_y(in_y),
        .in_sof(in_sof), .in_eol(in_eol), .in_eof(in_eof),
        .frame_done(frame_done), .frame_abort(frame_abort),
        .res_frame_id(res_frame_id), .res_valid(res_valid),
        .res_count(res_count), .res_sat(res_sat),
        .res_xmin(res_xmin), .res_xmax(res_xmax),
        .res_ymin(res_ymin), .res_ymax(res_ymax),
        .res_cx(res_cx), .res_cy(res_cy)
    );

    // ---------------- model of what the outputs must be
    reg         m_done, m_abort, m_valid, m_sat;
    reg  [15:0] m_id;
    integer     m_count;
    reg  [11:0] m_xmin, m_xmax, m_ymin, m_ymax, m_cx, m_cy;

    integer     cnt_sat;
    reg         vld;

    integer err_cnt;
    integer chk_cnt;
    integer frames_seen;
    integer valid_frames;
    integer invalid_frames;
    integer sat_frames;
    integer aborts_seen;
    integer act_cnt;

    initial begin
        err_cnt = 0; chk_cnt = 0; frames_seen = 0; valid_frames = 0;
        invalid_frames = 0; sat_frames = 0; aborts_seen = 0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_done <= 1'b0; m_abort <= 1'b0; m_valid <= 1'b0; m_sat <= 1'b0;
            m_id <= 16'd0; m_count <= 0;
            m_xmin <= 12'd0; m_xmax <= 12'd0; m_ymin <= 12'd0; m_ymax <= 12'd0;
            m_cx <= 12'd0; m_cy <= 12'd0;
        end
        else begin
            m_done  <= 1'b0;
            m_abort <= t_abort;
            if (t_abort) aborts_seen = aborts_seen + 1;
            if (t_expect) begin
                cnt_sat = (t_cnt > MAXC) ? MAXC : t_cnt;
                vld     = (cnt_sat != 0) && (cnt_sat >= MIN_PIXELS);
                frames_seen = frames_seen + 1;
                if (vld) valid_frames = valid_frames + 1; else invalid_frames = invalid_frames + 1;
                if (t_cnt > MAXC) sat_frames = sat_frames + 1;
                m_done  <= 1'b1;
                m_id    <= m_id + 16'd1;
                m_count <= cnt_sat;
                m_sat   <= (t_cnt > MAXC);
                m_valid <= vld;
                m_xmin  <= vld ? t_xmin[11:0] : 12'd0;
                m_xmax  <= vld ? t_xmax[11:0] : 12'd0;
                m_ymin  <= vld ? t_ymin[11:0] : 12'd0;
                m_ymax  <= vld ? t_ymax[11:0] : 12'd0;
                m_cx    <= vld ? ((t_xmin + t_xmax) / 2) : 12'd0;
                m_cy    <= vld ? ((t_ymin + t_ymax) / 2) : 12'd0;
            end
        end
    end

    task bad;
        input [159:0] what;
        input [31:0]  exp_v;
        input [31:0]  act_v;
        begin
            err_cnt = err_cnt + 1;
            if (err_cnt <= 12)
                $display("MISMATCH[%0s] t=%0t %0s expected=%0d actual=%0d (in_de=%b hit=%b x=%0d y=%0d sof=%b eof=%b)",
                         NAME, $time, what, exp_v, act_v, in_de, in_hit, in_x, in_y, in_sof, in_eof);
            if (err_cnt >= 100) begin
                $display("TB_RESULT: FAIL tb_frame_bbox[%0s] aborted after %0d mismatches", NAME, err_cnt);
                $finish;
            end
        end
    endtask

    always @(negedge clk) begin
        if (check_en) begin
            chk_cnt = chk_cnt + 1;
            act_cnt = res_count;
            if (frame_done   !== m_done)   bad("frame_done",   m_done,   frame_done);
            if (frame_abort  !== m_abort)  bad("frame_abort",  m_abort,  frame_abort);
            if (res_frame_id !== m_id)     bad("res_frame_id", m_id,     res_frame_id);
            if (res_valid    !== m_valid)  bad("res_valid",    m_valid,  res_valid);
            if (act_cnt      !== m_count)  bad("res_count",    m_count,  act_cnt);
            if (res_sat      !== m_sat)    bad("res_sat",      m_sat,    res_sat);
            if (res_xmin     !== m_xmin)   bad("res_xmin",     m_xmin,   res_xmin);
            if (res_xmax     !== m_xmax)   bad("res_xmax",     m_xmax,   res_xmax);
            if (res_ymin     !== m_ymin)   bad("res_ymin",     m_ymin,   res_ymin);
            if (res_ymax     !== m_ymax)   bad("res_ymax",     m_ymax,   res_ymax);
            if (res_cx       !== m_cx)     bad("res_cx",       m_cx,     res_cx);
            if (res_cy       !== m_cy)     bad("res_cy",       m_cy,     res_cy);
        end
    end

endmodule


module tb_frame_bbox;

    localparam integer MAXPIX = 1280 * 720;

    reg         clk;
    reg         rst_n;
    reg         in_de;
    reg         in_hit;
    reg  [11:0] in_x;
    reg  [11:0] in_y;
    reg         in_sof;
    reg         in_eol;
    reg         in_eof;
    reg         t_expect;
    reg         t_abort;
    reg  [31:0] t_cnt, t_xmin, t_xmax, t_ymin, t_ymax;
    reg         check_en;

    initial clk = 1'b0;
    always #5 clk = ~clk;

`define STIM .clk(clk), .rst_n(rst_n), .in_de(in_de), .in_hit(in_hit), \
             .in_x(in_x), .in_y(in_y), .in_sof(in_sof), .in_eol(in_eol), \
             .in_eof(in_eof), .t_expect(t_expect), .t_abort(t_abort), \
             .t_cnt(t_cnt), .t_xmin(t_xmin), .t_xmax(t_xmax), \
             .t_ymin(t_ymin), .t_ymax(t_ymax), .check_en(check_en)

    bbox_chk #(.NAME("u0"), .CNT_W(20), .MIN_PIXELS(16)) u0 (`STIM);
    bbox_chk #(.NAME("u1"), .CNT_W(20), .MIN_PIXELS(1))  u1 (`STIM);
    bbox_chk #(.NAME("u2"), .CNT_W(4),  .MIN_PIXELS(2))  u2 (`STIM);
    bbox_chk #(.NAME("u3"), .CNT_W(20), .MIN_PIXELS(0))  u3 (`STIM);

    integer seed;

    // ------------------------------------------------------------------
    // hit map and independent truth
    // ------------------------------------------------------------------
    reg hm [0:MAXPIX-1];
    reg colocc [0:4095];
    reg rowocc [0:4095];
    integer tn_cnt, tn_xmin, tn_xmax, tn_ymin, tn_ymax;

    task hm_clear;
        input integer w;
        input integer h;
        integer i;
        begin
            for (i = 0; i < w * h; i = i + 1) hm[i] = 1'b0;
        end
    endtask

    task hm_rect;                           // inclusive rectangle
        input integer w;
        input integer xa;
        input integer ya;
        input integer xb;
        input integer yb;
        integer x, y;
        begin
            for (y = ya; y <= yb; y = y + 1)
                for (x = xa; x <= xb; x = x + 1)
                    hm[y * w + x] = 1'b1;
        end
    endtask

    task truth;
        input integer w;
        input integer h;
        integer x, y;
        begin
            tn_cnt = 0; tn_xmin = 0; tn_xmax = 0; tn_ymin = 0; tn_ymax = 0;
            for (x = 0; x < w; x = x + 1) colocc[x] = 1'b0;
            for (y = 0; y < h; y = y + 1) rowocc[y] = 1'b0;
            for (y = 0; y < h; y = y + 1)
                for (x = 0; x < w; x = x + 1)
                    if (hm[y * w + x]) begin
                        tn_cnt = tn_cnt + 1;
                        colocc[x] = 1'b1;
                        rowocc[y] = 1'b1;
                    end
            if (tn_cnt > 0) begin
                x = 0;     while (!colocc[x]) x = x + 1;  tn_xmin = x;
                x = w - 1; while (!colocc[x]) x = x - 1;  tn_xmax = x;
                y = 0;     while (!rowocc[y]) y = y + 1;  tn_ymin = y;
                y = h - 1; while (!rowocc[y]) y = y - 1;  tn_ymax = y;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // stimulus: every call = one clock, inputs change at negedge.
    // t_* truth is copied only on the cycle that carries a result-producing EOF.
    // ------------------------------------------------------------------
    task pix;
        input        de;
        input        hit;
        input [11:0] x;
        input [11:0] y;
        input        sof;
        input        eol;
        input        eof;
        input        ex;
        input        ab;
        begin
            @(negedge clk);
            in_de    = de;
            in_hit   = hit;
            in_x     = x;
            in_y     = y;
            in_sof   = sof;
            in_eol   = eol;
            in_eof   = eof;
            t_expect = ex;
            t_abort  = ab;
            if (ex) begin
                t_cnt = tn_cnt; t_xmin = tn_xmin; t_xmax = tn_xmax;
                t_ymin = tn_ymin; t_ymax = tn_ymax;
            end
        end
    endtask

    // blanking cycle carrying garbage, including sof/eol/eof and hit
    task garbage;
        begin
            pix(1'b0, $random(seed), $random(seed), $random(seed),
                $random(seed), $random(seed), $random(seed), 1'b0, 1'b0);
        end
    endtask

    task idle;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                pix(1'b0, 1'b0, 12'd0, 12'd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
        end
    endtask

    // send rows [ya, yb) of a w x h frame; SOF is (0,0), EOF is (w-1,h-1)
    task send_part;
        input integer w;
        input integer h;
        input integer ya;
        input integer yb;
        input integer gaps;
        input integer ex_at_eof;
        input integer ab_at_sof;
        integer x, y;
        reg     sof, eof;
        begin
            for (y = ya; y < yb; y = y + 1) begin
                for (x = 0; x < w; x = x + 1) begin
                    sof = (x == 0) && (y == 0);
                    eof = (x == w - 1) && (y == h - 1);
                    pix(1'b1, hm[y * w + x], x, y, sof, (x == w - 1), eof,
                        (eof && (ex_at_eof != 0)), (sof && (ab_at_sof != 0)));
                    if (gaps != 0 && (({$random(seed)} & 3) == 0)) garbage;
                end
                if (gaps != 0) begin
                    garbage; garbage;
                end
            end
        end
    endtask

    task send_frame;
        input integer w;
        input integer h;
        input integer gaps;
        input integer ab;
        begin
            truth(w, h);
            send_part(w, h, 0, h, gaps, 1, ab);
        end
    endtask

    // ------------------------------------------------------------------
    // main sequence
    // ------------------------------------------------------------------
    localparam integer FW = 32;
    localparam integer FH = 24;

    integer i, f, w, h, dens, rr;
    integer total_err;

    initial begin
        seed = 32'h5EED0003;
        check_en = 1'b0;
        rst_n = 1'b0;
        in_de = 1'b0; in_hit = 1'b0; in_x = 12'd0; in_y = 12'd0;
        in_sof = 1'b0; in_eol = 1'b0; in_eof = 1'b0;
        t_expect = 1'b0; t_abort = 1'b0;
        t_cnt = 0; t_xmin = 0; t_xmax = 0; t_ymin = 0; t_ymax = 0;
        tn_cnt = 0; tn_xmin = 0; tn_xmax = 0; tn_ymin = 0; tn_ymax = 0;

        $display("tb_frame_bbox: seed=0x%h", seed);

        repeat (3) @(negedge clk);
        #2 rst_n = 1'b1;
        check_en = 1'b1;
        idle(3);

        // ---- S1 empty frame
        hm_clear(FW, FH);                                       send_frame(FW, FH, 0, 0); idle(2);
        // ---- S2 single point
        hm_clear(FW, FH); hm_rect(FW, 10, 7, 10, 7);            send_frame(FW, FH, 0, 0); idle(2);
        // ---- S3 rectangle 5x4 = 20 pixels
        hm_clear(FW, FH); hm_rect(FW, 5, 3, 9, 6);              send_frame(FW, FH, 0, 0); idle(2);
        // ---- S4 rectangle 4x4 = 16 (== MIN_PIXELS of u0)
        hm_clear(FW, FH); hm_rect(FW, 12, 10, 15, 13);          send_frame(FW, FH, 0, 0); idle(2);
        // ---- S5 rectangle 5x3 = 15 (MIN_PIXELS-1)
        hm_clear(FW, FH); hm_rect(FW, 20, 2, 24, 4);            send_frame(FW, FH, 0, 0); idle(2);
        // ---- S6 one-pixel-high run of 17 on the last row
        hm_clear(FW, FH); hm_rect(FW, 0, 23, 16, 23);           send_frame(FW, FH, 0, 0); idle(2);
        // ---- S7 target at the very first pixel
        hm_clear(FW, FH); hm_rect(FW, 0, 0, 0, 0);              send_frame(FW, FH, 0, 0); idle(2);
        hm_clear(FW, FH); hm_rect(FW, 0, 0, 3, 3);              send_frame(FW, FH, 0, 0); idle(2);
        // ---- S8 target at the very last pixel
        hm_clear(FW, FH); hm_rect(FW, 31, 23, 31, 23);          send_frame(FW, FH, 0, 0); idle(2);
        hm_clear(FW, FH); hm_rect(FW, 28, 20, 31, 23);          send_frame(FW, FH, 0, 0); idle(2);
        // ---- S9 four corners, single pixels and 4x4 blocks
        hm_clear(FW, FH);
        hm_rect(FW, 0, 0, 0, 0);   hm_rect(FW, 31, 0, 31, 0);
        hm_rect(FW, 0, 23, 0, 23); hm_rect(FW, 31, 23, 31, 23);
                                                                send_frame(FW, FH, 0, 0); idle(2);
        hm_clear(FW, FH);
        hm_rect(FW, 0, 0, 3, 3);   hm_rect(FW, 28, 0, 31, 3);
        hm_rect(FW, 0, 20, 3, 23); hm_rect(FW, 28, 20, 31, 23);
                                                                send_frame(FW, FH, 0, 0); idle(2);
        // ---- S10 full frame (u2 saturates)
        hm_clear(FW, FH); hm_rect(FW, 0, 0, FW - 1, FH - 1);    send_frame(FW, FH, 0, 0); idle(2);
        // ---- S11 two consecutive frames with different targets, EOF immediately followed by SOF
        hm_clear(FW, FH); hm_rect(FW, 0, 0, 3, 3);              send_frame(FW, FH, 0, 0);
        hm_clear(FW, FH); hm_rect(FW, 28, 20, 31, 23);          send_frame(FW, FH, 0, 0);
        hm_clear(FW, FH); hm_rect(FW, 14, 9, 18, 13);           send_frame(FW, FH, 0, 0);
        idle(2);
        // ---- S12 hits only on the SOF pixel and the EOF pixel
        hm_clear(FW, FH); hm_rect(FW, 0, 0, 0, 0); hm_rect(FW, 31, 23, 31, 23);
                                                                send_frame(FW, FH, 0, 0); idle(2);
        // ---- S13 pixel-count thresholds: 15/16/17 (u0) and 1/2/3 (u1,u2)
        hm_clear(FW, FH); hm_rect(FW, 2, 5, 16, 5);             send_frame(FW, FH, 0, 0); idle(2);   // 15
        hm_clear(FW, FH); hm_rect(FW, 2, 5, 17, 5);             send_frame(FW, FH, 0, 0); idle(2);   // 16
        hm_clear(FW, FH); hm_rect(FW, 2, 5, 18, 5);             send_frame(FW, FH, 0, 0); idle(2);   // 17
        hm_clear(FW, FH); hm_rect(FW, 2, 5, 2, 5);              send_frame(FW, FH, 0, 0); idle(2);   // 1
        hm_clear(FW, FH); hm_rect(FW, 2, 5, 3, 5);              send_frame(FW, FH, 0, 0); idle(2);   // 2
        hm_clear(FW, FH); hm_rect(FW, 2, 5, 4, 5);              send_frame(FW, FH, 0, 0); idle(2);   // 3
        hm_clear(FW, FH); hm_rect(FW, 2, 5, 16, 5);             send_frame(FW, FH, 0, 0); idle(2);   // 15 (u2 saturates at 15 exactly: sat must stay 0)
        hm_clear(FW, FH); hm_rect(FW, 2, 5, 17, 5);             send_frame(FW, FH, 0, 0); idle(2);   // 16 (u2: sat = 1)

        // ---- S14 degenerate sizes: sof = eol = eof on the same pixel, 1 x N, N x 1
        hm_clear(1, 1); hm_rect(1, 0, 0, 0, 0);                 send_frame(1, 1, 0, 0);
        hm_clear(1, 1);                                         send_frame(1, 1, 0, 0);
        hm_clear(1, 1); hm_rect(1, 0, 0, 0, 0);                 send_frame(1, 1, 1, 0);
        idle(2);
        hm_clear(1, 20); hm_rect(1, 0, 5, 0, 9);                send_frame(1, 20, 0, 0); idle(1);
        hm_clear(1, 20); hm_rect(1, 0, 5, 0, 9);                send_frame(1, 20, 1, 0); idle(1);
        hm_clear(20, 1); hm_rect(20, 3, 0, 10, 0);              send_frame(20, 1, 0, 0); idle(1);
        hm_clear(20, 1); hm_rect(20, 3, 0, 10, 0);              send_frame(20, 1, 1, 0); idle(2);

        // ---- S15 full-size 1280x720: all hits, then only the four corners
        hm_clear(1280, 720); hm_rect(1280, 0, 0, 1279, 719);    send_frame(1280, 720, 0, 0); idle(3);
        hm_clear(1280, 720);
        hm_rect(1280, 0, 0, 0, 0);       hm_rect(1280, 1279, 0, 1279, 0);
        hm_rect(1280, 0, 719, 0, 719);   hm_rect(1280, 1279, 719, 1279, 719);
                                                                send_frame(1280, 720, 0, 0); idle(3);

        // ---- S15b large coordinates (12-bit range): xmin+xmax needs the 13th bit, init value must be >= 4095
        hm_clear(4096, 1); hm_rect(4096, 4000, 0, 4095, 0);     send_frame(4096, 1, 0, 0); idle(2);   // cx = 4047
        hm_clear(4096, 1); hm_rect(4096, 4095, 0, 4095, 0);     send_frame(4096, 1, 0, 0); idle(2);   // single hit at x = 4095
        hm_clear(4096, 1); hm_rect(4096, 2040, 0, 2055, 0);     send_frame(4096, 1, 0, 0); idle(2);   // straddles 2047/2048
        hm_clear(4096, 1); hm_rect(4096, 0, 0, 4095, 0);        send_frame(4096, 1, 0, 0); idle(2);   // full line, cx = 2047
        hm_clear(1, 4096); hm_rect(1, 0, 4000, 0, 4095);        send_frame(1, 4096, 0, 0); idle(2);   // cy = 4047
        hm_clear(1, 4096); hm_rect(1, 0, 2040, 0, 2055);        send_frame(1, 4096, 1, 0); idle(2);

        // ---- S17 SOF in the middle of a running frame: first part discarded, abort pulse
        hm_clear(FW, FH); hm_rect(FW, 16, 0, 31, 9);
                                                                send_part(FW, FH, 0, 10, 0, 0, 0);
        hm_clear(FW, FH); hm_rect(FW, 2, 14, 8, 20);            send_frame(FW, FH, 0, 1); idle(2);
        // same, but the interrupted part contains garbage-qualified bubbles
        hm_clear(FW, FH); hm_rect(FW, 0, 0, 31, 4);
                                                                send_part(FW, FH, 0, 5, 1, 0, 0);
        hm_clear(FW, FH); hm_rect(FW, 25, 18, 30, 22);          send_frame(FW, FH, 1, 1); idle(2);

        // ---- S18 reset in the middle of a frame; rest of that frame (no SOF, with EOF) must be ignored
        hm_clear(FW, FH); hm_rect(FW, 0, 0, 31, 23);
                                                                send_part(FW, FH, 0, 12, 0, 0, 0);
        @(negedge clk);
        #2 rst_n = 1'b0;                                        // asynchronous, away from a clock edge
        in_de = 1'b1; in_hit = 1'b1; in_x = 12'd3; in_y = 12'd3;
        in_sof = 1'b1; in_eol = 1'b1; in_eof = 1'b1;
        t_expect = 1'b0; t_abort = 1'b0;
        pix(1'b1, 1'b1, 12'd3, 12'd3, 1'b1, 1'b1, 1'b1, 1'b0, 1'b0);   // still in reset: ignored
        pix(1'b1, 1'b1, 12'd3, 12'd3, 1'b1, 1'b1, 1'b1, 1'b0, 1'b0);
        pix(1'b0, 1'b0, 12'd0, 12'd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);   // bus idle BEFORE release: a valid sof/eof
                                                                       // pixel still on the bus at release would be
                                                                       // (correctly) taken as a real 1x1 frame
        #2 rst_n = 1'b1;
                                                                send_part(FW, FH, 12, 24, 0, 0, 0);
        idle(3);
        hm_clear(FW, FH); hm_rect(FW, 8, 8, 12, 12);            send_frame(FW, FH, 0, 0); idle(2);   // fresh frame: id restarts at 1

        // ---- S18b reset while idle between frames, then an orphan pixel burst without SOF
        @(negedge clk);
        #2 rst_n = 1'b0;
        #1 rst_n = 1'b1;                                        // released 3 ns after the negedge, 2 ns before the posedge
        hm_clear(FW, FH); hm_rect(FW, 0, 0, 31, 23);
                                                                send_part(FW, FH, 5, 24, 1, 0, 0);
        idle(2);
        hm_clear(FW, FH); hm_rect(FW, 3, 3, 9, 9);              send_frame(FW, FH, 1, 0); idle(2);

        // ---- S16 random frames: random size, density, gaps, back-to-back or idle between
        for (f = 0; f < 80; f = f + 1) begin
            w    = 1 + ({$random(seed)} % 40);
            h    = 1 + ({$random(seed)} % 30);
            dens = {$random(seed)} % 5;
            hm_clear(w, h);
            for (i = 0; i < w * h; i = i + 1) begin
                rr = {$random(seed)} % 100;
                case (dens)
                    0: hm[i] = 1'b0;
                    1: hm[i] = (rr < 1);
                    2: hm[i] = (rr < 5);
                    3: hm[i] = (rr < 30);
                    default: hm[i] = 1'b1;
                endcase
            end
            send_frame(w, h, {$random(seed)} % 2, 0);
            idle({$random(seed)} % 4);
        end
        idle(3);

        // ---- S19 res_frame_id wrap-around: > 65536 one-pixel frames
        hm_clear(1, 1);
        for (i = 0; i < 65540; i = i + 1) begin
            hm[0] = i[0];
            send_frame(1, 1, 0, 0);
        end
        idle(5);

        check_en = 1'b0;

        total_err = u0.err_cnt + u1.err_cnt + u2.err_cnt + u3.err_cnt;
        $display("tb_frame_bbox: clocks=%0d frames=%0d errors u0=%0d u1=%0d u2=%0d u3=%0d",
                 u0.chk_cnt, u0.frames_seen, u0.err_cnt, u1.err_cnt, u2.err_cnt, u3.err_cnt);
        $display("tb_frame_bbox: u0 valid=%0d invalid=%0d sat=%0d aborts=%0d | u1 valid=%0d invalid=%0d | u2 valid=%0d invalid=%0d sat=%0d | u3 valid=%0d invalid=%0d",
                 u0.valid_frames, u0.invalid_frames, u0.sat_frames, u0.aborts_seen,
                 u1.valid_frames, u1.invalid_frames,
                 u2.valid_frames, u2.invalid_frames, u2.sat_frames,
                 u3.valid_frames, u3.invalid_frames);

        // coverage: the scenarios must really have happened
        // (118 directed/random frames + 65540 one-pixel frames = 65658 expected results;
        //  two 1280x720 frames alone are 1.84 M clocks)
        if (u0.frames_seen < 65600 || u0.valid_frames < 20 || u0.invalid_frames < 20 ||
            u0.aborts_seen < 2 || u2.sat_frames < 3 || u1.valid_frames < 40 ||
            u3.invalid_frames < 5 || u0.chk_cnt < 1850000) begin
            total_err = total_err + 1;
            $display("COVERAGE too low: test would be vacuous");
        end
        if (total_err == 0) $display("TB_RESULT: PASS tb_frame_bbox");
        else                $display("TB_RESULT: FAIL tb_frame_bbox errors=%0d", total_err);
        $finish;
    end

endmodule
