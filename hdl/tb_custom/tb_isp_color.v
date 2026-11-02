// tb_isp_color.v - bit-exact check of rtl_custom/isp_color.v against tools/shade/isp_color_ref.py
//
// 13 frames of 1280 x 720 (320 beats of 4 pixels per line), the frame schedule (mode, manual gains) from <vec>/schedule.txt; pictures by pix()
// (the same formula as isp_color_ref.py). Valid has a gap after every 7th beat; line blanking is 12 idle clocks on every 5th line (the documented
// minimum for the node fetch at a line start) and 40 otherwise; frame blanking 1200 clocks, the next frame's mode / manual gains are applied 400
// clocks into it. Checks, every clock / beat:
//   * every output beat (96 bits) equals the next word of <vec>/exp_beats.txt; the beat count per frame is 230400;
//   * O_tvalid / O_tlast are the input valid / last delayed by exactly DELAY + 3 clocks; O_tuser is the input tuser;
//   * O_gain_r / g / b during every output beat equal the gains of that frame (<vec>/exp_frames.txt);
//   * 1100 clocks after each frame's last input beat the frame statistics (dut.c_sum, exact sums) and the closed-loop gains
//     (dut.a_r / a_g / a_b) equal the model's.
// Run: python tools/shade/isp_color_ref.py --table <lsc_table.hex> --out <vec>, then
//      iverilog -g2005 -o sim.vvp tb_isp_color.v isp_color.v div_seq.v <lsc_rom.v> ; vvp sim.vvp +VEC=<vec>
// Final line: TB_RESULT: PASS tb_isp_color  or  FAIL

