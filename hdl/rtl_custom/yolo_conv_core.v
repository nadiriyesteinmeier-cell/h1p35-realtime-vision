// yolo_conv_core.v - INT8 convolution operator of the PH1P35 detector (stride 1, 'same' padding, 3x3 or 1x1), LANES output channels in parallel
//
// Numerics (bit-exact with tools/yolo/qref.py, see there for the formulas): int8 x int8 products, 32-bit accumulators, bias add (int32),
// per-output-channel requantisation  y = (v * M + 2^(S-1)) >>> S  (M uint16, S 0..47, 48-bit intermediate, arithmetic shift = floor),
// saturation to int8, optional leaky ReLU z >= 0 ? z : (13 z + 64) >>> 7.
//
// Dataflow: for every tile of LANES output channels, for every output pixel (row by row), for every tap (ky, kx, ci with ci innermost) ONE int8
// activation is read from the activation memory and broadcast to all lanes, ONE word of LANES int8 weights (lane j = output channel tile*LANES + j)
// is read from the weight memory, and every lane does one multiply-accumulate. After T = cin * k * k taps the LANES accumulators are copied to a shadow
// register and the "finalize" unit turns them into LANES output bytes, one byte per clock (single shared requantiser), while the next pixel is already
// accumulating. A pixel therefore costs max(T, LANES + 1) clocks; all lanes work every clock when T >= LANES + 1.
//
// Optional fused 2x2 max-pool (cfg_pool = 1, parameter POOL = 1, h and w even): the output of every pixel is merged into the POOLED map with max():
// the first of the four pixels of a 2x2 window writes its byte, the other three read the byte back (out_rd_addr / out_rd_data, 1-clock synchronous
// read of the output memory), take the signed maximum and write it again. The stored map is (h/2) x (w/2): conv + pool cost no extra pass and the
// large pre-pool map is never stored. The window of one output element is touched at least LANES + 1 clocks apart, so the read-modify-write never races.
//
// Memory interfaces (all synchronous read with ONE clock latency, i.e. the data of an address presented in clock n is valid in clock n+1):
//   act_addr / act_data   int8 activations, HWC layout, 3x3 inputs stored with a one-pixel zero border (the border is part of the image in memory)
//   wt_addr / wt_data     tile-major weight words (qref.pack_weights): tile * T + (ky * k + kx) * cin + ci;  lane j in bits [8j+7:8j]
//   pm_addr / pm_data     per output channel (address = channel index) 54 bits  {bias[31:0], M[15:0], S[5:0]}  in bits [53:0]
//   out_we / out_addr / out_data   one int8 per write, 1 byte per clock at most
// Address arithmetic is done by incremental additions (no multipliers):
//   input element of (output pixel (y, x), tap (ky, kx), channel ci) = cfg_in_base + y * cfg_in_row + x * cfg_in_pix + ky * cfg_in_row + kx * cfg_in_pix + ci
//     (for a zero-padded 3x3 input map: cfg_in_base = element (0, 0, 0) of the PADDED map, cfg_in_row = (W + 2) * cin, cfg_in_pix = cin)
//   output element = cfg_out_base + y * cfg_out_row + x * cfg_out_pix + output channel
// The configuration inputs must be stable from start until done. Channels >= cfg_cout of the last tile are computed but not written.
// Limits: cin, cout <= 1024 (11-bit fields), h, w <= 4095, tile weight words T <= 2^WW.
// Timing: first tap issued 1 clock after start; total clocks ~ ntiles * h * w * max(T, LANES + 1) + LANES + 16; done = 2 clocks after the last write.
// Reset: active-low asynchronous.

