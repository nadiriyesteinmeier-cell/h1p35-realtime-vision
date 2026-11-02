`timescale 1ns/1ps
// HX1P35 board contract: PNP digit drivers select LOW; segments also light LOW.
module tb_seg7_scan;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg [31:0] digits = 32'h987A6543;
    wire [7:0] seg, sel;
    seg7_scan #(.TICK(3)) dut (.clk(clk), .rst_n(rst_n), .digits(digits), .seg(seg), .sel(sel));
    reg [7:0] expected [0:7];
    reg [7:0] seen = 0;
    integer cycle, digit, selected, errors = 0;
    initial begin
        // Display from left to right: 3 4 5 6 F 7 8 9 (decimal point off).
        expected[0] = 8'hB0; expected[1] = 8'h99;
        expected[2] = 8'h92; expected[3] = 8'h82;
        expected[4] = 8'h8E; expected[5] = 8'hF8;
        expected[6] = 8'h80; expected[7] = 8'h90;
        repeat (2) @(negedge clk);
        if (sel !== 8'hFF || seg !== 8'hFF) begin
            $display("ERROR: reset must switch all PNP digits and segments off"); errors = errors + 1;
        end
        rst_n = 1;
        for (cycle = 0; cycle < 48; cycle = cycle + 1) begin
            @(posedge clk); #1;
            selected = 0;
            for (digit = 0; digit < 8; digit = digit + 1) begin
                if (sel[digit] === 1'b0) begin
                    selected = selected + 1; seen[digit] = 1;
                    if (seg !== expected[digit]) begin
                        $display("ERROR: digit %0d has segment %h, expected %h", digit, seg, expected[digit]);
                        errors = errors + 1;
                    end
                end
            end
            if (selected != 1 || (^sel === 1'bx)) begin
                $display("ERROR: exactly one LOW digit-select required, sel=%h", sel); errors = errors + 1;
            end
        end
        if (seen !== 8'hFF) begin $display("ERROR: some digits never selected"); errors = errors + 1; end
        @(negedge clk); rst_n = 0; #1;
        if (sel !== 8'hFF || seg !== 8'hFF) begin $display("ERROR: reset while scanning"); errors = errors + 1; end
        if (errors == 0) $display("TB_RESULT: PASS tb_seg7_scan");
        else $display("TB_RESULT: FAIL tb_seg7_scan errors=%0d", errors);
        $finish;
    end
endmodule
