// tb_vtc_chk.v - checker module shared by tb_video_pos_adapter.v and tb_pos_chain.v
//
// Contains: the UNMODIFIED baseline timing generator lab1/.../vtc/uivtc.v, the DUT
// (video_pos_adapter) fed by uivtc's de/user/last, and an independent oracle.
//
// Oracle (does not use the adapter's counting method): the ground-truth pixel
// coordinates are taken from uivtc's own internal counters u_vtc.hcnt / u_vtc.vcnt,
// delayed by the 2 clocks that uivtc needs to produce O_vtc_de_valid. Expected
// sof/eol/eof come from those true coordinates, not from user/last. In addition the
// raw uivtc outputs are checked for the alignment assumed by the adapter:
//   user  <=> first valid pixel of a frame (true x=0,y=0)
//   last  <=> last valid pixel of a line   (true x=H_ACT-1)
//   user/last never appear without de
//
// Colour data: the adapter's vid_rgb is the colour of the pixel whose de was D clocks
// earlier (D = 0..4), garbage while no pixel is due. IMAGE_MODE 0: colour = {x,y} (so any
// colour/coordinate misalignment is visible), IMAGE_MODE 1: synthetic image with a red
// rectangle per frame (used by tb_pos_chain.v).
//
// Expected behaviour of the adapter on a well-formed generator: pixels before the first
// user are dropped; from the first user on every de pixel passes with its true coordinates;
// geom_err stays 0. The adapter outputs are exported (a_*) for chaining.

