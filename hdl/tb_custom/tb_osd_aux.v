// tb_osd_aux.v - self-checking testbench for osd_bin2bcd, view_mux and sync_delay
//
//  osd_bin2bcd (3 instances: 12 bit/4 digits, 20 bit/6 digits, 16 bit/5 digits)
//     oracle: decimal digits by repeated integer '/10' and '%10' (the DUT uses shift-and-add-3)
//     - exhaustive over all 4096 values of the 12-bit instance, held 28 clocks each
//     - random and edge values (0, 1, 9, 10, 99999, 999999, 999999+1, 2^20-1, 65535) for the others,
//       incl. saturation at 10^DIGITS-1
//     - the output must be a valid BCD (every digit <= 9) on EVERY clock, also while 'bin' changes
//       in the middle of a conversion; after the change has been stable long enough the result is
//       the value that is now on 'bin'
//  view_mux (all 4 modes, random data every clock, latency 1, de gating, tint)
//  sync_delay (N = 0,1,2,3,7; W = 5; random data, delay line cleared by an asynchronous reset)
//
// Build/run (Icarus Verilog), from F:\fpga_s2\tb_custom:
//   iverilog -g2005 -Wall -o sim_aux.vvp tb_osd_aux.v ../rtl_custom/osd_bin2bcd.v ../rtl_custom/view_mux.v ../rtl_custom/sync_delay.v
//   vvp sim_aux.vvp
// Final line: "TB_RESULT: PASS ..." or "TB_RESULT: FAIL ...".

