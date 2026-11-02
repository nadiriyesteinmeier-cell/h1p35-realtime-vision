// osd_overlay.v - on-screen display: Anlogic logo, status text, target box / crosshair, counting line
//
// Stream interface: the normalized pixel stream of this project (de, rgb, x, y, sof, eol, eof),
// one pixel per clock, no stall. FIXED LATENCY 3 clocks: out_* = f(in_* delayed by 3), sideband
// (de, x, y, sof, eol, eof) delayed by the same 3 clocks. When out_de = 0 every output is 0.
//
// Layers, bottom to top (a later layer overwrites an earlier one, the logo alpha-blends):
//   0 video
//   1 text backing   : rectangle around the text block, video darkened (each channel >> 1)
//   2 logo plate     : rectangle around the logo, blended towards PLATE_COLOR with weight PLATE_A/16
//   3 counting line  : full-height vertical line, 2 px wide, x = line_x and line_x+1, LINE_COLOR
//   4 target box     : 2 px frame OUTSIDE the box [xmin..xmax]x[ymin..ymax], BOX_COLOR
//   5 crosshair      : arms +-CROSS_ARM, 3 px thick, centred on (cx,cy), CROSS_COLOR
//   6 logo           : osd_logo_rom, out = (below*(16-alpha) + logo_colour*alpha) >> 4 per channel
//   7 text           : glyph pixels of the 22 x 6 character grid, TEXT_COLOR
//
// Frame consistency: every control input is sampled on the pixel with in_de & in_sof (that pixel
// already uses the new values) and held for the whole frame. The decimal digits come from
// osd_bin2bcd converters that run continuously on the live inputs, so inputs must be stable at
// least 43 clocks before in_sof (box/count results change right after the last pixel of a frame,
// a whole vertical blanking earlier). Overlay of frame N therefore shows the statistics of frame
// N-1 when they come from frame_bbox (one frame lag, by design).
//
// Controls
//   cfg_flags[0] text  [1] box  [2] crosshair  [3] counting line  [4] logo   (1 = draw)
//   cfg_mode     : 0 ORIG, 1 GRAY, 2 MASK, 3 TINT  (text only; the video mux itself is view_mux)
//   tgt_valid    : box and crosshair are drawn only while valid; text shows FOUND/LOST and the X/Y
//                  digits become '----' when not valid
//   tgt_xmin..tgt_ymax, tgt_cx, tgt_cy : box and centre (e.g. frame_bbox res_*)
//   tgt_count    : pixel count (e.g. frame_bbox res_count), shown as 6 digits, clamped to 999999
//   line_x       : x of the counting line
//   cross_cnt    : crossing counter, shown as 5 digits
//
// Text block (22 columns x 6 rows of 8x16 cells, scaled by 2^SCALE), rows:
//   0  <AN><LU> PH1P35 <SHI><SHI2><SHI3><JUE>          (CJK half cells 0x80..0x8B, see osd_font_rom)
//   1  MODE:ORIG | GRAY | MASK | TINT
//   2  TARGET:FOUND | TARGET:LOST
//   3  X:dddd Y:dddd
//   4  AREA:dddddd
//   5  CROSS:ddddd
//
// Geometry defaults are for 1280x720. The logo is 160 x LOGO_H pixels (osd_logo_rom). Text origin
// TEXT_X/TEXT_Y must be >= 8 so the backing rectangle does not start before the image.
//
// Reset: active-low asynchronous, release must be synchronized by the integrator.

