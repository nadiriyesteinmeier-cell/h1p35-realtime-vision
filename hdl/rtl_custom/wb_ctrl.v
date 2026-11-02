// wb_ctrl.v - white-balance page control: AUTO / MAN / OFF, three manual gains set with the keys, display digits
//
// Clock: the HDMI pixel clock (all inputs synchronous to it; cur_* come from the ISP clock through a CDC in the integrator).
// Output wb_mode uses the awb_frame I_mode codes: 0 AUTO (gray world), 1 OFF (unity gains), 2 MAN (man_r / man_g / man_b).
// Manual gains are kept in hundredths (h = 100 is 1.00, H_MIN..H_MAX, default 0.25..8.00) and given to the ISP in Q4.12:
//   man = round(h * 4096 / 100), computed exactly as (h * 1342177 + 16384) >> 15 (exact for every h <= 1023), sequentially: ~36 clocks for
//   all three channels after a change (only the CDC to the ISP and the next frame start follow).
// The gains the ISP applies (cur_*, Q4.12) are shown in hundredths: round(cur * 100 / 4096) = (cur * 25 + 512) >> 10.
//
// Keys (active-low buttons, debounced here; they are only interpreted while `active`, the WB page is on screen):
//   KEY1 - / KEY2 + : the selected gain by 0.01 at the press, auto-repeat after REP_DELAY every REP_PER, by 0.05 per step once held for REP_FAST.
//                     In AUTO / OFF the first step switches to MAN, starting from the gains the ISP applies at that moment (no jump in the picture).
//   KEY3 alone      : select the gain R -> G -> B -> R          (acts at the release, and only if KEY4 was not pressed meanwhile)
//   KEY4 alone      : mode AUTO -> MAN -> OFF -> AUTO           (at the release; entering MAN takes over the gains the ISP applies = one-push white
//                     balance: aim at a white / gray card in AUTO, press KEY4)
//   KEY4 held alone for LONG_PRESS: MAN with all three gains 1.00 (the release then does nothing)
//   KEY3 + KEY4     : nothing here (yolo_top steps the page with this chord)
// Mode and gains persist when the page is left, so the tuned white balance stays in effect for the other display modes.
// digits: 6 values x 3 BCD digits, {gain R, gain G, gain B, avg R, avg G, avg B}, each {hundreds, tens, ones} (gains: d.dd, values above 9.99 show 9.99),
//   converted one after the other by a small subtraction loop (about 20 clocks per value) and refreshed continuously; the overlay latches them per frame.
// Reset: active-low asynchronous: AUTO, R selected, gains 1.00.

