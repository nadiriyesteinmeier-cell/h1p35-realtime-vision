// motion_det.v - hardware frame-difference motion detection on a 32 x 18 grid of 40 x 40-pixel cells (contest advanced item 4)
//
// Input: the position-aligned stream of video_pos_adapter (de, x, y, rgb; 1280 x 720, x / y of the pixel on rgb), pixel clock.
// Per cell the mean brightness Y = (R + 2G + B) / 4 is estimated from 10 x 10 samples (pixels with x mod 4 = 2 on lines with y mod 4 = 2;
// the cell grid starts at multiples of 40, so x mod 4 = position in the cell mod 4). The sum of the 100 samples (15 bits) is kept as
// cur = sum >> 7 (8 bits, about 0.78 x the mean). A cell MOVES when |cur - prev| >= THR, prev = its value one frame earlier (ERAM,
// 576 x 8 bits). Nothing moves in the first frame after reset (no previous frame yet).
//
// Sums: one 12-bit accumulator for the cell segment of the current line; at the last pixel of every cell (x mod 40 = 39) on a sampled line
// the segment is added into a 32-entry ring of 15-bit row sums (one entry per cell column; the ring shifts once per cell, 32 times per
// line, so its head is always the current column). At the end of the last sampled line of a cell row (y mod 40 = 38) a small FSM walks
// the ring (2 clocks per cell, 64 clocks; the next sampled line is 4 lines later): compares with prev, writes prev, builds the row's
// 32 motion bits, counts and extends the bounding box. The row bits go to a 32 x 32-bit map (synchronous read port for the overlay).
// The frame result (count, box) is latched at the last pixel of the frame.
//
// Overlay read port: map_raddr = cell row 0..17, map_rdata = its 32 bits (bit i = column i) one clock later. Rows above the current
// read-out position hold this frame's result, rows below the previous frame's (the map is written row by row).

