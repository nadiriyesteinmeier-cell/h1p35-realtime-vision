`timescale 1ns/1ps
// tb_top_osd.v - top_osd against a per-pixel model written here
// Two 1280 x 720 frames of a pseudo-random picture. Frame 0: motion page off. Frame 1: motion page on, 5 moving cells, box 3..5 x 2..4.
// Every output pixel is compared with the model: stamp pixels (black), logo (blend with the ROM's alpha / class), plate, darkened text field,
// motion tint, box border, untouched elsewhere. Inside the text cells the model accepts white (glyph) or the field colour, and the number
// of white pixels per text line must be > 0 (and 0 for the MOTION line while the page is off). Output order and the 3-clock latency are
// checked through a FIFO of expected values (de / vs delayed by exactly 3 clocks).
module tb_top_osd;
    localparam integer W = 1280, H = 720;
    localparam integer TX = 1108, TY = 16, LX = 16, LY = 16;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;
    reg vs = 1'b0, de = 1'b0;
    reg [23:0] din = 24'd0;
    wire ovs, ode;
    wire [23:0] dout;
    reg  mot = 1'b0;
    wire [4:0]  raddr;
    reg  [31:0] rdata = 32'd0;
    reg  [31:0] map [0:31];
    always @(posedge clk) rdata <= map[raddr];
    top_osd #(.TX(TX), .TY(TY)) dut (
        .clk(clk), .rst_n(rst_n), .in_vs(vs), .in_de(de), .in_data(din), .out_vs(ovs), .out_de(ode), .out_data(dout),
        .lat_valid(1'b1), .lat_us(17'd16789), .max_us(17'd28456), .lat_fr(4'd1),
        .motion_en(mot), .he_en(1'b0), .mot_count(10'd5), .mot_bx0(5'd3), .mot_bx1(5'd5), .mot_by0(5'd2), .mot_by1(5'd4),
        .map_raddr(raddr), .map_rdata(rdata));

    function [23:0] pic;
        input integer f, px, py;
        integer h;
        begin
            h = (px * 1103515245 + py * 12345 + f * 777) ^ (px * py);
            pic = h[23:0];
        end
    endfunction
    function [7:0] bl;
        input [7:0] v, c;
        input [4:0] a;
        integer p;
        begin p = v * (16 - a) + c * a; bl = p >> 4; end
    endfunction

    // expected values: 24-bit colour + flag "text cell" (white also accepted) + text line
    reg [23:0] q_val [0:4095];
    reg        q_txt [0:4095];
    reg [1:0]  q_ln  [0:4095];
    integer wp = 0, rp = 0, errors = 0, f, i, j, nout = 0;
    integer white [0:2];
    integer wsum [0:2];                 // sum of the x positions of the white pixels: position-sensitive
    integer qdepth;
    integer fd;
    initial fd = $fopen("text_area.txt", "w");

    task expect_px(input integer fr, input integer px, input integer py, input [23:0] v_in);
        reg [23:0] v;
        reg [5:0]  lq;
        integer a, ldx, ldy, ln, ry, pr, pg, pb;
        reg txt;
        begin
            v = v_in;
            if (fr == 1 && map[py / 40][px / 40]) v = {1'b1, v[23:17], 1'b0, v[15:9], 1'b0, v[7:1]};
            if (fr == 1 && px >= 120 - 3 && px <= 239 + 3 && py >= 80 - 3 && py <= 199 + 3 && !(px > 120 && px < 239 && py > 80 && py < 199)) v = 24'hFFE000;
            if (px >= TX - 4 && px < TX + 13 * 12 + 4 && py >= TY - 4 && py < TY + ((fr == 1) ? 60 : 40)) v = {1'b0, v[23:17], 1'b0, v[15:9], 1'b0, v[7:1]};
            if (px >= LX - 6 && px < LX + 166 && py >= LY - 6 && py < LY + 100) begin
                pr = (v[23:16] + 765) >> 2; pg = (v[15:8] + 765) >> 2; pb = (v[7:0] + 765) >> 2;
                v = {pr[7:0], pg[7:0], pb[7:0]};
            end
            ldx = px - LX; ldy = py - LY;
            if (ldx >= 0 && ldx < 160 && ldy >= 0 && ldy < 94) begin
                lq = dut.u_logo.mem[ldy * 160 + ldx];
                a = lq[4:0];
                if (lq[5]) v = {bl(v[23:16], 8'hED, a), bl(v[15:8], 8'h1C, a), bl(v[7:0], 8'h24, a)};
                else       v = {bl(v[23:16], 8'h1C, a), bl(v[15:8], 8'h2D, a), bl(v[7:0], 8'h4E, a)};
            end
            txt = 1'b0; ln = 0;
            if (px >= TX && px < TX + 13 * 12 && py >= TY) begin
                ln = (py - TY) / 20; ry = (py - TY) % 20;
                if (ln <= 2 && ry < 16 && (ln < 2 || fr == 1)) txt = 1'b1;
            end
            if (py == 0 && px < 8) v = 24'h000000;
            q_val[wp % 4096] = v; q_txt[wp % 4096] = txt && !(py == 0 && px < 8); q_ln[wp % 4096] = ln; wp = wp + 1;
        end
    endtask

    reg [2:0] vs_d, de_d;
    always @(posedge clk) begin vs_d <= {vs_d[1:0], vs}; de_d <= {de_d[1:0], de}; end
    always @(posedge clk) if (rst_n) begin
        if (ovs !== vs_d[2] || ode !== de_d[2]) begin errors = errors + 1; if (errors < 10) $display("MISMATCH vs/de alignment"); end
        if (ode) begin
            if (rp >= wp) begin errors = errors + 1; if (errors < 10) $display("MISMATCH output pixel without input"); end
            else begin
                if (!(dout === q_val[rp % 4096] || (q_txt[rp % 4096] && dout === 24'hFFFFFF))) begin
                    errors = errors + 1;
                    if (errors < 20) $display("MISMATCH pixel %0d: %h expected %h (text %b)", rp, dout, q_val[rp % 4096], q_txt[rp % 4096]);
                end
                if (q_txt[rp % 4096] && dout === 24'hFFFFFF && q_val[rp % 4096] !== 24'hFFFFFF) begin
                    white[q_ln[rp % 4096]] = white[q_ln[rp % 4096]] + 1; wsum[q_ln[rp % 4096]] = wsum[q_ln[rp % 4096]] + (rp % W);
                end
                if (f == 1 && (rp % (W * H)) / W >= TY && (rp % (W * H)) / W < TY + 56 && (rp % W) >= TX && (rp % W) < TX + 156) begin
                    $fwrite(fd, "%s", (dout === 24'hFFFFFF) ? "#" : ".");
                    if ((rp % W) == TX + 155) $fwrite(fd, "\n");
                end
                rp = rp + 1; nout = nout + 1;
            end
        end
    end

    initial begin
        for (i = 0; i < 32; i = i + 1) map[i] = 32'd0;
        map[2] = 32'h18; map[3] = 32'h20; map[4] = 32'h28;          // cells (3,2) (4,2) (5,3) (3,4) (5,4)
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        for (f = 0; f < 2; f = f + 1) begin
            white[0] = 0; white[1] = 0; white[2] = 0; wsum[0] = 0; wsum[1] = 0; wsum[2] = 0;
            mot = (f == 1);
            @(negedge clk); vs = 1'b1; repeat (50) @(negedge clk); vs = 1'b0; repeat (200) @(negedge clk);
            for (j = 0; j < H; j = j + 1) begin
                for (i = 0; i < W; i = i + 1) begin
                    @(negedge clk); de = 1'b1; din = pic(f, i, j);
                    expect_px(f, i, j, din);
                end
                @(negedge clk); de = 1'b0; din = 24'd0;
                repeat (29) @(negedge clk);
            end
            repeat (20) @(negedge clk);
            $display("frame %0d: %0d pixels out, white text pixels per line %0d %0d %0d, x sums %0d %0d %0d", f, nout, white[0], white[1], white[2], wsum[0], wsum[1], wsum[2]);
            // glyph pixel counts and x-position sums of "LAT 16.7MS 1F" / "MAX 28.4MS" / "MOTION 005" (text checked by eye in logs_custom/adv/text_area.txt)
            if (white[0] != 548 || wsum[0] != 648966 || white[1] != 524 || wsum[1] != 611626 ||
                (f == 1 && (white[2] != 576 || wsum[2] != 672960)) || (f == 0 && white[2] != 0)) begin
                errors = errors + 1; $display("MISMATCH text lines frame %0d", f);
            end
        end
        if (rp != wp || nout != 2 * W * H) begin errors = errors + 1; $display("MISMATCH count %0d %0d %0d", rp, wp, nout); end
        if (errors == 0) $display("TB_RESULT: PASS tb_top_osd");
        else             $display("TB_RESULT: FAIL tb_top_osd errors=%0d", errors);
        $finish;
    end
endmodule
