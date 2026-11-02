// ui_ctrl.v - run-time settings from the four board push buttons (KEY1..KEY4, low = pressed)
//
//   KEY1  (short press, acts on release)  toggle 'recog_en'    : three-colour recognition panel and coloured boxes
//   KEY2  (short press, acts on release)  toggle 'adaptive_en' : adaptive segmentation thresholds
//   KEY2  (long press, >= LONG clocks)    toggle 'style_page'  : view page 0 (analysis) <-> page 1 (style); the release that
//                                          follows a long press does NOT toggle the thresholds
//   KEY1 + KEY2 pressed together          'clear_pulse' (1 clock): clear the crossing counters; the two releases that
//                                          follow do NOT toggle anything
//   KEY3  press / hold                    line_x -= STEP  (auto-repeat while held)
//   KEY4  press / hold                    line_x += STEP  (auto-repeat while held)
// line_x is limited to LINE_MIN..LINE_MAX, power-on / reset values: recog_en = 0, adaptive_en = 0, style_page = 0,
// line_x = LINE_INIT.
// Defaults of the timing parameters are for a 75 MHz clock: debounce 20 ms, auto-repeat after 0.4 s, then every 0.1 s,
// long press 1 s.
// Reset: active-low asynchronous.

module ui_ctrl #(
    parameter integer DEB       = 1500000,
    parameter integer HOLD0     = 30000000,
    parameter integer REP       = 7500000,
    parameter integer LONG      = 75000000,
    parameter integer LINE_INIT = 640,
    parameter integer LINE_MIN  = 32,
    parameter integer LINE_MAX  = 1247,
    parameter integer STEP      = 16
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [3:0]  key_n,

    output reg         recog_en,
    output reg         adaptive_en,
    output reg         style_page,
    output reg  [11:0] line_x,
    output reg         clear_pulse
);

    wire [3:0] down;
    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_key
            key_debounce #(.DEB(DEB)) u_kd (.clk(clk), .rst_n(rst_n), .raw_n(key_n[gi]), .down(down[gi]));
        end
    endgenerate

    reg [3:0] dq;                   // down, one clock ago
    reg       combo1, combo2;       // this press of KEY1 / KEY2 was part of a KEY1+KEY2 chord
    reg [31:0] h3, h4;              // hold timers of KEY3 / KEY4 (saturate at HOLD0)
    reg [31:0] c3, c4;              // auto-repeat interval counters
    reg [31:0] h2;                  // hold timer of KEY2 (long press)

    wire both_now  = down[0] & down[1];
    wire both_prev = dq[0] & dq[1];

    wire rel1 = ~down[0] & dq[0];
    wire rel2 = ~down[1] & dq[1];
    wire prs3 = down[2] & ~dq[2];
    wire prs4 = down[3] & ~dq[3];

    wire rep3 = down[2] & (h3 >= HOLD0) & (c3 >= REP - 1);
    wire rep4 = down[3] & (h4 >= HOLD0) & (c4 >= REP - 1);

    function [11:0] step_line;
        input [11:0] cur;
        input        inc;
        reg   [12:0] t;
        begin
            if (inc) begin
                t = {1'b0, cur} + STEP;
                step_line = (t > LINE_MAX) ? LINE_MAX : t[11:0];
            end
            else begin
                t = {1'b0, cur} - STEP;
                step_line = (cur <= LINE_MIN + STEP) ? LINE_MIN : t[11:0];
            end
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dq <= 4'd0; combo1 <= 1'b0; combo2 <= 1'b0; h3 <= 32'd0; h4 <= 32'd0; c3 <= 32'd0; c4 <= 32'd0; h2 <= 32'd0; style_page <= 1'b0;
            recog_en <= 1'b0; adaptive_en <= 1'b0; line_x <= LINE_INIT; clear_pulse <= 1'b0;
        end
        else begin
            dq <= down;
            clear_pulse <= 1'b0;

            // chord
            if (both_now & ~both_prev) begin
                clear_pulse <= 1'b1;
                combo1 <= 1'b1;
                combo2 <= 1'b1;
            end
            // toggles on release unless the press was part of a chord
            if (rel1) begin
                if (!combo1) recog_en <= ~recog_en;
                combo1 <= 1'b0;
            end
            if (rel2) begin
                if (!combo2) adaptive_en <= ~adaptive_en;
                combo2 <= 1'b0;
            end

            // long press of KEY2 (one shot): style page; the release then does not toggle the thresholds
            if (!down[1])               h2 <= 32'd0;
            else if (h2 < LONG)         h2 <= h2 + 32'd1;
            if (down[1] && h2 == LONG - 1 && !combo2) begin
                style_page <= ~style_page;
                combo2     <= 1'b1;
            end

            // hold timers
            if (!down[2])           begin h3 <= 32'd0;  c3 <= 32'd0; end
            else if (h3 < HOLD0)    begin h3 <= h3 + 32'd1; c3 <= 32'd0; end
            else                    c3 <= rep3 ? 32'd0 : (c3 + 32'd1);
            if (!down[3])           begin h4 <= 32'd0;  c4 <= 32'd0; end
            else if (h4 < HOLD0)    begin h4 <= h4 + 32'd1; c4 <= 32'd0; end
            else                    c4 <= rep4 ? 32'd0 : (c4 + 32'd1);

            // line position
            if (prs3 | rep3)      line_x <= step_line(line_x, 1'b0);
            else if (prs4 | rep4) line_x <= step_line(line_x, 1'b1);
        end
    end

endmodule
