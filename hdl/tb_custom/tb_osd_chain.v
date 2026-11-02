// tb_osd_chain.v - end-to-end chain including the OSD, at the real 1280x720 timing of the baseline
//
//   unmodified lab1 uivtc.v (1650x750) -> video_pos_adapter (colour lags de by 2) --+--> osd_overlay --> checked
//                                                                                    |        ^
//                                                                                    +--> color_segment -> frame_bbox -- res_* (controls)
//
// The video is the synthetic image of tb_vtc_chk.v (IMAGE_MODE 1: one 0xFF2010 rectangle per frame,
// k mod 3, plus a green block and an R=79 block that must not be detected). The OSD controls come
// straight from frame_bbox: tgt_valid=res_valid, box = res_x/ymin/max, centre = res_cx/cy, count = res_count;
// flags 11111, mode 0, line_x 640, cross 3 are constants.
//
// What is checked, for 4 consecutive frames (every pixel of every frame):
//   - the OSD output raster is complete and in order (1280x720, x/y as expected, no extra pixels);
//   - out_rgb equals the independent Python golden frame (gen_osd_golden.py --chain files
//     chain_exp_<k>.hex, built from the synthetic image of frame k and the bbox result of frame k-1):
//     frame 0 has no box and shows '----' (nothing detected yet), frames 1..3 show the box, crosshair, centre,
//     area of the PREVIOUS frame's rectangle -> the documented one-frame lag of the statistics overlay.
// The background image is regenerated here by the same formula as tb_vtc_chk.v (independent copy).
//
// Build/run (Icarus Verilog), from F:\fpga_s2\tb_custom (python gen_osd_golden.py first):
//   iverilog -g2005 -Wall -o sim_osdchain.vvp tb_osd_chain.v tb_vtc_chk.v ../rtl_custom/video_pos_adapter.v ../rtl_custom/color_segment.v \
//       ../rtl_custom/frame_bbox.v ../rtl_custom/osd_overlay.v ../rtl_custom/osd_bin2bcd.v ../rtl_custom/osd_font_rom.v \
//       ../rtl_custom/osd_logo_rom.v ../lab1/user_source/hdl_source/vtc/uivtc.v
//   vvp sim_osdchain.vvp
// Final line: "TB_RESULT: PASS ..." or "TB_RESULT: FAIL ...".

