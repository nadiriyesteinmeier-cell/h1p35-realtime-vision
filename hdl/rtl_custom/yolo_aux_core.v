// yolo_aux_core.v - the non-convolution operators of the PH1P35 detector: strided copy (route / concat), nearest-neighbour upsample x2, 2x2 max-pool
//
// One engine, four modes (cfg_mode), all on HWC int8 maps in a memory with a 1-clock synchronous read port and a write port (the same contract as
// yolo_conv_core.v; the maps are described by a base address and a row / pixel stride, the channel stride is 1):
//
//   0  copy        out(y, x, c) = in(y, x, c)                         concat = two copies into the channel ranges of one destination map
//   1  upsample    out(y, x, c) = in(y / 2, x / 2, c)                 nearest neighbour, the output map is twice as large as the source
//   2  pool s2     out(y, x, c) = max of in(2y .. 2y+1, 2x .. 2x+1, c)           the darknet 'maxpool size=2 stride=2' (source height / width even)
//   3  pool s1     out(y, x, c) = max of in(y .. y+1, x .. x+1, c), row / column H / W replicated (darknet 'size=2 stride=1')
//   4  fill        out(y, x, c) = 0                                   re-clears the one-pixel border of a padded map in a bank that was used by another
//                                                                     tensor before (two descriptors per map: rows 0 and H+1, columns 0 and W+1)
//
// cfg_h / cfg_w / cfg_c are the dimensions of the OUTPUT map. Element order: channel fastest, then x, then y. Copy / upsample: one element per
// clock; pool: four reads per element = four clocks per element (one read port). The engine never stalls: after start it issues a read every clock
// until the last element and then waits until the pipeline (read, collect, write) is empty; done is a 1-clock pulse after the last write.
//
// Pipeline (all registered): E0 counters -> rd_addr, meta0 | E1 the memory samples rd_addr, meta1 | E2 rd_data is collected (running max), out_we / out_addr / out_data
// registered | E3 the memory writes. Latency of one element 3 clocks.
//
// Reset: only the control flags (state, all_issued, valid bits, out_we, done); counters / pointers are loaded by start, the data registers are written before
// their valid flag can be 1 (keeps the reset net small, see yolo_conv_core.v).

