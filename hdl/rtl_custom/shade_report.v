// shade_report.v - prints the cell sums of flat_stats as ASCII text over a UART (8N1), one cell per line
//
// One report (started by go, a 1-clock request) is
//   HDR,<frame:2 hex>,<awb mode:1 hex>,<GRID_W:2 hex>,<GRID_H:2 hex>,<CELL_W:2 hex>\r\n            (19 characters)
//   C<row:2 hex><col:2 hex>,<R sum:6 hex>,<G sum:6 hex>,<B sum:6 hex>\r\n                          (28 characters, GRID_W * GRID_H lines)
//   END,<checksum:4 hex>\r\n                                                                         (10 characters)
// checksum = the sum, modulo 65536, of the low 16 bits of every printed R, G and B sum (a transmission check for the PC side).
// The values are the unsigned sums of flat_stats (mean = sum / (CELL_W * CELL_H)). rd_addr / rd_data are the read port of
// flat_stats: this module sets rd_addr, waits 2 clocks and takes rd_data; it must only run while flat_stats is idle.
// busy = 1 from go until the last character has been handed to the UART; done = 1-clock pulse after the last character was
// handed over (the UART may still be sending it). Reset: active-low asynchronous, tx idles high.

module shade_report #(
    parameter integer CLKDIV  = 651,
    parameter integer GRID_W  = 16,
    parameter integer GRID_H  = 9,
    parameter integer CELL_W  = 80
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        go,
    input  wire [7:0]  frame_no,
    input  wire [3:0]  mode,
    output reg         busy,
    output reg         done,

    output reg  [7:0]  rd_addr,
    input  wire [62:0] rd_data,

    output wire        tx
);

    localparam [2:0] S_IDLE = 3'd0;
    localparam [2:0] S_HDR  = 3'd1;
    localparam [2:0] S_ADDR = 3'd2;
    localparam [2:0] S_WAIT = 3'd3;
    localparam [2:0] S_CELL = 3'd4;
    localparam [2:0] S_FOOT = 3'd5;
    localparam [7:0] GW8 = GRID_W;
    localparam [7:0] GH8 = GRID_H;
    localparam [7:0] CW8 = CELL_W;
    localparam integer HDR_LEN  = 19;
    localparam integer CELL_LEN = 28;
    localparam integer FOOT_LEN = 10;

    reg [2:0] state;
    reg [5:0] pos;
    reg [3:0] wait_n;
    reg [3:0] crow;
    reg [4:0] ccol;
    reg [62:0] cdat;
    reg [15:0] chk;
    reg [7:0] frame_q;
    reg [3:0] mode_q;

    wire       u_busy;
    reg        u_start;
    reg  [7:0] u_data;
    uart_tx8 #(.CLKDIV(CLKDIV)) u_uart (.clk(clk), .rst_n(rst_n), .start(u_start), .data(u_data), .busy(u_busy), .tx(tx));

    function [7:0] hexc;
        input [3:0] n;
        begin
            hexc = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
        end
    endfunction

    function [7:0] hdr_ch;
        input [5:0] i;
        begin
            case (i)
                6'd0:  hdr_ch = "H";
                6'd1:  hdr_ch = "D";
                6'd2:  hdr_ch = "R";
                6'd3:  hdr_ch = ",";
                6'd4:  hdr_ch = hexc(frame_q[7:4]);
                6'd5:  hdr_ch = hexc(frame_q[3:0]);
                6'd6:  hdr_ch = ",";
                6'd7:  hdr_ch = hexc(mode_q);
                6'd8:  hdr_ch = ",";
                6'd9:  hdr_ch = hexc(GW8[7:4]);
                6'd10: hdr_ch = hexc(GW8[3:0]);
                6'd11: hdr_ch = ",";
                6'd12: hdr_ch = hexc(GH8[7:4]);
                6'd13: hdr_ch = hexc(GH8[3:0]);
                6'd14: hdr_ch = ",";
                6'd15: hdr_ch = hexc(CW8[7:4]);
                6'd16: hdr_ch = hexc(CW8[3:0]);
                6'd17: hdr_ch = 8'h0D;
                default: hdr_ch = 8'h0A;
            endcase
        end
    endfunction

    function [7:0] cell_ch;
        input [5:0]  i;
        input [3:0]  r;
        input [4:0]  c;
        input [62:0] d;
        begin
            case (i)
                6'd0:  cell_ch = "C";
                6'd1:  cell_ch = hexc(4'd0);
                6'd2:  cell_ch = hexc(r);
                6'd3:  cell_ch = hexc({3'd0, c[4]});
                6'd4:  cell_ch = hexc(c[3:0]);
                6'd5:  cell_ch = ",";
                6'd6:  cell_ch = hexc({3'd0, d[20]});        // R sum, 6 hex digits = 24 bits, the top 3 bits are 0
                6'd7:  cell_ch = hexc(d[19:16]);
                6'd8:  cell_ch = hexc(d[15:12]);
                6'd9:  cell_ch = hexc(d[11:8]);
                6'd10: cell_ch = hexc(d[7:4]);
                6'd11: cell_ch = hexc(d[3:0]);
                6'd12: cell_ch = ",";
                6'd13: cell_ch = hexc({3'd0, d[41]});        // G sum
                6'd14: cell_ch = hexc(d[40:37]);
                6'd15: cell_ch = hexc(d[36:33]);
                6'd16: cell_ch = hexc(d[32:29]);
                6'd17: cell_ch = hexc(d[28:25]);
                6'd18: cell_ch = hexc(d[24:21]);
                6'd19: cell_ch = ",";
                6'd20: cell_ch = hexc({3'd0, d[62]});        // B sum
                6'd21: cell_ch = hexc(d[61:58]);
                6'd22: cell_ch = hexc(d[57:54]);
                6'd23: cell_ch = hexc(d[53:50]);
                6'd24: cell_ch = hexc(d[49:46]);
                6'd25: cell_ch = hexc(d[45:42]);
                6'd26: cell_ch = 8'h0D;
                default: cell_ch = 8'h0A;
            endcase
        end
    endfunction

    function [7:0] foot_ch;
        input [5:0]  i;
        input [15:0] s;
        begin
            case (i)
                6'd0: foot_ch = "E";
                6'd1: foot_ch = "N";
                6'd2: foot_ch = "D";
                6'd3: foot_ch = ",";
                6'd4: foot_ch = hexc(s[15:12]);
                6'd5: foot_ch = hexc(s[11:8]);
                6'd6: foot_ch = hexc(s[7:4]);
                6'd7: foot_ch = hexc(s[3:0]);
                6'd8: foot_ch = 8'h0D;
                default: foot_ch = 8'h0A;
            endcase
        end
    endfunction

    wire can_send = !u_busy && !u_start;
    wire [15:0] cell_sum = cdat[15:0] + cdat[36:21] + cdat[57:42];       // low 16 bits of R, G and B (a 21-bit field starts at 0, 21, 42)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; pos <= 6'd0; wait_n <= 4'd0; crow <= 4'd0; ccol <= 5'd0; cdat <= 63'd0; chk <= 16'd0;
            frame_q <= 8'd0; mode_q <= 4'd0; u_start <= 1'b0; u_data <= 8'd0; busy <= 1'b0; done <= 1'b0; rd_addr <= 8'd0;
        end
        else begin
            u_start <= 1'b0;
            done    <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (go) begin
                        busy    <= 1'b1;
                        frame_q <= frame_no;
                        mode_q  <= mode;
                        chk     <= 16'd0;
                        pos     <= 6'd0;
                        state   <= S_HDR;
                    end
                end
                S_HDR: begin
                    if (can_send) begin
                        u_start <= 1'b1;
                        u_data  <= hdr_ch(pos);
                        if (pos == HDR_LEN - 1) begin
                            pos <= 6'd0; crow <= 4'd0; ccol <= 5'd0; rd_addr <= 8'd0; state <= S_ADDR;
                        end
                        else pos <= pos + 6'd1;
                    end
                end
                S_ADDR: begin                                   // rd_addr is already set; the RAM needs 1 clock, take the data 2 clocks later
                    wait_n <= 4'd2;
                    state  <= S_WAIT;
                end
                S_WAIT: begin
                    if (wait_n == 4'd0) begin
                        cdat  <= rd_data;
                        state <= S_CELL;
                        pos   <= 6'd0;
                    end
                    else wait_n <= wait_n - 4'd1;
                end
                S_CELL: begin
                    if (can_send) begin
                        u_start <= 1'b1;
                        u_data  <= cell_ch(pos, crow, ccol, cdat);
                        if (pos == 6'd0) chk <= chk + cell_sum;               // each cell enters the checksum once
                        if (pos == CELL_LEN - 1) begin
                            pos <= 6'd0;
                            if (ccol == GRID_W - 1) begin
                                ccol <= 5'd0;
                                if (crow == GRID_H - 1) state <= S_FOOT;
                                else begin
                                    crow    <= crow + 4'd1;
                                    rd_addr <= rd_addr + 8'd1;
                                    state   <= S_ADDR;
                                end
                            end
                            else begin
                                ccol    <= ccol + 5'd1;
                                rd_addr <= rd_addr + 8'd1;
                                state   <= S_ADDR;
                            end
                        end
                        else pos <= pos + 6'd1;
                    end
                end
                S_FOOT: begin
                    if (can_send) begin
                        u_start <= 1'b1;
                        u_data  <= foot_ch(pos, chk);
                        if (pos == FOOT_LEN - 1) begin
                            pos <= 6'd0; busy <= 1'b0; done <= 1'b1; state <= S_IDLE;
                        end
                        else pos <= pos + 6'd1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
