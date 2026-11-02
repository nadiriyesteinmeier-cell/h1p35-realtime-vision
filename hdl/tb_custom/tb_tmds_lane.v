// tb_tmds_lane.v - integrity check of the DIAGNOSTIC copy of the HDMI serializer lane
//                  (contest_work_v2_hdmidiag/user_source/hdl_source/lane_lvds_10_1.v, the only change against the vendor lane is the
//                  new input I_load_sel that picks the clock edge at which the parallel TMDS word is captured).
//
// Three instances share the clocks and the data: I_load_sel = 0 (original behaviour: capture at S_load_en_2d, which is the serial edge
// that coincides with the NEXT pixel edge), 1 (one serial clock earlier) and 2 (two earlier). Clocks as in the design: serial clock =
// 5 x pixel clock, rising edges aligned every 5th serial edge; the parallel word changes by non-blocking assignment at the pixel edge.
//
// What is checked, on the bits that leave the lane (S_oddr_data, two bits per serial clock, bit 9 first):
//   1. instance 0: for some word phase and word lag the bit stream is EXACTLY the sequence of the driven words, every word once, in
//      order (pseudo-random 10-bit words, 900 consecutive words compared);
//   2. instance 1 is the stream of instance 0 one serial clock earlier, instance 2 two serial clocks earlier (2 bits per serial clock).
// The ODDR itself is a stub (the real primitive is a vendor cell); nothing is said here about the electrical capture race, only that
// the selectable capture does not change the data.
//
// Run: iverilog -g2005 -o sim_lane.vvp tb_tmds_lane.v ../contest_work_v2_hdmidiag/user_source/hdl_source/lane_lvds_10_1.v
//      vvp sim_lane.vvp      final line: TB_RESULT: PASS tb_tmds_lane  or  FAIL

`timescale 1ns / 1ps

module PH1P_LOGIC_ODDR (input clk, input rst, input d1, input d0, output q);   // behavioural stand-in, output unused by this testbench
    assign q = clk ? d0 : d1;
endmodule

module tb_tmds_lane;

    localparam integer NW = 1200;                  // words driven
    localparam integer NB = 2 * 5 * NW;            // bits recorded per instance (2 bits per serial clock, 5 serial clocks per word)

    reg sclk, pclk, rst;
    initial begin sclk = 1'b0; pclk = 1'b0; rst = 1'b1; end
    always #1 sclk = ~sclk;                        // serial period 2 time units
    always #5 pclk = ~pclk;                        // pixel period 10 time units, rising edges coincide with every 5th serial edge

    // pseudo-random 10-bit words
    reg [9:0]  data;
    reg [15:0] lfsr;
    integer    k;
    reg [9:0]  words [0:NW+7];
    initial begin
        lfsr = 16'hACE1;
        for (k = 0; k < NW + 8; k = k + 1) begin
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            words[k] = lfsr[9:0];
        end
    end

    integer wcnt;
    initial begin wcnt = 0; data = 10'd0; end
    always @(posedge pclk) begin
        data <= words[wcnt];
        wcnt <= wcnt + 1;
    end

    wire o0, o1, o2;
    lane_lvds_10_1 #(.DEVICE("PH1P")) u0 (.I_pixel_clk(pclk), .I_serial_clk(sclk), .I_rst(rst), .I_load_sel(2'd0), .I_data_in(data), .O_serial_out(o0));
    lane_lvds_10_1 #(.DEVICE("PH1P")) u1 (.I_pixel_clk(pclk), .I_serial_clk(sclk), .I_rst(rst), .I_load_sel(2'd1), .I_data_in(data), .O_serial_out(o1));
    lane_lvds_10_1 #(.DEVICE("PH1P")) u2 (.I_pixel_clk(pclk), .I_serial_clk(sclk), .I_rst(rst), .I_load_sel(2'd2), .I_data_in(data), .O_serial_out(o2));

    // record what leaves each lane (before the ODDR): bit 9 first
    reg b0 [0:NB-1];
    reg b1 [0:NB-1];
    reg b2 [0:NB-1];
    integer n;
    initial n = 0;
    always @(posedge sclk) begin
        if (!rst && n < NB / 2) begin
            b0[2*n] = u0.S_oddr_data[1]; b0[2*n+1] = u0.S_oddr_data[0];
            b1[2*n] = u1.S_oddr_data[1]; b1[2*n+1] = u1.S_oddr_data[0];
            b2[2*n] = u2.S_oddr_data[1]; b2[2*n+1] = u2.S_oddr_data[0];
            n = n + 1;
        end
    end

    integer errors, ph, lag, j, i, best_ph, best_lag, best_ok, ok;
    reg [9:0] w;
    initial begin
        errors = 0;
        #20 rst = 1'b0;
        wait (n >= NB / 2);
        #4;

        // 1. word alignment of instance 0
        best_ok = -1; best_ph = 0; best_lag = 0;
        for (ph = 0; ph < 5; ph = ph + 1) begin
            for (lag = -4; lag <= 4; lag = lag + 1) begin
                ok = 0;
                for (j = 20; j < 920; j = j + 1) begin
                    for (i = 0; i < 10; i = i + 1) w[9 - i] = b0[2*ph + 10*j + i];
                    if (j + lag >= 0 && w === words[j + lag]) ok = ok + 1;
                end
                if (ok > best_ok) begin best_ok = ok; best_ph = ph; best_lag = lag; end
            end
        end
        $display("tb_tmds_lane: instance 0 best alignment: phase %0d serial clocks, word lag %0d, %0d of 900 words match", best_ph, best_lag, best_ok);
        if (best_ok != 900) begin errors = errors + 1; $display("FAIL: word stream of instance 0 is not the driven sequence"); end

        // 2. instance 1 / 2 = instance 0 earlier by 1 / 2 serial clocks (2 bits each)
        ok = 0;
        for (j = 100; j < NB - 200; j = j + 1) if (b1[j] !== b0[j + 2]) ok = ok + 1;
        $display("tb_tmds_lane: instance 1 vs instance 0 shifted by one serial clock: %0d differing bits", ok);
        if (ok != 0) errors = errors + 1;
        ok = 0;
        for (j = 100; j < NB - 200; j = j + 1) if (b2[j] !== b0[j + 4]) ok = ok + 1;
        $display("tb_tmds_lane: instance 2 vs instance 0 shifted by two serial clocks: %0d differing bits", ok);
        if (ok != 0) errors = errors + 1;

        if (errors == 0) $display("TB_RESULT: PASS tb_tmds_lane");
        else             $display("TB_RESULT: FAIL tb_tmds_lane errors=%0d", errors);
        $finish;
    end

endmodule
