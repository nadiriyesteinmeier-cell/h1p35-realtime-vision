`timescale 1ns/1ps
// tb_he_eq.v - he_eq against a model written here: histogram of the samples (x, y even) of frame f, cdf, lut = min(255, (cdf*74274 + 2^25) >> 26),
// bars = min(127, bin >> 5); in frame f+1 (enable = 1) every output pixel = clamp(c + lut[Y] - Y) per channel, the graph field (16..271 x 584..711)
// darkened with grey bars and the yellow curve; enable = 0 or no mapping yet: unchanged. Output order and the 2-clock latency of de / vs checked.
// The first build after reset only clears the (uninitialised) histogram: the mapping is used from the second build on.
// Frames (picture / enable): 0 low contrast / 1 (no mapping yet: unchanged), 1 high contrast / 1 (still none: the first build only cleared),
// 2 dark picture with a bright block / 1 (mapping of frame 1), 3 low contrast / 1 (mapping of frame 2), 4 dark + block / 0 (unchanged).
module tb_he_eq;
    localparam integer W = 1280, H = 720, GX = 16, GY = 584, NF = 5;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;
    reg de = 1'b0, vs = 1'b0, en = 1'b0;
    reg [11:0] x = 12'd0, y = 12'd0;
    reg [23:0] d = 24'd0;
    wire ovs, ode;
    wire [23:0] od;
    he_eq #(.GX(GX), .GY(GY)) dut (.clk(clk), .rst_n(rst_n), .s_de(de), .s_x(x), .s_y(y), .s_rgb(d),
                                   .enable(en), .in_vs(vs), .in_de(de), .in_data(d), .out_vs(ovs), .out_de(ode), .out_data(od));

    function [23:0] pic;
        input integer f, px, py;
        integer r, g, b, n;
        begin
            n = ((px * 13) ^ (py * 7) ^ (px * py)) & 15;
            if (f == 0)      begin r = 70 + (px >> 5) + n; g = 80 + (py >> 4) + n; b = 60 + ((px + py) >> 6); end
            else if (f == 1) begin r = (px * 255) / 1279; g = (py * 255) / 719; b = (px + py) & 255; end
            else             begin r = 20 + n; g = 25 + n; b = 18 + (n >> 1); if (px >= 400 && px < 700 && py >= 200 && py < 400) begin r = 230; g = 220; b = 210; end end
            pic = {r[7:0], g[7:0], b[7:0]};
        end
    endfunction
    function [7:0] luma;
        input [23:0] p;
        integer s;
        begin s = p[23:16] + 2 * p[15:8] + p[7:0]; luma = s >> 2; end
    endfunction
    function [7:0] cl;
        input integer v;
        begin cl = (v < 0) ? 8'd0 : (v > 255) ? 8'd255 : v; end
    endfunction

    integer hist [0:255];
    integer lut  [0:255];
    integer bar  [0:255];
    integer have_lut = 0, nbuild = 0;
    integer f, i, j, k, cdf, errors = 0, nout = 0, wp = 0, rp = 0;
    reg [23:0] q [0:4095];
    reg [2:0] vs_d, de_d;

    task build;
        integer v;
        reg [63:0] p;
        begin
            cdf = 0;
            for (v = 0; v < 256; v = v + 1) begin
                cdf = cdf + hist[v];
                p = cdf * 64'd74274 + 64'd33554432;
                lut[v] = ((p >> 26) > 255) ? 255 : (p >> 26);
                bar[v] = ((hist[v] >> 5) > 127) ? 127 : (hist[v] >> 5);
            end
        end
    endtask
    function [23:0] expect_px;
        input integer fr, px, py, apply;
        input [23:0] p;
        integer yv, dy, hgt, gc;
        reg [23:0] v;
        begin
            v = p;
            if (apply) begin
                yv = luma(p); dy = lut[yv] - yv;
                v = {cl(p[23:16] + dy), cl(p[15:8] + dy), cl(p[7:0] + dy)};
                if (px >= GX && px < GX + 256 && py >= GY && py < GY + 128) begin
                    hgt = 127 - (py - GY);
                    gc = lut[px - GX] >> 1;
                    if (hgt == gc || hgt == gc + 1) v = 24'hFFE000;
                    else if (hgt < bar[px - GX]) v = 24'hB0B0B0;
                    else v = {1'b0, v[23:17], 1'b0, v[15:9], 1'b0, v[7:1]};
                end
            end
            expect_px = v;
        end
    endfunction

    always @(posedge clk) begin vs_d <= {vs_d[1:0], vs}; de_d <= {de_d[1:0], de}; end
    always @(posedge clk) if (rst_n) begin
        if (ovs !== vs_d[1] || ode !== de_d[1]) begin errors = errors + 1; if (errors < 10) $display("MISMATCH vs/de alignment"); end
        if (ode) begin
            if (od !== q[rp % 4096]) begin errors = errors + 1; if (errors < 20) $display("MISMATCH pixel %0d: %h expected %h", rp, od, q[rp % 4096]); end
            rp = rp + 1; nout = nout + 1;
        end
    end

    integer use_lut;
    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        for (f = 0; f < NF; f = f + 1) begin
            en = (f != 4);
            use_lut = en && have_lut;
            @(negedge clk); vs = 1'b1; repeat (50) @(negedge clk); vs = 1'b0; repeat (100) @(negedge clk);
            for (k = 0; k < 256; k = k + 1) hist[k] = 0;
            for (j = 0; j < H; j = j + 1) begin
                for (i = 0; i < W; i = i + 1) begin
                    @(negedge clk); de = 1'b1; x = i; y = j; d = pic((f == 3) ? 0 : (f == 4) ? 2 : f, i, j);
                    if (i % 2 == 0 && j % 2 == 0) hist[luma(d)] = hist[luma(d)] + 1;
                    q[wp % 4096] = expect_px(f, i, j, use_lut, d); wp = wp + 1;
                end
                @(negedge clk); de = 1'b0; x = 12'd0; y = 12'd0; d = 24'd0;
                repeat (29) @(negedge clk);
            end
            repeat (400) @(negedge clk);                       // the mapping is rebuilt here (about 260 clocks)
            build; nbuild = nbuild + 1; have_lut = (nbuild >= 2);
            $display("frame %0d: enable %0d, mapping used %0d, lut[64] %0d lut[128] %0d lut[192] %0d", f, en, use_lut, lut[64], lut[128], lut[192]);
        end
        if (rp != wp || nout != NF * W * H) begin errors = errors + 1; $display("MISMATCH count %0d %0d %0d", rp, wp, nout); end
        if (errors == 0) $display("TB_RESULT: PASS tb_he_eq");
        else             $display("TB_RESULT: FAIL tb_he_eq errors=%0d", errors);
        $finish;
    end
endmodule
