`timescale 1ns/1ps
// tb_lat_probe.v - the four modules of lat_probe.v
//   A: us_gray_counter (50 MHz) -> gray_sync in a 74.25 MHz domain: the synchronised value is never more than 1 us behind the source
//      counter and never decreases (checked on every destination clock for 2.5 ms, including a 20-bit wrap forced by the test)
//   B: ts_stamp: frames with tuser before the first valid word (gap), with tuser on the first valid word, and with valid gaps; only the
//      first valid word of a frame is stamped (pixels 0,1,4 = A + time at tuser, 2,3 = 5A + frame number, low byte kept); fc_gray
//   C: lat_meter (HOLD 2, WIN 4): latencies, frames between, a corrupted stamp (ignored), a capped value (> 99.999 ms), the window maximum
module tb_lat_probe;
    integer errors = 0;

    // ---------------------------------------------------------------- A
    reg rclk = 1'b0, pclk = 1'b0;
    always #10 rclk = ~rclk;
    always #6.734 pclk = ~pclk;
    reg rst_n = 1'b0;
    wire [19:0] g;
    wire [19:0] tsync;
    us_gray_counter #(.DIV(50), .W(20)) u_cnt (.clk(rclk), .rst_n(rst_n), .gray(g));
    gray_sync #(.W(20)) u_sync (.clk(pclk), .rst_n(rst_n), .gray_in(g), .bin(tsync));
    reg  [19:0] last;
    reg  [19:0] a_t0;
    reg         a_on = 1'b0;
    integer na = 0;
    always @(posedge pclk) if (a_on) begin
        na = na + 1;
        if (((u_cnt.bin - tsync) & 20'hFFFFF) > 20'd1) begin errors = errors + 1; if (errors < 10) $display("MISMATCH A: source %0d synced %0d", u_cnt.bin, tsync); end
        if (((tsync - last) & 20'hFFFFF) > 20'd1) begin errors = errors + 1; if (errors < 10) $display("MISMATCH A: step %0d -> %0d", last, tsync); end
        last = tsync;
    end

    // ---------------------------------------------------------------- B
    reg cclk = 1'b0;
    always #4 cclk = ~cclk;
    reg  [19:0]  bts = 20'd0;
    reg          tuser = 1'b0, tvalid = 1'b0;
    reg  [127:0] din = 128'd0;
    wire [127:0] dout;
    wire [15:0]  fcg;
    ts_stamp u_st (.clk(cclk), .rst_n(rst_n), .ts(bts), .tuser(tuser), .tvalid(tvalid), .din(din), .dout(dout), .fc_gray(fcg));
    always @(posedge cclk) bts <= bts + 20'd3;
    reg  [19:0]  ts_at;
    integer fr, w, nst;
    task check_word(input integer frame_no, input integer first);
        reg [127:0] e;
        begin
            if (first) e = {4'hA, ts_at, 4'hA, ts_at, 8'h5A, frame_no[15:0], 8'h5A, frame_no[15:0], 4'hA, ts_at, din[7:0]};
            else       e = din;
            if (dout !== e) begin errors = errors + 1; $display("MISMATCH B: frame %0d first %0d dout %h expected %h", frame_no, first, dout, e); end
        end
    endtask
    // one frame of NW words; mode 0: tuser 3 clocks before the first valid word, 1: on it, 2: on it and every 2nd clock idle
    task cam_frame(input integer frame_no, input integer mode, input integer nw);
        integer k;
        begin
            @(negedge cclk);
            if (mode == 0) begin
                tuser = 1'b1; ts_at = bts; @(negedge cclk); tuser = 1'b0; repeat (2) @(negedge cclk);
            end
            for (k = 0; k < nw; k = k + 1) begin
                tvalid = 1'b1; din = {$random, $random, $random, $random};
                if (k == 0 && mode != 0) begin tuser = 1'b1; ts_at = bts; end
                #1 check_word(frame_no, k == 0);
                @(negedge cclk); tuser = 1'b0; tvalid = 1'b0;
                if (mode == 2) @(negedge cclk);
            end
            repeat (20) @(negedge cclk);
            if (fcg !== (frame_no[15:0] ^ (frame_no[15:0] >> 1))) begin errors = errors + 1; $display("MISMATCH B: fc_gray %h after frame %0d", fcg, frame_no); end
        end
    endtask

    // ---------------------------------------------------------------- C
    reg         de = 1'b0;
    reg  [11:0] x = 12'd0, y = 12'd0;
    reg  [23:0] rgb = 24'd0;
    reg  [19:0] lts = 20'd0;
    reg  [15:0] lfc = 16'd0;
    wire        lval;
    wire [16:0] lus, lmax;
    wire [3:0]  lfr;
    lat_meter #(.HOLD(2), .WIN(4)) u_lm (.clk(pclk), .rst_n(rst_n), .de(de), .x(x), .y(y), .rgb(rgb), .ts(lts), .fc_cam(lfc),
                                         .valid(lval), .lat_us(lus), .max_us(lmax), .lat_fr(lfr));
    integer m_nh = 0, m_nw = 0, m_wmax = 0, m_lat = 0, m_max = 0, m_fr = 0, m_val = 0;
    task disp_frame(input [19:0] s_ts, input [15:0] s_fc, input [19:0] now_ts, input [15:0] now_fc, input integer corrupt);
        integer k, d, fd;
        reg ok;
        begin
            @(negedge pclk);
            for (k = 0; k < 8; k = k + 1) begin
                de = 1'b1; x = k; y = 12'd0;
                rgb = (k == 0 || k == 1) ? {4'hA, s_ts} : (k == 2 || k == 3) ? {8'h5A, s_fc} : 24'h123456;
                if (corrupt == 1 && k == 1) rgb = rgb ^ 24'h000100;          // pixel 1 differs from pixel 0
                if (corrupt == 2 && k == 3) rgb = rgb ^ 24'h000010;          // pixel 3 differs from pixel 2
                lts = (k == 0) ? now_ts : now_ts + k;       // the time keeps running; pixel 0 is the reference
                lfc = now_fc;
                @(negedge pclk);
            end
            de = 1'b0; x = 12'd0; repeat (4) @(negedge pclk);
            // model
            ok = !corrupt;
            d = (now_ts - s_ts) & 20'hFFFFF;
            if (d > 99999) d = 99999;
            fd = (now_fc - s_fc) & 16'hFFFF;
            if (fd > 9) fd = 9;
            m_val = ok;
            if (ok) begin
                if (d > m_wmax) m_wmax = d;
                if (m_nh == 1) begin m_nh = 0; m_lat = d; m_fr = fd; end else m_nh = m_nh + 1;
                if (m_nw == 3) begin m_nw = 0; m_max = m_wmax; m_wmax = 0; end else m_nw = m_nw + 1;
            end
            if (lval !== m_val || lus !== m_lat || lmax !== m_max || lfr !== m_fr) begin
                errors = errors + 1;
                $display("MISMATCH C: valid %b lat %0d max %0d fr %0d expected %0d %0d %0d %0d", lval, lus, lmax, lfr, m_val, m_lat, m_max, m_fr);
            end
            else $display("C: frame stamp %0d now %0d -> valid %b lat %0d us max %0d us frames %0d", s_ts, now_ts, lval, lus, lmax, lfr);
        end
    endtask

    initial begin
        repeat (3) @(posedge rclk);
        rst_n = 1'b1;
        // A
        repeat (3) @(posedge pclk);
        last = 20'd0; a_on = 1'b1;
        a_t0 = u_cnt.bin;
        #(1_000_000);
        a_on = 1'b0;
        if (((u_cnt.bin - a_t0) & 20'hFFFFF) < 20'd999 || ((u_cnt.bin - a_t0) & 20'hFFFFF) > 20'd1001) begin   // 1 ms = 1000 us (rate of the time base)
            errors = errors + 1; $display("MISMATCH A: %0d us counted in 1 ms", (u_cnt.bin - a_t0) & 20'hFFFFF);
        end
        @(negedge rclk); force u_cnt.bin = 20'hFFFF0; @(negedge rclk); release u_cnt.bin;
        repeat (10) @(posedge pclk); last = tsync; a_on = 1'b1;          // after the forced jump has passed the synchroniser
        #(1_500_000);
        a_on = 1'b0;
        $display("A: %0d destination clocks checked, final value %0d", na, tsync);
        // B
        nst = 0;
        cam_frame(1, 0, 6);
        cam_frame(2, 1, 5);
        cam_frame(3, 2, 7);
        cam_frame(4, 0, 1);
        cam_frame(5, 1, 3);
        $display("B: 5 frames checked");
        // C
        disp_frame(20'd1000,   16'd1, 20'd17700,  16'd2, 0);    // 16.7 ms, 1 frame
        disp_frame(20'd17700,  16'd2, 20'd51000,  16'd4, 0);    // 33.3 ms, 2 frames
        disp_frame(20'd51000,  16'd4, 20'd67000,  16'd5, 1);    // corrupted: ignored
        disp_frame(20'd67000,  16'd5, 20'd84500,  16'd6, 0);
        disp_frame(20'd84500,  16'd6, 20'd101500, 16'd7, 0);    // end of a window
        disp_frame(20'hFFF00,  16'hFFFE, 20'd16000, 16'h0001, 0); // across the 20-bit / 16-bit wrap
        disp_frame(20'd1000,   16'd10, 20'd300000, 16'd40, 0);  // 299 ms -> capped to 99999, frames capped to 9
        disp_frame(20'd300000, 16'd40, 20'd316700, 16'd41, 0);
        disp_frame(20'd316700, 16'd41, 20'd333400, 16'd42, 0);
        disp_frame(20'd333400, 16'd42, 20'd350100, 16'd43, 0);
        disp_frame(20'd350100, 16'd43, 20'd366800, 16'd44, 2);    // corrupted frame number: ignored
        disp_frame(20'd350100, 16'd43, 20'd366800, 16'd44, 0);
        disp_frame(20'd383500, 16'd45, 20'd400200, 16'd46, 0);
        disp_frame(20'd400200, 16'd46, 20'd440200, 16'd48, 0);    // the last frame of a window is its largest (40 ms)
        if (errors == 0) $display("TB_RESULT: PASS tb_lat_probe");
        else             $display("TB_RESULT: FAIL tb_lat_probe errors=%0d", errors);
        $finish;
    end
endmodule
