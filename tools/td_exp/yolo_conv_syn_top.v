// yolo_conv_syn_top.v - synthesis / place-and-route experiment top for rtl_custom/yolo_conv_core.v (NOT part of any product build)
//
// Purpose: measure the real resource use (LUT / FF / DSP / ERAM) and the achievable clock of the convolution core on the PH1P35 with TD, in a design
// that is small enough to be placed on its own: the three read memories (activation, weights, parameters) are filled with LFSR data after reset,
// the core then runs one fixed layer over and over (8 x 8 pixels, cin 64, cout 32, 3x3) and a checksum of everything it writes drives 8 pins, so
// nothing can be optimised away. Memory sizes are representative of one tile of a real layer, not of the whole network.
module yolo_conv_syn_top #(
    parameter integer LANES = 16
)(
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

    // ---------------- memories
    (* ram_style = "bram" *) reg [7:0]          act_mem [0:32767];
    (* ram_style = "bram" *) reg [8*LANES-1:0]  wt_mem  [0:2047];
    (* ram_style = "bram" *) reg [55:0]         pm_mem  [0:1023];
    reg [7:0]         act_q;
    reg [8*LANES-1:0] wt_q;
    reg [55:0]        pm_q;
    wire [19:0] act_addr;
    wire [13:0] wt_addr;
    wire [10:0] pm_addr;

    // ---------------- LFSR fill, then run forever
    reg [31:0] lfsr;
    reg [31:0] lfsr1, lfsr2, lfsr3;                      // independent sequences so that no two lanes see identical data (the tools merge identical logic)
    reg [15:0] fcnt;
    reg        filling;
    wire       fill_we = filling;
    wire [127:0] wide4 = {lfsr3, lfsr2, lfsr1, lfsr};
    wire [8*LANES-1:0] wide = wide4[8*LANES-1:0];
    wire [55:0] pm_fill = {lfsr[23:0], lfsr[31:0]} & 56'h003FFFFFFFFFFF;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin lfsr <= 32'hACE1ACE1; lfsr1 <= 32'h1234ABCD; lfsr2 <= 32'h0F0F5A5A; lfsr3 <= 32'hC3A5E781; fcnt <= 16'd0; filling <= 1'b1; end
        else begin
            lfsr  <= {lfsr[30:0],  lfsr[31]  ^ lfsr[21]  ^ lfsr[1]  ^ lfsr[0]};
            lfsr1 <= {lfsr1[30:0], lfsr1[31] ^ lfsr1[27] ^ lfsr1[3] ^ lfsr1[0]};
            lfsr2 <= {lfsr2[30:0], lfsr2[31] ^ lfsr2[29] ^ lfsr2[5] ^ lfsr2[0]};
            lfsr3 <= {lfsr3[30:0], lfsr3[31] ^ lfsr3[25] ^ lfsr3[7] ^ lfsr3[0]};
            if (filling) begin
                fcnt <= fcnt + 16'd1;
                if (fcnt == 16'd32767) filling <= 1'b0;
            end
        end
    end
    always @(posedge clk) begin
        if (fill_we) begin
            act_mem[fcnt[14:0]] <= lfsr[7:0];
            wt_mem[fcnt[10:0]]  <= wide;
            pm_mem[fcnt[9:0]]   <= pm_fill;
        end
        act_q <= act_mem[act_addr[14:0]];
        wt_q  <= wt_mem[wt_addr[10:0]];
        pm_q  <= pm_mem[pm_addr[9:0]];
    end

    // ---------------- the core
    reg  start;
    wire busy, done, out_we;
    wire [19:0] out_addr;
    wire [7:0]  out_data;
    wire [19:0] out_rd_addr;
    (* ram_style = "bram" *) reg [7:0] out_mem [0:4095];                    // pooled output map of the fixed layer (4 x 4 x 32 = 512 bytes used)
    reg  [7:0]  out_rq;
    always @(posedge clk) begin
        if (out_we) out_mem[out_addr[11:0]] <= out_data;
        out_rq <= out_mem[out_rd_addr[11:0]];
    end
    yolo_conv_core #(.LANES(LANES), .AW(20), .WW(14), .PW(11)) u_core (
        .clk(clk), .rst_n(rst_n),
        .cfg_h(12'd8), .cfg_w(12'd8), .cfg_cin(11'd64), .cfg_cout(11'd32), .cfg_k3(1'b1), .cfg_act(1'b1),
        .cfg_in_base(20'd0), .cfg_in_row(20'd640), .cfg_in_pix(20'd64),
        .cfg_out_base(20'd0), .cfg_out_row(20'd128), .cfg_out_pix(20'd32), .cfg_pool(1'b1),
        .start(start), .busy(busy), .done(done),
        .act_addr(act_addr), .act_data(act_q), .wt_addr(wt_addr), .wt_data(wt_q), .pm_addr(pm_addr), .pm_data(pm_q),
        .out_we(out_we), .out_addr(out_addr), .out_data(out_data), .out_rd_addr(out_rd_addr), .out_rd_data(out_rq)
    );
    reg [7:0] chk;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin start <= 1'b0; chk <= 8'd0; end
        else begin
            start <= !filling && !busy && !start;
            if (out_we) chk <= chk + out_data + out_addr[7:0];
        end
    end
    assign O_chk = chk;
endmodule
