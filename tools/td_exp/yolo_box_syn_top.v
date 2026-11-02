// yolo_box_syn_top.v - synthesis / place-and-route experiment top for rtl_custom/yolo_box_down.v (NOT part of any product build)
// A pixel generator (LFSR data, 1280 x 720 raster with sof, one pixel per clock) feeds the downscaler, which is armed again after every frame_done;
// a checksum of the written bytes drives the output pins.
module yolo_box_syn_top (
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
    reg [10:0] x, y;
    reg [31:0] lfsr;
    reg        valid, sof, arm, started;
    wire       active, we, frame_done;
    wire [19:0] waddr;
    wire [7:0]  wdata;
    reg [7:0] chk;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin x <= 11'd0; y <= 11'd0; lfsr <= 32'hACE1ACE1; valid <= 1'b0; sof <= 1'b0; arm <= 1'b0; chk <= 8'd0; started <= 1'b0; end
        else begin
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            valid <= 1'b1;
            sof <= (x == 11'd0) && (y == 11'd0);
            if (x == 11'd1279) begin x <= 11'd0; y <= (y == 11'd749) ? 11'd0 : y + 11'd1; end else x <= x + 11'd1;
            started <= 1'b1;
            arm <= frame_done || !started;
            if (we) chk <= chk + wdata + waddr[7:0];
        end
    end
    wire v_act = (y < 11'd720);
    yolo_box_down u (.clk(clk), .rst_n(rst_n), .arm(arm), .active(active), .pix_valid(valid && v_act), .pix_sof(sof),
                     .pr(lfsr[7:0]), .pg(lfsr[15:8]), .pb(lfsr[23:16]), .we(we), .waddr(waddr), .wdata(wdata), .frame_done(frame_done));
    assign O_chk = chk;
endmodule
