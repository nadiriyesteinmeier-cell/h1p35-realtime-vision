// uart_report.v - sends the recognition result as one text line every PERIOD clocks over a UART (8N1, TX only)
//
// Line format (117 characters, ASCII, ends with CR LF), one block per colour, then the measured frame rates:
//   R:RECT,X0640,Y0360,A012345,N00012;G:CIRC,X0320,Y0100,A009876,N00003;B:----,X----,Y----,A000000,N00000;CAM060,DSP060
//   colour letter, ':', shape (RECT CIRC TRIA OVAL "OBJ " or ----), ',', X<centre x>, ',', Y<centre y>, ',',
//   A<hit-pixel count of the frame>, ',', N<line-crossing count>, ';'
//   X and Y show '-' while the target is not valid. CAM = measured camera frames per second, DSP = measured display
//   refresh (fps_meter.v).
// The values are taken from the statistics of the PREVIOUS frame (one-frame lag, like the OSD) and are snapshotted
// when a line starts, so one line is always self-consistent. A line takes 117 x 10 bit times (10.2 ms at 115200 baud);
// the default PERIOD of 15,000,000 clocks is 0.2 s at 75 MHz.
//
// Baud rate = clk / CLKDIV (default 75 MHz / 651 = 115,207 baud). The decimal digits of X, Y, N and the frame rates
// come from the osd_ext converters (bcd_* inputs); the pixel counts are converted here (osd_bin2bcd).
// Inputs follow the packing of osd_ext.v: target 0 (red) in the low bits.
// Reset: active-low asynchronous, TX idles high.

