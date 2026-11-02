// tb_rgb_to_gray.v - self-checking testbench for rtl_custom/rgb_to_gray.v
//
// Oracle: exp_gray() uses 32-bit integer arithmetic and the integer '/'
// operator (DUT uses 16-bit products and a bit slice). Latency is modelled by
// an independent 2-stage expected-value pipeline (e1 -> e2) that is clocked and
// reset exactly like the real chip would be; the DUT must match it every clock.
//
// Build/run (Icarus Verilog):
//   iverilog -g2005 -Wall -o sim_gray.vvp tb_rgb_to_gray.v ../rtl_custom/rgb_to_gray.v
//   vvp sim_gray.vvp
// Optional +define+FULL_SWEEP checks all 2^24 colours (slow).
// Final line is "TB_RESULT: PASS ..." or "TB_RESULT: FAIL ...".

`timescale 1ns / 1ps

module tb_rgb_to_gray;

    localparam LAT = 2;                 // contract latency; the e1->e2 pipeline below has exactly LAT stages

    reg         clk;
    reg         rst_n;
    reg         in_de;
    reg  [23:0] in_rgb;
    reg  [11:0] in_x;
    reg  [11:0] in_y;
    reg         in_sof;
    reg         in_eol;
    reg         in_eof;

    wire        out_de;
    wire [7:0]  out_gray;
    wire [23:0] out_rgb;
    wire [11:0] out_x;
    wire [11:0] out_y;
    wire        out_sof;
    wire        out_eol;
    wire        out_eof;

    rgb_to_gray dut (
        .clk(clk), .rst_n(rst_n),
        .in_de(in_de), .in_rgb(in_rgb), .in_x(in_x), .in_y(in_y),
        .in_sof(in_sof), .in_eol(in_eol), .in_eof(in_eof),
        .out_de(out_de), .out_gray(out_gray), .out_rgb(out_rgb),
        .out_x(out_x), .out_y(out_y),
        .out_sof(out_sof), .out_eol(out_eol), .out_eof(out_eof)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;               // 100 MHz, posedge at 5,15,25...

    integer errors;
    integer checked;                    // clocks compared
    integer de_checked;                 // clocks compared with out_de = 1
    integer seed;
    integer nz_gray;                    // out_gray != 0 observed

    // ------------------------------------------------------------------
    // independent oracle
    // ------------------------------------------------------------------
    function [7:0] exp_gray;
        input [23:0] rgb;
        integer r, g, b, s;
        begin
            r = rgb[23:16];
            g = rgb[15:8];
            b = rgb[7:0];
            s = 77 * r + 150 * g + 29 * b;
            exp_gray = s / 256;
        end
    endfunction

    // expected pipeline: e1 = after first clock, e2 = after second clock (== DUT output)
    reg         e1_de, e2_de;
    reg  [7:0]  e1_y,  e2_y;
    reg  [11:0] e1_x,  e2_x;
    reg  [11:0] e1_yy, e2_yy;
    reg         e1_sof, e2_sof, e1_eol, e2_eol, e1_eof, e2_eof;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            e1_de <= 1'b0; e1_y <= 8'd0; e1_x <= 12'd0; e1_yy <= 12'd0;
            e1_sof <= 1'b0; e1_eol <= 1'b0; e1_eof <= 1'b0;
            e2_de <= 1'b0; e2_y <= 8'd0; e2_x <= 12'd0; e2_yy <= 12'd0;
            e2_sof <= 1'b0; e2_eol <= 1'b0; e2_eof <= 1'b0;
        end
        else begin
            e1_de  <= in_de;
            e1_y   <= in_de ? exp_gray(in_rgb) : 8'd0;
            e1_x   <= in_de ? in_x : 12'd0;
            e1_yy  <= in_de ? in_y : 12'd0;
            e1_sof <= in_de & in_sof;
            e1_eol <= in_de & in_eol;
            e1_eof <= in_de & in_eof;
            e2_de <= e1_de; e2_y <= e1_y; e2_x <= e1_x; e2_yy <= e1_yy;
            e2_sof <= e1_sof; e2_eol <= e1_eol; e2_eof <= e1_eof;
        end
    end

    // ------------------------------------------------------------------
    // checker: sample at negedge (DUT only changes at posedge or on async reset)
    // ------------------------------------------------------------------
    reg check_en;

    task report;
        input [255:0] what;
        input [31:0]  exp_v;
        input [31:0]  act_v;
        begin
            errors = errors + 1;
            if (errors <= 25)
                $display("MISMATCH t=%0t %0s expected=%h actual=%h (in_de=%b rgb=%h)",
                         $time, what, exp_v, act_v, in_de, in_rgb);
            if (errors >= 100) begin
                $display("TB_RESULT: FAIL tb_rgb_to_gray aborted after %0d mismatches", errors);
                $finish;
            end
        end
    endtask

    always @(negedge clk) begin
        if (check_en) begin
            checked = checked + 1;
            if (e2_de) de_checked = de_checked + 1;
            if (out_gray !== 8'd0) nz_gray = nz_gray + 1;
            if (out_de   !== e2_de)  report("out_de",   e2_de,  out_de);
            if (out_gray !== e2_y)   report("out_gray", e2_y,   out_gray);
            if (out_rgb  !== {e2_y, e2_y, e2_y}) report("out_rgb", {e2_y,e2_y,e2_y}, out_rgb);
            if (out_x    !== e2_x)   report("out_x",    e2_x,   out_x);
            if (out_y    !== e2_yy)  report("out_y",    e2_yy,  out_y);
            if (out_sof  !== e2_sof) report("out_sof",  e2_sof, out_sof);
            if (out_eol  !== e2_eol) report("out_eol",  e2_eol, out_eol);
            if (out_eof  !== e2_eof) report("out_eof",  e2_eof, out_eof);
            if (!out_de) begin
                // blanking must be clean regardless of what the oracle says
                if (out_gray !== 8'd0 || out_rgb !== 24'd0 || out_x !== 12'd0 ||
                    out_y !== 12'd0 || out_sof !== 1'b0 || out_eol !== 1'b0 || out_eof !== 1'b0)
                    report("blanking_not_clean", 0, {out_gray});
            end
        end
    end

    // ------------------------------------------------------------------
    // stimulus helpers: every call = one clock; inputs change at negedge
    // ------------------------------------------------------------------
    task pix;
        input        de;
        input [23:0] rgb;
        input [11:0] x;
        input [11:0] y;
        input        sof;
        input        eol;
        input        eof;
        begin
            @(negedge clk);
            in_de  = de;
            in_rgb = rgb;
            in_x   = x;
            in_y   = y;
            in_sof = sof;
            in_eol = eol;
            in_eof = eof;
        end
    endtask

    // plain pixel without frame flags
    task pc;
        input [23:0] rgb;
        begin
            pix(1'b1, rgb, 12'd0, 12'd0, 1'b0, 1'b0, 1'b0);
        end
    endtask

    // blanking cycle with garbage on every input (must be ignored)
    task garbage;
        begin
            pix(1'b0, $random(seed), $random(seed), $random(seed),
                $random(seed), $random(seed), $random(seed));
        end
    endtask

    task idle;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                pix(1'b0, 24'd0, 12'd0, 12'd0, 1'b0, 1'b0, 1'b0);
        end
    endtask

    // frame with flags; if gaps=1 insert garbage blanking between pixels/lines
    task frame;
        input integer w;
        input integer h;
        input integer gaps;
        integer x, y;
        reg [23:0] c;
        begin
            for (y = 0; y < h; y = y + 1) begin
                for (x = 0; x < w; x = x + 1) begin
                    c = $random(seed);
                    pix(1'b1, c, x, y, (x == 0 && y == 0), (x == w - 1),
                        (x == w - 1 && y == h - 1));
                    if (gaps != 0 && (($random(seed) & 3) == 0)) garbage;
                end
                if (gaps != 0) begin
                    garbage; garbage; garbage;
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // main sequence
    // ------------------------------------------------------------------
    integer i, j, k;
    reg [23:0] c24;

    initial begin
        errors = 0; checked = 0; de_checked = 0; nz_gray = 0; seed = 32'h5EED0001;
        check_en = 1'b0;
        rst_n = 1'b0;
        in_de = 1'b0; in_rgb = 24'd0; in_x = 12'd0; in_y = 12'd0;
        in_sof = 1'b0; in_eol = 1'b0; in_eof = 1'b0;

        $display("tb_rgb_to_gray: seed=0x%h LAT=%0d", seed, LAT);

        // oracle self-check against the numbers written in FIRST_TASK
        if (exp_gray(24'h000000) !== 8'd0)   begin errors = errors + 1; $display("ORACLE black"); end
        if (exp_gray(24'hFF0000) !== 8'd76)  begin errors = errors + 1; $display("ORACLE red");   end
        if (exp_gray(24'h00FF00) !== 8'd149) begin errors = errors + 1; $display("ORACLE green"); end
        if (exp_gray(24'h0000FF) !== 8'd28)  begin errors = errors + 1; $display("ORACLE blue");  end
        if (exp_gray(24'hFFFFFF) !== 8'd255) begin errors = errors + 1; $display("ORACLE white"); end

        // ---- reset behaviour at power-up ----
        repeat (3) @(negedge clk);
        #2 rst_n = 1'b1;                // release away from a clock edge
        check_en = 1'b1;
        idle(3);

        // ---- directed colours (literal expectations also enforced by the oracle check above)
        pc(24'h000000);                 // black -> 0
        pc(24'hFFFFFF);                 // white -> 255
        pc(24'hFF0000);                 // red   -> 76
        pc(24'h00FF00);                 // green -> 149
        pc(24'h0000FF);                 // blue  -> 28
        pc(24'h010101);
        pc(24'h808080);
        pc(24'hFF0001);
        pc(24'h01FF00);
        pc(24'h0001FF);
        pc(24'hFEFEFE);
        idle(3);

        // ---- single channel sweeps (768 pixels, continuous stream, no gaps)
        for (i = 0; i < 256; i = i + 1) pc({i[7:0], 16'h0000});
        for (i = 0; i < 256; i = i + 1) pc({8'h00, i[7:0], 8'h00});
        for (i = 0; i < 256; i = i + 1) pc({16'h0000, i[7:0]});
        // grey ramp (v,v,v): 77+150+29 = 256, so Y must equal v
        for (i = 0; i < 256; i = i + 1) pc({i[7:0], i[7:0], i[7:0]});
        idle(3);

        // ---- coarse 3D grid including the rounding-sensitive edges
        for (i = 0; i < 256; i = i + 15)
            for (j = 0; j < 256; j = j + 15)
                for (k = 0; k < 256; k = k + 15)
                    pc({i[7:0], j[7:0], k[7:0]});
        for (i = 0; i < 256; i = i + 1)
            for (j = 250; j < 256; j = j + 1)
                pc({i[7:0], j[7:0], 8'hFF});
        idle(3);

        // ---- frame streams: continuous, then with blanking holes carrying garbage
        frame(8, 6, 0);
        idle(2);
        frame(8, 6, 1);
        frame(1, 1, 0);                 // 1x1: sof=eol=eof on the same pixel
        frame(1, 5, 0);
        frame(5, 1, 1);
        idle(3);

        // ---- random stream with random de holes
        for (i = 0; i < 200000; i = i + 1) begin
            c24 = $random(seed);
            if (($random(seed) & 7) < 6)
                pix(1'b1, c24, $random(seed), $random(seed),
                    $random(seed), $random(seed), $random(seed));
            else
                pix(1'b0, c24, $random(seed), $random(seed),
                    $random(seed), $random(seed), $random(seed));
        end
        idle(3);

        // ---- asynchronous reset in the middle of a running stream
        // keep feeding valid pixels; reset is asserted/released away from clock edges
        for (i = 0; i < 20; i = i + 1) pc($random(seed));
        @(negedge clk);
        #2 rst_n = 1'b0;
        in_de = 1'b1; in_rgb = 24'hFFFFFF; in_sof = 1'b1; in_eol = 1'b1; in_eof = 1'b1;
        #1;
        // outputs must already be cleared (asynchronous)
        if (out_de !== 1'b0 || out_gray !== 8'd0 || out_sof !== 1'b0 || out_eof !== 1'b0) begin
            errors = errors + 1;
            $display("MISMATCH reset not asynchronous: de=%b gray=%h", out_de, out_gray);
        end
        pix(1'b1, 24'hFF0000, 12'd1, 12'd1, 1'b1, 1'b1, 1'b1);   // still in reset
        pix(1'b1, 24'hFF0000, 12'd1, 12'd1, 1'b1, 1'b1, 1'b1);
        #2 rst_n = 1'b1;
        for (i = 0; i < 20; i = i + 1) pc($random(seed));
        idle(4);

        // ---- reset pulse shorter than a clock period, between edges
        @(negedge clk);
        in_de = 1'b1; in_rgb = 24'h123456;
        #1 rst_n = 1'b0;
        #1 rst_n = 1'b1;
        pc(24'h654321);
        idle(4);

`ifdef FULL_SWEEP
        // ---- every colour in the 24-bit space (16.7 M clocks)
        for (i = 0; i < 16777216; i = i + 1) begin
            c24 = i;
            pc(c24);
        end
        idle(4);
`endif

        idle(5);
        check_en = 1'b0;

        $display("tb_rgb_to_gray: compared_clocks=%0d with_de=%0d nonzero_gray=%0d errors=%0d",
                 checked, de_checked, nz_gray, errors);
        if (checked < 200000 || de_checked < 100000 || nz_gray < 50000) begin
            errors = errors + 1;
            $display("COVERAGE too low: test would be vacuous");
        end
        if (errors == 0) $display("TB_RESULT: PASS tb_rgb_to_gray");
        else             $display("TB_RESULT: FAIL tb_rgb_to_gray errors=%0d", errors);
        $finish;
    end

endmodule