`timescale 1ns / 1ps

module tb_osd_aux;

    reg clk;
    reg rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer errors;
    integer seed;

    // ================= osd_bin2bcd =================
    reg  [11:0] b12;
    reg  [19:0] b20;
    reg  [15:0] b16;
    wire [15:0] d12;
    wire [23:0] d20;
    wire [19:0] d16;

    osd_bin2bcd #(.BITS(12), .DIGITS(4)) u12 (.clk(clk), .rst_n(rst_n), .bin(b12), .bcd(d12));
    osd_bin2bcd #(.BITS(20), .DIGITS(6)) u20 (.clk(clk), .rst_n(rst_n), .bin(b20), .bcd(d20));
    osd_bin2bcd #(.BITS(16), .DIGITS(5)) u16 (.clk(clk), .rst_n(rst_n), .bin(b16), .bcd(d16));

    // decimal digits of v (clamped to maxv) packed as BCD, computed with '/' and '%'
    function [23:0] dec;
        input integer v;
        input integer maxv;
        input integer digits;
        integer t, i;
        reg [23:0] r;
        begin
            t = (v > maxv) ? maxv : v;
            r = 24'd0;
            for (i = 0; i < digits; i = i + 1) begin
                r = r | ((t % 10) << (4 * i));
                t = t / 10;
            end
            dec = r;
        end
    endfunction

    function valid_bcd;
        input [23:0] v;
        input integer digits;
        integer i;
        reg ok;
        begin
            ok = 1'b1;
            for (i = 0; i < digits; i = i + 1)
                if (v[4*i +: 4] > 4'd9) ok = 1'b0;
            valid_bcd = ok;
        end
    endfunction

    // invariant checked on every clock: valid BCD (no X, digits <= 9)
    always @(negedge clk) begin
        if (rst_n === 1'b1) begin
            if (!valid_bcd({8'd0, d12}, 4) || ^d12 === 1'bx)       begin errors = errors + 1; if (errors < 10) $display("MISMATCH u12 not BCD: %h", d12); end
            if (!valid_bcd(d20, 6) || ^d20 === 1'bx)               begin errors = errors + 1; if (errors < 10) $display("MISMATCH u20 not BCD: %h", d20); end
            if (!valid_bcd({4'd0, d16}, 5) || ^d16 === 1'bx)       begin errors = errors + 1; if (errors < 10) $display("MISMATCH u16 not BCD: %h", d16); end
        end
    end

    reg [23:0] dv;

    task chk12;
        input integer v;
        begin
            b12 = v;
            repeat (2 * 12 + 4) @(negedge clk);        // > 2*BITS+3, see osd_bin2bcd.v
            dv = dec(v, 9999, 4);
            if (d12 !== dv[15:0]) begin
                errors = errors + 1;
                if (errors < 10) $display("MISMATCH u12 v=%0d expected=%h actual=%h", v, dv[15:0], d12);
            end
        end
    endtask

    task chk20;
        input integer v;
        begin
            b20 = v;
            repeat (2 * 20 + 4) @(negedge clk);
            if (d20 !== dec(v, 999999, 6)) begin
                errors = errors + 1;
                if (errors < 10) $display("MISMATCH u20 v=%0d expected=%h actual=%h", v, dec(v, 999999, 6), d20);
            end
        end
    endtask

    task chk16;
        input integer v;
        begin
            b16 = v;
            repeat (2 * 16 + 4) @(negedge clk);
            dv = dec(v, 99999, 5);
            if (d16 !== dv[19:0]) begin
                errors = errors + 1;
                if (errors < 10) $display("MISMATCH u16 v=%0d expected=%h actual=%h", v, dv[19:0], d16);
            end
        end
    endtask

    integer i, j, vv;
    integer n_b2b;

    // ================= view_mux =================
    reg         vm_de, vm_sof, vm_eol, vm_eof, vm_hit;
    reg  [11:0] vm_x, vm_y;
    reg  [23:0] vm_o, vm_g, vm_m;
    reg  [1:0]  vm_mode;
    wire        vo_de, vo_sof, vo_eol, vo_eof;
    wire [23:0] vo_rgb;
    wire [11:0] vo_x, vo_y;

    view_mux #(.TINT_COLOR(24'hFF00FF)) vm (
        .clk(clk), .rst_n(rst_n),
        .in_de(vm_de), .in_x(vm_x), .in_y(vm_y), .in_sof(vm_sof), .in_eol(vm_eol), .in_eof(vm_eof),
        .rgb_orig(vm_o), .rgb_gray(vm_g), .rgb_mask(vm_m), .hit(vm_hit), .mode(vm_mode),
        .out_de(vo_de), .out_rgb(vo_rgb), .out_x(vo_x), .out_y(vo_y),
        .out_sof(vo_sof), .out_eol(vo_eol), .out_eof(vo_eof)
    );

    reg [75:0] vexp;        // expected record {de, rgb, x, y, sof, eol, eof} registered once
    reg        vchk_en;
    integer    vm_cnt;
    wire [75:0] vact = {vo_de, vo_rgb, vo_x, vo_y, vo_sof, vo_eol, vo_eof};

    function [23:0] vsel;
        input [1:0]  mode;
        input [23:0] o, g, m;
        input        hit;
        begin
            case (mode)
                2'd0: vsel = o;
                2'd1: vsel = g;
                2'd2: vsel = m;
                default: vsel = hit ? 24'hFF00FF : o;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) vexp <= 76'd0;
        else        vexp <= {vm_de, vm_de ? vsel(vm_mode, vm_o, vm_g, vm_m, vm_hit) : 24'd0,
                             vm_de ? vm_x : 12'd0, vm_de ? vm_y : 12'd0,
                             vm_de & vm_sof, vm_de & vm_eol, vm_de & vm_eof};
    end

    always @(negedge clk) begin
        if (vchk_en) begin
            vm_cnt = vm_cnt + 1;
            if (vact !== vexp) begin
                errors = errors + 1;
                if (errors < 10) $display("MISMATCH view_mux expected=%h actual=%h", vexp, vact);
            end
        end
    end

    // ================= sync_delay =================
    reg  [4:0]  sd_in;
    wire [4:0]  sd0, sd1, sd2, sd3, sd7;
    sync_delay #(.N(0), .W(5)) s0 (.clk(clk), .rst_n(rst_n), .din(sd_in), .dout(sd0));
    sync_delay #(.N(1), .W(5)) s1 (.clk(clk), .rst_n(rst_n), .din(sd_in), .dout(sd1));
    sync_delay #(.N(2), .W(5)) s2 (.clk(clk), .rst_n(rst_n), .din(sd_in), .dout(sd2));
    sync_delay #(.N(3), .W(5)) s3 (.clk(clk), .rst_n(rst_n), .din(sd_in), .dout(sd3));
    sync_delay #(.N(7), .W(5)) s7 (.clk(clk), .rst_n(rst_n), .din(sd_in), .dout(sd7));

    reg [4:0] hist [0:15];       // hist[k] = sd_in as it was k clocks ago (sampled at each posedge); cleared by reset
    integer   h;
    reg       sd_en;
    integer   sd_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (h = 0; h < 16; h = h + 1) hist[h] <= 5'd0;
        end
        else begin
            hist[1] <= sd_in;
            for (h = 2; h < 16; h = h + 1) hist[h] <= hist[h-1];
        end
    end
    // dout of delay N, seen at negedge, equals the input N clocks earlier: N = 0 -> current input, N >= 1 -> hist[N]
    always @(negedge clk) begin
        if (sd_en) begin
            sd_cnt = sd_cnt + 1;
            if (sd0 !== sd_in)    begin errors = errors + 1; if (errors < 10) $display("MISMATCH sync_delay N=0 exp=%h act=%h", sd_in, sd0); end
            if (sd1 !== hist[1])  begin errors = errors + 1; if (errors < 10) $display("MISMATCH sync_delay N=1 exp=%h act=%h", hist[1], sd1); end
            if (sd2 !== hist[2])  begin errors = errors + 1; if (errors < 10) $display("MISMATCH sync_delay N=2 exp=%h act=%h", hist[2], sd2); end
            if (sd3 !== hist[3])  begin errors = errors + 1; if (errors < 10) $display("MISMATCH sync_delay N=3 exp=%h act=%h", hist[3], sd3); end
            if (sd7 !== hist[7])  begin errors = errors + 1; if (errors < 10) $display("MISMATCH sync_delay N=7 exp=%h act=%h", hist[7], sd7); end
        end
    end

    // ================= main =================
    initial begin
        errors = 0; seed = 32'h5EED0008; vchk_en = 1'b0; sd_en = 1'b0; vm_cnt = 0; sd_cnt = 0; n_b2b = 0;
        b12 = 0; b20 = 0; b16 = 0;
        vm_de = 0; vm_sof = 0; vm_eol = 0; vm_eof = 0; vm_hit = 0; vm_x = 0; vm_y = 0;
        vm_o = 0; vm_g = 0; vm_m = 0; vm_mode = 0; sd_in = 5'd0;
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        #2 rst_n = 1'b1;
        repeat (30) @(negedge clk);

        // ---- bin2bcd: exhaustive 12-bit
        for (i = 0; i < 4096; i = i + 1) begin chk12(i); n_b2b = n_b2b + 1; end
        // ---- 20-bit instance: edges and random, incl. saturation
        chk20(0); chk20(1); chk20(9); chk20(10); chk20(99); chk20(100); chk20(999); chk20(1000);
        chk20(99999); chk20(100000); chk20(999999); chk20(1000000); chk20(1048575); chk20(500000);
        for (i = 0; i < 400; i = i + 1) begin chk20({$random(seed)} % 1048576); n_b2b = n_b2b + 1; end
        // ---- 16-bit instance
        chk16(0); chk16(9); chk16(10); chk16(65535); chk16(12345); chk16(10000); chk16(9999);
        for (i = 0; i < 400; i = i + 1) begin chk16({$random(seed)} % 65536); n_b2b = n_b2b + 1; end
        // ---- change in the middle of a conversion, then hold
        for (i = 0; i < 200; i = i + 1) begin
            b20 = {$random(seed)} % 1048576;
            repeat (3 + (i % 15)) @(negedge clk);
            vv = {$random(seed)} % 1048576;
            chk20(vv);
        end
        // ---- asynchronous reset clears the result
        @(negedge clk); #2 rst_n = 1'b0; #1;
        if (d12 !== 16'd0 || d20 !== 24'd0 || d16 !== 20'd0) begin errors = errors + 1; $display("MISMATCH bin2bcd not cleared by reset"); end
        @(negedge clk); #2 rst_n = 1'b1;
        chk12(1234); chk20(654321); chk16(4321);

        // ---- view_mux
        vchk_en = 1'b1;
        for (i = 0; i < 100000; i = i + 1) begin
            @(negedge clk);
            vm_de  = ({$random(seed)} % 8) != 0;
            vm_sof = $random(seed); vm_eol = $random(seed); vm_eof = $random(seed);
            vm_x = $random(seed); vm_y = $random(seed);
            vm_o = $random(seed); vm_g = $random(seed); vm_m = $random(seed);
            vm_hit = $random(seed); vm_mode = $random(seed);
        end
        // reset in the middle of the stream
        @(negedge clk); #2 rst_n = 1'b0; #1; @(negedge clk); @(negedge clk); vm_de = 1'b0; #2 rst_n = 1'b1;
        for (i = 0; i < 2000; i = i + 1) begin
            @(negedge clk);
            vm_de  = ({$random(seed)} % 8) != 0;
            vm_sof = $random(seed); vm_eol = $random(seed); vm_eof = $random(seed);
            vm_x = $random(seed); vm_y = $random(seed);
            vm_o = $random(seed); vm_g = $random(seed); vm_m = $random(seed);
            vm_hit = $random(seed); vm_mode = $random(seed);
        end
        @(negedge clk); vm_de = 1'b0; @(negedge clk); @(negedge clk);
        vchk_en = 1'b0;

        // ---- sync_delay
        sd_en = 1'b1;
        for (i = 0; i < 50000; i = i + 1) begin
            @(negedge clk);
            sd_in = $random(seed);
        end
        // asynchronous reset between edges: the delay lines are cleared, the history too
        @(negedge clk); #2 rst_n = 1'b0; sd_in = 5'h1F; #1; @(negedge clk); @(negedge clk); sd_in = 5'h15; #2 rst_n = 1'b1;
        for (i = 0; i < 100; i = i + 1) begin
            @(negedge clk);
            sd_in = $random(seed);
        end
        sd_en = 1'b0;

        $display("tb_osd_aux: bin2bcd checks %0d (+edges), view_mux clocks %0d, sync_delay clocks %0d, errors %0d",
                 n_b2b, vm_cnt, sd_cnt, errors);
        if (vm_cnt < 100000 || sd_cnt < 50000) begin
            errors = errors + 1;
            $display("COVERAGE too low: test would be vacuous");
        end
        if (errors == 0) $display("TB_RESULT: PASS tb_osd_aux");
        else             $display("TB_RESULT: FAIL tb_osd_aux errors=%0d", errors);
        $finish;
    end

endmodule
