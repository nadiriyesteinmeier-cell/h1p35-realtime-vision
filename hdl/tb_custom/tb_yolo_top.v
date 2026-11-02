// tb_yolo_top.v - system-level test of the detector: real 1280 x 720 video timing in, boxes out (and the dataset dump over the UART)
//
// +CASE=<prefix written by tools/yolo/train/export_board.py> (files <prefix>_frame.hex: 921600 RGB pixels of the test frame, <prefix>_boxes.hex: the boxes the integer reference
// (qref + decode_ref) finds in it). The design under test is yolo_top with the generated model ROMs / yolo_model_cfg of that case.
//   * a timing generator produces the HDMI 720p60 raster of the board (1650 x 750 clocks, de 1280 x 720, user on the first pixel, last on the last pixel of every line,
//     vsync lines 725..729); the colour follows de by 2 clocks (the baseline SKEW) - exactly the stream yolo_top samples on the board;
//   * part 1: mode 0 (the network runs in every mode except 3): wait for two results and compare nbox and every box with the reference (bit-exact);
//   * part 2: KEY3 + KEY4 chord three times -> mode 3 (dataset capture); the UART is decoded here and the received frame (header, 27648 image bytes, checksum) is compared
//     with the int8 image the network sees (frame pixel - 128);
//   * part 3: a fourth chord -> mode 4 (white-balance page): UART released, one more result compared bit-exactly; a fifth chord -> mode 0.
// Run: python tools/yolo/run_top_test.py   (compiles with KEY_DEB = 16 and CLKDIV = 8 to keep the simulation short)
// Final line: TB_RESULT: PASS tb_yolo_top <case> boxes=<n> results=<k> dump_bytes=<b> clocks=<c>   or   FAIL