`timescale 1ns / 1ps

module tb_osd_chain;

    localparam integer NFR = 4;
    localparam integer W   = 1280;
    localparam integer H   = 720;

    reg clk;
    reg rst_n;
    reg check_en;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---------------- timing generator + adapter (+ its own checker)
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

    // ---------------- statistics path
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

    // ---------------- display path
    wire        o_de, o_sof, o_eol, o_eof;
    wire [23:0] o_rgb;
    wire [11:0] o_x, o_y;
    osd_overlay osd (
        .clk(clk), .rst_n(rst_n),
        .in_de(a_de), .in_rgb(a_rgb), .in_x(a_x), .in_y(a_y), .in_sof(a_sof), .in_eol(a_eol), .in_eof(a_eof),
        .cfg_flags(5'b11111), .cfg_mode(2'd0), .tgt_valid(res_valid),
        .tgt_xmin(res_xmin), .tgt_xmax(res_xmax), .tgt_ymin(res_ymin), .tgt_ymax(res_ymax),
        .tgt_cx(res_cx), .tgt_cy(res_cy), .tgt_count(res_count), .line_x(12'd640), .cross_cnt(16'd3),
        .out_de(o_de), .out_rgb(o_rgb), .out_x(o_x), .out_y(o_y),
        .out_sof(o_sof), .out_eol(o_eol), .out_eof(o_eof)
    );

    // ---------------- expected background (same image as tb_vtc_chk.v IMAGE_MODE 1, independent copy)
    function [23:0] imgf;
        input integer k;
        input integer x;
        input integer y;
        integer m;
        begin
            m = k % 3;
            imgf = 24'h404040;
            if      (m == 0 && x >= 100 && x <= 299  && y >= 50  && y <= 149) imgf = 24'hFF2010;
            else if (m == 1 && x >= 900 && x <= 1000 && y >= 600 && y <= 700) imgf = 24'hFF2010;
            else if (m == 2 && x >= 0   && x <= 15   && y >= 0   && y <= 15)  imgf = 24'hFF2010;
            else if (x >= 400 && x <= 800 && y >= 300 && y <= 400)            imgf = 24'h10FF20;
            else if (x >= 200 && x <= 210 && y >= 300 && y <= 310)            imgf = 24'h4F2020;
        end
    endfunction

    // ---------------- golden sparse lists and the output checker
    reg [8*256-1:0] gdir;
    reg [8*256-1:0] fname;
    reg [47:0]      sp [0:131071];
    integer         spi;
    integer         errors;
    integer         compared;
    integer         ndiff;
    integer         frm;            // frame being received at the OSD output
    integer         ex_x, ex_y;     // next expected raster position
    integer         idx;
    integer         total_err;
    integer         guard;
    reg [23:0]      e;

    task bad;
        input [127:0] what;
        input [31:0]  exp_v;
        input [31:0]  act_v;
        begin
            errors = errors + 1;
            if (errors <= 10)
                $display("MISMATCH[osd_chain] t=%0t frame=%0d %0s expected=%h actual=%h (x=%0d y=%0d)",
                         $time, frm, what, exp_v, act_v, o_x, o_y);
            if (errors >= 100) begin
                $display("TB_RESULT: FAIL tb_osd_chain aborted after %0d mismatches", errors);
                $finish;
            end
        end
    endtask

    always @(negedge clk) begin
        if (check_en && o_de === 1'b1) begin
            compared = compared + 1;
            // raster order and position
            if (o_x !== ex_x[11:0] || o_y !== ex_y[11:0]) bad("raster_position", {ex_y[15:0], ex_x[15:0]}, {4'd0, o_y, 4'd0, o_x});
            idx = ex_y * W + ex_x;
            if (idx == 0) begin
                $sformat(fname, "%0s/chain_exp_%0d.hex", gdir, frm);
                $readmemh(fname, sp);
                spi = 0;
            end
            if (sp[spi][47:24] == idx) begin
                e = sp[spi][23:0];
                spi = spi + 1;
                ndiff = ndiff + 1;
            end
            else begin
                e = imgf(frm, ex_x, ex_y);
            end
            if (o_rgb !== e) bad("out_rgb", e, o_rgb);
            if (ex_x == W - 1) begin
                ex_x = 0;
                if (ex_y == H - 1) begin ex_y = 0; frm = frm + 1; end
                else                ex_y = ex_y + 1;
            end
            else ex_x = ex_x + 1;
        end
        else if (check_en && o_de !== 1'b0) begin
            bad("out_de_unknown", 0, o_de);
        end
        else if (check_en) begin
            // blanking: everything zero
            if (o_rgb !== 24'd0 || o_sof !== 1'b0 || o_eol !== 1'b0 || o_eof !== 1'b0) bad("blanking_not_clean", 0, o_rgb);
        end
    end

    initial begin
        errors = 0; compared = 0; ndiff = 0; frm = 0; ex_x = 0; ex_y = 0; guard = 0; spi = 0;
        check_en = 1'b0;
        rst_n    = 1'b0;
        if (!$value$plusargs("GOLDEN=%s", gdir)) gdir = "osd_assets/golden";
        $display("tb_osd_chain: uivtc 1280x720 -> adapter(D=2) -> {color_segment -> frame_bbox, osd_overlay}, %0d frames, golden '%0s'", NFR, gdir);
        repeat (4) @(negedge clk);
        #2 rst_n = 1'b1;
        repeat (60) @(negedge clk);
        check_en = 1'b1;

        while (frm < NFR && guard < 12000000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        repeat (10) @(negedge clk);
        check_en = 1'b0;

        total_err = errors + verr;
        $display("tb_osd_chain: clocks=%0d OSD pixels compared=%0d (expected %0d) golden-overlay pixels=%0d errors=%0d adapter/oracle errors=%0d",
                 vchk, compared, NFR * W * H, ndiff, errors, verr);
        if (guard >= 12000000 || compared != NFR * W * H || ndiff < 380000) begin
            total_err = total_err + 1;
            $display("COVERAGE too low (or timeout / wrong pixel count)");
        end
        if (total_err == 0) $display("TB_RESULT: PASS tb_osd_chain");
        else                $display("TB_RESULT: FAIL tb_osd_chain errors=%0d", total_err);
        $finish;
    end

endmodule
