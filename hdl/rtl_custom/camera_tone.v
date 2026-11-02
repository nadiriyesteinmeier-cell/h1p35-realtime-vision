// Camera tone: configurable saturation; optional mild lift or approximate Gamma 2.2.
// Combinational: no video timing or pixel-coordinate latency changes.
// Black stays black; without channel calibration neutral greys stay neutral. Arithmetic clips, never wraps.
// Default keeps the original gray levels. SAT_SHIFT=3 gives 1.125x; SAT_BOOST=0 disables saturation.
// GAMMA_ENABLE=1 restores the earlier display curve. This is not white-balance calibration.
module camera_tone #(
    parameter integer SAT_BOOST = 1,
    parameter integer SAT_SHIFT = 1,
    parameter integer GAMMA_ENABLE = 0,
    parameter integer LIFT_ENABLE = 0,
    parameter integer SHADOW_BOOST = 0,
    parameter integer RED_GAIN_Q8 = 256,
    parameter integer GREEN_GAIN_Q8 = 256,
    parameter integer BLUE_GAIN_Q8 = 256
)(
    input wire [23:0] in_rgb,
    input wire enable,
    output wire [23:0] out_rgb
);
    // Manual channel calibration. Q8=256 is unity; actual gains need a neutral-target hardware check.
    function [7:0] gain8;
        input [7:0] c;
        input integer gain_q8;
        reg signed [31:0] v;
        begin
            v = c * gain_q8 + 128;
            gain8 = v < 0 ? 8'd0 : (v > 65535 ? 8'd255 : v[15:8]);
        end
    endfunction
    function [7:0] gamma8;
        input [7:0] c;
        reg [7:0] base;
        reg [5:0] step;
        reg [9:0] v;
        begin
            case (c[7:3])
                5'd0: begin base=8'd0; step=6'd53; end
                5'd1: begin base=8'd53; step=6'd19; end
                5'd2: begin base=8'd72; step=6'd15; end
                5'd3: begin base=8'd87; step=6'd12; end
                5'd4: begin base=8'd99; step=6'd11; end
                5'd5: begin base=8'd110; step=6'd9; end
                5'd6: begin base=8'd119; step=6'd9; end
                5'd7: begin base=8'd128; step=6'd8; end
                5'd8: begin base=8'd136; step=6'd8; end
                5'd9: begin base=8'd144; step=6'd7; end
                5'd10: begin base=8'd151; step=6'd6; end
                5'd11: begin base=8'd157; step=6'd7; end
                5'd12: begin base=8'd164; step=6'd6; end
                5'd13: begin base=8'd170; step=6'd5; end
                5'd14: begin base=8'd175; step=6'd6; end
                5'd15: begin base=8'd181; step=6'd5; end
                5'd16: begin base=8'd186; step=6'd6; end
                5'd17: begin base=8'd192; step=6'd5; end
                5'd18: begin base=8'd197; step=6'd5; end
                5'd19: begin base=8'd202; step=6'd4; end
                5'd20: begin base=8'd206; step=6'd5; end
                5'd21: begin base=8'd211; step=6'd4; end
                5'd22: begin base=8'd215; step=6'd5; end
                5'd23: begin base=8'd220; step=6'd4; end
                5'd24: begin base=8'd224; step=6'd4; end
                5'd25: begin base=8'd228; step=6'd4; end
                5'd26: begin base=8'd232; step=6'd4; end
                5'd27: begin base=8'd236; step=6'd4; end
                5'd28: begin base=8'd240; step=6'd4; end
                5'd29: begin base=8'd244; step=6'd4; end
                5'd30: begin base=8'd248; step=6'd4; end
                5'd31: begin base=8'd252; step=6'd3; end
            endcase
            v = {2'b0,base} + ((step*c[2:0] + 10'd4) >> 3);
            gamma8 = v > 255 ? 8'd255 : v[7:0];
        end
    endfunction
    // Small shadow lift, diminishing towards white; preserves black/white and neutral greys.
    // LIFT_ENABLE is a hardware calibration knob; it does not correct white balance.
    function [7:0] lift8;
        input [7:0] c;
        reg [7:0] headroom, shadowroom;
        begin
            headroom = c < 128 ? c : 8'd255-c;
            // Optional extra lift only below midpoint; keeps the old highlight curve.
            shadowroom = c < 64 ? c : c < 128 ? 8'd127-c : 8'd0;
            lift8 = c + (headroom >> 1) + (SHADOW_BOOST ? (shadowroom >> 1) : 8'd0);
        end
    endfunction
    function [7:0] saturate;
        input [7:0] c, y;
        reg signed [9:0] delta, v;
        begin
            delta = $signed({1'b0,c}) - $signed({1'b0,y});
            v = $signed({1'b0,c}) + (delta >>> SAT_SHIFT);
            saturate = v < 0 ? 8'd0 : (v > 255 ? 8'd255 : v[7:0]);
        end
    endfunction
    wire [7:0] calibrated_r = gain8(in_rgb[23:16],RED_GAIN_Q8);
    wire [7:0] calibrated_g = gain8(in_rgb[15:8],GREEN_GAIN_Q8);
    wire [7:0] calibrated_b = gain8(in_rgb[7:0],BLUE_GAIN_Q8);
    wire [7:0] r = LIFT_ENABLE ? lift8(calibrated_r) : GAMMA_ENABLE ? gamma8(calibrated_r) : calibrated_r;
    wire [7:0] g = LIFT_ENABLE ? lift8(calibrated_g) : GAMMA_ENABLE ? gamma8(calibrated_g) : calibrated_g;
    wire [7:0] b = LIFT_ENABLE ? lift8(calibrated_b) : GAMMA_ENABLE ? gamma8(calibrated_b) : calibrated_b;
    wire [9:0] sum = {2'b0,r} + {1'b0,g,1'b0} + {2'b0,b};
    wire [7:0] y = sum[9:2];
    wire [23:0] toned;
    generate if (SAT_BOOST) begin : g_saturation
        assign toned[23:16] = saturate(r,y);
        assign toned[15:8] = saturate(g,y);
        assign toned[7:0] = saturate(b,y);
    end else begin : g_neutral
        assign toned = {r,g,b};
    end endgenerate
    assign out_rgb = enable ? toned : in_rgb;
endmodule
