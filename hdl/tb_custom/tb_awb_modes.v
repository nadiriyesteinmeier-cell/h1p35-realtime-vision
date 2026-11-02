// tb_awb_modes.v - the vendor AWB (contest_work_v3_shade/.../awb.v with the new I_mode input) against the unmodified color4 awb.v
//
// Instances (all fed with the same stream):
//   o  awb_orig   the UNMODIFIED vendor module from contest_work_v3_color4 (module renamed by tb_custom/awb_modes_run.py)
//   m0 awb        I_mode = 0   must behave exactly like the original, beat for beat (every output bit, every clock)
//   m1 awb        I_mode = 1   the FINAL gains of the previous frame are applied to the whole next frame
//   m2 awb        I_mode = 2   no white balance: R, G and B come out unchanged (delayed like the original)
// The vendor IP the module needs is replaced by behavioural stand-ins: `divider` (quotient = numerator / denominator, done 50 clocks after
// start, as its PIPLE parameter suggests; the real core is a gate-level netlist) and the dual-port RAM `blk_mem_gen_awb_delay_signal`
// (one-clock synchronous read). The checks do not depend on the exact divider latency: the expectation for mode 1 is built from the gains
// that the ORIGINAL instance holds at the end of every frame (hierarchical read of o.in_r_r1 / o.in_b_r1 in the clock of the next frame
// start), the expectation for mode 2 from the input stream itself.
// Geometry: the module takes IMG_WIDTH / IMG_HEIGHT; 256 x 12 is used here because the line delay (50 beats) needs more than 50 beats per
// line. Each frame has a vertical colour ramp, so the original gains drift visibly from the first to the last line.
//
// Run: python tb_custom/awb_modes_run.py        final line: TB_RESULT: PASS tb_awb_modes  or  FAIL