module osd_overlay #(
    parameter [11:0]  LOGO_X      = 12'd16,
    parameter [11:0]  LOGO_Y      = 12'd16,
    parameter [11:0]  TEXT_X      = 12'd200,
    parameter [11:0]  TEXT_Y      = 12'd16,
    parameter integer SCALE       = 1,                 // text cell = 8*2^SCALE x 16*2^SCALE pixels
    parameter [23:0]  TEXT_COLOR  = 24'hFFFFFF,
    parameter [23:0]  BOX_COLOR   = 24'h00FF40,
    parameter [23:0]  CROSS_COLOR = 24'hFF3030,
    parameter [23:0]  LINE_COLOR  = 24'h00E5FF,
    parameter [23:0]  PLATE_COLOR = 24'hFFFFFF,
    parameter integer PLATE_A     = 12,                // plate weight 0..16 (of 16)
    parameter integer CROSS_ARM   = 12
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_de,
    input  wire [23:0] in_rgb,
    input  wire [11:0] in_x,
    input  wire [11:0] in_y,
    input  wire        in_sof,
    input  wire        in_eol,
    input  wire        in_eof,

    input  wire [4:0]  cfg_flags,
    input  wire [1:0]  cfg_mode,
    input  wire        tgt_valid,
    input  wire [11:0] tgt_xmin,
    input  wire [11:0] tgt_xmax,
    input  wire [11:0] tgt_ymin,
    input  wire [11:0] tgt_ymax,
    input  wire [11:0] tgt_cx,
    input  wire [11:0] tgt_cy,
    input  wire [19:0] tgt_count,
    input  wire [11:0] line_x,
    input  wire [15:0] cross_cnt,

    output reg         out_de,
    output reg  [23:0] out_rgb,
    output reg  [11:0] out_x,
    output reg  [11:0] out_y,
    output reg         out_sof,
    output reg         out_eol,
    output reg         out_eof
);

    localparam LATENCY = 3;

    localparam integer COLS   = 22;
    localparam integer ROWS   = 6;
    localparam integer LOGO_W = 160;
    localparam integer LOGO_H = 94;                    // must equal LOGO_H in osd_logo_rom.v

    localparam [12:0] LX0 = LOGO_X;
    localparam [12:0] LY0 = LOGO_Y;
    localparam [12:0] TX0 = TEXT_X;
    localparam [12:0] TY0 = TEXT_Y;
    localparam [12:0] TW  = (COLS * 8)  << SCALE;
    localparam [12:0] TH  = (ROWS * 16) << SCALE;
    localparam [12:0] ARM = CROSS_ARM;

    localparam [23:0] LOGO_NAVY = 24'h1C2D4E;
    localparam [23:0] LOGO_RED  = 24'hED1C24;

    // ------------------------------------------------------------------
    // frame-start sampling of all controls
    // ------------------------------------------------------------------
    wire        start = in_de & in_sof;

    reg  [4:0]  r_flags;
    reg  [1:0]  r_mode;
    reg         r_valid;
    reg  [11:0] r_xmin, r_xmax, r_ymin, r_ymax, r_cx, r_cy, r_linex;
    reg  [15:0] r_bx, r_by;
    reg  [23:0] r_bc;
    reg  [19:0] r_bk;

    wire [15:0] bx_live;
    wire [15:0] by_live;
    wire [23:0] bc_live;
    wire [19:0] bk_live;

    osd_bin2bcd #(.BITS(12), .DIGITS(4)) u_bx (.clk(clk), .rst_n(rst_n), .bin(tgt_cx),    .bcd(bx_live));
    osd_bin2bcd #(.BITS(12), .DIGITS(4)) u_by (.clk(clk), .rst_n(rst_n), .bin(tgt_cy),    .bcd(by_live));
    osd_bin2bcd #(.BITS(20), .DIGITS(6)) u_bc (.clk(clk), .rst_n(rst_n), .bin(tgt_count), .bcd(bc_live));
    osd_bin2bcd #(.BITS(16), .DIGITS(5)) u_bk (.clk(clk), .rst_n(rst_n), .bin(cross_cnt), .bcd(bk_live));

    wire [4:0]  c_flags = start ? cfg_flags : r_flags;
    wire [1:0]  c_mode  = start ? cfg_mode  : r_mode;
    wire        c_valid = start ? tgt_valid : r_valid;
    wire [11:0] c_xmin  = start ? tgt_xmin  : r_xmin;
    wire [11:0] c_xmax  = start ? tgt_xmax  : r_xmax;
    wire [11:0] c_ymin  = start ? tgt_ymin  : r_ymin;
    wire [11:0] c_ymax  = start ? tgt_ymax  : r_ymax;
    wire [11:0] c_cx    = start ? tgt_cx    : r_cx;
    wire [11:0] c_cy    = start ? tgt_cy    : r_cy;
    wire [11:0] c_linex = start ? line_x    : r_linex;
    wire [15:0] c_bx    = start ? bx_live   : r_bx;
    wire [15:0] c_by    = start ? by_live   : r_by;
    wire [23:0] c_bc    = start ? bc_live   : r_bc;
    wire [19:0] c_bk    = start ? bk_live   : r_bk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_flags <= 5'd0;  r_mode <= 2'd0;  r_valid <= 1'b0;
            r_xmin <= 12'd0;  r_xmax <= 12'd0; r_ymin <= 12'd0; r_ymax <= 12'd0;
            r_cx <= 12'd0;    r_cy <= 12'd0;   r_linex <= 12'd0;
            r_bx <= 16'd0;    r_by <= 16'd0;   r_bc <= 24'd0;   r_bk <= 20'd0;
        end
        else if (start) begin
            r_flags <= cfg_flags; r_mode <= cfg_mode; r_valid <= tgt_valid;
            r_xmin <= tgt_xmin;   r_xmax <= tgt_xmax; r_ymin <= tgt_ymin; r_ymax <= tgt_ymax;
            r_cx <= tgt_cx;       r_cy <= tgt_cy;     r_linex <= line_x;
            r_bx <= bx_live;      r_by <= by_live;    r_bc <= bc_live;    r_bk <= bk_live;
        end
    end

    wire en_text  = c_flags[0];
    wire en_box   = c_flags[1];
    wire en_cross = c_flags[2];
    wire en_line  = c_flags[3];
    wire en_logo  = c_flags[4];

    // ------------------------------------------------------------------
    // character map
    // ------------------------------------------------------------------
    function [7:0] dig;
        input [3:0] n;
        begin
            dig = 8'h30 + {4'd0, n};
        end
    endfunction

    function [7:0] char_at;
        input [2:0]  row;
        input [4:0]  col;
        input [1:0]  mode;
        input        valid;
        input [15:0] bx;
        input [15:0] by;
        input [23:0] bc;
        input [19:0] bk;
        reg   [7:0]  c;
        begin
            c = 8'h20;
            if (row == 3'd0) begin
                case (col)
                    5'd0:  c = 8'h80;  5'd1:  c = 8'h81;  5'd2:  c = 8'h82;  5'd3:  c = 8'h83;
                    5'd5:  c = "P";    5'd6:  c = "H";    5'd7:  c = "1";    5'd8:  c = "P";
                    5'd9:  c = "3";    5'd10: c = "5";
                    5'd12: c = 8'h84;  5'd13: c = 8'h85;  5'd14: c = 8'h86;  5'd15: c = 8'h87;
                    5'd16: c = 8'h88;  5'd17: c = 8'h89;  5'd18: c = 8'h8A;  5'd19: c = 8'h8B;
                    default: c = 8'h20;
                endcase
            end
            else if (row == 3'd1) begin
                case (col)
                    5'd0: c = "M";  5'd1: c = "O";  5'd2: c = "D";  5'd3: c = "E";  5'd4: c = ":";
                    5'd5: c = (mode == 2'd0) ? "O" : (mode == 2'd1) ? "G" : (mode == 2'd2) ? "M" : "T";
                    5'd6: c = (mode == 2'd0) ? "R" : (mode == 2'd1) ? "R" : (mode == 2'd2) ? "A" : "I";
                    5'd7: c = (mode == 2'd0) ? "I" : (mode == 2'd1) ? "A" : (mode == 2'd2) ? "S" : "N";
                    5'd8: c = (mode == 2'd0) ? "G" : (mode == 2'd1) ? "Y" : (mode == 2'd2) ? "K" : "T";
                    default: c = 8'h20;
                endcase
            end
            else if (row == 3'd2) begin
                case (col)
                    5'd0: c = "T";  5'd1: c = "A";  5'd2: c = "R";  5'd3: c = "G";
                    5'd4: c = "E";  5'd5: c = "T";  5'd6: c = ":";
                    5'd7:  c = valid ? "F" : "L";
                    5'd8:  c = valid ? "O" : "O";
                    5'd9:  c = valid ? "U" : "S";
                    5'd10: c = valid ? "N" : "T";
                    5'd11: c = valid ? "D" : 8'h20;
                    default: c = 8'h20;
                endcase
            end
            else if (row == 3'd3) begin
                case (col)
                    5'd0: c = "X";  5'd1: c = ":";
                    5'd2: c = valid ? dig(bx[15:12]) : "-";
                    5'd3: c = valid ? dig(bx[11:8])  : "-";
                    5'd4: c = valid ? dig(bx[7:4])   : "-";
                    5'd5: c = valid ? dig(bx[3:0])   : "-";
                    5'd7: c = "Y";  5'd8: c = ":";
                    5'd9:  c = valid ? dig(by[15:12]) : "-";
                    5'd10: c = valid ? dig(by[11:8])  : "-";
                    5'd11: c = valid ? dig(by[7:4])   : "-";
                    5'd12: c = valid ? dig(by[3:0])   : "-";
                    default: c = 8'h20;
                endcase
            end
            else if (row == 3'd4) begin
                case (col)
                    5'd0: c = "A";  5'd1: c = "R";  5'd2: c = "E";  5'd3: c = "A";  5'd4: c = ":";
                    5'd5:  c = dig(bc[23:20]);
                    5'd6:  c = dig(bc[19:16]);
                    5'd7:  c = dig(bc[15:12]);
                    5'd8:  c = dig(bc[11:8]);
                    5'd9:  c = dig(bc[7:4]);
                    5'd10: c = dig(bc[3:0]);
                    default: c = 8'h20;
                endcase
            end
            else if (row == 3'd5) begin
                case (col)
                    5'd0: c = "C";  5'd1: c = "R";  5'd2: c = "O";  5'd3: c = "S";  5'd4: c = "S";  5'd5: c = ":";
                    5'd6:  c = dig(bk[19:16]);
                    5'd7:  c = dig(bk[15:12]);
                    5'd8:  c = dig(bk[11:8]);
                    5'd9:  c = dig(bk[7:4]);
                    5'd10: c = dig(bk[3:0]);
                    default: c = 8'h20;
                endcase
            end
            char_at = c;
        end
    endfunction

    // ------------------------------------------------------------------
    // stage 0 (combinational on the input pixel): regions and ROM addresses
    // ------------------------------------------------------------------
    wire [12:0] xw = {1'b0, in_x};
    wire [12:0] yw = {1'b0, in_y};

    // text block
    wire [12:0] tdx    = xw - TX0;
    wire [12:0] tdy    = yw - TY0;
    wire        t_in   = (xw >= TX0) & (tdx < TW) & (yw >= TY0) & (tdy < TH);
    wire        text_in = en_text & t_in;
    wire [12:0] tcx    = tdx >> (3 + SCALE);
    wire [12:0] tcy    = tdy >> (4 + SCALE);
    wire [12:0] tpx    = tdx >> SCALE;
    wire [12:0] tpy    = tdy >> SCALE;
    wire [4:0]  tcol   = tcx[4:0];
    wire [2:0]  trow   = tcy[2:0];
    wire [2:0]  tgx    = tpx[2:0];
    wire [3:0]  tgy    = tpy[3:0];

    wire [7:0]  ch     = char_at(trow, tcol, c_mode, c_valid, c_bx, c_by, c_bc, c_bk);
    wire [11:0] font_addr = {ch, tgy};

    wire        back_in = en_text & (xw + 13'd8 >= TX0) & (xw < TX0 + TW + 13'd8) &
                                    (yw + 13'd8 >= TY0) & (yw < TY0 + TH + 13'd8);

    // logo
    wire [12:0] ldx     = xw - LX0;
    wire [12:0] ldy     = yw - LY0;
    wire        logo_in = en_logo & (xw >= LX0) & (ldx < LOGO_W) & (yw >= LY0) & (ldy < LOGO_H);
    wire [13:0] logo_a  = {ldy[6:0], 7'd0} + {2'd0, ldy[6:0], 5'd0} + {1'b0, ldx};
    wire [13:0] logo_addr = logo_in ? logo_a : 14'd0;

    wire        plate_in = en_logo & (xw + 13'd6 >= LX0) & (xw < LX0 + LOGO_W + 13'd6) &
                                     (yw + 13'd6 >= LY0) & (yw < LY0 + LOGO_H + 13'd6);

    // counting line, box, crosshair
    wire        line_hit = en_line & ((xw == {1'b0, c_linex}) | (xw == {1'b0, c_linex} + 13'd1));

    wire [12:0] bxmin = {1'b0, c_xmin};
    wire [12:0] bxmax = {1'b0, c_xmax};
    wire [12:0] bymin = {1'b0, c_ymin};
    wire [12:0] bymax = {1'b0, c_ymax};
    wire        box_out = (xw + 13'd2 >= bxmin) & (xw <= bxmax + 13'd2) &
                          (yw + 13'd2 >= bymin) & (yw <= bymax + 13'd2);
    wire        box_in  = (xw >= bxmin) & (xw <= bxmax) & (yw >= bymin) & (yw <= bymax);
    wire        box_hit = en_box & c_valid & box_out & ~box_in;

    wire [12:0] ccx = {1'b0, c_cx};
    wire [12:0] ccy = {1'b0, c_cy};
    wire        arm_h = (xw + ARM >= ccx) & (xw <= ccx + ARM) & (yw + 13'd1 >= ccy) & (yw <= ccy + 13'd1);
    wire        arm_v = (xw + 13'd1 >= ccx) & (xw <= ccx + 13'd1) & (yw + ARM >= ccy) & (yw <= ccy + ARM);
    wire        cross_hit = en_cross & c_valid & (arm_h | arm_v);

    // ------------------------------------------------------------------
    // ROMs (synchronous read: data is valid together with the stage-1 registers)
    // ------------------------------------------------------------------
    wire [7:0] font_q;
    wire [5:0] logo_q;
    osd_font_rom u_font (.clk(clk), .addr(font_addr), .data(font_q));
    osd_logo_rom u_logo (.clk(clk), .addr(logo_addr), .data(logo_q));

    // ------------------------------------------------------------------
    // stage 1 registers
    // ------------------------------------------------------------------
    reg         r1_de;
    reg  [23:0] r1_rgb;
    reg  [11:0] r1_x, r1_y;
    reg         r1_sof, r1_eol, r1_eof;
    reg         r1_back, r1_plate, r1_line, r1_box, r1_cross, r1_logo, r1_text;
    reg  [2:0]  r1_gx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r1_de <= 1'b0; r1_rgb <= 24'd0; r1_x <= 12'd0; r1_y <= 12'd0;
            r1_sof <= 1'b0; r1_eol <= 1'b0; r1_eof <= 1'b0;
            r1_back <= 1'b0; r1_plate <= 1'b0; r1_line <= 1'b0; r1_box <= 1'b0;
            r1_cross <= 1'b0; r1_logo <= 1'b0; r1_text <= 1'b0; r1_gx <= 3'd0;
        end
        else begin
            r1_de  <= in_de;   r1_rgb <= in_rgb; r1_x <= in_x; r1_y <= in_y;
            r1_sof <= in_sof;  r1_eol <= in_eol; r1_eof <= in_eof;
            r1_back <= back_in;  r1_plate <= plate_in; r1_line <= line_hit; r1_box <= box_hit;
            r1_cross <= cross_hit; r1_logo <= logo_in;  r1_text <= text_in;  r1_gx <= tgx;
        end
    end

    // ------------------------------------------------------------------
    // stage 2: opaque layers below the logo
    // ------------------------------------------------------------------
    function [7:0] blend8;               // (v*(16-a) + c*a) >> 4, a = 0..16
        input [7:0]  v;
        input [7:0]  c;
        input [4:0]  a;
        reg   [12:0] p;
        begin
            p = v * (5'd16 - a) + c * a;
            blend8 = p[11:4];
        end
    endfunction

    wire [23:0] v_dark  = r1_back  ? {1'b0, r1_rgb[23:17], 1'b0, r1_rgb[15:9], 1'b0, r1_rgb[7:1]} : r1_rgb;
    wire [23:0] v_plate = r1_plate ? {blend8(v_dark[23:16], PLATE_COLOR[23:16], PLATE_A),
                                      blend8(v_dark[15:8],  PLATE_COLOR[15:8],  PLATE_A),
                                      blend8(v_dark[7:0],   PLATE_COLOR[7:0],   PLATE_A)} : v_dark;
    wire [23:0] v_line  = r1_line  ? LINE_COLOR  : v_plate;
    wire [23:0] v_box   = r1_box   ? BOX_COLOR   : v_line;
    wire [23:0] v_cross = r1_cross ? CROSS_COLOR : v_box;

    wire [4:0]  alpha1  = r1_logo ? logo_q[4:0] : 5'd0;
    wire        glyph1  = r1_text & font_q[3'd7 - r1_gx];

    reg         r2_de;
    reg  [23:0] r2_rgb;
    reg  [11:0] r2_x, r2_y;
    reg         r2_sof, r2_eol, r2_eof;
    reg  [4:0]  r2_alpha;
    reg         r2_cls, r2_glyph;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r2_de <= 1'b0; r2_rgb <= 24'd0; r2_x <= 12'd0; r2_y <= 12'd0;
            r2_sof <= 1'b0; r2_eol <= 1'b0; r2_eof <= 1'b0;
            r2_alpha <= 5'd0; r2_cls <= 1'b0; r2_glyph <= 1'b0;
        end
        else begin
            r2_de <= r1_de;  r2_rgb <= v_cross; r2_x <= r1_x; r2_y <= r1_y;
            r2_sof <= r1_sof; r2_eol <= r1_eol; r2_eof <= r1_eof;
            r2_alpha <= alpha1; r2_cls <= logo_q[5]; r2_glyph <= glyph1;
        end
    end

    // ------------------------------------------------------------------
    // stage 3: logo blend and text, outputs de-gated
    // ------------------------------------------------------------------
    wire [23:0] lcol  = r2_cls ? LOGO_RED : LOGO_NAVY;
    wire [23:0] v_logo = {blend8(r2_rgb[23:16], lcol[23:16], r2_alpha),
                          blend8(r2_rgb[15:8],  lcol[15:8],  r2_alpha),
                          blend8(r2_rgb[7:0],   lcol[7:0],   r2_alpha)};
    wire [23:0] v_out = r2_glyph ? TEXT_COLOR : v_logo;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_de  <= 1'b0; out_rgb <= 24'd0; out_x <= 12'd0; out_y <= 12'd0;
            out_sof <= 1'b0; out_eol <= 1'b0; out_eof <= 1'b0;
        end
        else begin
            out_de  <= r2_de;
            out_rgb <= r2_de ? v_out : 24'd0;
            out_x   <= r2_de ? r2_x  : 12'd0;
            out_y   <= r2_de ? r2_y  : 12'd0;
            out_sof <= r2_de & r2_sof;
            out_eol <= r2_de & r2_eol;
            out_eof <= r2_de & r2_eof;
        end
    end

endmodule
