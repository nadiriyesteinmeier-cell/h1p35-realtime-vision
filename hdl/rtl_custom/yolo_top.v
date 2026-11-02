// yolo_top.v - the complete on-chip detector of the PH1P35 board: frame sampling -> CNN (YOLOv3-tiny-derived, int8) -> head decode + NMS -> boxes, in ONE clock domain
//
// Clock: the HDMI pixel clock (75.0 MHz in this design's PLL / STA, not the nominal 74.25 MHz of 720p) - the same clock as the video read-out it samples, so there is no clock-domain crossing anywhere in the detector.
// Video is never stalled: the detector only listens to the read-out stream (vid_de / vid_user / vid_last / vid_rgb, colour 2 clocks behind de = the baseline SKEW).
//
// Cycle of the scheduler (modes 0..2):
//   ARM      arm yolo_box_down for the next frame start
//   CAP      the frame streams by; 1280 x 720 -> 10 x 10 averages -> 128 x 72 int8 written into bank A of the engine (padded map, letterbox rows by the descriptors)
//   NET      yolo_net_engine runs the descriptor table from the model ROMs (3 letterbox fills + border fills + 13 convolutions + pool9 + upsample)
//   DEC      yolo_decode: sigmoid / exp tables, score threshold, 32 candidate slots, class-wise NMS, up to 8 boxes in frame pixels
//   LATCH    the boxes, their count, the frame number of the sampled frame and the latency (sample start -> boxes) are latched for the overlay
// One result every second frame at 60 Hz (the inference runs while the next frame streams by), latency about one frame + the inference time (both are measured on chip
// and reported: det_rate = results in the last second, lat_ms).  Results older than STALE_FRAMES frames are withdrawn (nbox = 0).
// Mode 3 (dataset capture): the same sampling, but instead of running the network the 128 x 72 x 3 input image is sent over the UART (binary, see below) - these are the
// exact network inputs of this board for training / fine-tuning.
//
// Mode control: KEY3 + KEY4 pressed together (a chord nothing else uses) steps mode 0 -> 1 -> 2 -> 3 -> 4 (-> 5 with N_MODES = 6) -> 0.  mode: 0 = traditional detection only (the overlay
// shows the mode), 1 = YOLO only, 2 = both, 3 = dataset capture, 4 = white-balance page (wb_ctrl / wb_osd in the integrator own the keys and the picture there).
// The network runs in every mode except 3, so that switching shows boxes at once.
//
// UART (8N1, CLKDIV clocks per bit; 115200 baud at 75.0 MHz = 651):
//   modes 1, 2: a text report every REPORT_MS: "Y <n:1 hex> <frame:4 hex> <lat ms:2 hex>\r\n" then per box "<cls><score>>8:2 hex> <x0> <y0> <x1> <y1>\r\n" (3 hex digits each)
//   mode 3: per captured frame 0xA5 0x5A 'I' <frame 16 bit, MSB first> <27648 image bytes: rows 0..71, columns 0..127, R G B, int8 = pixel - 128> <checksum: sum of the image bytes mod 256>
//   modes 0, 4: the line is released (the integrator gives the UART to the traditional detector).
// Reset: control flags only (data registers are written before use).