module wb_ctrl #(
    parameter integer KEY_DEB    = 1500000,      // 20 ms at 75 MHz
    parameter integer REP_DELAY  = 37500000,     // 0.5 s
    parameter integer REP_PER    = 4687500,      // 1 / 16 s
    parameter integer REP_FAST   = 150000000,    // 2 s
    parameter integer LONG_PRESS = 75000000,     // 1 s
    parameter [9:0]   H_MIN      = 10'd25,
    parameter [9:0]   H_MAX      = 10'd800
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        active,
    input  wire [3:0]  key_n,
    input  wire [15:0] cur_r,
    input  wire [15:0] cur_g,
    input  wire [15:0] cur_b,
    input  wire [7:0]  avg_r,
    input  wire [7:0]  avg_g,
    input  wire [7:0]  avg_b,
    output reg  [1:0]  wb_mode,
    output reg  [1:0]  sel,
    output reg  [15:0] man_r,
    output reg  [15:0] man_g,
    output reg  [15:0] man_b,
    output reg  [71:0] digits
);

    localparam [1:0] M_AUTO = 2'd0, M_OFF = 2'd1, M_MAN = 2'd2;

    // ------------------------------------------------------------------ keys
    wire [3:0] kd;
    genvar gk;
    generate
        for (gk = 0; gk < 4; gk = gk + 1) begin : g_key
            key_debounce #(.DEB(KEY_DEB)) u_deb (.clk(clk), .rst_n(rst_n), .raw_n(key_n[gk]), .down(kd[gk]));
        end
    endgenerate

    // ------------------------------------------------------------------ the applied gains in hundredths (two pipeline stages)
    reg [20:0] t_r, t_g, t_b;
    reg [10:0] ch_r, ch_g, ch_b;
    always @(posedge clk) begin
        t_r  <= {5'd0, cur_r} + {2'd0, cur_r, 3'd0} + {1'd0, cur_r, 4'd0};      // x 25
        t_g  <= {5'd0, cur_g} + {2'd0, cur_g, 3'd0} + {1'd0, cur_g, 4'd0};
        t_b  <= {5'd0, cur_b} + {2'd0, cur_b, 3'd0} + {1'd0, cur_b, 4'd0};
        ch_r <= (t_r + 21'd512) >> 10;
        ch_g <= (t_g + 21'd512) >> 10;
        ch_b <= (t_b + 21'd512) >> 10;
    end
    function [9:0] clamp_h;                     // into the manual range
        input [10:0] v;
        begin clamp_h = (v < {1'b0, H_MIN}) ? H_MIN : (v > {1'b0, H_MAX}) ? H_MAX : v[9:0]; end
    endfunction

    // ------------------------------------------------------------------ - / + with auto-repeat (KEY1 / KEY2, one of them alone)
    wire       adj    = active & (kd[0] ^ kd[1]);
    wire       adj_up = kd[1];
    reg        adj_q, up_q;
    reg [27:0] hold_c, rep_c;
    reg        ev, ev_up, ev_big;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin adj_q <= 1'b0; up_q <= 1'b0; hold_c <= 28'd0; rep_c <= 28'd0; ev <= 1'b0; ev_up <= 1'b0; ev_big <= 1'b0; end
        else begin
            adj_q <= adj; up_q <= adj_up; ev <= 1'b0;
            if (!adj) begin hold_c <= 28'd0; rep_c <= 28'd0; end
            else if (!adj_q || up_q != adj_up) begin                      // a new press (or the other key alone now): one step at once
                hold_c <= 28'd0; rep_c <= 28'd0; ev <= 1'b1; ev_up <= adj_up; ev_big <= 1'b0;
            end
            else begin
                if (hold_c != 28'hFFFFFFF) hold_c <= hold_c + 28'd1;
                if (hold_c >= REP_DELAY) begin
                    if (rep_c >= REP_PER - 1) begin rep_c <= 28'd0; ev <= 1'b1; ev_up <= adj_up; ev_big <= (hold_c >= REP_FAST); end
                    else rep_c <= rep_c + 28'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------------ KEY3 / KEY4 alone, at the release; KEY4 long press
    reg [3:0]  kq;
    reg        a3, o3, a4, o4;                  // armed (pressed while active), the other key was down meanwhile
    reg [27:0] lc4;
    reg        sel_ev, mode_ev, reset_ev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin kq <= 4'd0; a3 <= 1'b0; o3 <= 1'b0; a4 <= 1'b0; o4 <= 1'b0; lc4 <= 28'd0; sel_ev <= 1'b0; mode_ev <= 1'b0; reset_ev <= 1'b0; end
        else begin
            kq <= kd; sel_ev <= 1'b0; mode_ev <= 1'b0; reset_ev <= 1'b0;
            // KEY3 (armed at the press; leaving the page disarms, below)
            if (kd[2] & ~kq[2]) begin a3 <= 1'b1; o3 <= kd[3]; end
            else if (kd[2]) begin if (kd[3]) o3 <= 1'b1; end
            else if (~kd[2] & kq[2]) begin sel_ev <= a3 & ~o3 & active; a3 <= 1'b0; end
            // KEY4
            if (kd[3] & ~kq[3]) begin a4 <= 1'b1; o4 <= kd[2]; lc4 <= 28'd0; end
            else if (kd[3]) begin
                if (kd[2]) o4 <= 1'b1;
                if (lc4 != 28'hFFFFFFF) lc4 <= lc4 + 28'd1;
                if (lc4 == LONG_PRESS - 1 && a4 && !o4) begin reset_ev <= 1'b1; a4 <= 1'b0; end
            end
            else if (~kd[3] & kq[3]) begin mode_ev <= a4 & ~o4 & active; a4 <= 1'b0; end
            if (!active) begin a3 <= 1'b0; a4 <= 1'b0; end         // a press only counts if the page stays on screen from the press to the action
        end
    end

    // ------------------------------------------------------------------ mode, selection and manual gains (hundredths)
    reg  [9:0] h_r, h_g, h_b;
    wire       is_man = (wb_mode == M_MAN);
    wire [9:0] b_r = is_man ? h_r : clamp_h(ch_r);        // base of a step: the manual value, or the gain applied now
    wire [9:0] b_g = is_man ? h_g : clamp_h(ch_g);
    wire [9:0] b_b = is_man ? h_b : clamp_h(ch_b);
    wire [9:0] b_s = (sel == 2'd0) ? b_r : (sel == 2'd1) ? b_g : b_b;
    wire [9:0] st  = ev_big ? 10'd5 : 10'd1;
    wire [10:0] up_v = {1'b0, b_s} + {1'b0, st};
    wire [9:0] n_s = ev_up ? ((up_v > {1'b0, H_MAX}) ? H_MAX : up_v[9:0])
                           : ((b_s < H_MIN + st) ? H_MIN : (b_s - st));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin wb_mode <= M_AUTO; sel <= 2'd0; h_r <= 10'd100; h_g <= 10'd100; h_b <= 10'd100; end
        else begin
            if (sel_ev) sel <= (sel == 2'd2) ? 2'd0 : sel + 2'd1;
            if (reset_ev) begin wb_mode <= M_MAN; h_r <= 10'd100; h_g <= 10'd100; h_b <= 10'd100; end
            else if (mode_ev) begin
                case (wb_mode)
                    M_AUTO:  begin wb_mode <= M_MAN; h_r <= clamp_h(ch_r); h_g <= clamp_h(ch_g); h_b <= clamp_h(ch_b); end
                    M_MAN:   wb_mode <= M_OFF;
                    default: wb_mode <= M_AUTO;
                endcase
            end
            else if (ev) begin
                wb_mode <= M_MAN;
                h_r <= (sel == 2'd0) ? n_s : b_r;
                h_g <= (sel == 2'd1) ? n_s : b_g;
                h_b <= (sel == 2'd2) ? n_s : b_b;
            end
        end
    end

    // ------------------------------------------------------------------ hundredths -> Q4.12, one channel after the other (12 clocks each)
    // man = (h * 1342177 + 16384) >> 15 = round(h * 4096 / 100) exactly for every h <= 1023 (checked exhaustively); shift-add, one bit of h per clock
    localparam [30:0] KQ = 31'd1342177;
    reg [1:0]  q_ch;
    reg [3:0]  q_i;
    reg [9:0]  q_h;
    reg [30:0] q_k, q_acc;
    wire [30:0] q_rnd = q_acc + 31'd16384;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            man_r <= 16'd4096; man_g <= 16'd4096; man_b <= 16'd4096;
            q_ch <= 2'd0; q_i <= 4'd0; q_h <= 10'd0; q_k <= 31'd0; q_acc <= 31'd0;
        end
        else if (q_i == 4'd0) begin
            q_h <= (q_ch == 2'd0) ? h_r : (q_ch == 2'd1) ? h_g : h_b;
            q_k <= KQ; q_acc <= 31'd0; q_i <= 4'd1;
        end
        else if (q_i <= 4'd10) begin
            if (q_h[0]) q_acc <= q_acc + q_k;
            q_h <= q_h >> 1; q_k <= q_k << 1; q_i <= q_i + 4'd1;
        end
        else begin
            case (q_ch)
                2'd0: man_r <= q_rnd[30:15];
                2'd1: man_g <= q_rnd[30:15];
                default: man_b <= q_rnd[30:15];
            endcase
            q_ch <= (q_ch == 2'd2) ? 2'd0 : q_ch + 2'd1;
            q_i  <= 4'd0;
        end
    end

    // ------------------------------------------------------------------ BCD digits of the six display values, one after the other
    function [9:0] disp_h;                        // gains above 9.99 show 9.99
        input [10:0] v;
        begin disp_h = (v > 11'd999) ? 10'd999 : v[9:0]; end
    endfunction
    reg [2:0] bi;
    reg [1:0] bst;
    reg [9:0] bv;
    reg [3:0] bd2, bd1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin bi <= 3'd0; bst <= 2'd0; bv <= 10'd0; bd2 <= 4'd0; bd1 <= 4'd0; digits <= 72'd0; end
        else begin
            case (bst)
                2'd0: begin
                    case (bi)
                        3'd0: bv <= disp_h(ch_r);
                        3'd1: bv <= disp_h(ch_g);
                        3'd2: bv <= disp_h(ch_b);
                        3'd3: bv <= {2'd0, avg_r};
                        3'd4: bv <= {2'd0, avg_g};
                        default: bv <= {2'd0, avg_b};
                    endcase
                    bd2 <= 4'd0; bd1 <= 4'd0; bst <= 2'd1;
                end
                2'd1: if (bv >= 10'd100) begin bv <= bv - 10'd100; bd2 <= bd2 + 4'd1; end else bst <= 2'd2;
                2'd2: if (bv >= 10'd10)  begin bv <= bv - 10'd10;  bd1 <= bd1 + 4'd1; end else bst <= 2'd3;
                default: begin
                    case (bi)
                        3'd0: digits[71:60] <= {bd2, bd1, bv[3:0]};
                        3'd1: digits[59:48] <= {bd2, bd1, bv[3:0]};
                        3'd2: digits[47:36] <= {bd2, bd1, bv[3:0]};
                        3'd3: digits[35:24] <= {bd2, bd1, bv[3:0]};
                        3'd4: digits[23:12] <= {bd2, bd1, bv[3:0]};
                        default: digits[11:0] <= {bd2, bd1, bv[3:0]};
                    endcase
                    bi  <= (bi == 3'd5) ? 3'd0 : bi + 3'd1;
                    bst <= 2'd0;
                end
            endcase
        end
    end

endmodule
