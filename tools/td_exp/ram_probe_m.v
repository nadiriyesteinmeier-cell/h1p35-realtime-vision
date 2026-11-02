// ram_probe_m.v - TD RAM inference probe 2 (NOT part of any product build): module boundary, combinational write controls, ROM address from an adder
// STYLE 0: yolo_bank_ram with every port driven directly by registers; 1: write enable / address / data are combinational muxes (busy ? a : b), read address a function mux;
// 2: ROM module (yolo_a_pm_rom) with address = reg + reg; 3: STYLE 1 plus the read data goes through a 4:1 mux into a register (like rd_sel -> a_q)
module ram_probe_m (
    input  wire       I_sys_clk,
    input  wire       I_rst_n,
    output wire [7:0] O_chk
);
    localparam integer STYLE = 0;
    wire clk = I_sys_clk;
    reg [2:0] rs;
    always @(posedge clk or negedge I_rst_n) begin
        if (!I_rst_n) rs <= 3'd0;
        else          rs <= {rs[1:0], 1'b1};
    end
    wire rst_n = rs[2];
    reg [19:0] wa0, wa1, ra0, ra1, ro;
    reg        sel, busy, we0, we1;
    reg [7:0]  wd0, wd1, chk;
    reg [1:0]  bsel;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin wa0 <= 20'd0; wa1 <= 20'd50; ra0 <= 20'd0; ra1 <= 20'd100; ro <= 20'd7; sel <= 1'b0; busy <= 1'b0; we0 <= 1'b0; we1 <= 1'b0; wd0 <= 8'd0; wd1 <= 8'd9; chk <= 8'd0; bsel <= 2'd0; end
        else begin
            wa0 <= wa0 + 20'd1; wa1 <= wa1 + 20'd2; ra0 <= ra0 + 20'd3; ra1 <= ra1 + 20'd5; ro <= ro + 20'd1; sel <= ~sel; busy <= wa0[6]; we0 <= wa0[3]; we1 <= wa0[2];
            wd0 <= wd0 + 8'd7; wd1 <= wd1 + 8'd3; bsel <= bsel + 2'd1;
            chk <= chk + obs;
        end
    end
    wire [7:0]  rdata;
    wire [7:0]  obs;
    wire [55:0] pdata;
    generate
        if (STYLE == 0) begin : g0
            yolo_bank_ram #(.DEPTH(38400), .AW(20)) u (.clk(clk), .we(we0), .waddr(wa0), .wdata(wd0), .raddr(ra0), .rdata(rdata));
            assign obs = rdata;
        end
        else if (STYLE == 1 || STYLE == 3) begin : g1
            wire        we  = busy ? we0 : we1;
            wire [19:0] wa  = busy ? wa0 : wa1;
            wire [7:0]  wd  = busy ? wd0 : wd1;
            wire [19:0] ra  = busy ? (sel ? ra0 : ra1) : 20'd0;
            yolo_bank_ram #(.DEPTH(38400), .AW(20)) u (.clk(clk), .we(we), .waddr(wa), .wdata(wd), .raddr(ra), .rdata(rdata));
            reg [7:0] q;
            always @(posedge clk) q <= (bsel == 2'd0) ? rdata : (bsel == 2'd1) ? ~rdata : (bsel == 2'd2) ? {rdata[3:0], rdata[7:4]} : 8'd0;
            assign obs = (STYLE == 3) ? q : rdata;
        end
        else begin : g2
            yolo_a_pm_rom u (.clk(clk), .addr(ro[10:0] + ra0[10:0]), .data(pdata));
            assign obs = pdata[7:0] ^ pdata[15:8] ^ pdata[55:48];
            assign rdata = 8'd0;
        end
    endgenerate
    assign O_chk = chk;
endmodule
