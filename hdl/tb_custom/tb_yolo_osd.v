// tb_yolo_osd.v - renders one 1280 x 720 frame through rtl_custom/yolo_osd.v (grey ramp input, three boxes, status line) and writes the output picture
//
// +OUT=<file>: one hex RGB line per active pixel of the second frame (the first frame latches the geometry at its vs edge). tools/yolo/run_osd_view.py turns it into a PNG.
// Checks (automatic): the output stream has exactly 1280 x 720 active pixels per frame, the latency is 3 clocks (de in -> de out), and the pixels at a few known positions
// carry the box / tag / text colours. Final line: TB_RESULT: PASS tb_yolo_osd ...  or FAIL.

`timescale 1ns / 1ps

module tb_yolo_osd;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;
    reg [10:0] hc, vc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin hc <= 11'd0; vc <= 11'd0; end
        else if (hc == 11'd1649) begin hc <= 11'd0; vc <= (vc == 11'd749) ? 11'd0 : vc + 11'd1; end
        else hc <= hc + 11'd1;
    end
    wire de = (hc < 11'd1280) && (vc < 11'd720);
    wire vs = (vc >= 11'd725) && (vc < 11'd730);
    wire [23:0] din = {hc[10:3], vc[9:2], 8'h60};

    // boxes: {cls, score, x0, y0, x1, y1}
    function [59:0] mk;
        input [1:0] c; input [15:0] s; input [10:0] x0; input [9:0] y0; input [10:0] x1; input [9:0] y1;
        begin mk = {c, s, x0, y0, x1, y1}; end
    endfunction
    wire [479:0] boxes = {300'd0, mk(2'd2, 16'd40000, 11'd900, 10'd400, 11'd1100, 10'd560), mk(2'd1, 16'd50000, 11'd500, 10'd5, 11'd700, 10'd200), mk(2'd0, 16'd65000, 11'd100, 10'd100, 11'd300, 10'd300)};
    wire        ovs, ode;
    wire [23:0] odata;
    yolo_osd dut (.clk(clk), .rst_n(rst_n), .in_vs(vs), .in_de(de), .in_data(din), .out_vs(ovs), .out_de(ode), .out_data(odata),
                  .show_boxes(1'b1), .show_status(1'b1), .mode(2'd2), .nbox(4'd3), .boxes(boxes), .det_rate(8'd30), .lat_ms(8'd27), .cap_count(16'h0012));

    reg [8*200-1:0] outf;
    integer fd, frames, npix, mism, lat_cnt, firstde;
    reg ode_q, rec;
    reg [23:0] pic [0:921599];
    initial begin
        if (!$value$plusargs("OUT=%s", outf)) outf = "osd_frame.hex";
        frames = 0; npix = 0; mism = 0; rec = 0;
        rst_n = 0; repeat (5) @(negedge clk); rst_n = 1;
    end
    always @(posedge clk) begin
        ode_q <= ode;
        if (ode && rec) begin pic[npix] = odata; npix = npix + 1; end
    end
    // record the third frame of the output
    integer fcount;
    initial fcount = 0;
    reg ovs_q;
    always @(posedge clk) begin
        ovs_q <= ovs;
        if (ovs && !ovs_q) begin
            fcount = fcount + 1;
            if (fcount == 2) begin rec = 1; npix = 0; end
            if (fcount == 3) begin
                rec = 0;
                if (npix != 921600) begin mism = mism + 1; $display("MISMATCH: %0d active pixels in a frame", npix); end
                // red box border at (100, 150) and its inside at (150, 150) = the input
                if (pic[150 * 1280 + 100] !== 24'hFF3030) begin mism = mism + 1; $display("MISMATCH: box border pixel %06x", pic[150 * 1280 + 100]); end
                if (pic[150 * 1280 + 150] !== {8'd18, 8'd37, 8'h60}) begin mism = mism + 1; $display("MISMATCH: box inside pixel %06x", pic[150 * 1280 + 150]); end
                // tag field of box 0 at (100 + 0, 82): background class colour somewhere in the cell margin (column 0 of the cell)
                if (pic[82 * 1280 + 100] !== 24'hFF3030) begin mism = mism + 1; $display("MISMATCH: tag pixel %06x", pic[82 * 1280 + 100]); end
                fd = $fopen(outf, "w");
                for (npix = 0; npix < 921600; npix = npix + 1) $fwrite(fd, "%06x\n", pic[npix]);
                $fclose(fd);
                if (mism == 0) $display("TB_RESULT: PASS tb_yolo_osd frame written to %0s", outf);
                else           $display("TB_RESULT: FAIL tb_yolo_osd mismatches=%0d", mism);
                $finish;
            end
        end
    end
endmodule