`timescale 1ns / 1ps

module vtc_chk #(
    parameter [31:0]  NAME       = "?",
    parameter integer H_ACT      = 8,
    parameter integer H_FRM      = 14,
    parameter integer H_SS       = 10,
    parameter integer H_SE       = 12,
    parameter integer V_ACT      = 6,
    parameter integer V_FRM      = 10,
    parameter integer V_SS       = 7,
    parameter integer V_SE       = 9,
    parameter integer D          = 0,
    parameter integer IMAGE_MODE = 0
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        check_en,

    output wire        a_de,
    output wire [23:0] a_rgb,
    output wire [11:0] a_x,
    output wire [11:0] a_y,
    output wire        a_sof,
    output wire        a_eol,
    output wire        a_eof,
    output wire        a_geom_err,

    output wire        x_eof,      // expected EOF, aligned with the a_* outputs
    output wire [7:0]  x_fidx,     // expected frame index of the pixel on the a_* outputs

    output reg  [31:0] err_cnt,
    output reg  [31:0] chk_cnt,
    output reg  [31:0] eof_cnt     // expected EOFs seen (frames completed on the output)
);

    // ---------------- baseline timing generator (unmodified source)
    wire vde, vuser, vlast;
    uivtc #(
        .H_ActiveSize(H_ACT), .H_FrameSize(H_FRM), .H_SyncStart(H_SS), .H_SyncEnd(H_SE),
        .V_ActiveSize(V_ACT), .V_FrameSize(V_FRM), .V_SyncStart(V_SS), .V_SyncEnd(V_SE)
    ) u_vtc (
        .I_vtc_rstn(rst_n), .I_vtc_clk(clk),
        .O_vtc_vs(), .O_vtc_hs(),
        .O_vtc_de_valid(vde), .O_vtc_user(vuser), .O_vtc_last(vlast)
    );

    // ---------------- ground truth: generator counters delayed by 2 clocks
    reg [11:0] hq1, hq2, vq1, vq2;
    always @(posedge clk) begin
        hq1 <= u_vtc.hcnt;
        hq2 <= hq1;
        vq1 <= u_vtc.vcnt;
        vq2 <= vq1;
    end

    // frame index: counted from the first user pixel
    reg        seen_user;
    reg [7:0]  fidx_r;
    initial begin
        seen_user = 1'b0;
        fidx_r    = 8'd0;
        err_cnt   = 0;
        chk_cnt   = 0;
        eof_cnt   = 0;
    end
    wire       new_frame = vde & vuser;
    wire [7:0] fidx_now  = new_frame ? (seen_user ? (fidx_r + 8'd1) : 8'd0) : fidx_r;
    wire       seen_now  = seen_user | new_frame;
    always @(posedge clk) begin
        if (new_frame) begin
            seen_user <= 1'b1;
            fidx_r    <= fidx_now;
        end
    end

    // ---------------- colour model
    function [23:0] colorfn;
        input [7:0]  k;
        input [11:0] x;
        input [11:0] y;
        integer ki, xi, yi;
        begin
            ki = k % 3;
            xi = x;
            yi = y;
            if (IMAGE_MODE == 0) begin
                colorfn = {x, y};
            end
            else begin
                colorfn = 24'h404040;
                if      (ki == 0 && xi >= 100 && xi <= 299 && yi >= 50  && yi <= 149) colorfn = 24'hFF2010;
                else if (ki == 1 && xi >= 900 && xi <= 1000 && yi >= 600 && yi <= 700) colorfn = 24'hFF2010;
                else if (ki == 2 && xi >= 0   && xi <= 15  && yi >= 0   && yi <= 15)  colorfn = 24'hFF2010;
                else if (xi >= 400 && xi <= 800 && yi >= 300 && yi <= 400)           colorfn = 24'h10FF20;   // green: not a hit
                else if (xi >= 200 && xi <= 210 && yi >= 300 && yi <= 310)           colorfn = 24'h4F2020;   // R = 79: just below R_MIN
            end
        end
    endfunction

    wire [23:0] c0 = colorfn(fidx_now, hq2, vq2);

    localparam integer DI = (D == 0) ? 1 : D;
    reg        vl [1:4];
    reg [23:0] cl [1:4];
    always @(posedge clk) begin
        vl[1] <= vde;   cl[1] <= c0;
        vl[2] <= vl[1]; cl[2] <= cl[1];
        vl[3] <= vl[2]; cl[3] <= cl[2];
        vl[4] <= vl[3]; cl[4] <= cl[3];
    end
    wire        v_d = (D == 0) ? vde : vl[DI];
    wire [23:0] c_d = (D == 0) ? c0  : cl[DI];

    reg [23:0] gcnt;
    initial gcnt = 24'd0;
    always @(posedge clk) gcnt <= gcnt + 24'h010203;
    wire [23:0] rgb_in = v_d ? c_d : (24'hC0FFEE ^ gcnt);

    // ---------------- DUT
    video_pos_adapter #(.WIDTH(H_ACT), .HEIGHT(V_ACT), .SYNC_DELAY(D)) dut (
        .clk(clk), .rst_n(rst_n),
        .vid_de(vde), .vid_user(vuser), .vid_last(vlast), .vid_rgb(rgb_in),
        .out_de(a_de), .out_rgb(a_rgb), .out_x(a_x), .out_y(a_y),
        .out_sof(a_sof), .out_eol(a_eol), .out_eof(a_eof),
        .frame_active(), .geom_err(a_geom_err)
    );

    // ---------------- expected record, delayed D+1 clocks to meet the DUT outputs
    wire        e_pass = vde & seen_now;
    wire        e_eol  = e_pass & (hq2 == (H_ACT - 1));
    wire        e_sof  = e_pass & (hq2 == 0) & (vq2 == 0);
    wire        e_eof  = e_eol & (vq2 == (V_ACT - 1));
    wire [59:0] rec0   = {e_pass,
                          e_pass ? hq2 : 12'd0,
                          e_pass ? vq2 : 12'd0,
                          e_sof, e_eol, e_eof,
                          e_pass ? c0 : 24'd0,
                          e_pass ? fidx_now : 8'd0};
    reg [59:0] rc [1:8];
    always @(posedge clk) begin
        rc[1] <= rec0;
        rc[2] <= rc[1];
        rc[3] <= rc[2];
        rc[4] <= rc[3];
        rc[5] <= rc[4];
        rc[6] <= rc[5];
        rc[7] <= rc[6];
        rc[8] <= rc[7];
    end
    wire [59:0] ex = rc[D + 1];
    assign x_eof  = ex[32];
    assign x_fidx = ex[7:0];

    // ---------------- checks (sampled at negedge, DUT/generator only change at posedge)
    task bad;
        input [191:0] what;
        input [31:0]  exp_v;
        input [31:0]  act_v;
        begin
            err_cnt = err_cnt + 1;
            if (err_cnt <= 12)
                $display("MISMATCH[%0s] t=%0t %0s expected=%0d actual=%0d (vde=%b user=%b last=%b true x=%0d y=%0d)",
                         NAME, $time, what, exp_v, act_v, vde, vuser, vlast, hq2, vq2);
            if (err_cnt >= 100) begin
                $display("TB_RESULT: FAIL tb_video_pos_adapter[%0s] aborted after %0d mismatches", NAME, err_cnt);
                $finish;
            end
        end
    endtask

    always @(negedge clk) begin
        if (check_en) begin
            chk_cnt = chk_cnt + 1;
            if (ex[32]) eof_cnt = eof_cnt + 1;
            if (a_de      !== ex[59])     bad("out_de",  ex[59],    a_de);
            if (a_x       !== ex[58:47])  bad("out_x",   ex[58:47], a_x);
            if (a_y       !== ex[46:35])  bad("out_y",   ex[46:35], a_y);
            if (a_sof     !== ex[34])     bad("out_sof", ex[34],    a_sof);
            if (a_eol     !== ex[33])     bad("out_eol", ex[33],    a_eol);
            if (a_eof     !== ex[32])     bad("out_eof", ex[32],    a_eof);
            if (a_rgb     !== ex[31:8])   bad("out_rgb", ex[31:8],  a_rgb);
            if (a_geom_err !== 1'b0)      bad("geom_err", 0,        a_geom_err);

            // alignment assumptions about the raw baseline generator
            if (vde === 1'b1 && vuser === 1'b1 && !(hq2 == 0 && vq2 == 0))
                bad("user_not_on_first_pixel", 0, hq2);
            if (vde === 1'b1 && seen_now && hq2 == 0 && vq2 == 0 && vuser !== 1'b1)
                bad("no_user_on_first_pixel", 1, vuser);
            if (vde === 1'b1 && vlast === 1'b1 && hq2 != (H_ACT - 1))
                bad("last_not_on_last_pixel", H_ACT - 1, hq2);
            if (vde === 1'b1 && hq2 == (H_ACT - 1) && vlast !== 1'b1)
                bad("no_last_on_last_pixel", 1, vlast);
            if (vde !== 1'b1 && (vuser === 1'b1 || vlast === 1'b1))
                bad("user_or_last_without_de", 0, vuser);
        end
    end

endmodule
