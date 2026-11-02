// fps_meter.v - counts frames per second of two independent frame sources against a crystal-derived time base
//
// ref_clk is the time base (the 50 MHz board crystal, REF_HZ = 50_000_000 clocks per second). tog_cam and tog_disp are the
// outputs of pulse_to_toggle in the clock domains of the camera frame start and of the display vsync; they are
// synchronized to ref_clk here (2 flip-flops + edge detect). Every second the number of edges seen is latched:
//   fps_cam, fps_disp : 0..255 (saturating), updated once per second, hold otherwise
// The count of a window that starts at an arbitrary phase of the frame rate is exact +-1 (a 60 Hz source reads 59..61 now
// and then); it is a measurement of the camera frame start (what the camera really delivers) and of the display
// vsync (what the HDMI timing really refreshes at), NOT of the end-to-end latency.
// The outputs belong to the ref_clk domain; read them in another domain through byte_cdc.v.
// Reset: active-low asynchronous (counts and outputs 0).

module fps_meter #(
    parameter integer REF_HZ = 50000000
)(
    input  wire       ref_clk,
    input  wire       ref_rst_n,
    input  wire       tog_cam,
    input  wire       tog_disp,
    output reg  [7:0] fps_cam,
    output reg  [7:0] fps_disp
);

    reg [2:0]  sc, sd;                 // synchronizer + previous value
    reg [31:0] tick;
    reg [8:0]  nc, nd;                 // 9 bit so that saturation at 255 is visible

    wire ec = sc[2] ^ sc[1];
    wire ed = sd[2] ^ sd[1];

    always @(posedge ref_clk or negedge ref_rst_n) begin
        if (!ref_rst_n) begin
            sc <= 3'b000; sd <= 3'b000; tick <= 32'd0; nc <= 9'd0; nd <= 9'd0;
            fps_cam <= 8'd0; fps_disp <= 8'd0;
        end
        else begin
            sc <= {sc[1:0], tog_cam};
            sd <= {sd[1:0], tog_disp};
            if (tick >= REF_HZ - 1) begin
                tick     <= 32'd0;
                fps_cam  <= (nc + {8'd0, ec} > 9'd255) ? 8'd255 : (nc[7:0] + {7'd0, ec});
                fps_disp <= (nd + {8'd0, ed} > 9'd255) ? 8'd255 : (nd[7:0] + {7'd0, ed});
                nc <= 9'd0;
                nd <= 9'd0;
            end
            else begin
                tick <= tick + 32'd1;
                if (ec && nc < 9'd256) nc <= nc + 9'd1;
                if (ed && nd < 9'd256) nd <= nd + 9'd1;
            end
        end
    end

endmodule
