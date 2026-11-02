// yolo_decode_syn_top.v - synthesis / place-and-route experiment top for rtl_custom/yolo_decode.v (NOT part of any product build)
//
// The head memory (2048 bytes) is filled with LFSR data after reset, the decoder then runs over it again and again; after every run the 8 result boxes are read and
// folded into an 8-bit checksum on the output pins (nothing can be optimised away). Resource and clock numbers of the post-processing, not a functional demo.
module yolo_decode_syn_top (
    input  wire       I_sys_clk,
    input  wire       I_rst_n,
    output wire [7:0] O_chk
);
    wire clk = I_sys_clk;
    reg [2:0] rs;
    always @(posedge clk or negedge I_rst_n) begin
        if (!I_rst_n) rs <= 3'd0;
        else          rs <= {rs[1:0], 1'b1};
    end
    wire rst_n = rs[2];

    (* ram_style = "bram" *) reg [7:0] mem [0:2047];
    reg [7:0]  rd_q;
    wire [19:0] rd_addr;
    reg [31:0] lfsr;
    reg [10:0] fcnt;
    reg        filling;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin lfsr <= 32'hACE1ACE1; fcnt <= 11'd0; filling <= 1'b1; end
        else begin
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            if (filling) begin
                fcnt <= fcnt + 11'd1;
                if (fcnt == 11'd2047) filling <= 1'b0;
            end
        end
    end
    always @(posedge clk) begin
        if (filling) mem[fcnt] <= lfsr[7:0];
        rd_q <= mem[rd_addr[10:0]];
    end

    reg        start;
    wire       busy, done;
    reg  [3:0] res_idx;
    wire [59:0] res_data;
    wire [3:0] res_n;
    yolo_decode u_dec (.clk(clk), .rst_n(rst_n), .anc1({8'd40, 8'd32, 8'd28, 8'd20, 8'd16, 8'd12}), .anc2({8'd12, 8'd14, 8'd10, 8'd8, 8'd6, 8'd4}), .start(start), .busy(busy), .done(done), .rd_addr(rd_addr), .rd_data(rd_q),
                       .res_idx(res_idx), .res_data(res_data), .res_n(res_n));
    reg [7:0] chk;
    reg [1:0] rl;
    reg       reading;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin start <= 1'b0; chk <= 8'd0; res_idx <= 4'd0; rl <= 2'd0; reading <= 1'b0; end
        else begin
            start <= 1'b0;
            if (!filling && !busy && !start && !reading) begin start <= 1'b1; end
            if (done) begin reading <= 1'b1; res_idx <= 4'd0; rl <= 2'd0; end
            if (reading) begin
                rl <= rl + 2'd1;
                if (rl == 2'd3) begin
                    chk <= chk + res_data[7:0] + res_data[27:20] + res_data[47:40] + res_n;
                    res_idx <= res_idx + 4'd1;
                    if (res_idx == 4'd7) reading <= 1'b0;
                end
            end
        end
    end
    assign O_chk = chk;
endmodule
