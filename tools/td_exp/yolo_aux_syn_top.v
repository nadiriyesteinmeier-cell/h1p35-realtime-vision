// yolo_aux_syn_top.v - synthesis / place-and-route experiment top for rtl_custom/yolo_aux_core.v (NOT part of any product build)
//
// The input memory is filled with LFSR data after reset, then the core runs the four modes one after the other on fixed maps (copy 12 x 16 x 8, upsample,
// pool s2, pool s1), forever; a checksum of everything it writes drives 8 pins so that nothing can be optimised away.
module yolo_aux_syn_top (
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

    (* ram_style = "bram" *) reg [7:0] in_mem  [0:16383];
    (* ram_style = "bram" *) reg [7:0] out_mem [0:16383];
    reg [7:0] in_q, out_q;
    wire [19:0] rd_addr;
    wire        out_we;
    wire [19:0] out_addr;
    wire [7:0]  out_data;

    reg [31:0] lfsr;
    reg [14:0] fcnt;
    reg        filling;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin lfsr <= 32'hACE1ACE1; fcnt <= 15'd0; filling <= 1'b1; end
        else begin
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            if (filling) begin
                fcnt <= fcnt + 15'd1;
                if (fcnt == 15'd16383) filling <= 1'b0;
            end
        end
    end
    always @(posedge clk) begin
        if (filling) in_mem[fcnt[13:0]] <= lfsr[7:0];
        in_q <= in_mem[rd_addr[13:0]];
        if (out_we) out_mem[out_addr[13:0]] <= out_data;
    end

    reg        start;
    reg [1:0]  mode;
    wire       busy, done;
    yolo_aux_core #(.AW(20)) u_core (
        .clk(clk), .rst_n(rst_n),
        .cfg_h(12'd12), .cfg_w(12'd16), .cfg_c(11'd8), .cfg_mode(mode),
        .cfg_in_base(20'd0), .cfg_in_row(20'd256), .cfg_in_pix(20'd8),
        .cfg_out_base(20'd0), .cfg_out_row(20'd128), .cfg_out_pix(20'd8),
        .start(start), .busy(busy), .done(done),
        .rd_addr(rd_addr), .rd_data(in_q), .out_we(out_we), .out_addr(out_addr), .out_data(out_data)
    );
    reg [7:0] chk;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin start <= 1'b0; mode <= 2'd0; chk <= 8'd0; end
        else begin
            start <= !filling && !busy && !start;
            if (done) mode <= mode + 2'd1;
            if (out_we) chk <= chk + out_data + out_addr[7:0];
        end
    end
    assign O_chk = chk;
endmodule
