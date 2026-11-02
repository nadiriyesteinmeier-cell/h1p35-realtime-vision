// tb_baseline_readout.v - measures, on the UNMODIFIED baseline sources, where each frame-buffer pixel ends up on the
// hdmi_mixer output (the stream that goes into hdmi_tx in lab1 / in the bypass path of contest_work*).
//
// DUT chain (all lab1 files, only read): uivtc (1280x720, 1650x750) -> hdmi_mixer + video_out + w128_d512_fifo (soft FIFO,
// NOREG, read latency 1). The DDR is replaced by a behavioural model: every read burst word is returned LAT clocks after the
// request; the frame buffer holds the pixel INDEX (y*1280+x) as its 24-bit colour, packed exactly like the baseline
// (16 pixels per three 128-bit words, MSB first).
//
// For every pixel on the mixer output (O_hdmi_de = 1) the testbench knows its screen position (x,y) (counted on de) and the
// pixel index it shows; it prints, for a few lines of the second frame, the index offset  shown - (y*1280 + x)  at the left
// and right ends of the line, and whether the colour is 0 (black) there. A line that is shifted right by d pixels shows:
// the first d positions black (or old data), then offset = -d.
//
// Run:  iverilog -g2005 -o sim_readout.vvp tb_baseline_readout.v ../lab1/user_source/hdl_source/video_out.v \
//         ../lab1/user_source/hdl_source/hdmi_mixer.v ../lab1/user_source/hdl_source/vtc/uivtc.v \
//         ../lab1/user_source/ip_source/w128_d512_fifo/w128_d512_fifo.v ../lab1/user_source/ip_source/w128_d512_fifo/soft_fifo_al_4057d6b76aa6.v
//       vvp sim_readout.vvp

