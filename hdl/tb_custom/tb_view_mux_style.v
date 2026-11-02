`timescale 1ns/1ps
// Camera display regression: retain shadow detail, paper shading and visible contours.
module tb_view_mux_style;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, de = 0, page = 1, edge_px = 0;
    reg [1:0] mode = 0;
    reg [7:0] gray = 0;
    reg [23:0] rgb = 0;
    wire out_de;
    wire [23:0] out_rgb;
    integer errors = 0, v, previous, channel, difference;
    view_mux_style dut (.clk(clk), .rst_n(rst_n), .in_de(de),
        .in_x(12'd20), .in_y(12'd30), .in_sof(1'b0), .in_eol(1'b0), .in_eof(1'b0),
        .rgb_orig(rgb), .gray(gray), .edge_px(edge_px),
        .hit_r(1'b0), .hit_g(1'b0), .hit_b(1'b0), .page(page), .mode(mode),
        .out_de(out_de), .out_rgb(out_rgb), .out_x(), .out_y(),
        .out_sof(), .out_eol(), .out_eof());
    task sample;
        begin @(posedge clk); #1; end
    endtask
    task check;
        input condition;
        input [511:0] message;
        begin if (condition !== 1'b1) begin
            errors = errors + 1;
            if (errors <= 10) $display("ERROR: %0s, RGB=%h", message, out_rgb);
        end end
    endtask
    initial begin
        repeat (2) sample;
        check(out_de === 0 && out_rgb === 0, "reset blanks output");
        @(negedge clk); rst_n = 1; de = 1;
        previous = -1;
        for (v = 0; v < 256; v = v + 1) begin
            @(negedge clk); mode = 0; gray = v; rgb = {3{gray}}; sample;
            channel = out_rgb[7:0];
            check(channel >= 96 && channel <= 223, "paper retains shading without white clipping");
            check(out_rgb[23:16] == channel && out_rgb[15:8] == channel, "paper is neutral gray");
            check(channel >= previous, "paper shading is monotonic"); previous = channel;
            @(negedge clk); mode = 1; sample;
            channel = out_rgb[7:0]; difference = channel - v;
            check(channel >= 16 && channel <= 240 && difference >= -16 && difference <= 16,
                "cartoon quantization preserves channel brightness within 16 levels");
            check(out_rgb[23:16] == channel && out_rgb[15:8] == channel, "neutral input stays neutral");
        end
        @(negedge clk); mode = 2; rgb = 24'h808080; edge_px = 0; sample;
        check(out_rgb === 24'h404040, "edge view dims background for contour contrast");
        @(negedge clk); edge_px = 1; sample;
        check(out_rgb === 24'h00FF80, "edge view keeps bright green contours");
        @(negedge clk); mode = 0; sample;
        check(out_rgb === 24'h101010, "sketch contour stays dark");
        @(negedge clk); mode = 1; sample;
        check(out_rgb === 24'h000000, "cartoon contour stays black");
        @(negedge clk); page = 0; mode = 0; sample;
        check(out_rgb === rgb, "analysis original view is unchanged");
        @(negedge clk); page = 1; mode = 3; gray = 0; sample;
        check(out_rgb === 24'h0000FF, "pseudo-color dark endpoint remains blue");
        @(negedge clk); gray = 255; sample;
        check(out_rgb === 24'hFF0300, "pseudo-color bright endpoint remains red");
        @(negedge clk); de = 0; sample;
        check(out_de === 0 && out_rgb === 0, "blanking clears pixels");
        if (errors == 0) $display("TB_RESULT: PASS tb_view_mux_style");
        else $display("TB_RESULT: FAIL tb_view_mux_style errors=%0d", errors);
        $finish;
    end
endmodule
