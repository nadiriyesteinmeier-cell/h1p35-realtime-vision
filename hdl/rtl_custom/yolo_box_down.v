// yolo_box_down.v - streaming BOX x BOX average of one frame: the network input of the PH1P35 detector (1280 x 720 RGB -> 128 x 72 int8 for BOX = 10)
//
// Bit-exact model: tools/yolo/box_ref.py. One pixel per clock in (pix_valid / pix_sof / pr pg pb, raster order, gaps allowed), bytes out through a write port in the padded
// input map layout of yolo_net_engine (bank A, host port): element (y, x, c) of the averaged image goes to ((y + PAD_TOP + 1) * (NET_W + 2) + x + 1) * 3 + c with the value
// avg - 128 (int8, zero point 128). The letterbox rows and the border of the padded map are NOT written here (fill descriptors of the engine clear them).
//
// Operation: `arm` (1-clock pulse) selects the next frame start (pix_sof with pix_valid) for capture; the frame is processed and frame_done pulses after the last byte is
// written; `active` is high from the frame start to frame_done. Frames that are not armed pass unseen. A frame start (pix_sof) while a capture is still running
// (a truncated frame) abandons that capture: the next armed frame is captured normally, no frame_done is given for the truncated one. An accumulator memory of OUT_W entries (3 x 16 bit) holds the column sums
// of the block row in progress; the horizontal sum of a box lives in three 12-bit registers. The averages of a finished block row leave while its last row streams in
// (one output pixel per BOX input pixels, 3 bytes, 1 byte per clock) - no burst, no second buffer. BOX >= 6 is required (3 byte writes + latency per output pixel).
// Latency: the last byte of an output pixel is written 7 clocks after the last pixel of its box.
// Clock domain: everything runs on `clk` (the pixel clock); crossing to the engine clock is the job of the integration (a small FIFO on the write port).
// Reset: control flags only.

