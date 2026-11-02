// flat_stats.v - per-cell colour sums of ONE frame (flat-field / shading measurement), stored in a RAM
//
// Input: the normalized pixel stream of this project (de, rgb, sof, eol, eof; one pixel per clock; rgb = {R, G, B}, 8 bits each).
// The frame is divided into GRID_W x GRID_H cells of CELL_W x CELL_H pixels (default 16 x 9 cells of 80 x 80 = 1280 x 720). For every
// cell the module keeps three unsigned sums (R, G, B), 21 bits each (CELL_W * CELL_H * 255 = 1,632,000 < 2^21), packed as
//   ext_data = {B[20:0], G[20:0], R[20:0]}        at address  row * GRID_W + col
// The mean of a cell is sum / (CELL_W * CELL_H); the sums themselves are exported so that no division is needed in the FPGA.
//
// Sequence (pixel clock domain only):
//   start (1 clock)  -> busy = 1, the first GRID_W * GRID_H RAM words are cleared (one per clock) -> wait for the next first pixel of a
//   frame (in_de & in_sof) -> accumulate that whole frame (ends with the pixel that has in_eof) -> done (1 clock) and busy = 0.
//   A second in_sof inside the accumulation (the stream restarted) aborts it: the RAM is cleared again and the module waits for the
//   next frame start. Pixels of cells beyond the grid are ignored. A start while busy is ignored.
// Accumulation: the pixels of one line inside one cell are summed in registers (CELL_W clocks), then one read-modify-write to the RAM
// (3 clocks, much faster than the 80-clock spacing of two flushes). RAM: one write port, one read port (shared with the readout:
// while busy = 0 ext_addr selects the word; ext_data is valid 1 clock after ext_addr changed; while accumulating ext_data is meaningless).
// Latency of the sums: the RAM holds the final sums 4 clocks after the last pixel of the frame (done is delayed to match).
// Reset: active-low asynchronous.