module motion_det #(
    parameter integer THR = 6
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         de,
    input  wire [11:0]  x,
    input  wire [11:0]  y,
    input  wire [23:0]  rgb,
    input  wire [4:0]   map_raddr,
    output reg  [31:0]  map_rdata,
    output reg  [9:0]   count,                  // moving cells of the last complete frame
    output reg  [4:0]   bx0,                    // their bounding box in cells (meaningful when count != 0)
    output reg  [4:0]   bx1,
    output reg  [4:0]   by0,
    output reg  [4:0]   by1,
    output reg          ready                   // a previous frame exists
);
    // ------------------------------------------------------------------ cell position of the current pixel
    reg  [5:0] xc_n, yc_n;                      // position in the cell of the next pixel / the next line
    reg  [4:0] bx_n, by_n;
    wire       x0  = (x == 12'd0);
    wire       y0  = (y == 12'd0);
    wire [5:0] xc  = x0 ? 6'd0 : xc_n;
    wire [4:0] bx  = x0 ? 5'd0 : bx_n;
    wire [5:0] yc  = y0 ? 6'd0 : yc_n;
    wire [4:0] by  = y0 ? 5'd0 : by_n;
    wire       eol = de && (x == 12'd1279);
    wire       eof = eol && (y == 12'd719);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin xc_n <= 6'd0; bx_n <= 5'd0; yc_n <= 6'd0; by_n <= 5'd0; end
        else if (de) begin
            if (xc == 6'd39) begin xc_n <= 6'd0; bx_n <= bx + 5'd1; end
            else begin xc_n <= xc + 6'd1; bx_n <= bx; end
            if (eol) begin
                if (yc == 6'd39) begin yc_n <= 6'd0; by_n <= by + 5'd1; end
                else begin yc_n <= yc + 6'd1; by_n <= by; end
            end
        end
    end

    // ------------------------------------------------------------------ sums
    wire [9:0]  ysum  = {2'b00, rgb[23:16]} + {1'b0, rgb[15:8], 1'b0} + {2'b00, rgb[7:0]};
    wire [7:0]  luma  = ysum[9:2];
    wire        sline = (y[1:0] == 2'd2);
    reg  [11:0] acc;
    reg  [14:0] ring [0:31];
    wire        cell_end = de && sline && (xc == 6'd39);
    wire [14:0] ring_new = ((yc == 6'd2) ? 15'd0 : ring[0]) + {3'd0, acc};

    // FSM
    reg  [1:0]  st;                             // 0 idle, 1 read prev, 2 compare / write
    reg  [4:0]  ci;                             // column
    reg  [4:0]  crow;                           // cell row being finished
    reg  [31:0] mrow;
    wire [7:0]  cur   = ring[0][14:7];
    reg  [7:0]  prev_mem [0:1023];
    reg  [7:0]  prev_q;
    wire [9:0]  paddr = {crow, ci};
    wire [8:0]  dif   = {1'b0, cur} - {1'b0, prev_q};
    wire [7:0]  adif  = dif[8] ? (8'd0 - dif[7:0]) : dif[7:0];
    wire        mbit  = ready && (adif >= THR);
    wire        shift = cell_end || (st == 2'd2);

    integer k;
    always @(posedge clk) begin
        if (shift) begin
            for (k = 0; k < 31; k = k + 1) ring[k] <= ring[k+1];
            ring[31] <= (st == 2'd2) ? ring[0] : ring_new;
        end
    end
    always @(posedge clk) begin
        if (de && sline && xc[1:0] == 2'd2) acc <= ((xc == 6'd2) ? 12'd0 : acc) + {4'd0, luma};
    end

    always @(posedge clk) prev_q <= prev_mem[paddr];
    always @(posedge clk) if (st == 2'd2) prev_mem[paddr] <= cur;

    reg  [31:0] map_mem [0:31];
    reg         map_we;
    reg  [4:0]  map_wa;
    reg  [31:0] map_wd;
    always @(posedge clk) begin
        if (map_we) map_mem[map_wa] <= map_wd;
        map_rdata <= map_mem[map_raddr];
    end

    reg [9:0] f_cnt;
    reg [4:0] f_bx0, f_bx1, f_by0, f_by1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= 2'd0; ci <= 5'd0; crow <= 5'd0; mrow <= 32'd0; map_we <= 1'b0; map_wa <= 5'd0; map_wd <= 32'd0;
            f_cnt <= 10'd0; f_bx0 <= 5'd31; f_bx1 <= 5'd0; f_by0 <= 5'd31; f_by1 <= 5'd0;
            count <= 10'd0; bx0 <= 5'd0; bx1 <= 5'd0; by0 <= 5'd0; by1 <= 5'd0; ready <= 1'b0;
        end
        else begin
            map_we <= 1'b0;
            case (st)
                2'd0: if (eol && yc == 6'd38) begin st <= 2'd1; ci <= 5'd0; crow <= by; end
                2'd1: st <= 2'd2;                                   // prev_q of (crow, ci) arrives
                default: begin                                      // compare, write prev (above), shift the ring (above)
                    mrow <= {mbit, mrow[31:1]};
                    if (mbit) begin
                        f_cnt <= f_cnt + 10'd1;
                        if (ci < f_bx0) f_bx0 <= ci;
                        if (ci > f_bx1) f_bx1 <= ci;
                        if (crow < f_by0) f_by0 <= crow;
                        if (crow > f_by1) f_by1 <= crow;
                    end
                    if (ci == 5'd31) begin
                        st <= 2'd0;
                        map_we <= 1'b1; map_wa <= crow; map_wd <= {mbit, mrow[31:1]};
                    end
                    else begin ci <= ci + 5'd1; st <= 2'd1; end
                end
            endcase
            if (eof) begin                                          // the FSM of the last cell row finished on line 718
                count <= f_cnt; bx0 <= f_bx0; bx1 <= f_bx1; by0 <= f_by0; by1 <= f_by1;
                f_cnt <= 10'd0; f_bx0 <= 5'd31; f_bx1 <= 5'd0; f_by0 <= 5'd31; f_by1 <= 5'd0;
                ready <= 1'b1;
            end
        end
    end
endmodule
