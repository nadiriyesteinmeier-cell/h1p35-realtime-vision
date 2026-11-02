// lat_probe.v - capture-to-display latency measurement (contest advanced item 3: latency visualisation)
//
// A microsecond time base runs in the 50 MHz reference domain and reaches the camera and the display domains as gray code (one bit
// changes per step, so a 2-stage synchroniser gives a value that is off by at most one step). The camera side writes the time and the
// camera frame number of every frame into the first 128-bit frame-buffer word of the frame (pixels 0..4 of line 0, they go through the
// DDR frame buffer like the picture). The display side reads those pixels back when it shows them and subtracts: the difference is the
// time the frame spent between the ISP output and the HDMI read-out (frame buffer + FIFOs), in microseconds and in camera frames.
//
//   us_gray_counter  (reference clock)  free-running microsecond counter, registered gray-code output
//   gray_sync        (any clock)        2-stage synchroniser + gray -> binary (registered)
//   ts_stamp         (camera clock)     inserts the stamp into the first valid word of every frame, counts camera frames
//   lat_meter        (pixel clock)      reads the stamp at pixels (0..3, 0) of the position-aligned stream, filters, holds the result
//
// Stamp format (frame-buffer word [127:0], pixel k at [127-24k -: 24], see video_out.v): pixels 0, 1, 4 = {4'hA, time_us[19:0]},
// pixels 2, 3 = {8'h5A, frame[15:0]}; the last byte of the word keeps the picture. The stamp pixels sit at the top-left corner of line 0
// (top_osd paints them black on the screen). Reset: active-low asynchronous in every module.

module us_gray_counter #(
    parameter integer DIV = 50,                 // reference clocks per microsecond
    parameter integer W   = 20
)(
    input  wire         clk,
    input  wire         rst_n,
    output reg  [W-1:0] gray
);
    reg [6:0]   pre;
    reg [W-1:0] bin;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin pre <= 7'd0; bin <= {W{1'b0}}; gray <= {W{1'b0}}; end
        else begin
            if (pre == DIV - 1) begin pre <= 7'd0; bin <= bin + 1'b1; end
            else pre <= pre + 7'd1;
            gray <= bin ^ (bin >> 1);
        end
    end
endmodule


module gray_sync #(
    parameter integer W = 20
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire [W-1:0] gray_in,                // from another clock domain, one bit changes per step
    output reg  [W-1:0] bin
);
    reg [W-1:0] s1, s2;
    reg [W-1:0] b;
    integer i;
    always @(*) begin
        b[W-1] = s2[W-1];
        for (i = W - 2; i >= 0; i = i - 1) b[i] = b[i+1] ^ s2[i];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s1 <= {W{1'b0}}; s2 <= {W{1'b0}}; bin <= {W{1'b0}}; end
        else begin s1 <= gray_in; s2 <= s1; bin <= b; end
    end
endmodule


module ts_stamp (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [19:0]  ts,                     // microseconds (gray_sync output in this domain)
    input  wire         tuser,                  // frame start (with or before the first valid word)
    input  wire         tvalid,
    input  wire [127:0] din,
    output wire [127:0] dout,                   // din with the stamp in the first valid word of the frame (combinational)
    output reg  [15:0]  fc_gray                 // camera frames started, gray code (for the display domain)
);
    reg  [15:0] fcount;
    reg  [19:0] ts_l;
    reg         armed;
    wire [15:0] fnum = tuser ? fcount + 16'd1 : fcount;
    wire [19:0] tnow = tuser ? ts : ts_l;
    wire        hit  = tvalid & (armed | tuser);
    wire [23:0] p_ts = {4'hA, tnow};
    wire [23:0] p_fc = {8'h5A, fnum};
    assign dout = hit ? {p_ts, p_ts, p_fc, p_fc, p_ts, din[7:0]} : din;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin fcount <= 16'd0; ts_l <= 20'd0; armed <= 1'b0; fc_gray <= 16'd0; end
        else begin
            if (tuser) begin fcount <= fcount + 16'd1; ts_l <= ts; end
            if (tvalid)     armed <= 1'b0;
            else if (tuser) armed <= 1'b1;
            fc_gray <= fcount ^ (fcount >> 1);
        end
    end
endmodule


module lat_meter #(
    parameter integer HOLD = 8,                 // the shown latency is refreshed every HOLD frames (readable digits)
    parameter integer WIN  = 64                 // the maximum is taken over WIN frames
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         de,                     // position-aligned stream (video_pos_adapter)
    input  wire [11:0]  x,
    input  wire [11:0]  y,
    input  wire [23:0]  rgb,
    input  wire [19:0]  ts,                     // microseconds, this domain
    input  wire [15:0]  fc_cam,                 // camera frames started, this domain
    output reg          valid,                  // the last displayed frame carried a stamp
    output reg  [16:0]  lat_us,                 // latency of a recent frame, us (99999 at most)
    output reg  [16:0]  max_us,                 // largest latency of the last complete window
    output reg  [3:0]   lat_fr                  // camera frames started between capture and display (9 at most)
);
    reg  [23:0] p0, p1, p2;
    reg  [19:0] t0;
    reg  [15:0] f0;
    reg  [3:0]  nh;
    reg  [6:0]  nw;
    reg  [16:0] wmax;
    wire [19:0] d    = t0 - p0[19:0];
    wire [16:0] dcap = (d > 20'd99999) ? 17'd99999 : d[16:0];
    wire [15:0] fd   = f0 - p2[15:0];
    wire        ok   = (p0 == p1) && (p0[23:20] == 4'hA) && (p2 == rgb) && (p2[23:16] == 8'h5A);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p0 <= 24'd0; p1 <= 24'd0; p2 <= 24'd0; t0 <= 20'd0; f0 <= 16'd0;
            nh <= 4'd0; nw <= 7'd0; wmax <= 17'd0;
            valid <= 1'b0; lat_us <= 17'd0; max_us <= 17'd0; lat_fr <= 4'd0;
        end
        else begin
            if (de && y == 12'd0) begin
                if (x == 12'd0) begin p0 <= rgb; t0 <= ts; f0 <= fc_cam; end
                if (x == 12'd1) p1 <= rgb;
                if (x == 12'd2) p2 <= rgb;
            end
            if (de && y == 12'd0 && x == 12'd3) begin           // pixel 3 is on rgb now: compared with pixel 2 in 'ok'
                valid <= ok;
                if (ok) begin
                    if (dcap > wmax) wmax <= dcap;
                    if (nh == HOLD - 1) begin
                        nh <= 4'd0;
                        lat_us <= dcap;
                        lat_fr <= (fd > 16'd9) ? 4'd9 : fd[3:0];
                    end
                    else nh <= nh + 4'd1;
                    if (nw == WIN - 1) begin
                        nw <= 7'd0;
                        max_us <= (dcap > wmax) ? dcap : wmax;
                        wmax <= 17'd0;
                    end
                    else nw <= nw + 7'd1;
                end
            end
        end
    end
endmodule
