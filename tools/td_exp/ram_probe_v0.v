// ram_probe_v0.v - TD RAM inference probe (NOT part of any product build): which read-address / output structures does TD map to ERAM?
// STYLE 0: read address straight from a register; 1: register + constant (adder); 2: mux of two registers selected by a register (like yolo_net_engine's ra_sel);
// 3: like 2 but through yolo_bank_ram's module boundary with a power-of-two depth
module ram_probe_v0 (
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
    reg [15:0] wa, ra0, ra1;
    reg        sel;
    reg [7:0]  wd, chk;
    reg        we;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin wa <= 16'd0; ra0 <= 16'd0; ra1 <= 16'd100; sel <= 1'b0; wd <= 8'd0; chk <= 8'd0; we <= 1'b0; end
        else begin
            wa <= wa + 16'd1; ra0 <= ra0 + 16'd3; ra1 <= ra1 + 16'd5; sel <= ~sel; wd <= wd + 8'd7; we <= wa[3];
            chk <= chk + rdata;
        end
    end
    wire [15:0] raddr = (STYLE == 0) ? ra0 : (STYLE == 1) ? (ra0 + 16'd5) : (sel ? ra1 : ra0);
    (* ram_style = "bram" *) reg [7:0] mem [0:38399];
    reg [7:0] rdata;
    always @(posedge clk) begin
        if (we) mem[wa] <= wd;
        rdata <= mem[raddr];
    end
    assign O_chk = chk;
endmodule
