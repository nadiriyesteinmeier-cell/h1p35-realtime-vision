// hdmi_testpat.v - HDMI diagnostic test patterns for 1280x720, plus the controls of the diagnostic build
//
// Purpose: separate "what the camera / DDR / our logic delivers" from "what the HDMI output stage and the screen make of it".
// While enable = 1 the module REPLACES the video stream (vs, de, data) that goes into hdmi_tx by a generated pattern; the
// pattern is derived from the timing (in_vs, in_de) of the stream it replaces, so the sync structure is unchanged. Output
// latency: 1 clock for vs / de / data together.
//
// Pattern (pat_id):
//    0 solid gray 0x80        1 solid white        2 solid black        3 solid red        4 solid green        5 solid blue
//    6 eight colour bars (white yellow cyan green magenta red blue black, 160 px each)
//    7 horizontal gray ramp   8 vertical gray ramp
//    9 grid: 2 px white lines every 64 px in x and y over black, 2 px white frame at the very edges of the image
//   10 alternating 1-pixel columns (black / white)      11 alternating 2-pixel columns
//   12 edge markers: left 16 columns red, right 16 columns green, top 8 rows blue, bottom 8 rows yellow, rest dark gray 0x40
//   13 8x8 checkerboard      14 sixteen gray steps (0, 17, ... 255, 80 px each)
//   15 x ruler: 2 px lines every 32 px in x on black, colours cycling white / red / green / blue with x/32, plus a 2 px white
//      line at y = 360 (so the position of any fixed screen artefact can be read off in source pixels)
//
// Controls (push buttons, active low, debounced; they only act while enable = 1):
//   KEY3  next pattern (wraps 15 -> 0)      KEY4  previous pattern (wraps 0 -> 15)
//   KEY1  next serializer capture phase load_sel (0 -> 1 -> 2 -> 0)    KEY2  back to pattern 0 / load_sel 0
// load_sel goes to the diagnostic copy of the HDMI serializer (lane_lvds_10_1 in the hdmi_phy_wrapper): 0 = the original
// vendor behaviour, 1 / 2 = the parallel TMDS word is captured 1 / 2 serial clocks earlier. At power-up and whenever enable
// is low, pat_id = 0 and load_sel = 0 (original behaviour).
// 'digits' are the eight seven-segment digit codes (see seg7_scan.v): "<pat_id 2 digits>  <load_sel>".
// Reset: active-low asynchronous.

