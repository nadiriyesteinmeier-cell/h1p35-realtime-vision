// osd_ext.v - second on-screen layer of the v2 build: three coloured target boxes and a recognition panel
//
// Same normalized pixel stream as osd_overlay.v (de, rgb, x, y, sof, eol, eof; one pixel per clock, no stall) and the
// same FIXED LATENCY of 3 clocks; out_de = 0 forces every output to 0. It is meant to sit behind osd_overlay.
//
// Layers (bottom to top)
//   0 video
//   1 panel backing  : rectangle (8 px margin) around the panel, video darkened (each channel >> 1)       [en_panel]
//   2 target boxes   : 2 px frame OUTSIDE the bounding box of every shown target, plus a small centre cross (centre of the
//                      box), colour per target (red FF3030, green 30FF30, blue 3070FF)                     [en_boxes]
//                      t_valid = the target is shown; t_hold = shown as a HELD box (short occlusion, target_track.v S_HOLD):
//                      the frame is then DASHED (8 px on / 8 px off), no cross, and the panel row says HOLD instead of the shape;
//                      a target that is not shown (t_valid = 0) has no box and the panel row says LOST
//   2b mode strip    : opaque dark rectangle over row 1 of the v1 text block (MODE_X, MODE_Y, 22 columns) showing
//                      'MODE:<view name>' for the 8 views of view_mux_style (the v1 block can only name 4 of them)
//   3 panel text     : 28 columns x 5 rows of 8x16 cells (scaled by 2^SCALE, default 16x32 px) at (PANEL_X, PANEL_Y)
//        row 0   RECOG  THR:ADAPT Y:128 R:090       (THR:FIXED when adaptive = 0; Y = mean luminance, R = red floor)
//        row 1   RED   RECT X0640 Y0360 N00012      (shape, centre X / Y, N = crossing count; HOLD X---- Y---- while the box is
//                                                    held, LOST X---- Y---- when there is no target)
//        row 2   GRN   CIRC X.... Y.... N.....
//        row 3   BLU   TRIA X.... Y.... N.....
//        row 4   CAM FPS:060  DISP HZ:060           (measured camera frame rate / display refresh rate)
//        row 5   RED A:03 H:12 R:11 L:01 J:FF       (tracker statistics of the RED target, two HEX digits each, saturating at FF:
//                                                    A = acquisitions, H = occlusions that began (box held), R = returned within
//                                                    the hold time, L = given up (LOST), J = frames whose jitter was absorbed)
//        text colours: row 0 yellow, rows 1..3 in the colour of the target, row 4 light gray, row 5 light aqua
//
// Control and statistics are sampled ONCE per frame, on the pixel with in_de & in_sof (that pixel already uses the
// new values), and held for the whole frame. The decimal digits come from osd_bin2bcd converters that run
// continuously on the live inputs, so the inputs have to be stable at least 43 clocks before in_sof (the per-frame
// statistics change right after the last pixel of a frame, a whole vertical blanking earlier). What is shown in
// frame N therefore belongs to frame N-1 (fixed one-frame lag), as for osd_overlay.
//
// The live BCD values are also exported (o_bcd_*), so a report module (UART) can reuse them without more converters.
// Vector packing: target 0 = red = bits [W-1:0], target 1 = green, target 2 = blue (W = field width).
// shape codes (shape_classify.v): 0 NONE, 1 RECT, 2 CIRC, 3 TRI, 4 OVAL, 5 OTHER.
// Reset: active-low asynchronous, release synchronized by the integrator.

