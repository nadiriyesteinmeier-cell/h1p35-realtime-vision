// yolo_decode.v - detection-head post-processing of the PH1P35 detector: sigmoid / exp decode, score threshold, candidate memory, class-wise greedy NMS
//
// Bit-exact model: tools/yolo/decode_ref.py (read its header for the arithmetic). Input: the two head tensors in bank D of yolo_net_engine (int8, channel =
// anchor * (5 + 3) + k, k = tx ty tw th obj c0 c1 c2, every channel of real scale 1/16; H1 from address 0, H2 right behind it); the module reads them linearly through a
// synchronous read port (rd_addr registered, rd_data valid two clocks later), anchor by anchor. NCLS = 3 (red / green / blue labels, provisional).
//
// Per anchor: 8 reads, 4 table lookups (obj, three classes) and one product obj * best class; candidates (score >= THR) get the box computed and are stored in a
// 32-slot memory (full: the first lowest score is replaced if the new score is strictly larger). After the last anchor, up to KOUT boxes are selected: highest score
// first (first slot wins ties), each selected box suppresses the remaining boxes of its class whose IoU exceeds IOU_Q6 / 64 (inter * 64 > IOU_Q6 * union, no division).
// Results: res_n boxes, read through res_idx / res_data (1-clock synchronous read): {cls[59:58], score[57:42], x0[41:31], y0[30:21], x1[20:10], y1[9:0]} in frame pixels.
// Timing: about 15 clocks per anchor + 35 per candidate + (KOUT * 32 * 3 + suppression 11 per same-class box) clocks - a few thousand clocks in all (< 100 us at 100 MHz).
// One shared 18 x 18 multiplier does every variable product; the constant products are shift-add networks; strides must be powers of two (16, 32).
// Reset: control flags only; data registers are loaded before they are used.