module yolo_top #(
    parameter integer KEY_DEB      = 1500000,     // 20 ms at 75 MHz
    parameter integer MS_DIV       = 75000,       // clocks per millisecond
    parameter integer STALE_FRAMES = 30,          // withdraw the boxes when the newest result is older than this
    parameter integer CLKDIV       = 651,         // UART bit time
    parameter integer REPORT_MS    = 200,
    parameter integer DEPTH_A      = 38220,       // activation banks (exact sizes of the model's memory plan, tools/yolo/mininet.py)
    parameter integer DEPTH_B      = 26400,
    parameter integer DEPTH_C      = 2560,
    parameter integer DEPTH_D      = 1440,
    parameter integer THR          = 26214,       // decode score threshold, Q16
    parameter integer N_MODES      = 5,           // pages in the KEY3 + KEY4 cycle (6 in contest_work_v3_adv: mode 5 = motion page, drawn by top_osd)
    parameter integer DIAG         = 0            // 1 = board diagnostics in the report header: frame field = {phase, 0, layer[5:4], layer[3:0], 0}, latency field = ms in net + decode
)(
    input  wire          clk,
    input  wire          rst_n,

    input  wire          vid_de,
    input  wire          vid_user,
    input  wire          vid_last,
    input  wire [23:0]   vid_rgb,
    input  wire          vid_vs,

    input  wire [3:0]    key_n,

    output reg  [2:0]    mode,
    output wire [3:0]    nbox,
    output wire [479:0]  boxes,
    output reg  [7:0]    det_rate,
    output reg  [7:0]    lat_ms,
    output reg  [15:0]   res_frame,
    output reg  [15:0]   cap_count,
    output wire          uart_tx,
    output wire          uart_own,          // 1: the UART line carries this block's data (modes 1..3)
    output wire [2:0]    phase              // scheduler phase (diagnostics: 0 arm/cap, 1 net, 2 dec, 3 latch, 4 dump)
);

    // ------------------------------------------------------------------ model configuration (generated with the ROMs)
    wire [5:0]  m_nlayers;
    wire [47:0] m_anc1, m_anc2;
    yolo_model_cfg u_cfg (.nlayers(m_nlayers), .anc1(m_anc1), .anc2(m_anc2));

    // ------------------------------------------------------------------ position-aligned stream
    wire        a_de, a_sof, a_eol, a_eof, a_active, a_err;
    wire [23:0] a_rgb;
    wire [11:0] a_x, a_y;
    video_pos_adapter #(.WIDTH(1280), .HEIGHT(720), .SYNC_DELAY(2)) u_pos (
        .clk(clk), .rst_n(rst_n), .vid_de(vid_de), .vid_user(vid_user), .vid_last(vid_last), .vid_rgb(vid_rgb),
        .out_de(a_de), .out_rgb(a_rgb), .out_x(a_x), .out_y(a_y), .out_sof(a_sof), .out_eol(a_eol), .out_eof(a_eof),
        .frame_active(a_active), .geom_err(a_err)
    );

    // ------------------------------------------------------------------ millisecond / second ticks, frame counter
    reg [16:0] msc;
    reg        ms_tick;
    reg [15:0] ms_now;
    reg [9:0]  ms_in_s;
    reg        s_tick;
    reg        vs_q;
    reg [15:0] fcount;
    wire       frame_tick = vid_vs & ~vs_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin msc <= 17'd0; ms_tick <= 1'b0; ms_now <= 16'd0; ms_in_s <= 10'd0; s_tick <= 1'b0; vs_q <= 1'b0; fcount <= 16'd0; end
        else begin
            vs_q <= vid_vs;
            if (frame_tick) fcount <= fcount + 16'd1;
            ms_tick <= 1'b0; s_tick <= 1'b0;
            if (msc == MS_DIV - 1) begin
                msc <= 17'd0; ms_tick <= 1'b1; ms_now <= ms_now + 16'd1;
                if (ms_in_s == 10'd999) begin ms_in_s <= 10'd0; s_tick <= 1'b1; end
                else ms_in_s <= ms_in_s + 10'd1;
            end
            else msc <= msc + 17'd1;
        end
    end

    // ------------------------------------------------------------------ mode: KEY3 + KEY4 chord
    wire k3, k4;
    key_debounce #(.DEB(KEY_DEB)) u_k3 (.clk(clk), .rst_n(rst_n), .raw_n(key_n[2]), .down(k3));
    key_debounce #(.DEB(KEY_DEB)) u_k4 (.clk(clk), .rst_n(rst_n), .raw_n(key_n[3]), .down(k4));
    reg chord_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin chord_q <= 1'b0; mode <= 3'd0; end
        else begin
            chord_q <= k3 & k4;
            if (k3 & k4 & ~chord_q) mode <= (mode == N_MODES - 1) ? 3'd0 : mode + 3'd1;
        end
    end

    // ------------------------------------------------------------------ downscaler
    reg         arm;
    wire        bd_active, bd_we, bd_done;
    wire [19:0] bd_waddr;
    wire [7:0]  bd_wdata;
    yolo_box_down #(.IN_W(1280), .IN_H(720), .BOX(10), .NET_W(128), .PAD_TOP(12), .RM(5243), .RA(262144), .RS(19)) u_box (
        .clk(clk), .rst_n(rst_n), .arm(arm), .active(bd_active),
        .pix_valid(a_de), .pix_sof(a_sof), .pr(a_rgb[23:16]), .pg(a_rgb[15:8]), .pb(a_rgb[7:0]),
        .we(bd_we), .waddr(bd_waddr), .wdata(bd_wdata), .frame_done(bd_done)
    );

    // ------------------------------------------------------------------ engine + model ROMs
    localparam [2:0] F_ARM = 3'd0, F_CAP = 3'd1, F_NET = 3'd2, F_DEC = 3'd3, F_LATCH = 3'd4, F_DUMP = 3'd5;
    reg  [2:0]  fs;
    reg         net_start, dec_start;
    wire        net_busy, net_done, layer_done;
    wire [5:0]  desc_addr, layer_idx;
    wire [207:0] desc_data;
    wire [13:0] wt_addr;
    wire [63:0] wt_data;
    wire [10:0] pm_addr;
    wire [55:0] pm_data;
    wire [7:0]  host_rdata;
    wire [19:0] dec_rd_addr;
    reg  [19:0] dump_addr;
    wire        dumping = (fs == F_DUMP);
    yolo_net_engine #(.LANES(8), .DEPTH_A(DEPTH_A), .DEPTH_B(DEPTH_B), .DEPTH_C(DEPTH_C), .DEPTH_D(DEPTH_D)) u_eng (
        .clk(clk), .rst_n(rst_n), .start(net_start), .busy(net_busy), .net_done(net_done), .cfg_nlayers(m_nlayers),
        .desc_addr(desc_addr), .desc_data(desc_data), .wt_addr(wt_addr), .wt_data(wt_data), .pm_addr(pm_addr), .pm_data(pm_data),
        .host_we(bd_we), .host_bank(2'd0), .host_addr(bd_waddr), .host_wdata(bd_wdata),
        .host_rbank(dumping ? 2'd0 : 2'd3), .host_raddr(dumping ? dump_addr : dec_rd_addr), .host_rdata(host_rdata),
        .layer_idx(layer_idx), .layer_done(layer_done)
    );
    yolo_desc_rom u_desc (.clk(clk), .addr(desc_addr), .data(desc_data));
    yolo_wt_rom   u_wt   (.clk(clk), .addr(wt_addr),   .data(wt_data));
    yolo_pm_rom   u_pm   (.clk(clk), .addr(pm_addr),   .data(pm_data));

    // ------------------------------------------------------------------ decoder
    wire        dec_busy, dec_done;
    reg  [3:0]  res_idx;
    wire [59:0] res_data;
    wire [3:0]  res_n;
    yolo_decode #(.THR(THR)) u_dec (
        .clk(clk), .rst_n(rst_n), .anc1(m_anc1), .anc2(m_anc2), .start(dec_start), .busy(dec_busy), .done(dec_done),
        .rd_addr(dec_rd_addr), .rd_data(host_rdata), .res_idx(res_idx), .res_data(res_data), .res_n(res_n)
    );

    // ------------------------------------------------------------------ scheduler (control: reset)
    reg [15:0] cap_frame, cap_ms;
    reg [3:0]  li;                  // latch index
    reg [1:0]  lw;                  // latch wait
    reg [3:0]  nbox_q;
    reg [59:0] box_q [0:7];
    reg [7:0]  age;
    reg [7:0]  det_cnt;
    reg        dump_go;
    wire       dump_done;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fs <= F_ARM; arm <= 1'b0; net_start <= 1'b0; dec_start <= 1'b0; nbox_q <= 4'd0; age <= 8'hFF; det_cnt <= 8'd0; det_rate <= 8'd0; lat_ms <= 8'd0;
            res_frame <= 16'd0; dump_go <= 1'b0; li <= 4'd0; lw <= 2'd0; res_idx <= 4'd0;
        end
        else begin
            arm <= 1'b0; net_start <= 1'b0; dec_start <= 1'b0; dump_go <= 1'b0;
            if (frame_tick && age != 8'hFF) age <= age + 8'd1;
            if (s_tick) begin det_rate <= det_cnt; det_cnt <= 8'd0; end
            case (fs)
                F_ARM: begin arm <= 1'b1; fs <= F_CAP; end
                F_CAP: begin
                    if (bd_done) begin
                        if (mode == 3'd3) begin fs <= F_DUMP; dump_go <= 1'b1; end
                        else begin fs <= F_NET; net_start <= 1'b1; end
                    end
                end
                F_NET: if (net_done) begin fs <= F_DEC; dec_start <= 1'b1; end
                F_DEC: if (dec_done) begin fs <= F_LATCH; li <= 4'd0; lw <= 2'd0; res_idx <= 4'd0; end
                F_LATCH: begin
                    // res_data is a 1-clock synchronous read of res_idx: present the index, wait, take the word
                    lw <= lw + 2'd1;
                    if (lw == 2'd2) begin
                        lw <= 2'd0;
                        if (li == 4'd8) begin
                            nbox_q <= res_n; res_frame <= cap_frame; age <= 8'd0;
                            lat_ms <= ((ms_now - cap_ms) > 16'd255) ? 8'd255 : (ms_now[7:0] - cap_ms[7:0]);
                            det_cnt <= s_tick ? 8'd1 : (det_cnt + 8'd1);
                            fs <= F_ARM;
                        end
                        else begin
                            li <= li + 4'd1;
                            res_idx <= li + 4'd1;
                        end
                    end
                end
                F_DUMP: if (dump_done) fs <= F_ARM;
                default: fs <= F_ARM;
            endcase
        end
    end
    // board diagnostics (DIAG = 1): milliseconds spent in net + decode since the last net_start, saturating
    reg [7:0] dbg_ms;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) dbg_ms <= 8'd0;
        else if (net_start) dbg_ms <= 8'd0;
        else if (ms_tick && (fs == F_NET || fs == F_DEC) && dbg_ms != 8'hFF) dbg_ms <= dbg_ms + 8'd1;
    end
    // data side of the scheduler (no reset)
    reg bd_active_q;
    always @(posedge clk) begin
        bd_active_q <= bd_active;
        if (bd_active & ~bd_active_q) begin cap_frame <= fcount; cap_ms <= ms_now; end      // the sampled frame starts streaming
        if (fs == F_LATCH && lw == 2'd2 && li != 4'd8) box_q[li[2:0]] <= res_data;
    end
    assign phase = (fs == F_NET) ? 3'd1 : (fs == F_DEC) ? 3'd2 : (fs == F_LATCH) ? 3'd3 : (fs == F_DUMP) ? 3'd4 : 3'd0;

    wire fresh = (age < STALE_FRAMES);
    assign nbox = fresh ? nbox_q : 4'd0;
    genvar gb;
    generate
        for (gb = 0; gb < 8; gb = gb + 1) begin : g_box
            assign boxes[60*gb +: 60] = box_q[gb];
        end
    endgenerate

    // ------------------------------------------------------------------ UART: text report (modes 1, 2) / dataset stream (mode 3)
    reg        u_start;
    reg  [7:0] u_data;
    wire       u_busy;
    uart_tx8 #(.CLKDIV(CLKDIV)) u_uart (.clk(clk), .rst_n(rst_n), .start(u_start), .data(u_data), .busy(u_busy), .tx(uart_tx));
    assign uart_own = (mode == 3'd1) || (mode == 3'd2) || (mode == 3'd3);

    function [7:0] hexc;
        input [3:0] n;
        begin hexc = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n); end
    endfunction

    // report snapshot
    reg [59:0] rb [0:7];
    reg [3:0]  rn;
    reg [15:0] rf;
    reg [7:0]  rl;
    reg [15:0] rep_ms;
    localparam [1:0] U_IDLE = 2'd0, U_REP = 2'd1, U_DUMP = 2'd2;
    reg [1:0]  us;
    reg [4:0]  up;                   // byte position inside a line
    reg [3:0]  ub;                   // box index (8 = header line)
    reg [14:0] ucnt;                 // dump byte counter
    reg [7:0]  csum;
    reg [6:0]  drow, dcol;           // dump image position
    reg [1:0]  dch;
    reg [19:0] drow_base;
    reg [1:0]  dw;                   // dump read wait
    reg        dump_done_r;
    reg        dump_req;               // dump_go is a pulse: remembered until the transmitter is free (it may be sending a report)
    assign dump_done = dump_done_r;
    wire [59:0] cur = rb[ub[2:0]];

    // the byte at position up of the current report line (header: ub == 8)
    reg [7:0] rep_byte;
    reg       rep_last;              // this is the last byte of the line
    always @(*) begin
        rep_byte = 8'h20; rep_last = 1'b0;
        if (ub == 4'd8) begin
            case (up)
                5'd0: rep_byte = "Y";   5'd1: rep_byte = 8'h20; 5'd2: rep_byte = hexc(rn);  5'd3: rep_byte = 8'h20;
                5'd4: rep_byte = hexc(rf[15:12]); 5'd5: rep_byte = hexc(rf[11:8]); 5'd6: rep_byte = hexc(rf[7:4]); 5'd7: rep_byte = hexc(rf[3:0]);
                5'd8: rep_byte = 8'h20; 5'd9: rep_byte = hexc(rl[7:4]); 5'd10: rep_byte = hexc(rl[3:0]); 5'd11: rep_byte = 8'h0D;
                default: begin rep_byte = 8'h0A; rep_last = 1'b1; end
            endcase
        end
        else begin
            case (up)
                5'd0:  rep_byte = hexc({2'b00, cur[59:58]});
                5'd1:  rep_byte = hexc(cur[57:54]);  5'd2:  rep_byte = hexc(cur[53:50]);  5'd3: rep_byte = 8'h20;
                5'd4:  rep_byte = hexc({1'b0, cur[41:39]}); 5'd5: rep_byte = hexc(cur[38:35]); 5'd6: rep_byte = hexc(cur[34:31]); 5'd7: rep_byte = 8'h20;
                5'd8:  rep_byte = hexc({2'b00, cur[30:29]}); 5'd9: rep_byte = hexc(cur[28:25]); 5'd10: rep_byte = hexc(cur[24:21]); 5'd11: rep_byte = 8'h20;
                5'd12: rep_byte = hexc({1'b0, cur[20:18]}); 5'd13: rep_byte = hexc(cur[17:14]); 5'd14: rep_byte = hexc(cur[13:10]); 5'd15: rep_byte = 8'h20;
                5'd16: rep_byte = hexc({2'b00, cur[9:8]});  5'd17: rep_byte = hexc(cur[7:4]);  5'd18: rep_byte = hexc(cur[3:0]);  5'd19: rep_byte = 8'h0D;
                default: begin rep_byte = 8'h0A; rep_last = 1'b1; end
            endcase
        end
    end

    integer ri;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            us <= U_IDLE; u_start <= 1'b0; dump_done_r <= 1'b0; cap_count <= 16'd0; rep_ms <= 16'd0; dump_req <= 1'b0;
        end
        else begin
            u_start <= 1'b0; dump_done_r <= 1'b0;
            if (dump_go) dump_req <= 1'b1;
            case (us)
                U_IDLE: begin
                    if (dump_req) begin us <= U_DUMP; dump_req <= 1'b0; ucnt <= 15'd0; csum <= 8'd0; drow <= 7'd0; dcol <= 7'd0; dch <= 2'd0; dw <= 2'd0; drow_base <= 20'd0; end
                    else if ((mode == 3'd1 || mode == 3'd2) && (ms_now - rep_ms >= REPORT_MS)) begin
                        us <= U_REP; up <= 5'd0; ub <= 4'd8; rep_ms <= ms_now;
                        rn <= nbox;
                        if (DIAG != 0) begin rf <= {1'b0, fs, 2'b00, layer_idx, 4'h0}; rl <= dbg_ms; end    // where the scheduler / engine is, how long it has run
                        else begin rf <= res_frame; rl <= lat_ms; end
                        for (ri = 0; ri < 8; ri = ri + 1) rb[ri] <= box_q[ri];
                    end
                end
                U_REP: begin
                    if (!u_busy && !u_start) begin
                        u_start <= 1'b1; u_data <= rep_byte;
                        if (rep_last) begin
                            up <= 5'd0;
                            if (ub == 4'd8) begin
                                if (rn == 4'd0) us <= U_IDLE; else ub <= 4'd0;
                            end
                            else if (ub + 4'd1 >= rn) us <= U_IDLE;
                            else ub <= ub + 4'd1;
                        end
                        else up <= up + 5'd1;
                    end
                end
                U_DUMP: begin
                    // 0..4: header, 5 .. 5 + 27647: image, then the checksum
                    if (!u_busy && !u_start) begin
                        if (ucnt < 15'd5) begin
                            u_start <= 1'b1;
                            u_data <= (ucnt == 15'd0) ? 8'hA5 : (ucnt == 15'd1) ? 8'h5A : (ucnt == 15'd2) ? "I" : (ucnt == 15'd3) ? cap_frame[15:8] : cap_frame[7:0];
                            ucnt <= ucnt + 15'd1;
                        end
                        else if (ucnt < 15'd27653) begin
                            // image byte: present the address, wait for the synchronous read (two clocks), send
                            dw <= dw + 2'd1;
                            if (dw == 2'd3) begin
                                dw <= 2'd0;
                                u_start <= 1'b1; u_data <= host_rdata; csum <= csum + host_rdata; ucnt <= ucnt + 15'd1;
                                if (dch != 2'd2) dch <= dch + 2'd1;
                                else begin
                                    dch <= 2'd0;
                                    if (dcol != 7'd127) dcol <= dcol + 7'd1;
                                    else begin dcol <= 7'd0; drow <= drow + 7'd1; drow_base <= drow_base + 20'd390; end
                                end
                            end
                        end
                        else begin
                            u_start <= 1'b1; u_data <= csum; us <= U_IDLE; dump_done_r <= 1'b1; cap_count <= cap_count + 16'd1;
                        end
                    end
                end
                default: us <= U_IDLE;
            endcase
        end
    end
    // dump read address: interior image row drow (map row 13 + drow), column dcol (map column 1 + dcol), channel dch
    always @(posedge clk) dump_addr <= 20'd5070 + drow_base + {13'd0, dcol} * 3 + 20'd3 + {18'd0, dch};

endmodule
