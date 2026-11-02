// tb_yolo_box.v - bit-exact comparison of rtl_custom/yolo_box_down.v with the integer reference (tools/yolo/box_ref.py)
//
// Compile-time parameters (set by tools/yolo/run_box_tests.py from the case's _cfg.txt): IN_W IN_H BOX NET_W PAD_TOP RM RA RS FRAMES ARMED GAP.
// +CASE=<prefix of the files written by tools/yolo/gen_box_vectors.py>. The testbench streams FRAMES frames (pixel per clock, random bubbles of probability GAP / 256 inside
// the lines, a line gap after every line and a long gap after every frame), arms the frames selected by ARMED, collects the byte writes into a memory image pre-filled with
// 0x55, and after frame_done compares the WHOLE image with the expected one (a stray or missing write is a mismatch). Frames that are not armed must cause no write, no
// `active` and no frame_done; an arm pulse in the middle of a frame (LATE) must not capture that frame, only the next one. Final line: TB_RESULT: PASS tb_yolo_box <case> frames=<n> captured=<k> writes=<w>   or   FAIL

`timescale 1ns / 1ps

module tb_yolo_box;

    parameter integer IN_W = 40;
    parameter integer IN_H = 30;
    parameter integer BOX = 10;
    parameter integer NET_W = 4;
    parameter integer PAD_TOP = 2;
    parameter integer RM = 5243;
    parameter integer RA = 262144;
    parameter integer RS = 19;
    parameter integer FRAMES = 3;
    parameter integer ARMED = 5;
    parameter integer GAP = 0;
    parameter integer TRUNC = 0;                      // bit f: frame f is armed but only half of its lines are sent (a truncated frame: no frame_done, no compare)
    parameter integer LATE = 0;                       // bit f: the arm pulse for frame f is sent in the middle of frame f - 1

    localparam integer NET_H = IN_H / BOX + 2 * PAD_TOP;
    localparam integer SIZE = (NET_H + 2) * (NET_W + 2) * 3;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    reg         arm, pix_valid, pix_sof;
    reg  [7:0]  pr, pg, pb;
    wire        active, we, frame_done;
    wire [19:0] waddr;
    wire [7:0]  wdata;

    yolo_box_down #(.IN_W(IN_W), .IN_H(IN_H), .BOX(BOX), .NET_W(NET_W), .PAD_TOP(PAD_TOP), .RM(RM), .RA(RA), .RS(RS)) dut (
        .clk(clk), .rst_n(rst_n), .arm(arm), .active(active), .pix_valid(pix_valid), .pix_sof(pix_sof), .pr(pr), .pg(pg), .pb(pb),
        .we(we), .waddr(waddr), .wdata(wdata), .frame_done(frame_done)
    );

    reg [23:0] frames_mem [0:IN_W*IN_H*FRAMES-1];
    reg [7:0]  exp_mem [0:SIZE*FRAMES-1];
    reg [7:0]  img [0:SIZE-1];
    reg [7:0]  wcnt [0:SIZE-1];
    integer    n_at_done;
    integer    n_writes, n_oob, n_double, n_done, n_active_unarmed, i, f, y, x, k, mism, captured, exp_base, timeout;
    reg [31:0] lfsr;
    reg        frame_is_armed, frame_cmp;
    integer    cur_line;
    always @(posedge clk) begin
        if (frame_done) begin n_done = n_done + 1; n_at_done = n_writes; end     // frame_done must come AFTER the last write strobe: the count before this edge's own write
        if (we) begin
            n_writes = n_writes + 1;
            if (waddr >= SIZE) n_oob = n_oob + 1;
            else begin
                img[waddr] <= wdata;
                if (wcnt[waddr] != 8'd0) n_double = n_double + 1;
                wcnt[waddr] <= wcnt[waddr] + 8'd1;
            end
        end
        if (!frame_is_armed && active && cur_line >= 1) n_active_unarmed = n_active_unarmed + 1;
    end

    task send_pixel;
        input [23:0] px;
        input        sof;
        begin
            // random bubble before the pixel
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            while (lfsr[7:0] < GAP) begin
                pix_valid = 1'b0; pix_sof = 1'b0; @(negedge clk);
                lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
                lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            end
            pix_valid = 1'b1; pix_sof = sof; pr = px[23:16]; pg = px[15:8]; pb = px[7:0];
            @(negedge clk);
            pix_valid = 1'b0; pix_sof = 1'b0;
        end
    endtask

    reg [8*200-1:0] prefix;
    reg [8*220-1:0] fn;
    initial begin
        if (!$value$plusargs("CASE=%s", prefix)) begin $display("TB_RESULT: FAIL tb_yolo_box (no +CASE=)"); $finish; end
        $sformat(fn, "%0s_frames.hex", prefix); $readmemh(fn, frames_mem);
        $sformat(fn, "%0s_exp.hex", prefix);    $readmemh(fn, exp_mem);
        n_writes = 0; n_oob = 0; n_double = 0; n_done = 0; n_active_unarmed = 0; mism = 0; captured = 0; exp_base = 0; lfsr = 32'hC0FFEE01; frame_is_armed = 1'b0;
        arm = 1'b0; pix_valid = 1'b0; pix_sof = 1'b0; pr = 8'd0; pg = 8'd0; pb = 8'd0;
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);
        for (f = 0; f < FRAMES; f = f + 1) begin
            frame_cmp = (ARMED >> f) & 1;
            frame_is_armed = frame_cmp || ((TRUNC >> f) & 1);
            cur_line = 0;
            for (i = 0; i < SIZE; i = i + 1) begin img[i] = 8'h55; wcnt[i] = 8'd0; end
            n_writes = 0; n_oob = 0; n_double = 0;
            if (frame_is_armed && !((LATE >> f) & 1)) begin arm = 1'b1; @(negedge clk); arm = 1'b0; repeat (2) @(negedge clk); end
            for (y = 0; y < (((TRUNC >> f) & 1) ? IN_H / 2 : IN_H); y = y + 1) begin
                cur_line = y;
                if (y == IN_H / 2 && (f + 1) < FRAMES && ((ARMED >> (f + 1)) & 1) && ((LATE >> (f + 1)) & 1)) begin arm = 1'b1; @(negedge clk); arm = 1'b0; end
                for (x = 0; x < IN_W; x = x + 1) send_pixel(frames_mem[(f * IN_H + y) * IN_W + x], (x == 0 && y == 0));
                repeat (3) @(negedge clk);                          // line gap
            end
            repeat (60) @(negedge clk);                             // frame gap (the tail of the emitter)
            if (frame_cmp) begin
                timeout = 0;
                while (n_done <= captured && timeout < 1000) begin @(negedge clk); timeout = timeout + 1; end
                repeat (4) @(negedge clk);
                captured = captured + 1;
                for (i = 0; i < SIZE; i = i + 1)
                    if (img[i] !== exp_mem[exp_base + i]) begin
                        mism = mism + 1;
                        if (mism <= 8) $display("MISMATCH %0s frame %0d byte %0d: got %02x expected %02x", prefix, f, i, img[i], exp_mem[exp_base + i]);
                    end
                exp_base = exp_base + SIZE;
                if (n_at_done != (IN_W / BOX) * (IN_H / BOX) * 3) begin mism = mism + 1; $display("MISMATCH %0s frame %0d: frame_done after %0d of %0d writes", prefix, f, n_at_done, (IN_W / BOX) * (IN_H / BOX) * 3); end
                if (n_oob != 0 || n_double != 0) begin mism = mism + 1; $display("MISMATCH %0s frame %0d: %0d writes outside the image, %0d bytes written twice", prefix, f, n_oob, n_double); end
                if (n_writes != (IN_W / BOX) * (IN_H / BOX) * 3) begin mism = mism + 1; $display("MISMATCH %0s frame %0d: %0d writes, expected %0d", prefix, f, n_writes, (IN_W / BOX) * (IN_H / BOX) * 3); end
            end
            else if (!frame_is_armed) begin
                if (n_writes != 0) begin mism = mism + 1; $display("MISMATCH %0s frame %0d: %0d writes for a frame that was not armed", prefix, f, n_writes); end
            end
            if (active && !((TRUNC >> f) & 1)) begin mism = mism + 1; $display("MISMATCH %0s frame %0d: active still high after the frame", prefix, f); end
        end
        if (n_done != captured) begin mism = mism + 1; $display("MISMATCH %0s: %0d frame_done pulses for %0d captured frames", prefix, n_done, captured); end
        if (n_active_unarmed != 0) begin mism = mism + 1; $display("MISMATCH %0s: active high during frames that were not armed", prefix); end
        if (mism == 0) $display("TB_RESULT: PASS tb_yolo_box %0s frames=%0d captured=%0d", prefix, FRAMES, captured);
        else           $display("TB_RESULT: FAIL tb_yolo_box %0s mismatches=%0d", prefix, mism);
        $finish;
    end

endmodule