module yolo_aux_core #(
    parameter integer AW = 20
)(
    input  wire          clk,
    input  wire          rst_n,

    input  wire [11:0]   cfg_h,
    input  wire [11:0]   cfg_w,
    input  wire [10:0]   cfg_c,
    input  wire [2:0]    cfg_mode,
    input  wire [AW-1:0] cfg_in_base,
    input  wire [AW-1:0] cfg_in_row,
    input  wire [AW-1:0] cfg_in_pix,
    input  wire [AW-1:0] cfg_out_base,
    input  wire [AW-1:0] cfg_out_row,
    input  wire [AW-1:0] cfg_out_pix,

    input  wire          start,
    output wire          busy,
    output reg           done,

    output reg  [AW-1:0] rd_addr,
    input  wire [7:0]    rd_data,

    output reg           out_we,
    output reg  [AW-1:0] out_addr,
    output reg  [7:0]    out_data
);

    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_RUN  = 2'd1;
    localparam [1:0] S_DRN  = 2'd2;

    reg [1:0]    state;
    reg          all_issued;
    assign busy = (state != S_IDLE);

    reg [11:0]   y, x;
    reg [10:0]   c;
    reg [1:0]    t;
    reg [AW-1:0] i_row, i_pix, a_c;         // input: row base, pixel base (tap 0 of the current output element), pixel base + channel
    reg [AW-1:0] o_row, o_pix, o_c;         // output: row base, pixel base, pixel base + channel

    wire is_pool = (cfg_mode == 3'd2) || (cfg_mode == 3'd3);
    wire is_up   = (cfg_mode == 3'd1);
    wire is_s2   = (cfg_mode == 3'd2);
    wire is_fill = (cfg_mode == 3'd4);
    wire t_end   = (t == (is_pool ? 2'd3 : 2'd0));
    wire c_last  = (c == cfg_c - 11'd1);
    wire x_last  = (x == cfg_w - 12'd1);
    wire y_last  = (y == cfg_h - 12'd1);
    wire y_ok    = is_s2 || !y_last;         // pool: the second row of the window exists (stride 1: not on the last row, edge replicated)
    wire x_ok    = is_s2 || !x_last;
    wire [AW-1:0] off_y = (t[1] && y_ok) ? cfg_in_row : {AW{1'b0}};      // t is 0 in the copy / upsample modes, so only the pools see dy / dx
    wire [AW-1:0] off_x = (t[0] && x_ok) ? cfg_in_pix : {AW{1'b0}};
    wire [AW-1:0] step_pix = is_s2 ? {cfg_in_pix[AW-2:0], 1'b0} : (is_up ? (x[0] ? cfg_in_pix : {AW{1'b0}}) : cfg_in_pix);
    wire [AW-1:0] step_row = is_s2 ? {cfg_in_row[AW-2:0], 1'b0} : (is_up ? (y[0] ? cfg_in_row : {AW{1'b0}}) : cfg_in_row);
    wire issue = (state == S_RUN) && !all_issued;

    // ------------------------------------------------------------------ control (reset)
    reg          m0_v, m1_v;                  // element descriptors of the two stages between the address register and the collect register
    reg          m0_first, m0_last, m1_first, m1_last;
    reg [AW-1:0] m0_oa, m1_oa;
    reg signed [7:0] mx;                      // running maximum of the element being collected
    wire pipe_busy = m1_v | out_we;           // S_DRN is entered one clock after the last issue, the address stage (m0) is empty by then
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; all_issued <= 1'b0; m0_v <= 1'b0; m1_v <= 1'b0; out_we <= 1'b0; done <= 1'b0;
        end
        else begin
            done  <= 1'b0;
            m0_v  <= issue;
            m1_v  <= m0_v;
            out_we <= m1_v && m1_last;
            case (state)
                S_IDLE: begin
                    all_issued <= 1'b0;
                    if (start) state <= S_RUN;
                end
                S_RUN: begin
                    if (issue && t_end && c_last && x_last && y_last) all_issued <= 1'b1;
                    if (all_issued) state <= S_DRN;
                end
                default: begin
                    if (!pipe_busy) begin state <= S_IDLE; done <= 1'b1; end
                end
            endcase
        end
    end

    // ------------------------------------------------------------------ address generation and data (no reset)
    wire signed [7:0] q   = rd_data;
    wire signed [7:0] mxn = m1_first ? q : ((q > mx) ? q : mx);

    always @(posedge clk) begin
        if (state == S_IDLE) begin
            y <= 12'd0; x <= 12'd0; c <= 11'd0; t <= 2'd0;
            i_row <= cfg_in_base; i_pix <= cfg_in_base; a_c <= cfg_in_base;
            o_row <= cfg_out_base; o_pix <= cfg_out_base; o_c <= cfg_out_base;
        end
        else if (issue) begin
            if (!t_end) t <= t + 2'd1;
            else begin
                t <= 2'd0;
                if (!c_last) begin
                    c <= c + 11'd1; a_c <= a_c + {{(AW-1){1'b0}}, 1'b1}; o_c <= o_c + {{(AW-1){1'b0}}, 1'b1};
                end
                else begin
                    c <= 11'd0;
                    if (!x_last) begin
                        x <= x + 12'd1;
                        i_pix <= i_pix + step_pix; a_c <= i_pix + step_pix;
                        o_pix <= o_pix + cfg_out_pix; o_c <= o_pix + cfg_out_pix;
                    end
                    else begin
                        x <= 12'd0;
                        y <= y + 12'd1;
                        i_row <= i_row + step_row; i_pix <= i_row + step_row; a_c <= i_row + step_row;
                        o_row <= o_row + cfg_out_row; o_pix <= o_row + cfg_out_row; o_c <= o_row + cfg_out_row;
                    end
                end
            end
        end
        // E0 -> E1: the read address and the element descriptor
        rd_addr  <= a_c + off_y + off_x;
        m0_first <= (t == 2'd0);
        m0_last  <= t_end;
        m0_oa    <= o_c;
        m1_first <= m0_first; m1_last <= m0_last; m1_oa <= m0_oa;
        // E2: collect
        mx <= mxn;                                // elements are issued back to back, the first tap of an element restarts the maximum
        out_addr <= m1_oa;
        out_data <= is_fill ? 8'd0 : mxn;
    end

endmodule