module yolo_box_down #(
    parameter integer IN_W   = 1280,
    parameter integer IN_H   = 720,
    parameter integer BOX    = 10,
    parameter integer NET_W  = 128,
    parameter integer PAD_TOP = 12,
    parameter integer RM     = 5243,       // avg = (sum * RM + RA) >> RS, round half up of sum / BOX^2 (tools/yolo/box_ref.py avg_params)
    parameter integer RA     = 262144,
    parameter integer RS     = 19
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire          arm,
    output reg           active,

    input  wire          pix_valid,
    input  wire          pix_sof,
    input  wire [7:0]    pr,
    input  wire [7:0]    pg,
    input  wire [7:0]    pb,

    output reg           we,
    output reg  [19:0]   waddr,
    output reg  [7:0]    wdata,
    output reg           frame_done
);

    localparam integer OUT_W = IN_W / BOX;
    localparam integer OUT_H = IN_H / BOX;
    localparam integer XB = 11;                       // column / row counter widths (IN_W, IN_H < 2048)

    reg          armed;
    reg  [XB-1:0] in_x, in_y;                         // pixel position inside the frame
    reg  [3:0]    bx, by;                             // position inside the box
    reg  [XB-1:0] ox;                                 // box column (the box row lives in row_base)
    reg  [11:0]   hr, hg, hb;                         // horizontal sums of the current box row
    wire          new_frame = pix_valid && pix_sof;
    wire          first_pix = new_frame && armed;                   // an armed frame starts (also while a truncated capture is still running: it is restarted)
    wire          take = first_pix || (pix_valid && active && !pix_sof);
    wire          last_in_box = (bx == BOX - 1);
    wire          last_row_in_box = (by == BOX - 1);
    wire          last_pix = (in_x == IN_W - 1) && (in_y == IN_H - 1);

    // ------------------------------------------------------------------ accumulator memory (column sums), read two clocks before the last pixel of a box
    reg [47:0] acc_mem [0:OUT_W-1];
    reg [47:0] acc_q;
    reg [XB-1:0] acc_ra;
    reg          acc_we;
    reg [XB-1:0] acc_wa;
    reg [47:0]   acc_wd;
    always @(posedge clk) begin
        if (acc_we) acc_mem[acc_wa] <= acc_wd;
        acc_q <= acc_mem[acc_ra];
    end

    // current box sums including the last pixel of the box row
    wire [11:0] hr_n = hr + {4'd0, pr};
    wire [11:0] hg_n = hg + {4'd0, pg};
    wire [11:0] hb_n = hb + {4'd0, pb};
    wire [15:0] sr = (by == 4'd0 ? 16'd0 : acc_q[15:0])  + {4'd0, hr_n};
    wire [15:0] sg = (by == 4'd0 ? 16'd0 : acc_q[31:16]) + {4'd0, hg_n};
    wire [15:0] sb = (by == 4'd0 ? 16'd0 : acc_q[47:32]) + {4'd0, hb_n};

    // ------------------------------------------------------------------ output emission: 3 bytes per finished box
    reg [1:0]  em;                                    // 0 idle, else the byte being produced is em - 1
    reg [15:0] e_r, e_g, e_b;
    reg [19:0] e_base;
    reg [19:0] row_base;                              // ((box row + PAD_TOP + 1) * (NET_W + 2)) * 3, kept incrementally (no multiplier)
    localparam [19:0] ROW0  = (PAD_TOP + 1) * (NET_W + 2) * 3;
    localparam [19:0] RSTEP = (NET_W + 2) * 3;
    function [31:0] rmul;                             // x * RM as a shift-add network (RM is a parameter: no DSP)
        input [15:0] x;
        integer b;
        begin
            rmul = 32'd0;
            for (b = 0; b < 16; b = b + 1) if ((RM >> b) & 1) rmul = rmul + ({16'd0, x} << b);
        end
    endfunction
    reg [31:0] e_prod;
    reg [1:0]  em_d;
    reg        pend_done;                             // the last output pixel of the frame has been handed to the emitter

    // ------------------------------------------------------------------ control (reset)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            armed <= 1'b0; active <= 1'b0; frame_done <= 1'b0; we <= 1'b0; em <= 2'd0; pend_done <= 1'b0;
        end
        else begin
            frame_done <= 1'b0;
            if (arm) armed <= 1'b1;
            if (first_pix) begin armed <= 1'b0; active <= 1'b1; pend_done <= 1'b0; end
            else if (new_frame && active) begin active <= 1'b0; pend_done <= 1'b0; end          // a frame start while a capture is running: the truncated capture is abandoned
            // emitter: byte k is written two clocks after its multiplication started
            we <= 1'b0;
            if (em != 2'd0) begin
                if (em == 2'd3) em <= 2'd0; else em <= em + 2'd1;
            end
            if (take && last_in_box && last_row_in_box && em == 2'd0) begin
                em <= 2'd1;
            end
            if (take && !first_pix && last_pix) pend_done <= 1'b1;
            if (pend_done && em == 2'd0 && em_d == 2'd0) begin pend_done <= 1'b0; active <= 1'b0; frame_done <= 1'b1; end     // the last byte is being written (frame_done and the last write strobe coincide)
            if (em_d != 2'd0) we <= 1'b1;
        end
    end
    always @(posedge clk) em_d <= em;

    // ------------------------------------------------------------------ data path (no reset)
    always @(posedge clk) begin
        acc_we <= 1'b0;
        if (first_pix) begin
            in_x <= 11'd1; in_y <= 11'd0; bx <= 4'd1; by <= 4'd0; ox <= 11'd0; row_base <= ROW0;
            hr <= {4'd0, pr}; hg <= {4'd0, pg}; hb <= {4'd0, pb};
        end
        else if (take) begin
            // position bookkeeping
            if (in_x == IN_W - 1) begin
                in_x <= 11'd0; in_y <= in_y + 11'd1;
                ox <= 11'd0; bx <= 4'd0;
                if (by == BOX - 1) begin by <= 4'd0; row_base <= row_base + RSTEP; end
                else by <= by + 4'd1;
            end
            else begin
                in_x <= in_x + 11'd1;
                if (last_in_box) begin bx <= 4'd0; ox <= ox + 11'd1; end
                else bx <= bx + 4'd1;
            end
            // horizontal sum
            if (last_in_box) begin hr <= 12'd0; hg <= 12'd0; hb <= 12'd0; end
            else begin hr <= hr_n; hg <= hg_n; hb <= hb_n; end
            // box finished: accumulate or emit
            if (last_in_box) begin
                if (last_row_in_box) begin
                    e_r <= sr; e_g <= sg; e_b <= sb;
                    e_base <= row_base + {8'd0, ox, 1'b0} + {9'd0, ox} + 20'd3;                 // + (ox + 1) * 3
                end
                else begin
                    acc_we <= 1'b1; acc_wa <= ox; acc_wd <= {sb, sg, sr};
                end
            end
        end
        // the column sum of the next box is read two clocks ahead of its last pixel
        if (take && bx == BOX - 3) acc_ra <= ox;
        // emitter datapath: em = 1 / 2 / 3 start the products of byte 0 / 1 / 2
        e_prod <= rmul(em == 2'd1 ? e_r : (em == 2'd2 ? e_g : e_b)) + RA;
        if (em_d != 2'd0) begin
            wdata <= {~e_prod[RS+7], e_prod[RS+6:RS]};          // (avg - 128) as int8: avg ^ 0x80
            waddr <= e_base + {18'd0, em_d} - 20'd1;
        end
    end

endmodule
