// shade_diag.v - image-shading diagnostic block: AWB mode keys + flat-field statistics + UART report
//
// Purpose: measure what the camera / ISP path delivers over the image area (centre-green / edge-red cast) WITHOUT adding any correction.
//   * The stream under test is the frame-buffer read-out BEFORE the display enhancements (the same tap the blue detector uses): pass it
//     in vid_rgb together with the undelayed uivtc de / user / last (video_pos_adapter aligns them, SYNC_DELAY = SKEW).
//   * flat_stats sums R, G, B per cell (16 x 9 cells of 80 x 80 pixels), shade_report prints the sums as text on the UART (see
//     shade_report.v for the format); tools/shade_capture.ps1 + tools/shade_analyze.py read and evaluate them on the PC.
//   * awb_mode (static, 2 bits, goes to the vendor AWB in the camera clock domain) selects the white-balance behaviour:
//        0 = original vendor behaviour (running gray-world gains that change during the frame)
//        1 = frame-held gains (the final gains of the previous frame are applied to the whole next frame)
//        2 = unity gains (no white balance: the raw demosaiced colours, the best view of the lens / sensor shading)
//     so that the same flat white target can be measured in the three modes.
//
// Controls (only while diag_active = 1; they do nothing otherwise and the report is silent):
//   KEY1 (press)  awb_mode 0 -> 1 -> 2 -> 0        KEY2 (press)  report on / off (power-up: on)
// A mode change restarts the measurement and the first SETTLE reports after it are discarded (the gains need a frame or two to follow).
// The report loop: measure one frame (flat_stats) -> print it (shade_report) -> wait GAP_CLKS -> measure again. rep_count counts the
// printed reports (8 bits, wraps). uart_tx idles high; the integrator multiplexes it with the other UART source.
// All in the pixel clock domain; awb_mode must be synchronized by the integrator into the camera clock domain.
// Reset: active-low asynchronous (awb_mode = 0, report on).

module shade_diag #(
    parameter integer SKEW        = 2,
    parameter integer KEY_DEB     = 1500000,
    parameter integer UART_CLKDIV = 651,
    parameter integer GAP_CLKS    = 37500000,
    parameter integer SETTLE      = 3,
    parameter integer AWB_MODES   = 3,          // number of AWB modes the KEY1 cycle visits (3 = vendor awb.v build, 2 = awb_frame build)
    parameter integer GRID_W      = 16,
    parameter integer GRID_H      = 9,
    parameter integer CELL_W      = 80,
    parameter integer CELL_H      = 80
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        vid_de,
    input  wire        vid_user,
    input  wire        vid_last,
    input  wire [23:0] vid_rgb,

    input  wire        diag_active,
    input  wire [1:0]  key_n,              // KEY1, KEY2 (low = pressed)

    output reg  [1:0]  awb_mode,
    output reg         rep_en,
    output wire        rep_busy,
    output reg  [7:0]  rep_count,
    output wire        uart_tx
);

    // ---------------- keys
    wire [1:0] down;
    key_debounce #(.DEB(KEY_DEB)) u_k1 (.clk(clk), .rst_n(rst_n), .raw_n(key_n[0]), .down(down[0]));
    key_debounce #(.DEB(KEY_DEB)) u_k2 (.clk(clk), .rst_n(rst_n), .raw_n(key_n[1]), .down(down[1]));
    reg [1:0] dq;
    wire [1:0] press = down & ~dq;
    reg        mode_chg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dq <= 2'd0; awb_mode <= 2'd0; rep_en <= 1'b1; mode_chg <= 1'b0;
        end
        else begin
            dq <= down;
            mode_chg <= 1'b0;
            if (diag_active && press[0]) begin
                awb_mode <= (awb_mode == AWB_MODES - 1) ? 2'd0 : (awb_mode + 2'd1);
                mode_chg <= 1'b1;
            end
            if (diag_active && press[1]) rep_en <= ~rep_en;
        end
    end

    // ---------------- stream under test
    wire        a_de, a_sof, a_eol, a_eof;
    wire [23:0] a_rgb;
    video_pos_adapter #(.WIDTH(1280), .HEIGHT(720), .SYNC_DELAY(SKEW)) u_adapter (
        .clk(clk), .rst_n(rst_n),
        .vid_de(vid_de), .vid_user(vid_user), .vid_last(vid_last), .vid_rgb(vid_rgb),
        .out_de(a_de), .out_rgb(a_rgb), .out_x(), .out_y(),
        .out_sof(a_sof), .out_eol(a_eol), .out_eof(a_eof),
        .frame_active(), .geom_err()
    );

    reg        st_start;
    wire       st_busy, st_done;
    wire [7:0] st_addr;
    wire [62:0] st_data;
    flat_stats #(.GRID_W(GRID_W), .GRID_H(GRID_H), .CELL_W(CELL_W), .CELL_H(CELL_H)) u_stats (
        .clk(clk), .rst_n(rst_n), .start(st_start), .busy(st_busy), .done(st_done),
        .in_de(a_de), .in_sof(a_sof), .in_eol(a_eol), .in_eof(a_eof), .in_rgb(a_rgb),
        .ext_addr(st_addr), .ext_data(st_data)
    );

    reg        rp_go;
    wire       rp_done;
    reg  [1:0] mode_at_start;
    shade_report #(.CLKDIV(UART_CLKDIV), .GRID_W(GRID_W), .GRID_H(GRID_H), .CELL_W(CELL_W)) u_report (
        .clk(clk), .rst_n(rst_n), .go(rp_go), .frame_no(rep_count), .mode({2'd0, mode_at_start}),
        .busy(rep_busy), .done(rp_done), .rd_addr(st_addr), .rd_data(st_data), .tx(uart_tx)
    );

    // ---------------- measurement / report loop
    localparam [1:0] C_IDLE = 2'd0;
    localparam [1:0] C_CAP  = 2'd1;
    localparam [1:0] C_REP  = 2'd2;
    localparam [1:0] C_GAP  = 2'd3;
    reg [1:0]  cstate;
    reg [31:0] gap;
    reg [3:0]  settle;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cstate <= C_IDLE; gap <= 32'd0; settle <= SETTLE; st_start <= 1'b0; rp_go <= 1'b0; mode_at_start <= 2'd0; rep_count <= 8'd0;
        end
        else begin
            st_start <= 1'b0;
            rp_go    <= 1'b0;
            if (mode_chg) settle <= SETTLE;
            case (cstate)
                C_IDLE: begin
                    if (diag_active && rep_en && !st_busy && !rep_busy) begin
                        st_start      <= 1'b1;
                        mode_at_start <= awb_mode;
                        cstate        <= C_CAP;
                    end
                end
                C_CAP: begin
                    if (st_done) begin
                        if (mode_at_start != awb_mode || mode_chg) cstate <= C_IDLE;            // the mode changed during the frame: measure again
                        else if (settle != 4'd0) begin settle <= settle - 4'd1; cstate <= C_IDLE; end
                        else if (diag_active && rep_en) begin rp_go <= 1'b1; cstate <= C_REP; end
                        else cstate <= C_IDLE;
                    end
                end
                C_REP: begin
                    if (rp_done) begin
                        rep_count <= rep_count + 8'd1;
                        gap       <= GAP_CLKS;
                        cstate    <= C_GAP;
                    end
                end
                default: begin
                    if (gap == 32'd0) cstate <= C_IDLE;
                    else gap <= gap - 32'd1;
                end
            endcase
        end
    end

endmodule