module flat_stats #(
    parameter integer GRID_W = 16,
    parameter integer GRID_H = 9,
    parameter integer CELL_W = 80,
    parameter integer CELL_H = 80
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    output reg         busy,
    output reg         done,

    input  wire        in_de,
    input  wire        in_sof,
    input  wire        in_eol,
    input  wire        in_eof,
    input  wire [23:0] in_rgb,

    input  wire [7:0]  ext_addr,
    output wire [62:0] ext_data
);

    localparam integer NCELL = GRID_W * GRID_H;

    localparam [2:0] S_IDLE  = 3'd0;
    localparam [2:0] S_CLEAR = 3'd1;
    localparam [2:0] S_WAIT  = 3'd2;
    localparam [2:0] S_ACC   = 3'd3;
    localparam [2:0] S_FIN   = 3'd4;

    reg [2:0] state;

    // ---------------- RAM (inferred block RAM): one write port, one read port
    (* ram_style = "bram" *) reg [62:0] mem [0:255];
    reg  [62:0] rq;
    wire [7:0]  ra;
    wire [7:0]  wa;
    wire [62:0] wd;
    wire        we;
    always @(posedge clk) begin
        if (we) mem[wa] <= wd;
        rq <= mem[ra];
    end
    assign ext_data = rq;

    // ---------------- accumulation
    reg [6:0]  xc;                       // pixel index inside the cell run (0 .. CELL_W-1)
    reg [4:0]  col;
    reg [6:0]  yc;                       // line index inside the cell row
    reg [3:0]  row;
    reg [7:0]  row_base;                 // row * GRID_W
    reg [14:0] sr, sg, sb;               // run sums of the current cell on this line

    reg        f_v;                      // flush request: add the run sums to the RAM word f_addr
    reg [7:0]  f_addr;
    reg [14:0] f_r, f_g, f_b;
    reg        p_v;                      // second stage: the RAM word is being read
    reg [7:0]  p_addr;
    reg [14:0] p_r, p_g, p_b;

    reg [7:0]  clr_cnt;
    reg [2:0]  drain;

    wire pix_first = (state == S_WAIT) && in_de && in_sof;
    wire pix_v     = in_de && (state == S_ACC || pix_first);

    wire [14:0] sr_n = sr + {7'd0, in_rgb[23:16]};
    wire [14:0] sg_n = sg + {7'd0, in_rgb[15:8]};
    wire [14:0] sb_n = sb + {7'd0, in_rgb[7:0]};
    wire        run_end = (xc == CELL_W - 1) || in_eol;
    wire        cell_ok = (col < GRID_W) && (row < GRID_H);
    wire [7:0]  cell_addr = row_base + {3'd0, col};

    assign ra = (state == S_ACC || state == S_FIN) ? f_addr : ext_addr;      // S_FIN: the last flush is still in the pipeline
    wire [20:0] q_r = rq[20:0];
    wire [20:0] q_g = rq[41:21];
    wire [20:0] q_b = rq[62:42];
    wire [20:0] n_r = q_r + {6'd0, p_r};
    wire [20:0] n_g = q_g + {6'd0, p_g};
    wire [20:0] n_b = q_b + {6'd0, p_b};
    assign we = (state == S_CLEAR) || p_v;
    assign wa = (state == S_CLEAR) ? clr_cnt : p_addr;
    assign wd = (state == S_CLEAR) ? 63'd0 : {n_b, n_g, n_r};

    task zero_counters;
        begin
            xc <= 7'd0; col <= 5'd0; yc <= 7'd0; row <= 4'd0; row_base <= 8'd0;
            sr <= 15'd0; sg <= 15'd0; sb <= 15'd0;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; busy <= 1'b0; done <= 1'b0;
            xc <= 7'd0; col <= 5'd0; yc <= 7'd0; row <= 4'd0; row_base <= 8'd0;
            sr <= 15'd0; sg <= 15'd0; sb <= 15'd0;
            f_v <= 1'b0; f_addr <= 8'd0; f_r <= 15'd0; f_g <= 15'd0; f_b <= 15'd0;
            p_v <= 1'b0; p_addr <= 8'd0; p_r <= 15'd0; p_g <= 15'd0; p_b <= 15'd0;
            clr_cnt <= 8'd0; drain <= 3'd0;
        end
        else begin
            done <= 1'b0;
            f_v  <= 1'b0;
            // second stage of the read-modify-write pipeline
            p_v    <= f_v;
            p_addr <= f_addr;
            p_r    <= f_r;
            p_g    <= f_g;
            p_b    <= f_b;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy    <= 1'b1;
                        clr_cnt <= 8'd0;
                        zero_counters;
                        state   <= S_CLEAR;
                    end
                end
                S_CLEAR: begin
                    if (clr_cnt == NCELL - 1) state <= S_WAIT;
                    else                      clr_cnt <= clr_cnt + 8'd1;
                end
                S_WAIT: begin
                    // pix_first is handled together with the accumulation below
                    if (pix_first) state <= S_ACC;
                end
                S_ACC: begin
                    if (in_de && in_sof) begin                    // the stream restarted: abort, measure the next frame
                        clr_cnt <= 8'd0;
                        zero_counters;
                        state   <= S_CLEAR;
                    end
                end
                S_FIN: begin
                    if (drain == 3'd0) begin
                        state <= S_IDLE;
                        busy  <= 1'b0;
                        done  <= 1'b1;
                    end
                    else drain <= drain - 3'd1;
                end
                default: state <= S_IDLE;
            endcase

            // pixel accumulation (also the first pixel of the frame, which arrives in S_WAIT)
            if (pix_v && !(state == S_ACC && in_sof)) begin
                if (run_end) begin
                    f_v    <= cell_ok;
                    f_addr <= cell_addr;
                    f_r    <= sr_n;
                    f_g    <= sg_n;
                    f_b    <= sb_n;
                    sr <= 15'd0; sg <= 15'd0; sb <= 15'd0;
                    xc <= 7'd0;
                    if (in_eol) begin
                        col <= 5'd0;
                        if (yc == CELL_H - 1) begin
                            yc <= 7'd0;
                            row <= row + 4'd1;
                            row_base <= row_base + GRID_W;
                        end
                        else yc <= yc + 7'd1;
                    end
                    else col <= col + 5'd1;
                end
                else begin
                    sr <= sr_n; sg <= sg_n; sb <= sb_n;
                    xc <= xc + 7'd1;
                end
                if (in_eof) begin
                    state <= S_FIN;
                    drain <= 3'd4;
                end
            end
        end
    end

endmodule