module osd_ext #(
    parameter [11:0]  PANEL_X     = 12'd16,
    parameter [11:0]  PANEL_Y     = 12'd520,
    parameter [11:0]  MODE_X      = 12'd200,
    parameter [11:0]  MODE_Y      = 12'd48,
    parameter integer SCALE       = 1,
    parameter integer ARM         = 8
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rst_n_b,          // reset of the decimal converters (a separate copy of the reset: lower fanout per net)

    input  wire        in_de,
    input  wire [23:0] in_rgb,
    input  wire [11:0] in_x,
    input  wire [11:0] in_y,
    input  wire        in_sof,
    input  wire        in_eol,
    input  wire        in_eof,

    input  wire        en_panel,
    input  wire        en_boxes,
    input  wire        en_mode,
    input  wire        view_page,
    input  wire [1:0]  view_mode,
    input  wire        adaptive,
    input  wire [7:0]  ymean,
    input  wire [7:0]  rmin,
    input  wire [7:0]  fps_cam,
    input  wire [7:0]  fps_disp,

    input  wire [2:0]  t_valid,
    input  wire [2:0]  t_hold,
    input  wire [8:0]  t_shape,
    input  wire [35:0] t_xmin,
    input  wire [35:0] t_xmax,
    input  wire [35:0] t_ymin,
    input  wire [35:0] t_ymax,
    input  wire [35:0] t_cx,          // measured centre, only used for the decimal digits (panel / o_bcd_*)
    input  wire [35:0] t_cy,
    input  wire [47:0] t_cross,
    input  wire [39:0] t_stat,        // red tracker statistics {J, L, R, H, A}, 8 bits each (saturated), shown in panel row 5

    output reg         out_de,
    output reg  [23:0] out_rgb,
    output reg  [11:0] out_x,
    output reg  [11:0] out_y,
    output reg         out_sof,
    output reg         out_eol,
    output reg         out_eof,

    output wire [47:0] o_bcd_x,       // 3 x 4 digits
    output wire [47:0] o_bcd_y,       // 3 x 4 digits
    output wire [59:0] o_bcd_k,       // 3 x 5 digits (crossing counters)
    output wire [11:0] o_bcd_fc,      // camera fps, 3 digits
    output wire [11:0] o_bcd_fd       // display Hz, 3 digits
);

    localparam LATENCY = 3;

    localparam integer COLS = 28;
    localparam integer ROWS = 6;
    localparam [12:0]  PX0  = PANEL_X;
    localparam [12:0]  PY0  = PANEL_Y;
    localparam [12:0]  PW   = (COLS * 8)  << SCALE;
    localparam [12:0]  PH   = (ROWS * 16) << SCALE;
    localparam [12:0]  ARMW = ARM;
    localparam [12:0]  MX0  = MODE_X;
    localparam [12:0]  MY0  = MODE_Y;
    localparam [12:0]  MW   = (22 * 8) << SCALE;
    localparam [12:0]  MH   = (1 * 16) << SCALE;

    localparam [23:0] COL_R   = 24'hFF3030;
    localparam [23:0] COL_G   = 24'h30FF30;
    localparam [23:0] COL_B   = 24'h3070FF;
    localparam [23:0] TXT_HDR = 24'hFFE060;
    localparam [23:0] TXT_R   = 24'hFF7070;
    localparam [23:0] TXT_G   = 24'h70FF70;
    localparam [23:0] TXT_B   = 24'h80A0FF;
    localparam [23:0] TXT_FPS = 24'hE0E0E0;
    localparam [23:0] TXT_TRK = 24'hA0F0E0;

    // ------------------------------------------------------------------
    // frame-start sampling
    // ------------------------------------------------------------------
    wire start = in_de & in_sof;

    wire [47:0] bx_live;
    wire [47:0] by_live;
    wire [59:0] bk_live;
    wire [11:0] bm_live;      // mean luminance
    wire [11:0] br_live;      // red floor
    wire [11:0] bfc_live;
    wire [11:0] bfd_live;

    genvar gi;
    generate
        for (gi = 0; gi < 3; gi = gi + 1) begin : g_bcd
            osd_bin2bcd #(.BITS(12), .DIGITS(4)) u_x (.clk(clk), .rst_n(rst_n_b), .bin(t_cx[12*gi+11:12*gi]),    .bcd(bx_live[16*gi+15:16*gi]));
            osd_bin2bcd #(.BITS(12), .DIGITS(4)) u_y (.clk(clk), .rst_n(rst_n_b), .bin(t_cy[12*gi+11:12*gi]),    .bcd(by_live[16*gi+15:16*gi]));
            osd_bin2bcd #(.BITS(16), .DIGITS(5)) u_k (.clk(clk), .rst_n(rst_n_b), .bin(t_cross[16*gi+15:16*gi]), .bcd(bk_live[20*gi+19:20*gi]));
        end
    endgenerate
    osd_bin2bcd #(.BITS(8), .DIGITS(3)) u_bm  (.clk(clk), .rst_n(rst_n_b), .bin(ymean),    .bcd(bm_live));
    osd_bin2bcd #(.BITS(8), .DIGITS(3)) u_br  (.clk(clk), .rst_n(rst_n_b), .bin(rmin),     .bcd(br_live));
    osd_bin2bcd #(.BITS(8), .DIGITS(3)) u_bfc (.clk(clk), .rst_n(rst_n_b), .bin(fps_cam),  .bcd(bfc_live));
    osd_bin2bcd #(.BITS(8), .DIGITS(3)) u_bfd (.clk(clk), .rst_n(rst_n_b), .bin(fps_disp), .bcd(bfd_live));

    assign o_bcd_x  = bx_live;
    assign o_bcd_y  = by_live;
    assign o_bcd_k  = bk_live;
    assign o_bcd_fc = bfc_live;
    assign o_bcd_fd = bfd_live;

    reg         r_panel, r_boxes, r_ad, r_mode_en, r_page;
    reg  [1:0]  r_vmode;
    reg  [2:0]  r_v, r_hold;
    reg  [8:0]  r_shape;
    reg  [35:0] r_xmin, r_xmax, r_ymin, r_ymax;
    reg  [47:0] r_bx, r_by;
    reg  [59:0] r_bk;
    reg  [11:0] r_bm, r_br, r_bfc, r_bfd;
    reg  [39:0] r_stat;

    wire         c_panel = start ? en_panel : r_panel;
    wire         c_boxes = start ? en_boxes : r_boxes;
    wire         c_ad    = start ? adaptive : r_ad;
    wire         c_men   = start ? en_mode  : r_mode_en;
    wire         c_page  = start ? view_page : r_page;
    wire [1:0]   c_vmode = start ? view_mode : r_vmode;
    wire [2:0]   c_v     = start ? t_valid  : r_v;
    wire [2:0]   c_hold  = start ? t_hold   : r_hold;
    wire [8:0]   c_shape = start ? t_shape  : r_shape;
    wire [35:0]  c_xmin  = start ? t_xmin   : r_xmin;
    wire [35:0]  c_xmax  = start ? t_xmax   : r_xmax;
    wire [35:0]  c_ymin  = start ? t_ymin   : r_ymin;
    wire [35:0]  c_ymax  = start ? t_ymax   : r_ymax;
    wire [47:0]  c_bx    = start ? bx_live  : r_bx;
    wire [47:0]  c_by    = start ? by_live  : r_by;
    wire [59:0]  c_bk    = start ? bk_live  : r_bk;
    wire [11:0]  c_bm    = start ? bm_live  : r_bm;
    wire [11:0]  c_br    = start ? br_live  : r_br;
    wire [11:0]  c_bfc   = start ? bfc_live : r_bfc;
    wire [11:0]  c_bfd   = start ? bfd_live : r_bfd;
    wire [39:0]  c_stat  = start ? t_stat   : r_stat;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_panel <= 1'b0; r_boxes <= 1'b0; r_ad <= 1'b0; r_mode_en <= 1'b0; r_page <= 1'b0; r_vmode <= 2'd0; r_v <= 3'd0; r_hold <= 3'd0; r_shape <= 9'd0;
            r_xmin <= 36'd0; r_xmax <= 36'd0; r_ymin <= 36'd0; r_ymax <= 36'd0;
            r_bx <= 48'd0; r_by <= 48'd0; r_bk <= 60'd0; r_bm <= 12'd0; r_br <= 12'd0; r_bfc <= 12'd0; r_bfd <= 12'd0; r_stat <= 40'd0;
        end
        else if (start) begin
            r_panel <= en_panel; r_boxes <= en_boxes; r_ad <= adaptive; r_mode_en <= en_mode; r_page <= view_page; r_vmode <= view_mode;
            r_v <= t_valid; r_hold <= t_hold; r_shape <= t_shape;
            r_xmin <= t_xmin; r_xmax <= t_xmax; r_ymin <= t_ymin; r_ymax <= t_ymax;
            r_bx <= bx_live; r_by <= by_live; r_bk <= bk_live; r_bm <= bm_live; r_br <= br_live;
            r_bfc <= bfc_live; r_bfd <= bfd_live; r_stat <= t_stat;
        end
    end

    // ------------------------------------------------------------------
    // character map of the panel
    // ------------------------------------------------------------------
    function [7:0] dig;
        input [3:0] n;
        begin
            dig = 8'h30 + {4'd0, n};
        end
    endfunction

    function [7:0] hexc;                           // one hexadecimal digit as ASCII
        input [3:0] n;
        begin
            hexc = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
        end
    endfunction

    function [7:0] vname_ch;          // 7-character name of the view {page, mode}
        input       pg;
        input [1:0] md;
        input [2:0] i;
        reg [55:0] nm;
        begin
            case ({pg, md})
                3'd0: nm = "ORIG   ";
                3'd1: nm = "GRAY   ";
                3'd2: nm = "MASK   ";
                3'd3: nm = "TINT   ";
                3'd4: nm = "SKETCH ";
                3'd5: nm = "CARTOON";
                3'd6: nm = "EDGE+  ";
                default: nm = "THERMAL";
            endcase
            vname_ch = nm[8*(6-i) +: 8];
        end
    endfunction

    function [7:0] shape_ch;
        input [2:0] s;
        input [1:0] i;
        begin
            case ({s, i})
                {3'd1, 2'd0}: shape_ch = "R";  {3'd1, 2'd1}: shape_ch = "E";  {3'd1, 2'd2}: shape_ch = "C";  {3'd1, 2'd3}: shape_ch = "T";
                {3'd2, 2'd0}: shape_ch = "C";  {3'd2, 2'd1}: shape_ch = "I";  {3'd2, 2'd2}: shape_ch = "R";  {3'd2, 2'd3}: shape_ch = "C";
                {3'd3, 2'd0}: shape_ch = "T";  {3'd3, 2'd1}: shape_ch = "R";  {3'd3, 2'd2}: shape_ch = "I";  {3'd3, 2'd3}: shape_ch = "A";
                {3'd4, 2'd0}: shape_ch = "O";  {3'd4, 2'd1}: shape_ch = "V";  {3'd4, 2'd2}: shape_ch = "A";  {3'd4, 2'd3}: shape_ch = "L";
                {3'd5, 2'd0}: shape_ch = "O";  {3'd5, 2'd1}: shape_ch = "B";  {3'd5, 2'd2}: shape_ch = "J";  {3'd5, 2'd3}: shape_ch = 8'h20;
                default:      shape_ch = "-";
            endcase
        end
    endfunction

    // stage-0 geometry of the panel
    wire [12:0] xw = {1'b0, in_x};
    wire [12:0] yw = {1'b0, in_y};

    wire [12:0] pdx    = xw - PX0;
    wire [12:0] pdy    = yw - PY0;
    wire        p_in   = (xw >= PX0) & (pdx < PW) & (yw >= PY0) & (pdy < PH);
    wire        text_p  = c_panel & p_in;
    wire [12:0] pcx    = pdx >> (3 + SCALE);
    wire [12:0] pcy    = pdy >> (4 + SCALE);
    wire [12:0] ppx    = pdx >> SCALE;
    wire [12:0] ppy    = pdy >> SCALE;
    wire [4:0]  pcol   = pcx[4:0];
    wire [2:0]  prow   = pcy[2:0];
    wire [2:0]  pgx    = ppx[2:0];
    wire [3:0]  pgy    = ppy[3:0];

    wire        back_in = c_panel & (xw + 13'd8 >= PX0) & (xw < PX0 + PW + 13'd8) &
                                    (yw + 13'd8 >= PY0) & (yw < PY0 + PH + 13'd8);

    // mode strip (row 1 of the v1 text block)
    wire [12:0] mdx    = xw - MX0;
    wire [12:0] mdy    = yw - MY0;
    wire        m_in   = c_men & (xw >= MX0) & (mdx < MW) & (yw >= MY0) & (mdy < MH);
    wire [12:0] mcx    = mdx >> (3 + SCALE);
    wire [12:0] mpx    = mdx >> SCALE;
    wire [12:0] mpy    = mdy >> SCALE;
    wire [4:0]  mcol   = mcx[4:0];
    wire [2:0]  mgx    = mpx[2:0];
    wire [3:0]  mgy    = mpy[3:0];
    wire        text_in = text_p | m_in;
    wire [4:0]  mi     = mcol - 5'd5;
    reg  [7:0]  mch;
    always @* begin
        mch = 8'h20;
        case (mcol)
            5'd0: mch = "M";  5'd1: mch = "O";  5'd2: mch = "D";  5'd3: mch = "E";  5'd4: mch = ":";
            5'd5, 5'd6, 5'd7, 5'd8, 5'd9, 5'd10, 5'd11: mch = vname_ch(c_page, c_vmode, mi[2:0]);
            default: mch = 8'h20;
        endcase
    end

    // the target a row 1..3 talks about
    wire [1:0]  ti      = (prow == 3'd1) ? 2'd0 : (prow == 3'd2) ? 2'd1 : 2'd2;
    reg         s_valid, s_hold;
    reg  [2:0]  s_shape;
    reg  [15:0] s_bx, s_by;
    reg  [19:0] s_bk;
    always @* begin
        case (ti)
            2'd0:    begin s_valid = c_v[0]; s_hold = c_hold[0]; s_shape = c_shape[2:0]; s_bx = c_bx[15:0];  s_by = c_by[15:0];  s_bk = c_bk[19:0];  end
            2'd1:    begin s_valid = c_v[1]; s_hold = c_hold[1]; s_shape = c_shape[5:3]; s_bx = c_bx[31:16]; s_by = c_by[31:16]; s_bk = c_bk[39:20]; end
            default: begin s_valid = c_v[2]; s_hold = c_hold[2]; s_shape = c_shape[8:6]; s_bx = c_bx[47:32]; s_by = c_by[47:32]; s_bk = c_bk[59:40]; end
        endcase
    end
    wire s_digits = s_valid & ~s_hold;             // measured centre digits only while the target is really seen

    function [7:0] status_ch;                      // 4-character status field: shape, HOLD (held box) or LOST (not shown)
        input       shown;
        input       held;
        input [2:0] shp;
        input [1:0] i;
        begin
            if (held)        status_ch = (i == 2'd0) ? "H" : (i == 2'd1) ? "O" : (i == 2'd2) ? "L" : "D";
            else if (!shown) status_ch = (i == 2'd0) ? "L" : (i == 2'd1) ? "O" : (i == 2'd2) ? "S" : "T";
            else             status_ch = shape_ch(shp, i);
        end
    endfunction

    reg [7:0] ch;
    always @* begin
        ch = 8'h20;
        case (prow)
            3'd0: begin
                case (pcol)
                    5'd0: ch = "R";  5'd1: ch = "E";  5'd2: ch = "C";  5'd3: ch = "O";  5'd4: ch = "G";
                    5'd7: ch = "T";  5'd8: ch = "H";  5'd9: ch = "R";  5'd10: ch = ":";
                    5'd11: ch = c_ad ? "A" : "F";
                    5'd12: ch = c_ad ? "D" : "I";
                    5'd13: ch = c_ad ? "A" : "X";
                    5'd14: ch = c_ad ? "P" : "E";
                    5'd15: ch = c_ad ? "T" : "D";
                    5'd17: ch = "Y";  5'd18: ch = ":";
                    5'd19: ch = dig(c_bm[11:8]);  5'd20: ch = dig(c_bm[7:4]);  5'd21: ch = dig(c_bm[3:0]);
                    5'd23: ch = "R";  5'd24: ch = ":";
                    5'd25: ch = dig(c_br[11:8]);  5'd26: ch = dig(c_br[7:4]);  5'd27: ch = dig(c_br[3:0]);
                    default: ch = 8'h20;
                endcase
            end
            3'd1, 3'd2, 3'd3: begin
                case (pcol)
                    5'd0: ch = (ti == 2'd0) ? "R" : (ti == 2'd1) ? "G" : "B";
                    5'd1: ch = (ti == 2'd0) ? "E" : (ti == 2'd1) ? "R" : "L";
                    5'd2: ch = (ti == 2'd0) ? "D" : (ti == 2'd1) ? "N" : "U";
                    5'd5: ch = status_ch(s_valid, s_hold, s_shape, 2'd0);
                    5'd6: ch = status_ch(s_valid, s_hold, s_shape, 2'd1);
                    5'd7: ch = status_ch(s_valid, s_hold, s_shape, 2'd2);
                    5'd8: ch = status_ch(s_valid, s_hold, s_shape, 2'd3);
                    5'd10: ch = "X";
                    5'd11: ch = s_digits ? dig(s_bx[15:12]) : "-";
                    5'd12: ch = s_digits ? dig(s_bx[11:8])  : "-";
                    5'd13: ch = s_digits ? dig(s_bx[7:4])   : "-";
                    5'd14: ch = s_digits ? dig(s_bx[3:0])   : "-";
                    5'd16: ch = "Y";
                    5'd17: ch = s_digits ? dig(s_by[15:12]) : "-";
                    5'd18: ch = s_digits ? dig(s_by[11:8])  : "-";
                    5'd19: ch = s_digits ? dig(s_by[7:4])   : "-";
                    5'd20: ch = s_digits ? dig(s_by[3:0])   : "-";
                    5'd22: ch = "N";
                    5'd23: ch = dig(s_bk[19:16]);  5'd24: ch = dig(s_bk[15:12]);  5'd25: ch = dig(s_bk[11:8]);
                    5'd26: ch = dig(s_bk[7:4]);    5'd27: ch = dig(s_bk[3:0]);
                    default: ch = 8'h20;
                endcase
            end
            3'd4: begin                                    // row 4
                case (pcol)
                    5'd0: ch = "C";  5'd1: ch = "A";  5'd2: ch = "M";
                    5'd4: ch = "F";  5'd5: ch = "P";  5'd6: ch = "S";  5'd7: ch = ":";
                    5'd8: ch = dig(c_bfc[11:8]);  5'd9: ch = dig(c_bfc[7:4]);  5'd10: ch = dig(c_bfc[3:0]);
                    5'd13: ch = "D";  5'd14: ch = "I";  5'd15: ch = "S";  5'd16: ch = "P";
                    5'd18: ch = "H";  5'd19: ch = "Z";  5'd20: ch = ":";
                    5'd21: ch = dig(c_bfd[11:8]);  5'd22: ch = dig(c_bfd[7:4]);  5'd23: ch = dig(c_bfd[3:0]);
                    default: ch = 8'h20;
                endcase
            end
            default: begin                                 // row 5: tracker statistics of the red target
                case (pcol)
                    5'd0: ch = "R";  5'd1: ch = "E";  5'd2: ch = "D";
                    5'd4: ch = "A";  5'd5: ch = ":";  5'd6: ch = hexc(c_stat[7:4]);    5'd7: ch = hexc(c_stat[3:0]);
                    5'd9: ch = "H";  5'd10: ch = ":"; 5'd11: ch = hexc(c_stat[15:12]); 5'd12: ch = hexc(c_stat[11:8]);
                    5'd14: ch = "R"; 5'd15: ch = ":"; 5'd16: ch = hexc(c_stat[23:20]); 5'd17: ch = hexc(c_stat[19:16]);
                    5'd19: ch = "L"; 5'd20: ch = ":"; 5'd21: ch = hexc(c_stat[31:28]); 5'd22: ch = hexc(c_stat[27:24]);
                    5'd24: ch = "J"; 5'd25: ch = ":"; 5'd26: ch = hexc(c_stat[39:36]); 5'd27: ch = hexc(c_stat[35:32]);
                    default: ch = 8'h20;
                endcase
            end
        endcase
    end

    wire [11:0] font_addr = m_in ? {mch, mgy} : {ch, pgy};
    wire [7:0]  font_q;
    osd_font_rom u_font (.clk(clk), .addr(font_addr), .data(font_q));

    // text colour of the row
    wire [23:0] row_col = (prow == 3'd0) ? TXT_HDR :
                          (prow == 3'd1) ? TXT_R   :
                          (prow == 3'd2) ? TXT_G   :
                          (prow == 3'd3) ? TXT_B   :
                          (prow == 3'd4) ? TXT_FPS : TXT_TRK;

    // boxes and centre crosses of the three targets
    wire [2:0] box_hit;
    wire [2:0] cr_hit;
    generate
        for (gi = 0; gi < 3; gi = gi + 1) begin : g_box
            wire [12:0] bxmin = {1'b0, c_xmin[12*gi+11:12*gi]};
            wire [12:0] bxmax = {1'b0, c_xmax[12*gi+11:12*gi]};
            wire [12:0] bymin = {1'b0, c_ymin[12*gi+11:12*gi]};
            wire [12:0] bymax = {1'b0, c_ymax[12*gi+11:12*gi]};
            wire [12:0] bsx   = bxmin + bxmax;                          // centre of the displayed box = the frame_bbox formula
            wire [12:0] bsy   = bymin + bymax;
            wire [12:0] bcx   = {1'b0, bsx[12:1]};
            wire [12:0] bcy   = {1'b0, bsy[12:1]};
            wire        dash  = ~(xw[3] ^ yw[3]);                        // 8 px on / 8 px off along every edge of the box
            wire out_r = (xw + 13'd2 >= bxmin) & (xw <= bxmax + 13'd2) & (yw + 13'd2 >= bymin) & (yw <= bymax + 13'd2);
            wire in_r  = (xw >= bxmin) & (xw <= bxmax) & (yw >= bymin) & (yw <= bymax);
            wire arm_h = (xw + ARMW >= bcx) & (xw <= bcx + ARMW) & (yw + 13'd1 >= bcy) & (yw <= bcy + 13'd1);
            wire arm_v = (xw + 13'd1 >= bcx) & (xw <= bcx + 13'd1) & (yw + ARMW >= bcy) & (yw <= bcy + ARMW);
            assign box_hit[gi] = c_boxes & c_v[gi] & out_r & ~in_r & (~c_hold[gi] | dash);
            assign cr_hit[gi]  = c_boxes & c_v[gi] & ~c_hold[gi] & (arm_h | arm_v);
        end
    endgenerate

    // ------------------------------------------------------------------
    // stage 1 registers
    // ------------------------------------------------------------------
    reg         r1_de;
    reg  [23:0] r1_rgb;
    reg  [11:0] r1_x, r1_y;
    reg         r1_sof, r1_eol, r1_eof;
    reg         r1_back, r1_text, r1_mback;
    reg  [2:0]  r1_box, r1_cr;
    reg  [2:0]  r1_gx;
    reg  [23:0] r1_col;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r1_de <= 1'b0; r1_rgb <= 24'd0; r1_x <= 12'd0; r1_y <= 12'd0;
            r1_sof <= 1'b0; r1_eol <= 1'b0; r1_eof <= 1'b0;
            r1_back <= 1'b0; r1_text <= 1'b0; r1_mback <= 1'b0; r1_box <= 3'd0; r1_cr <= 3'd0; r1_gx <= 3'd0; r1_col <= 24'd0;
        end
        else begin
            r1_de <= in_de; r1_rgb <= in_rgb; r1_x <= in_x; r1_y <= in_y;
            r1_sof <= in_sof; r1_eol <= in_eol; r1_eof <= in_eof;
            r1_back <= back_in; r1_text <= text_in; r1_mback <= m_in; r1_box <= box_hit; r1_cr <= cr_hit;
            r1_gx <= m_in ? mgx : pgx; r1_col <= m_in ? 24'hFFFFFF : row_col;
        end
    end

    // ------------------------------------------------------------------
    // stage 2: opaque layers, glyph bit
    // ------------------------------------------------------------------
    wire [23:0] v_dark = r1_mback ? 24'h181818 :
                         r1_back  ? {1'b0, r1_rgb[23:17], 1'b0, r1_rgb[15:9], 1'b0, r1_rgb[7:1]} : r1_rgb;
    wire [2:0]  hit3   = r1_box | r1_cr;
    wire [23:0] v_box  = hit3[2] ? COL_B : hit3[1] ? COL_G : hit3[0] ? COL_R : v_dark;
    wire        glyph1 = r1_text & font_q[3'd7 - r1_gx];

    reg         r2_de;
    reg  [23:0] r2_rgb;
    reg  [11:0] r2_x, r2_y;
    reg         r2_sof, r2_eol, r2_eof;
    reg         r2_glyph;
    reg  [23:0] r2_col;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r2_de <= 1'b0; r2_rgb <= 24'd0; r2_x <= 12'd0; r2_y <= 12'd0;
            r2_sof <= 1'b0; r2_eol <= 1'b0; r2_eof <= 1'b0; r2_glyph <= 1'b0; r2_col <= 24'd0;
        end
        else begin
            r2_de <= r1_de; r2_rgb <= v_box; r2_x <= r1_x; r2_y <= r1_y;
            r2_sof <= r1_sof; r2_eol <= r1_eol; r2_eof <= r1_eof;
            r2_glyph <= glyph1; r2_col <= r1_col;
        end
    end

    // ------------------------------------------------------------------
    // stage 3: text on top, outputs de-gated
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_de <= 1'b0; out_rgb <= 24'd0; out_x <= 12'd0; out_y <= 12'd0;
            out_sof <= 1'b0; out_eol <= 1'b0; out_eof <= 1'b0;
        end
        else begin
            out_de  <= r2_de;
            out_rgb <= r2_de ? (r2_glyph ? r2_col : r2_rgb) : 24'd0;
            out_x   <= r2_de ? r2_x : 12'd0;
            out_y   <= r2_de ? r2_y : 12'd0;
            out_sof <= r2_de & r2_sof;
            out_eol <= r2_de & r2_eol;
            out_eof <= r2_de & r2_eof;
        end
    end

endmodule