module hdmi_testpat #(
    parameter integer DEB = 1500000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire [3:0]  key_n,

    input  wire        in_vs,
    input  wire        in_de,

    output reg         out_vs,
    output reg         out_de,
    output reg  [23:0] out_data,

    output reg  [3:0]  pat_id,
    output reg  [1:0]  load_sel,
    output wire [31:0] digits
);

    // ---------------- keys
    wire [3:0] down;
    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_key
            key_debounce #(.DEB(DEB)) u_kd (.clk(clk), .rst_n(rst_n), .raw_n(key_n[gi]), .down(down[gi]));
        end
    endgenerate
    reg [3:0] dq;
    wire [3:0] press = down & ~dq;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dq <= 4'd0; pat_id <= 4'd0; load_sel <= 2'd0;
        end
        else begin
            dq <= down;
            if (!enable) begin
                pat_id <= 4'd0; load_sel <= 2'd0;
            end
            else begin
                if (press[2])      pat_id <= pat_id + 4'd1;
                else if (press[3]) pat_id <= pat_id - 4'd1;
                if (press[0])      load_sel <= (load_sel == 2'd2) ? 2'd0 : (load_sel + 2'd1);
                if (press[1]) begin pat_id <= 4'd0; load_sel <= 2'd0; end
            end
        end
    end

    // digits: pattern id as two decimal digits at the left, load_sel at digit 3, the rest blank (code 15)
    wire [3:0] p_tens = (pat_id >= 4'd10) ? 4'd1 : 4'd0;
    wire [3:0] p_ones = (pat_id >= 4'd10) ? (pat_id - 4'd10) : pat_id;
    assign digits = {4'd15, 4'd15, 4'd15, 4'd15, {2'b00, load_sel}, 4'd15, p_ones, p_tens};

    // ---------------- pixel position from the incoming timing
    reg [11:0] x, y;
    reg        de_q, vs_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 12'd0; y <= 12'd0; de_q <= 1'b0; vs_q <= 1'b0;
        end
        else begin
            de_q <= in_de;
            vs_q <= in_vs;
            x <= in_de ? (x + 12'd1) : 12'd0;
            if (in_vs && !vs_q)           y <= 12'd0;
            else if (!in_de && de_q)      y <= y + 12'd1;
        end
    end

    // ---------------- patterns (x, y are the coordinates of the pixel that is on the input in this clock)
    wire [20:0] xr   = x * 9'd205;                    // x * 205 >> 10 ~ x / 5.0
    wire [7:0]  ramp_x = (xr[20:10] > 11'd255) ? 8'd255 : xr[17:10];
    wire [16:0] yr   = y * 7'd91;                     // y * 91 >> 8 ~ y * 0.355
    wire [7:0]  ramp_y = (yr[16:8] > 9'd255) ? 8'd255 : yr[15:8];
    wire [25:0] sr   = x * 15'd205;                   // x * 205 >> 14 ~ x / 80
    wire [8:0]  sh   = sr[22:14];
    wire [3:0]  step = (sh > 9'd15) ? 4'd15 : sh[3:0];
    wire [7:0]  step_gray = {step, step};             // 17 * step

    reg [23:0] pix;
    always @* begin
        case (pat_id)
            4'd0:  pix = 24'h808080;
            4'd1:  pix = 24'hFFFFFF;
            4'd2:  pix = 24'h000000;
            4'd3:  pix = 24'hFF0000;
            4'd4:  pix = 24'h00FF00;
            4'd5:  pix = 24'h0000FF;
            4'd6:  pix = (x < 12'd160) ? 24'hFFFFFF : (x < 12'd320) ? 24'hFFFF00 : (x < 12'd480) ? 24'h00FFFF :
                         (x < 12'd640) ? 24'h00FF00 : (x < 12'd800) ? 24'hFF00FF : (x < 12'd960) ? 24'hFF0000 :
                         (x < 12'd1120) ? 24'h0000FF : 24'h000000;
            4'd7:  pix = {ramp_x, ramp_x, ramp_x};
            4'd8:  pix = {ramp_y, ramp_y, ramp_y};
            4'd9:  pix = (x[5:0] < 6'd2 || y[5:0] < 6'd2 || x >= 12'd1278 || y >= 12'd718) ? 24'hFFFFFF : 24'h000000;
            4'd10: pix = x[0] ? 24'hFFFFFF : 24'h000000;
            4'd11: pix = x[1] ? 24'hFFFFFF : 24'h000000;
            4'd12: pix = (x < 12'd16) ? 24'hFF0000 : (x >= 12'd1264) ? 24'h00FF00 :
                         (y < 12'd8) ? 24'h0000FF : (y >= 12'd712) ? 24'hFFFF00 : 24'h404040;
            4'd13: pix = (x[3] ^ y[3]) ? 24'hFFFFFF : 24'h000000;
            4'd14: pix = {step_gray, step_gray, step_gray};
            default: begin
                if (y >= 12'd360 && y < 12'd362)  pix = 24'hFFFFFF;
                else if (x[4:0] < 5'd2)           pix = (x[6:5] == 2'd0) ? 24'hFFFFFF : (x[6:5] == 2'd1) ? 24'hFF0000 :
                                                         (x[6:5] == 2'd2) ? 24'h00FF00 : 24'h0000FF;
                else                              pix = 24'h000000;
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_vs <= 1'b0; out_de <= 1'b0; out_data <= 24'd0;
        end
        else begin
            out_vs   <= in_vs;
            out_de   <= in_de;
            out_data <= (enable && in_de) ? pix : 24'd0;
        end
    end

endmodule
