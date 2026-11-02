// tb_pos_chain.v - end-to-end chain at the real 1280x720 timing of the baseline
//
//   unmodified lab1 uivtc.v (1650x750 total, as instantiated in design_top_wrapper.v)
//     -> video_pos_adapter (colour lags de by 2 clocks, the suspected baseline skew)
//     -> color_segment (defaults: R_MIN 80, DELTA 30, full image)
//     -> frame_bbox    (defaults: CNT_W 20, MIN_PIXELS 16)
//
// The synthetic image (see vtc_chk.colorfn, IMAGE_MODE 1) has a 0xFF2010 target rectangle that
// changes every frame (frame k mod 3), a green rectangle (G > R, must not hit) and a block with
// R = 79 (just below R_MIN, must not hit). Expected result of frame k is derived here from the
// rectangle definition only:
//     k mod 3 = 0: x 100..299  y  50..149   20000 pixels
//     k mod 3 = 1: x 900..1000 y 600..700   10201 pixels
//     k mod 3 = 2: x   0..15   y   0..15      256 pixels
//   cx = (xmin+xmax)/2, cy = (ymin+ymax)/2, res_valid = 1, res_frame_id = k+1
//
// Timing expectation: frame_done is visible exactly 3 clocks after the adapter's EOF output
// (color_segment 2 + frame_bbox 1); every clock all res_* must equal the expected current
// result (this also checks that results are held until the next frame completes).
//
// Build/run (Icarus Verilog), from F:\fpga_s2\tb_custom:
//   iverilog -g2005 -Wall -o sim_chain.vvp tb_pos_chain.v tb_vtc_chk.v ../rtl_custom/video_pos_adapter.v ../rtl_custom/color_segment.v ../rtl_custom/frame_bbox.v ../lab1/user_source/hdl_source/vtc/uivtc.v
//   vvp sim_chain.vvp
// Final line: "TB_RESULT: PASS ..." or "TB_RESULT: FAIL ...".

