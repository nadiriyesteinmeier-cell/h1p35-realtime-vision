// Reject display-induced blue on a cool neutral patch, retain real blue and
// exact first/last pixel geometry. Fixtures are synthetic, not camera captures.
// OLD_BLUE_INPUT compiles the released bonus02 interface for the failing control.
`timescale 1ns/1ps
module tb_blue_glare;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, vs=0, de=0, user=0, last=0;
    reg [3:0] keys=4'b1111;
    reg [23:0] pix=0, pix_q1=0, pix_q2=0;
    always @(posedge clk) begin pix_q1<=pix; pix_q2<=pix_q1; end
    wire [23:0] balanced, lifted, displayed;
`ifdef COLOR4_PROFILE
    camera_tone #(.SAT_BOOST(0), .RED_GAIN_Q8(320), .GREEN_GAIN_Q8(264), .BLUE_GAIN_Q8(256)) c0
        (.in_rgb(pix_q2), .enable(1'b1), .out_rgb(balanced));
    camera_tone #(.SAT_BOOST(0), .LIFT_ENABLE(1), .SHADOW_BOOST(1)) c1
        (.in_rgb(balanced), .enable(1'b1), .out_rgb(lifted));
`else
    camera_tone #(.SAT_BOOST(0), .RED_GAIN_Q8(288), .GREEN_GAIN_Q8(240), .BLUE_GAIN_Q8(304)) c0
        (.in_rgb(pix_q2), .enable(1'b1), .out_rgb(balanced));
    camera_tone #(.SAT_BOOST(0), .LIFT_ENABLE(1)) c1
        (.in_rgb(balanced), .enable(1'b1), .out_rgb(lifted));
`endif
    camera_tone #(.SAT_SHIFT(0)) c2
        (.in_rgb(lifted), .enable(1'b1), .out_rgb(displayed));
    contest_vision_v2 #(.WIDTH(64), .HEIGHT(32), .MIN_PIXELS(32), .LINE_INIT(32),
        .KEY_DEB(2), .KEY_LONG(1000), .UART_PERIOD(100000), .SEG_TICK(20)) dut (
        .clk(clk), .rst_n_async(rst_n), .vtc_vs(vs), .vtc_de(de), .vtc_user(user), .vtc_last(last),
        .rd_rgb(displayed),
`ifndef OLD_BLUE_INPUT
        .blue_rd_rgb(pix_q2),
`endif
        .base_vs(vs), .base_de(de), .base_data(displayed), .sw(4'b1001), .key_n(keys),
        .ref_clk(clk), .cam_clk(clk), .cam_start(1'b0),
        .tx_vs(), .tx_de(), .tx_data(), .led(), .buzzer_n(), .uart_tx(), .seg(), .sel(),
        .req_pending(), .mode_gen());
    integer errors=0, x, y, frame;
    function [23:0] sample;
        input integer f, xx, yy;
        begin
            sample=24'h606060;
            if (f==0 && xx>=8 && xx<24 && yy>=8 && yy<16) sample=24'h50648C;
            if (f==1) begin
                if (xx>=8 && xx<24 && yy>=8 && yy<16) sample=24'h1E28B4;
                if (xx>=32 && xx<48 && yy>=8 && yy<16) sample=24'hC82828;
                if (xx>=8 && xx<24 && yy>=20 && yy<28) sample=24'h28C828;
            end
            if (f==2) sample=24'hFAFAFA;
            if (f==3) sample=24'h000000;
            if (f==4 && ((xx<16 && yy<8) || (xx>=48 && yy>=24))) sample=24'h1E28B4;
        end
    endfunction
    task tick_blank;
        input integer n;
        integer k;
        begin
            @(negedge clk); de=0; user=0; last=0; pix=0;
            for(k=0;k<n;k=k+1) @(negedge clk);
        end
    endtask
    task boundary;
        begin
            tick_blank(8); vs=1;
            repeat(6) @(negedge clk);
            vs=0;
            repeat(8) @(negedge clk);
        end
    endtask
    task expect_blue;
        input integer valid_want, area_want, xmin_want, xmax_want, ymin_want, ymax_want;
        begin
            if (dut.rv[2] !== valid_want[0] || dut.cnt2 !== area_want[19:0]) begin
                $display("FAIL frame=%0d blue valid=%b area=%0d expected=%0d/%0d",frame,dut.rv[2],dut.cnt2,valid_want,area_want);
                errors=errors+1;
            end
            if(valid_want && (dut.xmin2!==xmin_want[11:0] || dut.xmax2!==xmax_want[11:0] ||
                dut.ymin2!==ymin_want[11:0] || dut.ymax2!==ymax_want[11:0])) begin
                $display("FAIL frame=%0d blue geometry %0d..%0d,%0d..%0d",frame,dut.xmin2,dut.xmax2,dut.ymin2,dut.ymax2);
                errors=errors+1;
            end
        end
    endtask
    initial begin
        tick_blank(12); rst_n=1; tick_blank(12);
        keys=4'b1101; tick_blank(8); keys=4'b1111; tick_blank(8); boundary;
        if(dut.adapt_en!==1'b1) $fatal(1,"ADAPT not enabled in setup");
        for(frame=0;frame<5;frame=frame+1) begin
            for(y=0;y<32;y=y+1) begin
                for(x=0;x<64;x=x+1) begin
                    @(negedge clk); de=1; user=(x==0 && y==0); last=(x==63); pix=sample(frame,x,y);
                end
                tick_blank(8);
            end
            tick_blank(40);
            case(frame)
                0,2,3: begin
                    expect_blue(0,0,0,0,0,0);
                    if(dut.rv[1:0]!==2'b00 || dut.cnt0!==20'd0 || dut.cnt1!==20'd0) begin
                        $display("FAIL neutral/white/black creates red/green target"); errors=errors+1;
                    end
                end
                1: begin
                    expect_blue(1,128,8,23,8,15);
                    if(dut.rv[1:0]!==2'b11 || dut.cnt0!==20'd128 || dut.cnt1!==20'd128) begin
                        $display("FAIL red/green detection changed"); errors=errors+1;
                    end
                end
                4: expect_blue(1,256,0,63,0,31);
            endcase
            boundary;
        end
        if(errors) $fatal(1,"TB_RESULT: FAIL tb_blue_glare errors=%0d",errors);
        $display("TB_RESULT: PASS tb_blue_glare (cool-neutral rejection, real RGB, white/black, edge geometry)");
        $finish;
    end
endmodule
