`timescale 1ns/1ps
module tb_camera_tone;
    reg [23:0] in_rgb;
    reg enable;
    wire [23:0] out_rgb;
    wire [23:0] sat_rgb;
    wire [23:0] lift_rgb;
    wire [23:0] chain_balance_rgb, chain_lift_rgb, chain_rgb;
    wire [23:0] balance_rgb;
    reg [3:0] sw;
    integer mode;
`ifdef BASELINE
    assign out_rgb = in_rgb;
    assign sat_rgb = in_rgb;
    assign lift_rgb = in_rgb;
    assign chain_rgb = in_rgb;
    assign balance_rgb = in_rgb;
`else
    camera_tone #(.GAMMA_ENABLE(1), .SAT_SHIFT(3)) dut (.in_rgb(in_rgb), .enable(enable), .out_rgb(out_rgb));
    camera_tone #(.SAT_BOOST(0), .RED_GAIN_Q8(288), .GREEN_GAIN_Q8(240), .BLUE_GAIN_Q8(304)) balance_dut
        (.in_rgb(in_rgb), .enable(enable), .out_rgb(balance_rgb));
    camera_tone sat_dut (.in_rgb(in_rgb), .enable(enable), .out_rgb(sat_rgb));
    camera_tone #(.LIFT_ENABLE(1), .SAT_SHIFT(0)) lift_dut (.in_rgb(in_rgb), .enable(enable), .out_rgb(lift_rgb));
    camera_tone #(.SAT_BOOST(0), .RED_GAIN_Q8(288), .GREEN_GAIN_Q8(240), .BLUE_GAIN_Q8(304)) chain_balance
        (.in_rgb(in_rgb), .enable(sw[0] || sw[3]), .out_rgb(chain_balance_rgb));
    camera_tone #(.SAT_BOOST(0), .LIFT_ENABLE(1)) chain_lift
        (.in_rgb(chain_balance_rgb), .enable(sw[0] || sw[2]), .out_rgb(chain_lift_rgb));
    camera_tone #(.SAT_SHIFT(0)) chain_sat
        (.in_rgb(chain_lift_rgb), .enable(sw[0] || sw[1]), .out_rgb(chain_rgb));
`endif
    integer i, errors, previous, r, g, b, y, er, eg, eb, dr, dg, db;
    real ideal;
    integer lift_previous, expected_lift;
    function integer lift_ref;
        input integer c;
        real headroom;
        begin
            headroom = c < 128 ? c : 255-c;
            lift_ref = $rtoi(c + headroom/2.0);
        end
    endfunction
    // Independent real arithmetic for channel calibration (Q8 gain, nearest rounding).
    function integer gain_ref;
        input integer c, gain;
        real n;
        begin
            n = c * (gain / 256.0);
            gain_ref = n < 0 ? 0 : (n >= 255 ? 255 : $rtoi(n+0.5));
        end
    endfunction
    function integer clip;
        input integer n;
        begin clip = n < 0 ? 0 : (n > 255 ? 255 : n); end
    endfunction
    initial begin
        errors = 0; previous = -1; lift_previous = -1; enable = 1; sw = 0;
        for (i = 0; i < 256; i = i + 1) begin
            in_rgb = {i[7:0],i[7:0],i[7:0]}; #1;
            if (sat_rgb !== in_rgb) errors = errors + 1;
            expected_lift = lift_ref(i);
            dr = lift_rgb[7:0];
            if (dr != expected_lift || dr < lift_previous ||
                lift_rgb[23:16] !== lift_rgb[15:8] || lift_rgb[15:8] !== lift_rgb[7:0]) errors = errors + 1;
            lift_previous = dr;
            ideal = 255.0 * ((i / 255.0) ** (1.0 / 2.2));
            if (out_rgb[23:16] !== out_rgb[15:8] || out_rgb[15:8] !== out_rgb[7:0]) errors = errors + 1;
            dr = out_rgb[7:0];
            if (dr < previous || dr < ideal - 16 || dr > ideal + 2) begin errors = errors + 1; if(errors<8) $display("GRAY i=%0d out=%0d previous=%0d ideal=%f",i,dr,previous,ideal); end
            previous = out_rgb[7:0];
        end
        in_rgb = 24'h000000; #1; if (out_rgb !== 24'h000000) errors = errors + 1;
        in_rgb = 24'hffffff; #1; if (out_rgb !== 24'hffffff) errors = errors + 1;
        in_rgb = 24'h202020; #1; if (out_rgb[7:0] < 90) errors = errors + 1;
        in_rgb = 24'h808080; #1; if (out_rgb[7:0] < 180) errors = errors + 1;
        for (i = 0; i < 2000; i = i + 1) begin
            in_rgb = $random; enable = 0; #1;
            if (out_rgb !== in_rgb) errors = errors + 1;
            if (sat_rgb !== in_rgb) errors = errors + 1;
            if (lift_rgb !== in_rgb) errors = errors + 1;
            if (balance_rgb !== in_rgb) errors = errors + 1;
            enable = 1; #1;
            // Independent floating point Gamma + 1.125 saturation reference.
            r = $rtoi(255.0 * ((in_rgb[23:16] / 255.0) ** (1.0 / 2.2)) + 0.5);
            g = $rtoi(255.0 * ((in_rgb[15:8] / 255.0) ** (1.0 / 2.2)) + 0.5);
            b = $rtoi(255.0 * ((in_rgb[7:0] / 255.0) ** (1.0 / 2.2)) + 0.5);
            y = (r + 2*g + b) / 4;
            er = clip($rtoi(y + 1.125*(r-y)));
            eg = clip($rtoi(y + 1.125*(g-y)));
            eb = clip($rtoi(y + 1.125*(b-y)));
            dr = out_rgb[23:16]; dg = out_rgb[15:8]; db = out_rgb[7:0];
            if (dr < er-19 || dr > er+19 || dg < eg-19 || dg > eg+19 || db < eb-19 || db > eb+19)
                begin errors = errors + 1; if(errors<8) $display("COLOUR in=%h out=%h expected=%0d,%0d,%0d",in_rgb,out_rgb,er,eg,eb); end
            er=gain_ref(in_rgb[23:16],288); eg=gain_ref(in_rgb[15:8],240); eb=gain_ref(in_rgb[7:0],304);
            dr=balance_rgb[23:16]; dg=balance_rgb[15:8]; db=balance_rgb[7:0];
            if (dr!=er || dg!=eg || db!=eb) errors=errors+1;
            // Default mode must boost saturation 1.5x without a brightness curve.
            r = in_rgb[23:16]; g = in_rgb[15:8]; b = in_rgb[7:0]; y = (r+2*g+b)/4;
            er = clip($rtoi(y + 1.5*(r-y)));
            eg = clip($rtoi(y + 1.5*(g-y)));
            eb = clip($rtoi(y + 1.5*(b-y)));
            dr = sat_rgb[23:16]; dg = sat_rgb[15:8]; db = sat_rgb[7:0];
            if (dr != er || dg != eg || db != eb) begin
                errors = errors + 1;
                if(errors<8) $display("SATURATION in=%h out=%h expected=%0d,%0d,%0d",in_rgb,sat_rgb,er,eg,eb);
            end
            // Mild lift + 2x saturation, reference evaluated independently as real arithmetic.
            r = lift_ref(in_rgb[23:16]); g = lift_ref(in_rgb[15:8]); b = lift_ref(in_rgb[7:0]);
            y = (r+2*g+b)/4;
            er = clip($rtoi(y + 2.0*(r-y)));
            eg = clip($rtoi(y + 2.0*(g-y)));
            eb = clip($rtoi(y + 2.0*(b-y)));
            dr = lift_rgb[23:16]; dg = lift_rgb[15:8]; db = lift_rgb[7:0];
            if (dr != er || dg != eg || db != eb) begin
                errors = errors + 1;
                if(errors<8) $display("MILD_LIFT in=%h out=%h expected=%0d,%0d,%0d",in_rgb,lift_rgb,er,eg,eb);
            end
            // User controls: original, saturation, lift, both; calibration with each enhanced view; processed view.
            for (mode=0; mode<8; mode=mode+1) begin
                case(mode)
                    0: sw=4'h0; 1: sw=4'h2; 2: sw=4'h4; 3: sw=4'h6;
                    4: sw=4'ha; 5: sw=4'hc; 6: sw=4'he; 7: sw=4'h1;
                endcase
                #1;
                r = in_rgb[23:16]; g = in_rgb[15:8]; b = in_rgb[7:0];
                if (mode>=4) begin r=gain_ref(r,288); g=gain_ref(g,240); b=gain_ref(b,304); end
                if (mode==2 || mode==3 || mode==5 || mode==6 || mode==7) begin r=lift_ref(r); g=lift_ref(g); b=lift_ref(b); end
                y = (r+2*g+b)/4;
                if (mode==1 || mode==3 || mode==4 || mode==6 || mode==7) begin
                    er=clip($rtoi(y+2.0*(r-y))); eg=clip($rtoi(y+2.0*(g-y))); eb=clip($rtoi(y+2.0*(b-y)));
                end else begin er=r; eg=g; eb=b; end
                dr=chain_rgb[23:16]; dg=chain_rgb[15:8]; db=chain_rgb[7:0];
                if (dr!=er || dg!=eg || db!=eb) errors=errors+1;
            end
        end
        // Synthetic green/yellow cast matched to this candidate: (80,96,75) -> (90,90,89).
        // This checks the compensation math; it is not a measurement of the real camera.
        enable=1; in_rgb=24'h50604b; #1;
        if (balance_rgb !== 24'h5a5a59) errors=errors+1;
        in_rgb=24'h000000; #1; if (balance_rgb !== 24'h000000) errors=errors+1;
        in_rgb=24'hffffff; #1; if (balance_rgb !== 24'hffefff) errors=errors+1;
        if (errors) begin $display("TB_RESULT: FAIL camera_tone errors=%0d", errors); $finish; end
        else begin $display("TB_RESULT: PASS camera_tone 256 gray levels, 2000 colours, exact saturation/lift and bypass, eight control states, RGB gains, optional Gamma"); $finish; end
    end
endmodule