module uart_report #(
    parameter integer CLKDIV = 651,
    parameter integer PERIOD = 15000000
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [2:0]  t_valid,
    input  wire [8:0]  t_shape,
    input  wire [59:0] t_count,       // 3 x 20-bit binary pixel counts
    input  wire [47:0] bcd_x,         // 3 x 4 digits
    input  wire [47:0] bcd_y,         // 3 x 4 digits
    input  wire [59:0] bcd_k,         // 3 x 5 digits
    input  wire [11:0] bcd_fc,
    input  wire [11:0] bcd_fd,

    output reg         tx
);

    // pixel-count digits
    wire [71:0] ba_live;
    genvar gi;
    generate
        for (gi = 0; gi < 3; gi = gi + 1) begin : g_a
            osd_bin2bcd #(.BITS(20), .DIGITS(6)) u_a (.clk(clk), .rst_n(rst_n), .bin(t_count[20*gi+19:20*gi]), .bcd(ba_live[24*gi+23:24*gi]));
        end
    endgenerate

    // snapshot
    reg [2:0]  s_v;
    reg [8:0]  s_sh;
    reg [47:0] s_x, s_y;
    reg [59:0] s_k;
    reg [71:0] s_a;
    reg [11:0] s_fc, s_fd;

    // message position
    reg [1:0]  tgt;
    reg [5:0]  pos;
    reg        tail;
    reg        sending;

    reg  [7:0]  c;
    reg         v;
    reg  [2:0]  sh;
    reg  [15:0] dx, dy;
    reg  [23:0] da;
    reg  [19:0] dk;

    function [7:0] dig;
        input [3:0] x;
        begin
            dig = 8'h30 + {4'd0, x};
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

    // character at the current position
    always @* begin
        case (tgt)
            2'd0:    begin v = s_v[0]; sh = s_sh[2:0]; dx = s_x[15:0];  dy = s_y[15:0];  da = s_a[23:0];  dk = s_k[19:0];  end
            2'd1:    begin v = s_v[1]; sh = s_sh[5:3]; dx = s_x[31:16]; dy = s_y[31:16]; da = s_a[47:24]; dk = s_k[39:20]; end
            default: begin v = s_v[2]; sh = s_sh[8:6]; dx = s_x[47:32]; dy = s_y[47:32]; da = s_a[71:48]; dk = s_k[59:40]; end
        endcase
        c = 8'h20;
        if (!tail) begin
            case (pos)
                6'd0:  c = (tgt == 2'd0) ? "R" : (tgt == 2'd1) ? "G" : "B";
                6'd1:  c = ":";
                6'd2:  c = shape_ch(sh, 2'd0);
                6'd3:  c = shape_ch(sh, 2'd1);
                6'd4:  c = shape_ch(sh, 2'd2);
                6'd5:  c = shape_ch(sh, 2'd3);
                6'd6:  c = ",";
                6'd7:  c = "X";
                6'd8:  c = v ? dig(dx[15:12]) : "-";
                6'd9:  c = v ? dig(dx[11:8])  : "-";
                6'd10: c = v ? dig(dx[7:4])   : "-";
                6'd11: c = v ? dig(dx[3:0])   : "-";
                6'd12: c = ",";
                6'd13: c = "Y";
                6'd14: c = v ? dig(dy[15:12]) : "-";
                6'd15: c = v ? dig(dy[11:8])  : "-";
                6'd16: c = v ? dig(dy[7:4])   : "-";
                6'd17: c = v ? dig(dy[3:0])   : "-";
                6'd18: c = ",";
                6'd19: c = "A";
                6'd20: c = dig(da[23:20]);
                6'd21: c = dig(da[19:16]);
                6'd22: c = dig(da[15:12]);
                6'd23: c = dig(da[11:8]);
                6'd24: c = dig(da[7:4]);
                6'd25: c = dig(da[3:0]);
                6'd26: c = ",";
                6'd27: c = "N";
                6'd28: c = dig(dk[19:16]);
                6'd29: c = dig(dk[15:12]);
                6'd30: c = dig(dk[11:8]);
                6'd31: c = dig(dk[7:4]);
                6'd32: c = dig(dk[3:0]);
                default: c = ";";
            endcase
        end
        else begin
            case (pos)
                6'd0:  c = "C";  6'd1: c = "A";  6'd2: c = "M";
                6'd3:  c = dig(s_fc[11:8]);  6'd4: c = dig(s_fc[7:4]);  6'd5: c = dig(s_fc[3:0]);
                6'd6:  c = ",";
                6'd7:  c = "D";  6'd8: c = "S";  6'd9: c = "P";
                6'd10: c = dig(s_fd[11:8]);  6'd11: c = dig(s_fd[7:4]);  6'd12: c = dig(s_fd[3:0]);
                6'd13: c = 8'h0D;
                default: c = 8'h0A;
            endcase
        end
    end

    // transmitter and sequencer
    reg         busy;
    reg         req;
    reg         tx_start;
    reg  [7:0]  tx_data;
    reg  [9:0]  shreg;
    reg  [15:0] bcnt;
    reg  [3:0]  bitn;
    reg  [31:0] timer;

    wire last_char     = tail & (pos == 6'd14);
    wire last_of_block = ~tail & (pos == 6'd33);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx <= 1'b1; busy <= 1'b0; req <= 1'b0; tx_start <= 1'b0; tx_data <= 8'd0; shreg <= 10'h3FF;
            bcnt <= 16'd0; bitn <= 4'd0; timer <= 32'd0; sending <= 1'b0; tgt <= 2'd0; pos <= 6'd0; tail <= 1'b0;
            s_v <= 3'd0; s_sh <= 9'd0; s_x <= 48'd0; s_y <= 48'd0; s_k <= 60'd0; s_a <= 72'd0; s_fc <= 12'd0; s_fd <= 12'd0;
        end
        else begin
            // ---- transmitter
            if (!busy) begin
                tx <= 1'b1;
                if (tx_start) begin
                    shreg <= {1'b1, tx_data, 1'b0};
                    busy  <= 1'b1;
                    bcnt  <= 16'd0;
                    bitn  <= 4'd0;
                    tx    <= 1'b0;                       // start bit
                end
            end
            else begin
                if (bcnt == CLKDIV - 1) begin
                    bcnt <= 16'd0;
                    if (bitn == 4'd9) begin
                        busy <= 1'b0;
                        tx   <= 1'b1;
                    end
                    else begin
                        shreg <= {1'b1, shreg[9:1]};
                        tx    <= shreg[1];
                        bitn  <= bitn + 4'd1;
                    end
                end
                else bcnt <= bcnt + 16'd1;
            end

            // ---- message sequencing
            if (!sending) begin
                tx_start <= 1'b0;
                req      <= 1'b0;
                if (timer >= PERIOD - 1) begin
                    timer <= 32'd0;
                    s_v <= t_valid; s_sh <= t_shape; s_x <= bcd_x; s_y <= bcd_y; s_k <= bcd_k; s_a <= ba_live;
                    s_fc <= bcd_fc; s_fd <= bcd_fd;
                    tgt <= 2'd0; pos <= 6'd0; tail <= 1'b0;
                    sending <= 1'b1;
                end
                else timer <= timer + 32'd1;
            end
            else begin
                if (!req) begin
                    if (!busy) begin
                        tx_data  <= c;
                        tx_start <= 1'b1;
                        req      <= 1'b1;
                    end
                end
                else begin
                    tx_start <= 1'b0;
                    if (busy) begin                      // the character was taken: advance
                        req <= 1'b0;
                        if (last_char) begin
                            sending <= 1'b0;
                        end
                        else if (last_of_block) begin
                            pos <= 6'd0;
                            if (tgt == 2'd2) tail <= 1'b1;
                            else             tgt  <= tgt + 2'd1;
                        end
                        else pos <= pos + 6'd1;
                    end
                end
            end
        end
    end

endmodule
