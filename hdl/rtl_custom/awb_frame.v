// awb_frame.v - gray-world automatic white balance with FRAME-HELD gains (replacement for the vendor awb.v in the ISP chain)
//
// Why: the vendor module (contest_work_v3_color4/.../awb.v) computes its gains from the RUNNING sums of the frame (restarting at 1.0 on every
// frame start) with two fully pipelined 48-bit dividers (about 8,100 flip-flops, 43 % of the registers of the whole design) and a 320-word line
// delay RAM. The gain applied to a pixel therefore depends on its vertical position and on the scene above it, so a lens / sensor colour shading
// cannot be balanced out and the picture changes colour from the top to the bottom of the frame.
// What: the same gray-world rule, but evaluated once per frame:
//   * statistics: the first pixel of every 4-pixel beat (like the vendor module), only pixels with SUM_MIN <= R+G+B < SUM_MAX (vendor: < 720),
//     sums of R, G, B over the whole frame (32 bits, started at 1 so no sum is ever 0);
//   * at the end of the frame (the last beat of line IMG_HEIGHT-1; if a frame ends early, at the next frame start) one sequential divider
//     computes gain_r = G / R and gain_b = G / B in Q4.12 (4096 = 1.0), clamped to [GAIN_MIN, GAIN_MAX];
//   * the new gains are taken over at the first beat of the NEXT frame and held for the whole frame (one frame lag, no change inside a frame);
//   * pixels: R' = min(255, (gain_r * R) >> 12), G' and B' likewise (G gain 1.0 except in manual mode).
// Modes (I_mode, static, synchronized by the integrator; like the gains it takes effect at the first beat of a frame, never inside a frame):
//   0 automatic (gray world above, G gain 1.0)   1 off: unity gains, no white balance at all   2 / 3 manual: the gains I_man_r / I_man_g / I_man_b
//   (Q4.12, static, sampled at the first beat of the frame, any value 0..65535 is used as given).
// O_gain_r / O_gain_g / O_gain_b: the gains applied to the current frame (registered; they change once per frame, at its first beat) - read back by
// the white-balance page for its display and for the one-push capture of the automatic gains.
// Timing / interface (drop-in for awb.v): 96-bit beat = 4 pixels, pixel k = {R, G, B} at [24*k +: 24]. O_tuser is the INPUT tuser passed straight
// through (as in the vendor module: video_in resets its FIFO on the stretched frame start, so the first data beat has to come later), the data
// path is delayed by DELAY clocks (default 24 > the 8-clock stretch + synchronizer of video_in) through a small RAM, then 2 pipeline stages.
// Latency of data / valid / tlast: DELAY + 2 clocks. I_tready = O_tready. Reset: active-low asynchronous; gains start at 1.0.
// Area: 3 x 32 sum registers, one 44/32-bit sequential divider, 8 multipliers 16 x 8 for R / B (DSP), the 4 G products as shift-add logic (two 4-bit
// halves in the first stage, their sum in the second: no further DSP), one 32 x 99-bit RAM; no 50-stage dividers.