`timescale 1ns / 1ps

module tb_pos_chain;

    localparam integer NFR = 4;         // frames to check (k = 0..3, covers every rectangle and the wrap)

    reg clk;
    reg rst_n;
    reg check_en;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---------------- timing generator + adapter + oracle
    wire        a_de, a_sof, a_eol, a_eof, a_err, x_eof;
    wire [23:0] a_rgb;
    wire [11:0] a_x, a_y;
    wire [7:0]  x_fidx;
    wire [31:0] verr, vchk, veof;

    vtc_chk #(.NAME("real"), .H_ACT(1280), .H_FRM(1650), .H_SS(1390), .H_SE(1430),
              .V_ACT(720), .V_FRM(750), .V_SS(725), .V_SE(730), .D(2), .IMAGE_MODE(1))
        vc (.clk(clk), .rst_n(rst_n), .check_en(check_en),
            .a_de(a_de), .a_rgb(a_rgb), .a_x(a_x), .a_y(a_y), .a_sof(a_sof), .a_eol(a_eol), .a_eof(a_eof),
            .a_geom_err(a_err), .x_eof(x_eof), .x_fidx(x_fidx),
            .err_cnt(verr), .chk_cnt(vchk), .eof_cnt(veof));

    // ---------------- DUT chain
    wire        s_de, s_hit, s_sof, s_eol, s_eof;
    wire [11:0] s_x, s_y;

    color_segment seg (
        .clk(clk), .rst_n(rst_n),
        .in_de(a_de), .in_rgb(a_rgb), .in_x(a_x), .in_y(a_y),
        .in_sof(a_sof), .in_eol(a_eol), .in_eof(a_eof),
        .out_de(s_de), .out_hit(s_hit), .out_rgb(), .out_mask(),
        .out_x(s_x), .out_y(s_y), .out_sof(s_sof), .out_eol(s_eol), .out_eof(s_eof)
    );

    wire        frame_done, frame_abort, res_valid, res_sat;
    wire [15:0] res_frame_id;
    wire [19:0] res_count;
    wire [11:0] res_xmin, res_xmax, res_ymin, res_ymax, res_cx, res_cy;

    frame_bbox bb (
        .clk(clk), .rst_n(rst_n),
        .in_de(s_de), .in_hit(s_hit), .in_x(s_x), .in_y(s_y),
        .in_sof(s_sof), .in_eol(s_eol), .in_eof(s_eof),
        .frame_done(frame_done), .frame_abort(frame_abort),
        .res_frame_id(res_frame_id), .res_valid(res_valid), .res_count(res_count), .res_sat(res_sat),
        .res_xmin(res_xmin), .res_xmax(res_xmax), .res_ymin(res_ymin), .res_ymax(res_ymax),
        .res_cx(res_cx), .res_cy(res_cy)
    );

    // ---------------- expected result of frame k, from the rectangle definition only
    function [67:0] truth;              // {count[67:48] xa[47:36] xb[35:24] ya[23:12] yb[11:0]}
        input integer k;
        integer m, xa, xb, ya, yb;
        reg [19:0] cnt20;
        begin
            m = k % 3;
            if (m == 0)      begin xa = 100; xb = 299;  ya = 50;  yb = 149; end
            else if (m == 1) begin xa = 900; xb = 1000; ya = 600; yb = 700; end
            else             begin xa = 0;   xb = 15;   ya = 0;   yb = 15;  end
            cnt20 = (xb - xa + 1) * (yb - ya + 1);
            truth = {cnt20, xa[11:0], xb[11:0], ya[11:0], yb[11:0]};
        end
    endfunction

    // expected frame_done: oracle EOF (aligned with adapter outputs) delayed by 3 clocks
    reg        d1, d2, d3;
    reg [7:0]  k1, k2;
    reg        cur_valid;
    reg [15:0] cur_id;
    reg [19:0] cur_count;
    reg [11:0] cur_xmin, cur_xmax, cur_ymin, cur_ymax, cur_cx, cur_cy;
    reg [67:0] tr;
    integer    kk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d1 <= 1'b0; d2 <= 1'b0; d3 <= 1'b0; k1 <= 8'd0; k2 <= 8'd0;
            cur_valid <= 1'b0; cur_id <= 16'd0; cur_count <= 20'd0;
            cur_xmin <= 12'd0; cur_xmax <= 12'd0; cur_ymin <= 12'd0; cur_ymax <= 12'd0; cur_cx <= 12'd0; cur_cy <= 12'd0;
        end
        else begin
            d1 <= x_eof;  k1 <= x_fidx;
            d2 <= d1;     k2 <= k1;
            d3 <= d2;
            if (d2) begin               // becomes visible together with d3 / frame_done
                kk = k2;
                tr = truth(kk);
                cur_valid <= 1'b1;
                cur_id    <= kk + 1;
                cur_count <= tr[67:48];
                cur_xmin  <= tr[47:36];
                cur_xmax  <= tr[35:24];
                cur_ymin  <= tr[23:12];
                cur_ymax  <= tr[11:0];
                cur_cx    <= (tr[47:36] + tr[35:24]) / 2;
                cur_cy    <= (tr[23:12] + tr[11:0]) / 2;
            end
        end
    end

    // ---------------- checks
    integer err_cnt;
    integer chk_cnt;
    integer done_cnt;
    integer guard;
    integer total_err;

    task bad;
        input [159:0] what;
        input [31:0]  exp_v;
        input [31:0]  act_v;
        begin
            err_cnt = err_cnt + 1;
            if (err_cnt <= 12)
                $display("MISMATCH[chain] t=%0t %0s expected=%0d actual=%0d (frame %0d)", $time, what, exp_v, act_v, k2);
            if (err_cnt >= 100) begin
                $display("TB_RESULT: FAIL tb_pos_chain aborted after %0d mismatches", err_cnt);
                $finish;
            end
        end
    endtask

    always @(negedge clk) begin
        if (check_en) begin
            chk_cnt = chk_cnt + 1;
            if (frame_done) done_cnt = done_cnt + 1;
            if (frame_done   !== d3)         bad("frame_done",   d3,        frame_done);
            if (frame_abort  !== 1'b0)       bad("frame_abort",  0,         frame_abort);
            if (res_sat      !== 1'b0)       bad("res_sat",      0,         res_sat);
            if (res_frame_id !== cur_id)     bad("res_frame_id", cur_id,    res_frame_id);
            if (res_valid    !== cur_valid)  bad("res_valid",    cur_valid, res_valid);
            if (res_count    !== cur_count)  bad("res_count",    cur_count, res_count);
            if (res_xmin     !== cur_xmin)   bad("res_xmin",     cur_xmin,  res_xmin);
            if (res_xmax     !== cur_xmax)   bad("res_xmax",     cur_xmax,  res_xmax);
            if (res_ymin     !== cur_ymin)   bad("res_ymin",     cur_ymin,  res_ymin);
            if (res_ymax     !== cur_ymax)   bad("res_ymax",     cur_ymax,  res_ymax);
            if (res_cx       !== cur_cx)     bad("res_cx",       cur_cx,    res_cx);
            if (res_cy       !== cur_cy)     bad("res_cy",       cur_cy,    res_cy);
        end
    end

    // ---------------- main
    initial begin
        err_cnt = 0; chk_cnt = 0; done_cnt = 0; guard = 0;
        check_en = 1'b0;
        rst_n    = 1'b0;
        $display("tb_pos_chain: uivtc 1280x720 (1650x750) -> video_pos_adapter(D=2) -> color_segment -> frame_bbox, %0d frames", NFR);
        repeat (4) @(negedge clk);
        #2 rst_n = 1'b1;
        repeat (60) @(negedge clk);
        check_en = 1'b1;

        while (!(veof >= NFR && done_cnt >= NFR) && guard < 12000000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        repeat (10) @(negedge clk);
        check_en = 1'b0;

        total_err = err_cnt + verr;
        $display("tb_pos_chain: clocks=%0d expected EOFs=%0d frame_done pulses=%0d chain errors=%0d adapter/oracle errors=%0d",
                 chk_cnt, veof, done_cnt, err_cnt, verr);
        $display("tb_pos_chain: last result id=%0d valid=%b count=%0d box x %0d..%0d y %0d..%0d centre (%0d,%0d)",
                 res_frame_id, res_valid, res_count, res_xmin, res_xmax, res_ymin, res_ymax, res_cx, res_cy);
        if (guard >= 12000000 || done_cnt < NFR || veof < NFR || vchk < 4000000) begin
            total_err = total_err + 1;
            $display("COVERAGE too low (or timeout): test would be vacuous");
        end
        if (total_err == 0) $display("TB_RESULT: PASS tb_pos_chain");
        else                $display("TB_RESULT: FAIL tb_pos_chain errors=%0d", total_err);
        $finish;
    end

endmodule