module yolo_decode #(
    parameter integer W1 = 4,
    parameter integer H1 = 3,
    parameter integer W2 = 8,
    parameter integer H2 = 6,
    parameter integer SH1 = 5,                 // log2 of the stride of head 1 (32)
    parameter integer SH2 = 4,                 // log2 of the stride of head 2 (16)
    parameter integer PAD_TOP = 12,            // letterbox rows above the image in the network input
    parameter integer KSC = 10,                // frame pixels per network pixel
    parameter integer FW = 1280,
    parameter integer FH = 720,
    parameter integer THR = 26214,             // score threshold, Q16 (0.4)
    parameter integer IOU_Q6 = 29,             // NMS overlap threshold in 1/64 (29 / 64 = 0.453)
    parameter integer KOUT = 8
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire [47:0]   anc1,                 // anchors of head 1 / head 2 (model data, from yolo_model_cfg): anchor a = width [16a +: 8], height [16a + 8 +: 8], network pixels
    input  wire [47:0]   anc2,
    input  wire          start,
    output wire          busy,
    output reg           done,

    output reg  [19:0]   rd_addr,
    input  wire [7:0]    rd_data,

    input  wire [3:0]    res_idx,
    output reg  [59:0]   res_data,
    output reg  [3:0]    res_n
);

    localparam integer NCH = 8;                // 5 + NCLS

    localparam [4:0] D_IDLE = 5'd0,  D_SCAN = 5'd1,  D_EVAL = 5'd2,  D_STORE = 5'd3, D_MINA = 5'd4, D_MINB = 5'd5, D_MINC = 5'd6, D_NEXT = 5'd7,
                     D_SELA = 5'd8,  D_SELB = 5'd9,  D_SELC = 5'd10, D_OUT = 5'd11,  D_SUPA = 5'd12, D_SUPB = 5'd13, D_SUPC = 5'd14, D_IOU = 5'd15,
                     D_FIN  = 5'd16;

    reg [4:0] st;
    assign busy = (st != D_IDLE);

    // ------------------------------------------------------------------ tables (synchronous read, address = q + 128)
    reg  [7:0]  sig_a, exp_a;
    wire [15:0] sig_d, exp_d;
    yolo_sig_rom u_sig (.clk(clk), .addr(sig_a), .data(sig_d));
    yolo_exp_rom u_exp (.clk(clk), .addr(exp_a), .data(exp_d));

    // ------------------------------------------------------------------ candidate memory and result memory
    reg [59:0] slot_mem [0:31];
    reg [4:0]  slot_ra, slot_wa;
    reg        slot_we;
    reg [59:0] slot_wd, slot_q;
    always @(posedge clk) begin
        if (slot_we) slot_mem[slot_wa] <= slot_wd;
        slot_q <= slot_mem[slot_ra];
    end
    reg [59:0] res_mem [0:7];
    reg        res_we;
    reg [2:0]  res_wa;
    reg [59:0] res_wd;
    always @(posedge clk) begin
        if (res_we) res_mem[res_wa] <= res_wd;
        res_data <= res_mem[res_idx[2:0]];
    end

    // ------------------------------------------------------------------ shared multiplier and constant multipliers
    reg signed [17:0] mul_a, mul_b;
    reg signed [35:0] mul_p;
    always @(posedge clk) mul_p <= mul_a * mul_b;

    function signed [31:0] kmul;               // x * KSC as a shift-add network
        input signed [31:0] x;
        integer b;
        begin
            kmul = 32'sd0;
            for (b = 0; b < 8; b = b + 1) if ((KSC >> b) & 1) kmul = kmul + (x <<< b);
        end
    endfunction
    function signed [31:0] imul;               // x * IOU_Q6
        input signed [31:0] x;
        integer b;
        begin
            imul = 32'sd0;
            for (b = 0; b < 7; b = b + 1) if ((IOU_Q6 >> b) & 1) imul = imul + (x <<< b);
        end
    endfunction
    function signed [11:0] clipx;
        input signed [31:0] v;
        begin clipx = (v < 0) ? 12'sd0 : ((v > FW - 1) ? (FW - 1) : v[11:0]); end
    endfunction
    function signed [11:0] clipy;
        input signed [31:0] v;
        begin clipy = (v < 0) ? 12'sd0 : ((v > FH - 1) ? (FH - 1) : v[11:0]); end
    endfunction

    // ------------------------------------------------------------------ scan counters
    reg        hi;
    reg [3:0]  cy, cx;
    reg [1:0]  ca;
    reg [3:0]  k;
    reg [19:0] ra;
    reg [7:0]  vb [0:7];
    wire [3:0] wmax = hi ? (W2 - 1) : (W1 - 1);
    wire [3:0] hmax = hi ? (H2 - 1) : (H1 - 1);
    wire is_last_anchor = hi && (cx == wmax) && (cy == hmax) && (ca == 2'd2);
    wire [47:0] anc = hi ? anc2 : anc1;
    wire [7:0]  aw  = (ca == 2'd0) ? anc[7:0]  : ((ca == 2'd1) ? anc[23:16] : anc[39:32]);
    wire [7:0]  ah  = (ca == 2'd0) ? anc[15:8] : ((ca == 2'd1) ? anc[31:24] : anc[47:40]);

    // ------------------------------------------------------------------ evaluation registers
    reg [5:0]  t;
    reg [15:0] obj_s, best_s, score_r, sx_r, sy_r, ew_r, eh_r;
    reg [1:0]  cls_r;
    reg signed [31:0] cxq, cyq, bwq, bhq, x0q, x1q, y0q, y1q;
    reg [59:0] cand;
    reg signed [11:0] x0f, y0f, x1f, y1f;
    reg [5:0]  cnt;
    reg [4:0]  mi;
    reg [15:0] msc;
    reg        have;
    reg [5:0]  j;

    // NMS
    reg [31:0] alive;
    reg [59:0] best_rec, sel;
    reg        found;
    reg [4:0]  bi;
    reg [3:0]  n_out;
    reg [3:0]  ip;
    reg signed [12:0] ixr, iyr;
    reg signed [31:0] inter, aa, bb, uni, lhs, rhs;

    wire [15:0] q_score = slot_q[57:42];
    wire        sup_last = (j + 6'd1 >= cnt);
    wire [1:0]  q_cls   = slot_q[59:58];
    wire [10:0] q_x0 = slot_q[41:31], q_x1 = slot_q[20:10];
    wire [9:0]  q_y0 = slot_q[30:21], q_y1 = slot_q[9:0];
    wire [10:0] s_x0 = sel[41:31], s_x1 = sel[20:10];
    wire [9:0]  s_y0 = sel[30:21], s_y1 = sel[9:0];
    wire [1:0]  s_cls = sel[59:58];
    wire        sel_upd = alive[j[4:0]] && (!found || q_score > best_rec[57:42]);

    // ------------------------------------------------------------------ control (reset)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= D_IDLE; done <= 1'b0;
        end
        else begin
            done <= 1'b0;
            case (st)
                D_IDLE: if (start) st <= D_SCAN;
                D_SCAN: if (k == NCH + 1) st <= D_EVAL;
                D_EVAL: begin
                    if (t == 6'd9 && score_r < THR) st <= D_NEXT;
                    else if (t == 6'd21) st <= D_STORE;
                end
                D_STORE: st <= (cnt < 6'd32) ? D_NEXT : D_MINA;
                D_MINA:  st <= D_MINB;
                D_MINB:  st <= D_MINC;
                D_MINC:  st <= (j == 6'd31) ? D_NEXT : D_MINA;
                D_NEXT:  st <= is_last_anchor ? D_SELA : D_SCAN;
                D_SELA:  st <= D_SELB;
                D_SELB:  st <= D_SELC;
                D_SELC:  st <= (j + 6'd1 >= cnt) ? ((found || sel_upd) ? D_OUT : D_FIN) : D_SELA;
                D_OUT:   st <= (n_out == KOUT - 1) ? D_FIN : D_SUPA;
                D_SUPA:  st <= D_SUPB;
                D_SUPB:  st <= D_SUPC;
                D_SUPC:  st <= (alive[j[4:0]] && (q_cls == s_cls)) ? D_IOU : (sup_last ? D_SELA : D_SUPA);
                D_IOU:   if (ip == 4'd8) st <= sup_last ? D_SELA : D_SUPA;
                default: begin
                    st <= D_IDLE; done <= 1'b1;
                end
            endcase
        end
    end

    // ------------------------------------------------------------------ data path (no reset)
    always @(posedge clk) begin
        slot_we <= 1'b0;
        res_we  <= 1'b0;
        case (st)
            D_IDLE: begin
                hi <= 1'b0; cy <= 4'd0; cx <= 4'd0; ca <= 2'd0; k <= 4'd0; ra <= 20'd0; cnt <= 6'd0;
                n_out <= 4'd0;
                if (start) res_n <= 4'd0;                 // the result stays valid after done until the next start
            end
            D_SCAN: begin
                if (k < NCH) begin rd_addr <= ra; ra <= ra + 20'd1; end
                if (k >= 4'd2) vb[k - 4'd2] <= rd_data;
                k <= k + 4'd1;
                t <= 6'd0;
            end
            D_EVAL: begin
                t <= t + 6'd1;
                case (t)
                    6'd0:  sig_a <= {~vb[4][7], vb[4][6:0]};
                    6'd1:  sig_a <= {~vb[5][7], vb[5][6:0]};
                    6'd2:  begin sig_a <= {~vb[6][7], vb[6][6:0]}; obj_s <= sig_d; end
                    6'd3:  begin sig_a <= {~vb[7][7], vb[7][6:0]}; best_s <= sig_d; cls_r <= 2'd0; end
                    6'd4:  if (sig_d > best_s) begin best_s <= sig_d; cls_r <= 2'd1; end
                    6'd5:  if (sig_d > best_s) begin best_s <= sig_d; cls_r <= 2'd2; end
                    6'd6:  begin mul_a <= {2'b00, obj_s}; mul_b <= {2'b00, best_s}; end
                    6'd8:  score_r <= mul_p[31:16];
                    6'd9:  sig_a <= {~vb[0][7], vb[0][6:0]};
                    6'd10: sig_a <= {~vb[1][7], vb[1][6:0]};
                    6'd11: begin exp_a <= {~vb[2][7], vb[2][6:0]}; sx_r <= sig_d; end
                    6'd12: begin exp_a <= {~vb[3][7], vb[3][6:0]}; sy_r <= sig_d; end
                    6'd13: ew_r <= exp_d;
                    6'd14: begin eh_r <= exp_d; mul_a <= {10'd0, aw}; mul_b <= {2'b00, ew_r}; end
                    6'd15: begin mul_a <= {10'd0, ah}; mul_b <= {2'b00, eh_r}; end
                    6'd16: bwq <= mul_p[31:0] >>> 4;
                    6'd17: bhq <= mul_p[31:0] >>> 4;
                    6'd18: begin
                        cxq <= (((({16'd0, cx} << 16) + {16'd0, sx_r}) << (hi ? SH2 : SH1)) >> 12);
                        cyq <= (((({16'd0, cy} << 16) + {16'd0, sy_r}) << (hi ? SH2 : SH1)) >> 12) - PAD_TOP * 16;
                    end
                    6'd19: begin
                        x0q <= cxq - (bwq >>> 1); x1q <= cxq + (bwq >>> 1);
                        y0q <= cyq - (bhq >>> 1); y1q <= cyq + (bhq >>> 1);
                    end
                    6'd20: begin
                        x0f <= clipx(kmul(x0q) >>> 4); y0f <= clipy(kmul(y0q) >>> 4); x1f <= clipx(kmul(x1q) >>> 4); y1f <= clipy(kmul(y1q) >>> 4);
                    end
                    6'd21: cand <= {cls_r, score_r, x0f[10:0], y0f[9:0], x1f[10:0], y1f[9:0]};
                    default: ;
                endcase
            end
            D_STORE: begin
                if (cnt < 6'd32) begin
                    slot_we <= 1'b1; slot_wa <= cnt[4:0]; slot_wd <= cand; cnt <= cnt + 6'd1;
                end
                j <= 6'd0; have <= 1'b0;
            end
            D_MINA: slot_ra <= j[4:0];
            D_MINB: ;
            D_MINC: begin
                if (!have || q_score < msc) begin msc <= q_score; mi <= j[4:0]; have <= 1'b1; end
                if (j == 6'd31) begin
                    // (the decision uses the values after this clock: see D_NEXT)
                end
                j <= j + 6'd1;
            end
            D_NEXT: begin
                if (have && (cand[57:42] > msc)) begin slot_we <= 1'b1; slot_wa <= mi; slot_wd <= cand; end
                have <= 1'b0;
                k <= 4'd0;
                if (ca != 2'd2) ca <= ca + 2'd1;
                else begin
                    ca <= 2'd0;
                    if (cx != wmax) cx <= cx + 4'd1;
                    else begin
                        cx <= 4'd0;
                        if (cy != hmax) cy <= cy + 4'd1;
                        else begin
                            cy <= 4'd0;
                            hi <= 1'b1;
                        end
                    end
                end
                alive <= (cnt >= 6'd32) ? 32'hFFFFFFFF : ((32'd1 << cnt) - 32'd1);
                j <= 6'd0; found <= 1'b0; n_out <= 4'd0;
            end
            D_SELA: slot_ra <= j[4:0];
            D_SELB: ;
            D_SELC: begin
                if (sel_upd) begin best_rec <= slot_q; found <= 1'b1; bi <= j[4:0]; end
                j <= j + 6'd1;
            end
            D_OUT: begin
                res_we <= 1'b1; res_wa <= n_out[2:0]; res_wd <= best_rec; n_out <= n_out + 4'd1; res_n <= n_out + 4'd1;
                alive[bi] <= 1'b0; sel <= best_rec;
                j <= 6'd0;
            end
            D_SUPA: slot_ra <= j[4:0];
            D_SUPB: ;
            D_SUPC: begin
                ip <= 4'd0;
                if (!(alive[j[4:0]] && (q_cls == s_cls))) begin
                    if (sup_last) begin j <= 6'd0; found <= 1'b0; end
                    else j <= j + 6'd1;
                end
            end
            D_IOU: begin
                ip <= ip + 4'd1;
                case (ip)
                    4'd0: begin
                        ixr <= $signed({2'b00, (s_x1 < q_x1) ? s_x1 : q_x1}) - $signed({2'b00, (s_x0 > q_x0) ? s_x0 : q_x0});
                        iyr <= $signed({3'b000, (s_y1 < q_y1) ? s_y1 : q_y1}) - $signed({3'b000, (s_y0 > q_y0) ? s_y0 : q_y0});
                    end
                    4'd1: begin mul_a <= (ixr < 0) ? 18'sd0 : ixr; mul_b <= (iyr < 0) ? 18'sd0 : iyr; end
                    4'd2: begin mul_a <= {7'd0, s_x1} - {7'd0, s_x0}; mul_b <= {8'd0, s_y1} - {8'd0, s_y0}; end
                    4'd3: begin inter <= mul_p[31:0]; mul_a <= {7'd0, q_x1} - {7'd0, q_x0}; mul_b <= {8'd0, q_y1} - {8'd0, q_y0}; end
                    4'd4: aa <= mul_p[31:0];
                    4'd5: bb <= mul_p[31:0];
                    4'd6: uni <= aa + bb - inter;
                    4'd7: begin lhs <= inter <<< 6; rhs <= imul(uni); end
                    4'd8: begin
                        if (lhs > rhs) alive[j[4:0]] <= 1'b0;
                        if (sup_last) begin j <= 6'd0; found <= 1'b0; end
                        else j <= j + 6'd1;
                    end
                    default: ;
                endcase
            end
            default: ;
        endcase
    end

endmodule