module awb_frame #(
    parameter integer IMG_HEIGHT = 720,
    parameter integer IMG_WIDTH  = 1280,
    parameter integer DELAY      = 24,
    parameter [9:0]   SUM_MAX    = 10'd720,
    parameter [9:0]   SUM_MIN    = 10'd0,
    parameter [15:0]  GAIN_MIN   = 16'd1024,
    parameter [15:0]  GAIN_MAX   = 16'd32768
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire [1:0]  I_mode,
    input  wire [15:0] I_man_r,
    input  wire [15:0] I_man_g,
    input  wire [15:0] I_man_b,
    output wire [15:0] O_gain_r,
    output wire [15:0] O_gain_g,
    output wire [15:0] O_gain_b,

    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    output wire        I_tready,

    output wire        O_tlast,
    output wire        O_tuser,
    output wire [95:0] O_tdata,
    output wire        O_tvalid,
    input  wire        O_tready
);

    assign I_tready = O_tready;
    assign O_tuser  = I_tuser;

    // ---------------------------------------------------------------- statistics (undelayed input)
    reg [31:0] sum_r, sum_g, sum_b;
    reg [15:0] lcnt;                          // lines finished in this frame
    reg        fe_seen;                       // the end of this frame has been processed
    reg        fe_q;                          // frame end, one clock later (the sums include the last beat)
    reg        part_q;                        // a frame started before the previous one ended: process the partial sums

    wire [7:0] p_r = I_tdata[23:16];
    wire [7:0] p_g = I_tdata[15:8];
    wire [7:0] p_b = I_tdata[7:0];
    wire [9:0] p_sum = {2'b00, p_r} + {2'b00, p_g} + {2'b00, p_b};
    wire       p_ok  = (p_sum < SUM_MAX) && (p_sum >= SUM_MIN);
    wire [31:0] a_r = p_ok ? {24'd0, p_r} : 32'd0;
    wire [31:0] a_g = p_ok ? {24'd0, p_g} : 32'd0;
    wire [31:0] a_b = p_ok ? {24'd0, p_b} : 32'd0;

    wire frame_end = I_tvalid && I_tlast && !I_tuser && (lcnt == IMG_HEIGHT - 1);

    reg [31:0] cap_r, cap_g, cap_b;
    reg        div_go;                        // start the two divisions with the captured sums

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            sum_r <= 32'd1; sum_g <= 32'd1; sum_b <= 32'd1; lcnt <= 16'd0; fe_seen <= 1'b1; fe_q <= 1'b0; part_q <= 1'b0;
            cap_r <= 32'd1; cap_g <= 32'd1; cap_b <= 32'd1; div_go <= 1'b0;
        end
        else begin
            fe_q   <= frame_end;
            part_q <= 1'b0;
            div_go <= 1'b0;
            if (I_tvalid && I_tuser) begin
                // a new frame: if the previous one never reached its last line, its partial sums are used now
                if (!fe_seen) part_q <= 1'b1;
                sum_r   <= 32'd1 + a_r;
                sum_g   <= 32'd1 + a_g;
                sum_b   <= 32'd1 + a_b;
                lcnt    <= I_tlast ? 16'd1 : 16'd0;
                fe_seen <= 1'b0;
                if (!fe_seen) begin cap_r <= sum_r; cap_g <= sum_g; cap_b <= sum_b; end
            end
            else if (I_tvalid) begin
                sum_r <= sum_r + a_r;
                sum_g <= sum_g + a_g;
                sum_b <= sum_b + a_b;
                if (I_tlast) lcnt <= lcnt + 16'd1;
            end
            if (fe_q) begin
                cap_r <= sum_r; cap_g <= sum_g; cap_b <= sum_b;
                fe_seen <= 1'b1;
                div_go <= 1'b1;
            end
            if (part_q) div_go <= 1'b1;
        end
    end

    // ---------------------------------------------------------------- two divisions, one after the other
    wire        d_busy, d_done;
    wire [43:0] d_quo;
    wire [31:0] d_rem;
    reg         d_start;
    reg  [43:0] d_num;
    reg  [31:0] d_den;
    reg  [1:0]  d_st;                         // 0 idle, 1 R running, 2 B running
    reg  [15:0] nx_r, nx_b;                   // gains for the next frame

    div_seq #(.NW(44), .WD(32)) u_div (
        .clk(I_clk), .rst_n(I_rst_n), .start(d_start), .num(d_num), .den(d_den),
        .busy(d_busy), .done(d_done), .quo(d_quo), .rem(d_rem)
    );

    function [15:0] clamp_gain;
        input [43:0] q;
        begin
            if (|q[43:16])           clamp_gain = GAIN_MAX;
            else if (q[15:0] > GAIN_MAX) clamp_gain = GAIN_MAX;
            else if (q[15:0] < GAIN_MIN) clamp_gain = GAIN_MIN;
            else                     clamp_gain = q[15:0];
        end
    endfunction

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            d_start <= 1'b0; d_num <= 44'd0; d_den <= 32'd1; d_st <= 2'd0; nx_r <= 16'd4096; nx_b <= 16'd4096;
        end
        else begin
            d_start <= 1'b0;
            case (d_st)
                2'd0: if (div_go) begin
                    d_num   <= {cap_g, 12'd0};
                    d_den   <= cap_r;
                    d_start <= 1'b1;
                    d_st    <= 2'd1;
                end
                2'd1: if (d_done) begin
                    nx_r    <= clamp_gain(d_quo);
                    d_num   <= {cap_g, 12'd0};
                    d_den   <= cap_b;
                    d_start <= 1'b1;
                    d_st    <= 2'd2;
                end
                default: if (d_done) begin
                    nx_b <= clamp_gain(d_quo);
                    d_st <= 2'd0;
                end
            endcase
        end
    end

    // ---------------------------------------------------------------- data path: delay RAM, multiply, saturate
    localparam integer AW = 5;                // 32 words, DELAY <= 30
    (* ram_style = "bram" *) reg [98:0] dmem [0:(1<<AW)-1];
    localparam [AW-1:0] DLY = DELAY;
    reg  [AW-1:0] wp;
    reg  [98:0]   rq;
    wire [AW-1:0] rp = wp - DLY + 1'b1;                    // read-first RAM: rq (visible after the edge) = the word written DELAY - 1 edges earlier
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) wp <= {AW{1'b0}};
        else          wp <= wp + 1'b1;
    end
    always @(posedge I_clk) begin
        dmem[wp] <= {I_tuser & I_tvalid, I_tlast, I_tvalid, I_tdata};
        rq       <= dmem[rp];
    end
    // the RAM content is undefined after power-up: the words read during the first 34 clocks are masked with mem_ok below
    reg [AW:0] init_cnt;
    reg        mem_ok;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin init_cnt <= {(AW+1){1'b0}}; mem_ok <= 1'b0; end
        else if (!mem_ok) begin
            init_cnt <= init_cnt + 1'b1;
            if (init_cnt == (1 << AW) + 2) mem_ok <= 1'b1;                        // the RAM has been overwritten once with real data
        end
    end

    wire        d_valid = rq[96] & mem_ok;
    wire        d_last  = rq[97] & mem_ok;
    wire        d_user  = rq[98] & mem_ok;
    wire [95:0] d_data  = rq[95:0];

    // gains of the next frame by mode; taken at the first beat (d_user) and held for the frame
    reg [15:0] g_r, g_g, g_b;
    wire        man  = I_mode[1];
    wire [15:0] nf_r = man ? I_man_r : (I_mode == 2'd1) ? 16'd4096 : nx_r;
    wire [15:0] nf_g = man ? I_man_g : 16'd4096;
    wire [15:0] nf_b = man ? I_man_b : (I_mode == 2'd1) ? 16'd4096 : nx_b;
    wire [15:0] gu_r = d_user ? nf_r : g_r;
    wire [15:0] gu_g = d_user ? nf_g : g_g;
    wire [15:0] gu_b = d_user ? nf_b : g_b;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin g_r <= 16'd4096; g_g <= 16'd4096; g_b <= 16'd4096; end
        else if (d_user && d_valid) begin g_r <= nf_r; g_g <= nf_g; g_b <= nf_b; end
    end
    assign O_gain_r = g_r;
    assign O_gain_g = g_g;
    assign O_gain_b = g_b;

    // gain x 4-bit nibble as shift-add (keeps the G products out of the DSP blocks)
    function [19:0] mul4;
        input [15:0] g;
        input [3:0]  n;
        begin
            mul4 = (n[0] ? {4'd0, g} : 20'd0) + (n[1] ? {3'd0, g, 1'b0} : 20'd0) +
                   (n[2] ? {2'd0, g, 2'b0} : 20'd0) + (n[3] ? {1'd0, g, 3'b0} : 20'd0);
        end
    endfunction

    reg [23:0] m_r [0:3];
    reg [23:0] m_b [0:3];
    reg [19:0] m_gl [0:3];                    // gain_g * G[3:0]
    reg [19:0] m_gh [0:3];                    // gain_g * G[7:4]
    reg        m_v, m_l;
    integer k;
    integer k2;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            m_v <= 1'b0; m_l <= 1'b0;
            for (k = 0; k < 4; k = k + 1) begin m_r[k] <= 24'd0; m_b[k] <= 24'd0; m_gl[k] <= 20'd0; m_gh[k] <= 20'd0; end
        end
        else begin
            m_v <= d_valid;
            m_l <= d_last;
            for (k = 0; k < 4; k = k + 1) begin
                m_r[k]  <= gu_r * d_data[24*k+16 +: 8];
                m_gl[k] <= mul4(gu_g, d_data[24*k+8 +: 4]);
                m_gh[k] <= mul4(gu_g, d_data[24*k+12 +: 4]);
                m_b[k]  <= gu_b * d_data[24*k +: 8];
            end
        end
    end

    function [7:0] sat12;
        input [23:0] p;
        begin
            sat12 = (|p[23:20]) ? 8'd255 : p[19:12];
        end
    endfunction

    reg [95:0] o_data;
    reg        o_v, o_l;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin o_data <= 96'd0; o_v <= 1'b0; o_l <= 1'b0; end
        else begin
            o_v <= m_v;
            o_l <= m_l;
            for (k2 = 0; k2 < 4; k2 = k2 + 1)
                o_data[24*k2 +: 24] <= m_v ? {sat12(m_r[k2]), sat12({4'd0, m_gl[k2]} + {m_gh[k2], 4'd0}), sat12(m_b[k2])} : 24'd0;
        end
    end

    assign O_tdata  = o_data;
    assign O_tvalid = o_v;
    assign O_tlast  = o_l;

endmodule