`timescale 1ns / 1ps

module divider (clk, denominator, numerator, rst, start, done, quotient, remainder);
    input clk;
    input [31:0] denominator;
    input [47:0] numerator;
    input rst;
    input start;
    output done;
    output [47:0] quotient;
    output [31:0] remainder;
    parameter PIPLE = 50;
    reg [47:0] q [0:PIPLE];
    reg [PIPLE:0] d;
    integer i;
    always @(posedge clk) begin
        q[0] <= (denominator == 0) ? 48'hFFFFFFFFFFFF : (numerator / denominator);
        d[0] <= start;
        for (i = 1; i <= PIPLE; i = i + 1) begin q[i] <= q[i-1]; d[i] <= d[i-1]; end
    end
    assign quotient  = q[PIPLE];
    assign done      = d[PIPLE] & ~rst;
    assign remainder = 32'd0;
endmodule

module blk_mem_gen_awb_delay_signal (doa, dia, addra, clka, wea, dob, dib, addrb, clkb, web);
    output [95:0] doa;
    output [95:0] dob;
    input  [95:0] dia;
    input  [95:0] dib;
    input  [10:0] addra;
    input  [10:0] addrb;
    input         clka, clkb, wea, web;
    reg [95:0] mem [0:2047];
    reg [95:0] rq;
    always @(posedge clka) if (wea) mem[addra] <= dia;
    always @(posedge clkb) rq <= mem[addrb];
    assign dob = rq;
    assign doa = 96'd0;
endmodule

module tb_awb_modes;

    localparam integer W = 256;                 // pixels per line
    localparam integer H = 12;                  // lines per frame
    localparam integer BPL = W / 4;             // beats per line
    localparam integer NFR = 5;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    reg         i_tlast, i_tuser, i_tvalid;
    reg  [95:0] i_tdata;

    wire        o_tlast, o_tuser, o_tvalid;  wire [95:0] o_tdata;
    wire        a0_tlast, a0_tuser, a0_tvalid; wire [95:0] a0_tdata;
    wire        a1_tlast, a1_tuser, a1_tvalid; wire [95:0] a1_tdata;
    wire        a2_tlast, a2_tuser, a2_tvalid; wire [95:0] a2_tdata;
    wire        rdy_o, rdy0, rdy1, rdy2;

    awb_orig #(.IMG_HEIGHT(H), .IMG_WIDTH(W)) o (
        .I_clk(clk), .I_rst_n(rst_n), .I_tlast(i_tlast), .I_tuser(i_tuser), .I_tdata(i_tdata), .I_tvalid(i_tvalid), .I_tready(rdy_o),
        .O_tlast(o_tlast), .O_tuser(o_tuser), .O_tdata(o_tdata), .O_tvalid(o_tvalid), .O_tready(1'b1));
    awb #(.IMG_HEIGHT(H), .IMG_WIDTH(W)) m0 (
        .I_clk(clk), .I_rst_n(rst_n), .I_mode(2'd0), .I_tlast(i_tlast), .I_tuser(i_tuser), .I_tdata(i_tdata), .I_tvalid(i_tvalid), .I_tready(rdy0),
        .O_tlast(a0_tlast), .O_tuser(a0_tuser), .O_tdata(a0_tdata), .O_tvalid(a0_tvalid), .O_tready(1'b1));
    awb #(.IMG_HEIGHT(H), .IMG_WIDTH(W)) m1 (
        .I_clk(clk), .I_rst_n(rst_n), .I_mode(2'd1), .I_tlast(i_tlast), .I_tuser(i_tuser), .I_tdata(i_tdata), .I_tvalid(i_tvalid), .I_tready(rdy1),
        .O_tlast(a1_tlast), .O_tuser(a1_tuser), .O_tdata(a1_tdata), .O_tvalid(a1_tvalid), .O_tready(1'b1));
    awb #(.IMG_HEIGHT(H), .IMG_WIDTH(W)) m2 (
        .I_clk(clk), .I_rst_n(rst_n), .I_mode(2'd2), .I_tlast(i_tlast), .I_tuser(i_tuser), .I_tdata(i_tdata), .I_tvalid(i_tvalid), .I_tready(rdy2),
        .O_tlast(a2_tlast), .O_tuser(a2_tuser), .O_tdata(a2_tdata), .O_tvalid(a2_tvalid), .O_tready(1'b1));

    // ---------------- stimulus: NFR frames, vertical colour ramp + small pixel texture
    function [23:0] pix;
        input integer x;
        input integer y;
        input integer f;
        integer r, g, b;
        begin
            r = 90 + y * 9 + (x % 7) + f;
            g = 120 + y * 4 + ((x * 3) % 11);
            b = 140 - y * 6 + ((x * 5) % 13);
            pix = {r[7:0], g[7:0], b[7:0]};
        end
    endfunction

    // input frame store (for the mode-2 expectation) and the gains the original holds at the end of each frame
    reg [23:0] inpix [0:NFR*H*W-1];
    reg [19:0] fin_r_cap [0:NFR];
    reg [19:0] fin_b_cap [0:NFR];
    integer fr_in;                          // frame index of the beat being driven
    integer errors, cmp0, cmp1, cmp2;

    task send_frame;
        input integer f;
        integer y, bt, k;
        reg [95:0] d;
        begin
            for (y = 0; y < H; y = y + 1) begin
                for (bt = 0; bt < BPL; bt = bt + 1) begin
                    for (k = 0; k < 4; k = k + 1) begin
                        d[24*k +: 24] = pix(bt * 4 + k, y, f);
                        inpix[(f * H + y) * W + bt * 4 + k] = pix(bt * 4 + k, y, f);
                    end
                    @(negedge clk);
                    i_tdata = d; i_tvalid = 1'b1; i_tuser = (y == 0 && bt == 0); i_tlast = (bt == BPL - 1);
                end
                @(negedge clk);
                i_tvalid = 1'b0; i_tuser = 1'b0; i_tlast = 1'b0; i_tdata = 96'd0;
                repeat (90) @(negedge clk);                            // line blanking
            end
            repeat (200) @(negedge clk);                               // frame blanking
        end
    endtask

    // capture the original's gains at the clock of every frame start (before the reset to 1.0 takes effect)
    always @(posedge clk) begin
        if (i_tvalid && i_tuser) begin
            fin_r_cap[fr_in] <= o.in_r_r1;
            fin_b_cap[fr_in] <= o.in_b_r1;
        end
    end

    // ---------------- output checking: beat-by-beat for m0, expectation for m1 / m2
    integer ob1_f, ob1_l, ob1_b, ob2_f, ob2_l, ob2_b;        // output beat position trackers of m1 / m2
    reg     v1_q, v2_q, pf1, pf2;                                    // pf: a frame start (O_tuser) was seen and no output beat of it yet
    initial begin ob1_f = -1; ob1_l = 0; ob1_b = 0; ob2_f = -1; ob2_l = 0; ob2_b = 0; v1_q = 1'b0; v2_q = 1'b0; pf1 = 1'b0; pf2 = 1'b0; cmp0 = 0; cmp1 = 0; cmp2 = 0; end

    function [7:0] gain_apply;
        input [19:0] g;
        input [7:0]  v;
        reg [27:0] p;
        begin
            p = g * v;
            gain_apply = p[27:24] ? 8'd255 : p[23:16];
        end
    endfunction

    function [95:0] exp_beat;                 // expected output beat for a given gain pair and input beat
        input [19:0] gr;
        input [19:0] gb;
        input [95:0] din;
        integer k;
        begin
            for (k = 0; k < 4; k = k + 1)
                exp_beat[24*k +: 24] = {gain_apply(gr, din[24*k+16 +: 8]), din[24*k+8 +: 8], gain_apply(gb, din[24*k +: 8])};
        end
    endfunction

    reg [95:0] din_exp;
    integer kk;
    always @(negedge clk) begin
        // m0 == original, every bit
        if (rst_n) begin
            cmp0 = cmp0 + 1;
            if ({a0_tlast, a0_tuser, a0_tvalid, a0_tdata} !== {o_tlast, o_tuser, o_tvalid, o_tdata}) begin
                errors = errors + 1;
                if (errors <= 10) $display("MISMATCH t=%0t mode 0 differs from the original awb: %h vs %h", $time, {a0_tuser, a0_tvalid, a0_tdata}, {o_tuser, o_tvalid, o_tdata});
            end
        end
        // m1: frame / line / beat tracking from the output handshake of m1 (tuser starts a frame, a run of valid beats is one line)
        // NOTE: the vendor O_tuser is the INPUT tuser passed straight through, it comes ~50 beats before the first output beat of the frame
        if (a1_tuser) pf1 = 1'b1;
        if (a1_tvalid) begin
            if (pf1) begin ob1_f = ob1_f + 1; ob1_l = 0; ob1_b = 0; pf1 = 1'b0; end
            else if (!v1_q) begin ob1_l = ob1_l + 1; ob1_b = 0; end
            if (ob1_f >= 1 && ob1_f < NFR && ob1_l < H) begin
                // frame f uses the final gains of frame f-1
                for (kk = 0; kk < 4; kk = kk + 1) din_exp[24*kk +: 24] = inpix[(ob1_f * H + ob1_l) * W + ob1_b * 4 + kk];
                cmp1 = cmp1 + 1;
                if (a1_tdata !== exp_beat(fin_r_cap[ob1_f], fin_b_cap[ob1_f], din_exp)) begin
                    errors = errors + 1;
                    if (errors <= 10) $display("MISMATCH t=%0t mode 1 beat f=%0d l=%0d b=%0d got %h expected %h (gains %h %h)", $time, ob1_f, ob1_l, ob1_b, a1_tdata,
                                               exp_beat(fin_r_cap[ob1_f], fin_b_cap[ob1_f], din_exp), fin_r_cap[ob1_f], fin_b_cap[ob1_f]);
                end
            end
            ob1_b = ob1_b + 1;
        end
        v1_q = a1_tvalid;
        // m2: unchanged colours
        if (a2_tuser) pf2 = 1'b1;
        if (a2_tvalid) begin
            if (pf2) begin ob2_f = ob2_f + 1; ob2_l = 0; ob2_b = 0; pf2 = 1'b0; end
            else if (!v2_q) begin ob2_l = ob2_l + 1; ob2_b = 0; end
            if (ob2_f >= 0 && ob2_f < NFR && ob2_l < H) begin
                for (kk = 0; kk < 4; kk = kk + 1) din_exp[24*kk +: 24] = inpix[(ob2_f * H + ob2_l) * W + ob2_b * 4 + kk];
                cmp2 = cmp2 + 1;
                if (a2_tdata !== din_exp) begin
                    errors = errors + 1;
                    if (errors <= 10) $display("MISMATCH t=%0t mode 2 beat f=%0d l=%0d b=%0d got %h expected %h", $time, ob2_f, ob2_l, ob2_b, a2_tdata, din_exp);
                end
            end
            ob2_b = ob2_b + 1;
        end
        v2_q = a2_tvalid;
    end

    integer f;
    initial begin
        errors = 0; fr_in = 0;
        i_tlast = 0; i_tuser = 0; i_tvalid = 0; i_tdata = 0;
        rst_n = 1'b0;
        repeat (6) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);
        for (f = 0; f < NFR; f = f + 1) begin
            fr_in = f;
            send_frame(f);
        end
        repeat (400) @(negedge clk);
        $display("tb_awb_modes: beats compared  mode0=%0d (all bits, every clock)  mode1=%0d  mode2=%0d  errors=%0d", cmp0, cmp1, cmp2, errors);
        if (cmp1 < (NFR - 1) * H * BPL * 9 / 10 || cmp2 < NFR * H * BPL * 9 / 10) begin errors = errors + 1; $display("COVERAGE too low"); end
        // the original gains must really drift inside a frame (otherwise mode 1 could not be told apart from mode 0)
        if (fin_r_cap[1] === fin_r_cap[2] && fin_b_cap[1] === fin_b_cap[2] && fin_r_cap[1] === 20'h10000) begin errors = errors + 1; $display("gains never left 1.0: the test would be vacuous"); end
        if (errors == 0) $display("TB_RESULT: PASS tb_awb_modes");
        else             $display("TB_RESULT: FAIL tb_awb_modes errors=%0d", errors);
        $finish;
    end

endmodule