`timescale 1ns / 1ps

module tb_isp_color;
    // grey gate / initial gains of the DUT (iverilog -P tb_isp_color.GRAY_SH=1 ...; the vectors must come from isp_color_ref.py with the same
    // --gray-sh / --init)
    parameter integer GRAY_SH = 0;
    parameter [15:0]  INIT_R = 16'd4096;
    parameter [15:0]  INIT_G = 16'd4096;
    parameter [15:0]  INIT_B = 16'd4096;

    localparam integer W = 1280, H = 720, BPL = 320, NFR = 15, DELAY = 24;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    reg         i_tlast, i_tuser, i_tvalid;
    reg  [95:0] i_tdata;
    reg  [1:0]  mode;
    reg  [15:0] man_r, man_g, man_b;
    wire [15:0] g_r, g_g, g_b;
    wire        o_tlast, o_tuser, o_tvalid, i_tready;
    wire [95:0] o_tdata;

    isp_color #(.IMG_HEIGHT(H), .IMG_WIDTH(W), .DELAY(DELAY), .GRAY_SH(GRAY_SH), .INIT_R(INIT_R), .INIT_G(INIT_G), .INIT_B(INIT_B)) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_mode(mode), .I_man_r(man_r), .I_man_g(man_g), .I_man_b(man_b),
        .O_gain_r(g_r), .O_gain_g(g_g), .O_gain_b(g_b),
        .I_tlast(i_tlast), .I_tuser(i_tuser), .I_tdata(i_tdata), .I_tvalid(i_tvalid), .I_tready(i_tready),
        .O_tlast(o_tlast), .O_tuser(o_tuser), .O_tdata(o_tdata), .O_tvalid(o_tvalid), .O_tready(1'b1));

    // ---------------- pictures (identical to isp_color_ref.py)
    function [23:0] pix;
        input integer x, y, f;
        integer base, r, g, b;
        begin
            base = ((x >> 2) + (y >> 1) + f * 37) & 255;
            r = (base * 3 + (x & 7) * 5 + 11 * f) & 255;
            g = (base + (y & 15) * 3 + 23) & 255;
            b = (255 - base + ((x + y) & 31)) & 255;
            if (f == 4) begin r = r & 15; g = g & 31; b = b & 7; end
            if (f == 6) begin r = r | 192; g = g | 128; b = b | 224; end
            if (f == 7) begin r = (r >> 4) + 18; g = (g >> 3) + 19; b = (b >> 2) + 17; end
            if (f == 8) begin r = (r >> 2) + 18; g = (g >> 3) + 19; b = (b >> 4) + 17; end
            if (f == 9) begin r = (r >> 3) + 18; g = (g >> 5) + 19; b = (b >> 2) + 17; end
            if (f == 11) begin r = (r & 15) + 16; g = (g & 3) + 19; b = (b & 15) + 15; if (x == 0 && y < 8) g = 40; end
            if (f == 13) begin r = (r & 1) + 17; g = (g & 63) + 40; b = (b & 7) + 238; end
            pix = {r[7:0], g[7:0], b[7:0]};
        end
    endfunction

    // ---------------- vectors
    reg [8*256-1:0] vec, fn;
    integer fd_b, fd_f, fd_s, rc;
    integer s_mode [0:NFR-1];
    integer s_mr [0:NFR-1];
    integer s_mg [0:NFR-1];
    integer s_mb [0:NFR-1];
    integer e_mode [0:NFR-1];
    integer e_gr [0:NFR-1];
    integer e_gg [0:NFR-1];
    integer e_gb [0:NFR-1];
    integer e_ar [0:NFR-1];
    integer e_ag [0:NFR-1];
    integer e_ab [0:NFR-1];
    integer e_sr [0:NFR-1];
    integer e_sg [0:NFR-1];
    integer e_sb [0:NFR-1];

    // ---------------- latency reference
    reg [DELAY+3:0] sv, sl;
    initial begin sv = 0; sl = 0; end
    always @(posedge clk) begin sv <= {sv[DELAY+2:0], i_tvalid}; sl <= {sl[DELAY+2:0], i_tvalid & i_tlast}; end

    // ---------------- output check
    integer errors, nb_frame, of, ob, tclk;
    reg [95:0] expw;
    reg        out_started;
    initial begin errors = 0; of = 0; ob = 0; nb_frame = 0; tclk = 0; out_started = 0; end
    always @(posedge clk) begin
        if (rst_n) tclk = tclk + 1;
        if (o_tuser !== i_tuser) begin errors = errors + 1; if (errors < 10) $display("MISMATCH t=%0t O_tuser is not the input tuser", $time); end
        if (tclk > 40 && (o_tvalid !== sv[DELAY+2] || o_tlast !== sl[DELAY+2])) begin
            errors = errors + 1; if (errors < 10) $display("MISMATCH t=%0t valid/last latency (want DELAY + 3)", $time);
        end
        if (o_tvalid) begin
            rc = $fscanf(fd_b, "%h\n", expw);
            if (rc != 1) begin errors = errors + 1; if (errors < 10) $display("MISMATCH t=%0t more output beats than expected", $time); end
            else if (o_tdata !== expw) begin
                errors = errors + 1;
                if (errors < 20) $display("MISMATCH frame %0d beat %0d (line %0d, beat %0d): got %h expected %h", of, ob, ob / BPL, ob % BPL, o_tdata, expw);
            end
            if (of < NFR && (g_r !== e_gr[of] || g_g !== e_gg[of] || g_b !== e_gb[of])) begin
                errors = errors + 1;
                if (errors < 20) $display("MISMATCH frame %0d O_gain %0d %0d %0d expected %0d %0d %0d", of, g_r, g_g, g_b, e_gr[of], e_gg[of], e_gb[of]);
            end
            if (o_tlast !== ((ob % BPL) == BPL - 1)) begin errors = errors + 1; if (errors < 20) $display("MISMATCH frame %0d beat %0d tlast", of, ob); end
            ob = ob + 1;
            if (ob == BPL * H) begin of = of + 1; ob = 0; end
        end
    end

    // ---------------- driver
    task send_frame;
        input integer f;
        integer y, b, k, gap;
        reg [95:0] d;
        begin
            for (y = 0; y < H; y = y + 1) begin
                for (b = 0; b < BPL; b = b + 1) begin
                    for (k = 0; k < 4; k = k + 1) d[24*k +: 24] = pix(4 * b + k, y, f);
                    @(negedge clk);
                    i_tdata = d; i_tvalid = 1'b1; i_tuser = (y == 0 && b == 0); i_tlast = (b == BPL - 1);
                    if (b % 7 == 6 && b != BPL - 1) begin
                        @(negedge clk); i_tvalid = 1'b0; i_tuser = 1'b0; i_tlast = 1'b0;
                    end
                end
                gap = (y % 5 == 0) ? 12 : 40;
                @(negedge clk); i_tvalid = 1'b0; i_tuser = 1'b0; i_tlast = 1'b0; i_tdata = 96'd0;
                repeat (gap - 1) @(negedge clk);
            end
        end
    endtask

    integer f;
    initial begin
        if (!$value$plusargs("VEC=%s", vec)) begin $display("TB_RESULT: FAIL tb_isp_color (no +VEC=)"); $finish; end
        $sformat(fn, "%0s/schedule.txt", vec);   fd_s = $fopen(fn, "r");
        $sformat(fn, "%0s/exp_frames.txt", vec); fd_f = $fopen(fn, "r");
        $sformat(fn, "%0s/exp_beats.txt", vec);  fd_b = $fopen(fn, "r");
        if (fd_s == 0 || fd_f == 0 || fd_b == 0) begin $display("TB_RESULT: FAIL tb_isp_color (vector files missing in %0s)", vec); $finish; end
        for (f = 0; f < NFR; f = f + 1) begin
            rc = $fscanf(fd_s, "%d %d %d %d\n", s_mode[f], s_mr[f], s_mg[f], s_mb[f]);
            rc = $fscanf(fd_f, "%d %d %d %d %d %d %d %d %d %d\n", e_mode[f], e_gr[f], e_gg[f], e_gb[f], e_ar[f], e_ag[f], e_ab[f], e_sr[f], e_sg[f], e_sb[f]);
        end
        i_tlast = 0; i_tuser = 0; i_tvalid = 0; i_tdata = 0;
        mode = s_mode[0]; man_r = s_mr[0]; man_g = s_mg[0]; man_b = s_mb[0];
        rst_n = 1'b0;
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (100) @(negedge clk);
        for (f = 0; f < NFR; f = f + 1) begin
            send_frame(f);
            repeat (400) @(negedge clk);
            if (f + 1 < NFR) begin mode = s_mode[f + 1]; man_r = s_mr[f + 1]; man_g = s_mg[f + 1]; man_b = s_mb[f + 1]; end
            repeat (700) @(negedge clk);
            if (dut.c_sum[0] !== e_sr[f] || dut.c_sum[1] !== e_sg[f] || dut.c_sum[2] !== e_sb[f]) begin
                errors = errors + 1;
                $display("MISMATCH after frame %0d: statistics %0d %0d %0d expected %0d %0d %0d", f, dut.c_sum[0], dut.c_sum[1], dut.c_sum[2], e_sr[f], e_sg[f], e_sb[f]);
            end
            if (dut.a_r !== e_ar[f] || dut.a_g !== e_ag[f] || dut.a_b !== e_ab[f]) begin
                errors = errors + 1;
                $display("MISMATCH after frame %0d: closed-loop gains %0d %0d %0d expected %0d %0d %0d", f, dut.a_r, dut.a_g, dut.a_b, e_ar[f], e_ag[f], e_ab[f]);
            end
            else $display("frame %0d (mode %0d): gains %0d %0d %0d -> closed loop %0d %0d %0d", f, e_mode[f], e_gr[f], e_gg[f], e_gb[f], e_ar[f], e_ag[f], e_ab[f]);
            repeat (100) @(negedge clk);
        end
        repeat (200) @(negedge clk);
        if (of != NFR) begin errors = errors + 1; $display("MISMATCH only %0d of %0d frames came out completely (beats of the next: %0d)", of, NFR, ob); end
        rc = $fscanf(fd_b, "%h\n", expw);
        if (rc == 1) begin errors = errors + 1; $display("MISMATCH fewer output beats than expected"); end
        $display("tb_isp_color: frames %0d, errors %0d", of, errors);
        if (errors == 0) $display("TB_RESULT: PASS tb_isp_color");
        else             $display("TB_RESULT: FAIL tb_isp_color errors=%0d", errors);
        $finish;
    end

endmodule