`timescale 1ns / 1ps

module tb_baseline_readout;

    localparam integer W = 1280;
    localparam integer H = 720;
    localparam integer LAT = 40;                 // DDR read latency in ddr_clk cycles

    reg pix_clk, ddr_clk, rst_n;
    initial begin pix_clk = 1'b0; ddr_clk = 1'b0; end
    always #6.667 pix_clk = ~pix_clk;
    always #7.5   ddr_clk = ~ddr_clk;

    // ---------------- timing generator
    wire vs, hs, de, user, last;
    uivtc #(.H_ActiveSize(1280), .H_FrameSize(1650), .H_SyncStart(1390), .H_SyncEnd(1430),
            .V_ActiveSize(720),  .V_FrameSize(750),  .V_SyncStart(725),  .V_SyncEnd(730)) u_vtc (
        .I_vtc_rstn(rst_n), .I_vtc_clk(pix_clk),
        .O_vtc_vs(vs), .O_vtc_hs(hs), .O_vtc_de_valid(de), .O_vtc_user(user), .O_vtc_last(last)
    );

    // ---------------- video_out + DDR model
    wire        rd_en_ddr;
    wire [24:0] ddr_addr;
    reg         rd_valid;
    reg  [127:0] rd_data;
    wire [23:0] vdata;
    wire        win_rd_en;

    video_out u_vo (
        .I_rst_n(rst_n),
        .I_ddr_clk(ddr_clk),
        .O_video_out_rd_busy(),
        .I_video_in_wr_busy(1'b0),
        .I_video_out_rp(2'd0),
        .O_ddr_user_rd_en(rd_en_ddr),
        .O_ddr_user_addr(ddr_addr),
        .I_ddr_user_ready(1'b1),
        .I_ddr_user_rd_valid(rd_valid),
        .I_ddr_user_rd_data(rd_data),
        .I_dsi_clk(pix_clk),
        .I_video_vsync(~vs),
        .I_video_rd_en(win_rd_en),
        .O_vdieo_data(vdata)
    );

    // frame buffer content: pixel p = {p[23:0]}; word w of the stream = bits 128w..128w+127 (MSB first):
    // three words hold 16 pixels (384 bits), so word w uses the 384-bit group g = w/3 and the slice w%3
    function [127:0] word_of;
        input integer w;
        integer g, s, j, base;
        reg [383:0] grp;
        reg [23:0]  pv;
        begin
            g = w / 3;
            s = w % 3;
            base = 16 * g;
            for (j = 0; j < 16; j = j + 1) begin
                pv = base + j;
                grp[383 - 24 * j -: 24] = pv;
            end
            case (s)
                0: word_of = grp[383:256];
                1: word_of = grp[255:128];
                default: word_of = grp[127:0];
            endcase
        end
    endfunction

    // request pipeline: circular buffer, the data of a request returns LAT ddr clocks later
    reg [24:0] req_addr [0:63];
    reg        req_vld  [0:63];
    integer    wp, rp, i;
    initial begin wp = 0; for (i = 0; i < 64; i = i + 1) begin req_vld[i] = 1'b0; req_addr[i] = 25'd0; end end
    always @(posedge ddr_clk) begin
        req_vld[wp]  <= rd_en_ddr;
        req_addr[wp] <= ddr_addr;
        rp = (wp + 64 - (LAT - 1)) % 64;
        rd_valid <= req_vld[rp];
        rd_data  <= req_vld[rp] ? word_of(req_addr[rp] / 8) : 128'd0;
        wp = (wp + 1) % 64;
    end

    // ---------------- mixer: its rd_en is de, its output is what hdmi_tx gets
    wire        mvs, mhs, mde;
    wire [23:0] mdata;
    hdmi_mixer #(.H_OFFSET(0), .V_OFFSET(0), .IMG_WIDTH(1280), .IMG_HEIGHT(720), .DEBUG_MODE(0)) u_mix (
        .I_clk(pix_clk), .I_rst_n(rst_n),
        .I_video_vsync(vs), .I_video_hsync(hs), .I_video_de(de), .I_video_user(user), .I_video_last(last),
        .I_debug_status(4'd0),
        .O_video_rd_en(win_rd_en), .I_video_rd_data(vdata),
        .O_hdmi_vsync(mvs), .O_hdmi_hsync(mhs), .O_hdmi_de(mde), .O_hdmi_data(mdata)
    );

    // ---------------- observation on the mixer output
    integer xo, yo, frame;
    reg     mde_q, mvs_q;
    integer off, row_start_black, nblack, lines_seen;
    integer dleft [0:7];
    integer dright[0:7];
    integer l;
    reg [23:0] firstpix [0:7];
    initial begin xo = 0; yo = 0; frame = 0; mde_q = 1'b0; mvs_q = 1'b0; lines_seen = 0; end

    always @(posedge pix_clk) begin
        mde_q <= mde;
        mvs_q <= mvs;
        if (mvs && !mvs_q) begin frame = frame + 1; yo = 0; xo = 0; end
        if (mde) begin
            if (frame >= 3 && yo >= 100 && yo < 108) begin
                // record the first and the last 6 positions of the line
                if (xo < 6)         begin dleft [xo]       = mdata - (yo * W + xo); firstpix[xo] = mdata; end
                if (xo >= W - 6)    begin dright[xo - (W-6)] = mdata - (yo * W + xo); end
            end
            xo = xo + 1;
        end
        if (!mde && mde_q) begin
            if (frame >= 3 && yo >= 100 && yo < 108) begin
                $write("line %0d  left positions 0..5: offset/value ", yo);
                for (l = 0; l < 6; l = l + 1) $write("[%0d: %0d (0x%06h)] ", l, dleft[l], firstpix[l]);
                $write("\n         right positions 1274..1279: offset ");
                for (l = 0; l < 6; l = l + 1) $write("%0d ", dright[l]);
                $write("\n");
            end
            xo = 0;
            yo = yo + 1;
        end
    end

    initial begin
        rst_n = 1'b0;
        repeat (20) @(posedge pix_clk);
        rst_n = 1'b1;
        wait (frame == 4);
        $display("tb_baseline_readout: done (frames observed: %0d)", frame);
        $finish;
    end

endmodule