module yolo_conv_core #(
    parameter integer LANES = 16,
    parameter integer AW    = 20,
    parameter integer WW    = 14,
    parameter integer PW    = 11,
    parameter integer POOL  = 1             // 1 = include the fused max-pool path (read port of the output memory)
)(
    input  wire                clk,
    input  wire                rst_n,

    input  wire [11:0]         cfg_h,
    input  wire [11:0]         cfg_w,
    input  wire [10:0]         cfg_cin,
    input  wire [10:0]         cfg_cout,
    input  wire                cfg_k3,
    input  wire                cfg_act,
    input  wire                cfg_pool,
    input  wire [AW-1:0]       cfg_in_base,
    input  wire [AW-1:0]       cfg_in_row,
    input  wire [AW-1:0]       cfg_in_pix,
    input  wire [AW-1:0]       cfg_out_base,
    input  wire [AW-1:0]       cfg_out_row,
    input  wire [AW-1:0]       cfg_out_pix,

    input  wire                start,
    output wire                busy,
    output reg                 done,

    output wire [AW-1:0]       act_addr,
    input  wire [7:0]          act_data,
    output wire [WW-1:0]       wt_addr,
    input  wire [8*LANES-1:0]  wt_data,
    output wire [PW-1:0]       pm_addr,
    input  wire [55:0]         pm_data,

    output reg                 out_we,
    output reg  [AW-1:0]       out_addr,
    output reg  [7:0]          out_data,

    output wire [AW-1:0]       out_rd_addr,      // only used when cfg_pool = 1
    input  wire [7:0]          out_rd_data
);

    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_RUN  = 2'd1;
    localparam [1:0] S_DRN  = 2'd2;

    reg [1:0] state;
    assign busy = (state != S_IDLE);
    wire pipe_busy;                                  // any stage of the datapath or of the finalize unit still holds data

    // ------------------------------------------------------------------ derived configuration
    wire [1:0]  kmax = cfg_k3 ? 2'd2 : 2'd0;
    wire [WW-1:0] taps = cfg_k3 ? ({3'd0, cfg_cin} + {3'd0, cfg_cin, 3'd0}) : {3'd0, cfg_cin};   // T = cin * 9 or cin (WW >= 14)
    wire [10:0] ntiles_m1 = (cfg_cout + LANES - 1) / LANES - 11'd1;                              // elaborated as a constant divider for power-of-two LANES

    // ------------------------------------------------------------------ issue (address generation)
    reg  [10:0]   ci;
    reg  [1:0]    kx, ky;
    reg  [11:0]   px, py;
    reg  [10:0]   tile;
    reg  [AW-1:0] a_cur, a_kx, a_ky, a_pix, a_row;
    reg  [AW-1:0] o_pix, o_row;
    reg  [WW-1:0] wt_i, wt_base;
    reg  [PW:0]   oc_base;
    reg  [7:0]    gap;
    reg           all_issued;

    wire ci_last  = (ci == cfg_cin - 11'd1);
    wire kx_last  = (kx == kmax);
    wire ky_last  = (ky == kmax);
    wire tap_last = ci_last && kx_last && ky_last;
    wire px_last  = (px == cfg_w - 12'd1);
    wire py_last  = (py == cfg_h - 12'd1);
    wire tile_last = (tile == ntiles_m1);
    wire first_tap = (ci == 11'd0) && (kx == 2'd0) && (ky == 2'd0);
    wire issue = (state == S_RUN) && !all_issued && (gap == 8'd0);

    assign act_addr = a_cur;
    assign wt_addr  = wt_base + wt_i;

    // gap after the last tap so that two pixels start at least LANES + 1 clocks apart: the finalize unit reads the shadow register in the clocks
    // 5 .. 4 + LANES after the last tap and the next pixel overwrites it at the end of clock 3 + (distance of the last taps)
    localparam integer PERIOD_MIN = LANES + 1;
    wire [WW-1:0] lanes_w = PERIOD_MIN;
    wire short_vec = (taps < lanes_w);
    wire [WW-1:0] gap_len = lanes_w - taps;

    reg           iss_q;                       // a tap was issued in the previous clock
    reg           iss_first, iss_last, iss_pf;  // iss_pf: this pixel is the first of its pooling window (always 1 without pooling)
    reg [AW-1:0]  iss_opix;
    reg [PW:0]    iss_ocbase;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; ci <= 11'd0; kx <= 2'd0; ky <= 2'd0; px <= 12'd0; py <= 12'd0; tile <= 11'd0;
            a_cur <= {AW{1'b0}}; a_kx <= {AW{1'b0}}; a_ky <= {AW{1'b0}}; a_pix <= {AW{1'b0}}; a_row <= {AW{1'b0}};
            o_pix <= {AW{1'b0}}; o_row <= {AW{1'b0}}; wt_i <= {WW{1'b0}}; wt_base <= {WW{1'b0}}; oc_base <= {(PW+1){1'b0}};
            gap <= 8'd0; all_issued <= 1'b0; iss_q <= 1'b0; iss_first <= 1'b0; iss_last <= 1'b0; iss_pf <= 1'b1; iss_opix <= {AW{1'b0}}; iss_ocbase <= {(PW+1){1'b0}};
        end
        else begin
            iss_q <= 1'b0;
            case (state)
                S_IDLE: begin
                    all_issued <= 1'b0;
                    if (start) begin
                        state <= S_RUN;
                        ci <= 11'd0; kx <= 2'd0; ky <= 2'd0; px <= 12'd0; py <= 12'd0; tile <= 11'd0;
                        a_cur <= cfg_in_base; a_kx <= cfg_in_base; a_ky <= cfg_in_base; a_pix <= cfg_in_base; a_row <= cfg_in_base;
                        o_pix <= cfg_out_base; o_row <= cfg_out_base; wt_i <= {WW{1'b0}}; wt_base <= {WW{1'b0}}; oc_base <= {(PW+1){1'b0}};
                        gap <= 8'd0;
                    end
                end
                S_RUN: begin
                    if (gap != 8'd0) gap <= gap - 8'd1;
                    if (issue) begin
                        iss_q     <= 1'b1;
                        iss_first <= first_tap;
                        iss_last  <= tap_last;
                        iss_pf    <= !cfg_pool || (!px[0] && !py[0]);
                        iss_opix  <= o_pix;
                        iss_ocbase <= oc_base;
                        if (!tap_last) begin
                            wt_i <= wt_i + 1'b1;
                            if (!ci_last) begin
                                ci <= ci + 11'd1; a_cur <= a_cur + 1'b1;
                            end
                            else begin
                                ci <= 11'd0;
                                if (!kx_last) begin
                                    kx <= kx + 2'd1; a_kx <= a_kx + cfg_in_pix; a_cur <= a_kx + cfg_in_pix;
                                end
                                else begin
                                    kx <= 2'd0; ky <= ky + 2'd1;
                                    a_ky <= a_ky + cfg_in_row; a_kx <= a_ky + cfg_in_row; a_cur <= a_ky + cfg_in_row;
                                end
                            end
                        end
                        else begin
                            // last tap of this pixel: move to the next pixel / row / tile
                            ci <= 11'd0; kx <= 2'd0; ky <= 2'd0; wt_i <= {WW{1'b0}};
                            if (short_vec) gap <= gap_len[7:0];
                            if (!px_last) begin
                                px <= px + 12'd1;
                                a_pix <= a_pix + cfg_in_pix; a_cur <= a_pix + cfg_in_pix; a_kx <= a_pix + cfg_in_pix; a_ky <= a_pix + cfg_in_pix;
                                if (!(cfg_pool && !px[0])) o_pix <= o_pix + cfg_out_pix;      // pooled x advances when leaving an odd column
                            end
                            else begin
                                px <= 12'd0;
                                if (!py_last) begin
                                    py <= py + 12'd1;
                                    a_row <= a_row + cfg_in_row; a_pix <= a_row + cfg_in_row; a_cur <= a_row + cfg_in_row;
                                    a_kx <= a_row + cfg_in_row; a_ky <= a_row + cfg_in_row;
                                    if (cfg_pool && !py[0]) o_pix <= o_row;                       // even -> odd row: same pooled row
                                    else begin o_row <= o_row + cfg_out_row; o_pix <= o_row + cfg_out_row; end
                                end
                                else begin
                                    py <= 12'd0;
                                    if (!tile_last) begin
                                        tile <= tile + 11'd1;
                                        wt_base <= wt_base + taps;
                                        oc_base <= oc_base + LANES;
                                        a_row <= cfg_in_base; a_pix <= cfg_in_base; a_cur <= cfg_in_base; a_kx <= cfg_in_base; a_ky <= cfg_in_base;
                                        o_row <= cfg_out_base; o_pix <= cfg_out_base;
                                    end
                                    else all_issued <= 1'b1;
                                end
                            end
                        end
                    end
                    if (all_issued) state <= S_DRN;
                end
                default: begin                                  // S_DRN: wait until the pipeline and the finalize unit are empty
                    if (!pipe_busy) begin
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end

    // ------------------------------------------------------------------ pipeline: memory data -> product -> accumulate -> shadow
    reg           v1, f1, l1, pf1, pf2;               // stage 1: memory data valid
    reg  [AW-1:0] o1;  reg [PW:0] c1;
    reg  signed [7:0] a_q;
    reg  [8*LANES-1:0] w_q;
    reg           v2, f2, l2;                         // stage 2: products
    reg  [AW-1:0] o2;  reg [PW:0] c2;
    reg  signed [15:0] p [0:LANES-1];
    reg           v3, f3, l3;                         // stage 3: accumulate
    reg  [AW-1:0] o3;  reg [PW:0] c3;
    reg  signed [31:0] acc [0:LANES-1];
    reg  signed [31:0] res [0:LANES-1];
    reg           fin_go;                             // pulse: res holds a finished pixel
    reg  [AW-1:0] fin_opix;
    reg  [PW:0]   fin_ocbase;
    reg           fin_pf;

    integer j;
    // Only the valid flags and the finalize trigger are reset. Every data register of the pipeline is written before the flag that gates it can
    // become 1, so the reset net stays small (with the reset on all ~2000 product / accumulator / pipeline flops TD routed one 700-way reset net in 9 ns).
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0; fin_go <= 1'b0;
        end
        else begin
            v1 <= iss_q;
            v2 <= v1;
            v3 <= v2;
            fin_go <= v2 && l2;                       // the last tap of a pixel has been accumulated: res holds a finished pixel
        end
    end

    always @(posedge clk) begin
        // stage 1: the memories delivered the data of the tap issued one clock ago
        f1 <= iss_first; l1 <= iss_last; o1 <= iss_opix; c1 <= iss_ocbase; pf1 <= iss_pf;
        a_q <= act_data;
        w_q <= wt_data;
        // stage 2: multiply
        f2 <= f1; l2 <= l1; o2 <= o1; c2 <= c1; pf2 <= pf1;
        for (j = 0; j < LANES; j = j + 1) p[j] <= a_q * $signed(w_q[8*j +: 8]);
        // stage 3: accumulate; the last tap also fills the shadow register
        f3 <= f2; l3 <= l2; o3 <= o2; c3 <= c2;
        if (v2) begin
            for (j = 0; j < LANES; j = j + 1) begin
                acc[j] <= f2 ? {{16{p[j][15]}}, p[j]} : (acc[j] + {{16{p[j][15]}}, p[j]});
                if (l2) res[j] <= f2 ? {{16{p[j][15]}}, p[j]} : (acc[j] + {{16{p[j][15]}}, p[j]});
            end
            if (l2) begin
                fin_opix   <= o2;
                fin_ocbase <= c2;
                fin_pf     <= pf2;
            end
        end
    end

    // ------------------------------------------------------------------ finalize: one lane per clock through bias / requant / saturate / leaky
    reg [7:0]     fidx;
    reg           f_act;                              // F0: lane fidx is being fetched
    reg [AW-1:0]  f_opix;
    reg [PW:0]    f_ocb;
    reg           f_pf;
    wire [PW:0] oc_now = f_ocb + {{(PW-7){1'b0}}, fidx};
    assign pm_addr = oc_now[PW-1:0];
    wire        wr_ok_now = (oc_now < {1'b0, cfg_cout});

    reg           s1_v;  reg signed [31:0] s1_r;  reg [AW-1:0] s1_a;  reg s1_wr;  reg s1_pf;
    reg           s2_v;  reg signed [31:0] s2_v32; reg [15:0] s2_m;  reg [5:0] s2_s;  reg [AW-1:0] s2_a;  reg s2_wr;  reg s2_pf;
    reg           s3_v;  reg signed [47:0] s3_p;   reg [5:0] s3_s;   reg [AW-1:0] s3_a;  reg s3_wr;  reg s3_pf;
    reg           s4_v;  reg signed [47:0] s4_p;   reg [5:0] s4_s;   reg [AW-1:0] s4_a;  reg s4_wr;  reg s4_pf;
    reg           s5_v;  reg signed [47:0] s5_p;   reg [AW-1:0] s5_a;  reg s5_wr;  reg s5_pf;
    reg           s6_v;  reg signed [7:0]  s6_z;   reg [AW-1:0] s6_a;  reg s6_wr;  reg s6_pf;
    reg           s7_v;  reg signed [7:0]  s7_z;   reg [AW-1:0] s7_a;  reg s7_wr;  reg s7_pf;       // activation applied, merge address presented
    reg           s8_v;  reg signed [7:0]  s8_z;   reg [AW-1:0] s8_a;  reg s8_wr;  reg s8_pf;       // out_rd_data valid
    wire signed [7:0] out_rd_data_s = out_rd_data;

    wire [4:0]         ridx = (fidx < LANES) ? fidx[4:0] : 5'd0;
    wire signed [31:0] r_sel = res[ridx];
    wire signed [31:0] bias_w = pm_data[53:22];
    wire [15:0]        mult_w = pm_data[21:6];
    wire [5:0]         shift_w = pm_data[5:0];
    wire signed [47:0] rnd48 = (s3_s == 6'd0) ? 48'sd0 : (48'sd1 <<< (s3_s - 6'd1));
    wire signed [47:0] sh48 = s4_p >>> s4_s;
    wire signed [7:0]  z_c = (s5_p > 48'sd127) ? 8'sd127 : ((s5_p < -48'sd128) ? -8'sd128 : s5_p[7:0]);
    wire signed [15:0] z13 = {{8{s6_z[7]}}, s6_z} * 16'sd13 + 16'sd64;
    wire signed [7:0]  leaky_v = (s6_z >= 0) ? s6_z : z13[14:7];

    // control: lane counter and the valid flag of every stage (the only reset flops of the finalize unit)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fidx <= 8'd0; f_act <= 1'b0;
            s1_v <= 1'b0; s2_v <= 1'b0; s3_v <= 1'b0; s4_v <= 1'b0; s5_v <= 1'b0; s6_v <= 1'b0; s7_v <= 1'b0; s8_v <= 1'b0;
            out_we <= 1'b0;
        end
        else begin
            if (fin_go) begin
                f_act <= 1'b1; fidx <= 8'd0;
            end
            else if (f_act) begin
                if (fidx == LANES - 1) f_act <= 1'b0;
                fidx <= fidx + 8'd1;
            end
            s1_v <= f_act;
            s2_v <= s1_v;
            s3_v <= s2_v;
            s4_v <= s3_v;
            s5_v <= s4_v;
            s6_v <= s5_v;
            s7_v <= s6_v;
            s8_v <= s7_v;
            out_we   <= s8_v && s8_wr;
        end
    end

    // data: written before the valid flag of its stage can be 1, no reset
    always @(posedge clk) begin
        if (fin_go) begin
            f_opix <= fin_opix; f_ocb <= fin_ocbase; f_pf <= fin_pf;
        end
        // F0 -> F1: select the lane, the parameter RAM is addressed with the same lane
        s1_r <= r_sel; s1_a <= f_opix + {{(AW-PW-1){1'b0}}, oc_now}; s1_wr <= wr_ok_now; s1_pf <= f_pf;
        // F1 -> F2: bias
        s2_v32 <= s1_r + bias_w; s2_m <= mult_w; s2_s <= shift_w; s2_a <= s1_a; s2_wr <= s1_wr; s2_pf <= s1_pf;
        // F2 -> F3: multiply (32 x 16 -> 48 bit)
        s3_p <= s2_v32 * $signed({1'b0, s2_m}); s3_s <= s2_s; s3_a <= s2_a; s3_wr <= s2_wr; s3_pf <= s2_pf;
        // F3 -> F4: rounding constant
        s4_p <= s3_p + rnd48; s4_s <= s3_s; s4_a <= s3_a; s4_wr <= s3_wr; s4_pf <= s3_pf;
        // F4 -> F5: shift
        s5_p <= sh48; s5_a <= s4_a; s5_wr <= s4_wr; s5_pf <= s4_pf;
        // F5 -> F6: saturate
        s6_z <= z_c; s6_a <= s5_a; s6_wr <= s5_wr; s6_pf <= s5_pf;
        // F6 -> F7: activation
        s7_z <= cfg_act ? leaky_v : s6_z; s7_a <= s6_a; s7_wr <= s6_wr; s7_pf <= s6_pf;
        // F7 -> F8: (pooling only) the old byte of the pooled cell is read while the new one waits
        s8_z <= s7_z; s8_a <= s7_a; s8_wr <= s7_wr; s8_pf <= s7_pf;
        // F8 -> write: merge with the old byte unless this pixel is the first of its window
        out_addr <= s8_a;
        out_data <= ((POOL != 0) && !s8_pf && (out_rd_data_s > s8_z)) ? out_rd_data_s : s8_z;
    end

    assign out_rd_addr = s7_a;
    assign pipe_busy = iss_q | v1 | v2 | v3 | fin_go | f_act | s1_v | s2_v | s3_v | s4_v | s5_v | s6_v | s7_v | s8_v | out_we;

    // done: one clock after the last write
    reg busy_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin busy_q <= 1'b0; done <= 1'b0; end
        else begin
            busy_q <= busy;
            done   <= busy_q && !busy;
        end
    end

endmodule
