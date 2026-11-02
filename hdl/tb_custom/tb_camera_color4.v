// Synthetic display-profile checks; these are not measurements of the SC500CS.
// OLD_PROFILE runs the same acceptance checks against the previous settings.
`timescale 1ns/1ps
module tb_camera_color4;
    reg [23:0] pix=0;
    reg [3:0] sw=0;
    wire [23:0] balanced, lifted, displayed, shadow_gray;
`ifdef OLD_PROFILE
    camera_tone #(.SAT_BOOST(0), .RED_GAIN_Q8(288), .GREEN_GAIN_Q8(240), .BLUE_GAIN_Q8(304)) balance
        (.in_rgb(pix), .enable(sw[0] || sw[3]), .out_rgb(balanced));
    camera_tone #(.SAT_BOOST(0), .LIFT_ENABLE(1)) lift
        (.in_rgb(balanced), .enable(sw[0] || sw[2]), .out_rgb(lifted));
    camera_tone #(.SAT_BOOST(0), .LIFT_ENABLE(1)) gray_lift
        (.in_rgb(pix), .enable(1'b1), .out_rgb(shadow_gray));
`else
    camera_tone #(.SAT_BOOST(0), .RED_GAIN_Q8(320), .GREEN_GAIN_Q8(264), .BLUE_GAIN_Q8(256)) balance
        (.in_rgb(pix), .enable(sw[0] || sw[3]), .out_rgb(balanced));
    camera_tone #(.SAT_BOOST(0), .LIFT_ENABLE(1), .SHADOW_BOOST(1)) lift
        (.in_rgb(balanced), .enable(sw[0] || sw[2]), .out_rgb(lifted));
    camera_tone #(.SAT_BOOST(0), .LIFT_ENABLE(1), .SHADOW_BOOST(1)) gray_lift
        (.in_rgb(pix), .enable(1'b1), .out_rgb(shadow_gray));
`endif
    camera_tone #(.SAT_SHIFT(0)) sat
        (.in_rgb(lifted), .enable(sw[0] || sw[1]), .out_rgb(displayed));
    integer i, mode, previous=-1, luma, errors=0;
    reg [23:0] processed;
    task check;
        input condition;
        input [511:0] label;
        begin
            if(condition!==1'b1) begin
                $display("FAIL %0s: in=%h sw=%h out=%h",label,pix,sw,displayed);
                errors=errors+1;
            end
        end
    endtask
    initial begin
        sw=4'he; pix=24'h3c465a; #1;
        luma=(displayed[23:16]+2*displayed[15:8]+displayed[7:0])/4;
        $display("PROFILE dark cool fixture out=%h weighted brightness=%0d",displayed,luma);
        check(luma>=135,"dark colour brightness");
        check(displayed[7:0]<=displayed[15:8]+42,"limit blue excess on fixture");
        // Known channel-gain anchor, measured before saturation/brightness.
        pix=24'h404040; #1;
        check(balanced===24'h504240,"RGB calibration anchor");
        for(i=0;i<256;i=i+1) begin
            pix={i[7:0],i[7:0],i[7:0]}; #1;
            check(shadow_gray[23:16]===shadow_gray[15:8] && shadow_gray[15:8]===shadow_gray[7:0],"neutral lift");
            check(previous<0 || $signed({1'b0,shadow_gray[7:0]})>=previous,"monotonic lift");
            previous=shadow_gray[7:0];
            // Above midpoint the old highlight curve must remain unchanged.
            if(i>=128) check(shadow_gray[7:0]==i+(255-i)/2,"highlight detail unchanged");
            if(i==32) check(shadow_gray[7:0]==64,"shadow lift anchor 32");
            if(i==64) check(shadow_gray[7:0]==127,"shadow lift anchor 64");
        end
        pix=24'h000000; #1; check(displayed===24'h000000,"black endpoint");
        pix=24'hffffff; #1; check(displayed===24'hffffff,"white endpoint");
        pix=24'hc82828; #1; check(displayed[23:16]>displayed[15:8]+100 && displayed[23:16]>displayed[7:0]+100,"red retained");
        pix=24'h28c828; #1; check(displayed[15:8]>displayed[23:16]+100 && displayed[15:8]>displayed[7:0]+100,"green retained");
        pix=24'h1e28b4; #1; check(displayed[7:0]>displayed[23:16]+100 && displayed[7:0]>displayed[15:8]+100,"blue retained");
        for(i=0;i<2000;i=i+1) begin
            pix=$random; sw=0; #1; check(displayed===pix,"raw bypass");
            // SW1 processing view must match all three independent enhancements ON.
            sw=4'he; #1; processed=displayed;
            sw=4'h1; #1; check(displayed===processed,"processed-view controls");
            for(mode=0;mode<8;mode=mode+1) begin
                sw=mode<<1; #1;
                if(!sw[3]) check(balanced===pix,"SW4 calibration bypass");
                if(!sw[2]) check(lifted===balanced,"SW3 lift bypass");
                if(!sw[1]) check(displayed===lifted,"SW2 saturation bypass");
                check((^displayed)!==1'bx,"no undefined output");
            end
        end
        if(errors) $fatal(1,"TB_RESULT: FAIL tb_camera_color4 errors=%0d",errors);
        $display("TB_RESULT: PASS tb_camera_color4: brightness/blue fixture, neutral monotonic lift, highlight curve, RGB targets, 2000 colours/control bypass");
        $finish;
    end
endmodule