`timescale 1ns / 1ps

module tb_yolo_top;

    parameter integer CLKDIV = 8;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #6.734 clk = ~clk;

    // ---------------- raster
    reg [10:0] hc, vc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin hc <= 11'd0; vc <= 11'd0; end
        else if (hc == 11'd1649) begin hc <= 11'd0; vc <= (vc == 11'd749) ? 11'd0 : vc + 11'd1; end
        else hc <= hc + 11'd1;
    end
    wire de   = (hc < 11'd1280) && (vc < 11'd720);
    wire user = de && (hc == 11'd0) && (vc == 11'd0);
    wire last = de && (hc == 11'd1279);
    wire vs   = (vc >= 11'd725) && (vc < 11'd730);
    reg [23:0] frame [0:921599];
    reg [23:0] rgb1, rgb2;
    always @(posedge clk) begin
        rgb1 <= de ? frame[vc * 1280 + hc] : 24'd0;
        rgb2 <= rgb1;
    end

    reg  [3:0]   key_n;
    wire [2:0]   mode;
    wire [3:0]   nbox;
    wire [479:0] boxes;
    wire [7:0]   det_rate, lat_ms;
    wire [15:0]  res_frame, cap_count;
    wire         uart_tx, uart_own;
    wire [2:0]   phase;
    yolo_top #(.KEY_DEB(16), .CLKDIV(CLKDIV)) dut (
        .clk(clk), .rst_n(rst_n), .vid_de(de), .vid_user(user), .vid_last(last), .vid_rgb(rgb2), .vid_vs(vs), .key_n(key_n),
        .mode(mode), .nbox(nbox), .boxes(boxes), .det_rate(det_rate), .lat_ms(lat_ms), .res_frame(res_frame), .cap_count(cap_count),
        .uart_tx(uart_tx), .uart_own(uart_own), .phase(phase)
    );

    // ---------------- UART receiver (8N1, CLKDIV clocks per bit)
    reg [7:0] rx_byte;
    reg       rx_strobe;
    integer   rx_bit, rx_cnt;
    reg       rx_busy;
    reg [9:0] rx_sh;
    initial begin rx_busy = 1'b0; rx_strobe = 1'b0; end
    always @(posedge clk) begin
        rx_strobe <= 1'b0;
        if (!rx_busy) begin
            if (rst_n && uart_tx == 1'b0) begin rx_busy <= 1'b1; rx_cnt = -(CLKDIV / 2); rx_bit = 0; end   // first sample 1.5 bit times after the falling edge = middle of data bit 0
        end
        else begin
            rx_cnt = rx_cnt + 1;
            if (rx_cnt == CLKDIV) begin
                rx_cnt = 0;
                rx_bit = rx_bit + 1;
                if (rx_bit >= 1 && rx_bit <= 8) rx_byte[rx_bit - 1] <= uart_tx;
                if (rx_bit == 9) begin rx_busy <= 1'b0; rx_strobe <= 1'b1; end
            end
        end
    end

    // ---------------- expected data
    reg [59:0] exp_box [0:7];
    integer    n_exp;
    reg [8*200-1:0] prefix;
    reg [8*220-1:0] fn;
    integer fd, r, i, mism, results, cyc, dump_n, k;
    reg [59:0] w;
    reg [7:0]  dump [0:27700];
    reg [7:0]  csum, expb;

    // count the dump bytes once mode 3 is active
    reg dump_on;
    initial dump_on = 1'b0;
    always @(posedge clk) if (rx_strobe && dump_on && dump_n < 27700) begin dump[dump_n] = rx_byte; dump_n = dump_n + 1; end

    task check_boxes;
        begin
            if (nbox !== n_exp[3:0]) begin mism = mism + 1; $display("MISMATCH %0s: %0d boxes, expected %0d", prefix, nbox, n_exp); end
            for (i = 0; i < n_exp; i = i + 1)
                if (boxes[60*i +: 60] !== exp_box[i]) begin
                    mism = mism + 1;
                    if (mism <= 10) $display("MISMATCH %0s box %0d: got %015x expected %015x", prefix, i, boxes[60*i +: 60], exp_box[i]);
                end
        end
    endtask

    task chord;
        begin
            @(negedge clk); key_n = 4'b0011; repeat (60) @(negedge clk); key_n = 4'b1111; repeat (60) @(negedge clk);
        end
    endtask

    initial begin
        if (!$value$plusargs("CASE=%s", prefix)) begin $display("TB_RESULT: FAIL tb_yolo_top (no +CASE=)"); $finish; end
        $sformat(fn, "%0s_frame.hex", prefix); $readmemh(fn, frame);
        $sformat(fn, "%0s_boxes.hex", prefix);
        fd = $fopen(fn, "r");
        if (fd == 0) begin $display("TB_RESULT: FAIL tb_yolo_top cannot open %0s", fn); $finish; end
        r = $fscanf(fd, "%d", n_exp);
        for (i = 0; i < n_exp; i = i + 1) begin r = $fscanf(fd, "%h", w); exp_box[i] = w; end
        $fclose(fd);
        mism = 0; results = 0; cyc = 0; dump_n = 0;
        key_n = 4'b1111;
        rst_n = 1'b0;
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        // ---- part 1: two results in mode 0
        while (results < 2 && cyc < 8000000) begin
            @(negedge clk); cyc = cyc + 1;
            if (dut.fs == 3'd4 && dut.li == 4'd8 && dut.lw == 2'd2) begin
                repeat (3) @(negedge clk);
                results = results + 1;
                check_boxes;
                $display("RESULT %0d at clock %0d: frame %0d, %0d boxes, latency %0d ms", results, cyc, res_frame, nbox, lat_ms);
            end
        end
        if (results < 2) begin mism = mism + 1; $display("MISMATCH %0s: only %0d results within %0d clocks", prefix, results, cyc); end
        if (mode !== 3'd0 || uart_own !== 1'b0) begin mism = mism + 1; $display("MISMATCH %0s: mode %0d / uart_own %0d after reset", prefix, mode, uart_own); end
        // ---- part 2: three chords -> mode 3, receive one dataset frame
        chord; chord; chord;
        if (mode !== 3'd3) begin mism = mism + 1; $display("MISMATCH %0s: mode %0d after three chords, expected 3", prefix, mode); end
        // wait for the start of a dump (the scheduler finishes the inference that may be running, then captures a frame for the dump)
        while (dut.us != 2'd2 && cyc < 16000000) begin @(negedge clk); cyc = cyc + 1; end
        dump_on = 1'b1; dump_n = 0;
        while (dut.us == 2'd2 && cyc < 24000000) begin @(negedge clk); cyc = cyc + 1; end
        repeat (CLKDIV * 12) @(negedge clk);
        if (dump_n != 27654) begin mism = mism + 1; $display("MISMATCH %0s: %0d dump bytes, expected 27654", prefix, dump_n); end
        else begin
            if (dump[0] !== 8'hA5 || dump[1] !== 8'h5A || dump[2] !== "I") begin mism = mism + 1; $display("MISMATCH %0s: dump header %02x %02x %02x", prefix, dump[0], dump[1], dump[2]); end
            csum = 8'd0;
            for (k = 0; k < 27648; k = k + 1) begin
                // byte k = row k / 384, column (k % 384) / 3, channel k % 3 of the 128 x 72 image; the test frame is constant in every 10 x 10 block
                w = frame[((k / 384) * 10) * 1280 + ((k % 384) / 3) * 10];
                expb = ((k % 3) == 0 ? w[23:16] : (k % 3) == 1 ? w[15:8] : w[7:0]) ^ 8'h80;
                csum = csum + dump[5 + k];
                if (dump[5 + k] !== expb) begin
                    mism = mism + 1;
                    if (mism <= 10) $display("MISMATCH %0s dump byte %0d: got %02x expected %02x", prefix, k, dump[5 + k], expb);
                end
            end
            if (dump[5 + 27648] !== csum) begin mism = mism + 1; $display("MISMATCH %0s: checksum %02x, expected %02x", prefix, dump[5 + 27648], csum); end
        end
        // ---- part 3: fourth chord -> mode 4 (white-balance page: UART released, the network runs again), fifth -> mode 0
        chord;
        if (mode !== 3'd4 || uart_own !== 1'b0) begin mism = mism + 1; $display("MISMATCH %0s: mode %0d / uart_own %0d after four chords, expected 4 / 0", prefix, mode, uart_own); end
        results = 0;
        while (results < 1 && cyc < 34000000) begin
            @(negedge clk); cyc = cyc + 1;
            if (dut.fs == 3'd4 && dut.li == 4'd8 && dut.lw == 2'd2) begin
                repeat (3) @(negedge clk);
                results = results + 1;
                check_boxes;
                $display("RESULT in mode 4 at clock %0d: frame %0d, %0d boxes", cyc, res_frame, nbox);
            end
        end
        if (results < 1) begin mism = mism + 1; $display("MISMATCH %0s: no result in mode 4", prefix); end
        chord;
        if (mode !== 3'd0 || uart_own !== 1'b0) begin mism = mism + 1; $display("MISMATCH %0s: mode %0d after five chords, expected 0", prefix, mode); end
        if (mism == 0) $display("TB_RESULT: PASS tb_yolo_top %0s boxes=%0d results=%0d dump_bytes=%0d clocks=%0d", prefix, n_exp, results, dump_n, cyc);
        else           $display("TB_RESULT: FAIL tb_yolo_top %0s mismatches=%0d", prefix, mism);
        $finish;
    end

endmodule
