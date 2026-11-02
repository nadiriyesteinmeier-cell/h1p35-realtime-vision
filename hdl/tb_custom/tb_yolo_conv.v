// tb_yolo_conv.v - bit-exact comparison of rtl_custom/yolo_conv_core.v with the integer reference (tools/yolo/qref.py)
//
// One run checks one case: +CASE=<path prefix of the files written by tools/yolo/gen_conv_vectors.py>. The testbench
//   * loads the activation, weight and parameter memories and the layer configuration, pre-fills the output memory with 0x55,
//   * models the three read memories with the contract of the core (1-clock synchronous read) and the output memory write port,
//   * starts the core, waits for done and compares EVERY byte of the output memory with the expected image (a stray write or a missing write shows up
//     as a mismatch of the 0x55 pattern), checks that every output element was written exactly once and that the core did not write anywhere else,
//   * prints the number of clocks and the utilisation of the multiply-accumulate lanes (useful MACs / (clocks * lanes)).
// Run (see tools/yolo/run_conv_tests.py which generates the vectors, compiles for LANES = 8 and 16 and runs all cases):
//   iverilog -g2005 -P tb_yolo_conv.LANES=16 -o sim.vvp tb_yolo_conv.v ../rtl_custom/yolo_conv_core.v ; vvp sim.vvp +CASE=<prefix>
// Final line: TB_RESULT: PASS tb_yolo_conv <case> ...  or  FAIL

`timescale 1ns / 1ps

module tb_yolo_conv;

    parameter integer LANES = 16;
    localparam integer AW = 20;
    localparam integer WW = 14;
    localparam integer PW = 11;
    localparam integer ACT_DEPTH = 1 << 16;
    localparam integer WT_DEPTH  = 1 << 14;
    localparam integer PM_DEPTH  = 2048;
    localparam integer OUT_DEPTH = 1 << 16;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    reg  [11:0] cfg_h, cfg_w;
    reg  [10:0] cfg_cin, cfg_cout;
    reg         cfg_k3, cfg_act, cfg_pool;
    reg  [AW-1:0] cfg_in_base, cfg_in_row, cfg_in_pix, cfg_out_base, cfg_out_row, cfg_out_pix;
    reg         start;
    wire        busy, done;
    wire [AW-1:0] act_addr;
    wire [7:0]  act_data;
    wire [WW-1:0] wt_addr;
    wire [8*LANES-1:0] wt_data;
    wire [PW-1:0] pm_addr;
    wire [55:0] pm_data;
    wire        out_we;
    wire [AW-1:0] out_addr;
    wire [7:0]  out_data;
    wire [AW-1:0] out_rd_addr;
    wire [7:0]  out_rd_data;

    yolo_conv_core #(.LANES(LANES), .AW(AW), .WW(WW), .PW(PW)) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_h(cfg_h), .cfg_w(cfg_w), .cfg_cin(cfg_cin), .cfg_cout(cfg_cout), .cfg_k3(cfg_k3), .cfg_act(cfg_act), .cfg_pool(cfg_pool),
        .cfg_in_base(cfg_in_base), .cfg_in_row(cfg_in_row), .cfg_in_pix(cfg_in_pix),
        .cfg_out_base(cfg_out_base), .cfg_out_row(cfg_out_row), .cfg_out_pix(cfg_out_pix),
        .start(start), .busy(busy), .done(done),
        .act_addr(act_addr), .act_data(act_data), .wt_addr(wt_addr), .wt_data(wt_data), .pm_addr(pm_addr), .pm_data(pm_data),
        .out_we(out_we), .out_addr(out_addr), .out_data(out_data), .out_rd_addr(out_rd_addr), .out_rd_data(out_rd_data)
    );

    // ---------------- memories
    reg [7:0]          act_mem [0:ACT_DEPTH-1];
    reg [8*LANES-1:0]  wt_mem  [0:WT_DEPTH-1];
    reg [55:0]         pm_mem  [0:PM_DEPTH-1];
    reg [7:0]          out_mem [0:OUT_DEPTH-1];
    reg [7:0]          exp_mem [0:OUT_DEPTH-1];
    reg [7:0]          wcnt    [0:OUT_DEPTH-1];
    reg [7:0]          act_q;
    reg [8*LANES-1:0]  wt_q;
    reg [55:0]         pm_q;
    reg [7:0]          out_rq;
    assign out_rd_data = out_rq;
    assign act_data = act_q;
    assign wt_data  = wt_q;
    assign pm_data  = pm_q;

    integer n_writes, n_oob, n_double, i;
    reg     done_seen;                                   // done is a 1-clock pulse
    initial done_seen = 1'b0;
    always @(posedge clk) if (done) done_seen <= 1'b1;
    always @(posedge clk) begin
        act_q <= act_mem[act_addr[15:0]];
        wt_q  <= wt_mem[wt_addr];
        pm_q  <= pm_mem[pm_addr];
        out_rq <= out_mem[out_rd_addr[15:0]];
        if (out_we) begin
            n_writes = n_writes + 1;
            if (out_addr >= OUT_DEPTH) n_oob = n_oob + 1;
            else begin
                out_mem[out_addr] <= out_data;
                if (wcnt[out_addr] != 8'd0) n_double = n_double + 1;
                wcnt[out_addr] <= wcnt[out_addr] + 8'd1;
            end
        end
    end

    // ---------------- run
    reg [8*200-1:0] prefix;
    reg [8*220-1:0] fn;
    integer fd, r, act_size, wt_size, out_size, mism, cycles, h_i, w_i, cin_i, cout_i, k3_i, actf_i, ib, ir, ip, ob, orow, op, pool_i;
    integer macs;
    initial begin
        if (!$value$plusargs("CASE=%s", prefix)) begin $display("TB_RESULT: FAIL tb_yolo_conv (no +CASE=)"); $finish; end
        $sformat(fn, "%0s_cfg.txt", prefix);
        fd = $fopen(fn, "r");
        if (fd == 0) begin $display("TB_RESULT: FAIL tb_yolo_conv cannot open %0s", fn); $finish; end
        r = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d", h_i, w_i, cin_i, cout_i, k3_i, actf_i, ib, ir, ip, ob, orow, op, act_size, wt_size, out_size, pool_i);
        $fclose(fd);
        for (i = 0; i < OUT_DEPTH; i = i + 1) begin out_mem[i] = 8'h55; wcnt[i] = 8'd0; exp_mem[i] = 8'h55; end
        for (i = 0; i < ACT_DEPTH; i = i + 1) act_mem[i] = 8'h00;
        for (i = 0; i < WT_DEPTH; i = i + 1) wt_mem[i] = {(8*LANES){1'b0}};
        for (i = 0; i < PM_DEPTH; i = i + 1) pm_mem[i] = 56'd0;
        $sformat(fn, "%0s_act.hex", prefix); $readmemh(fn, act_mem);
        $sformat(fn, "%0s_wt.hex", prefix);  $readmemh(fn, wt_mem);
        $sformat(fn, "%0s_pm.hex", prefix);  $readmemh(fn, pm_mem);
        $sformat(fn, "%0s_exp.hex", prefix); $readmemh(fn, exp_mem);
        n_writes = 0; n_oob = 0; n_double = 0;
        cfg_h = h_i; cfg_w = w_i; cfg_cin = cin_i; cfg_cout = cout_i; cfg_k3 = k3_i; cfg_act = actf_i; cfg_pool = pool_i;
        cfg_in_base = ib; cfg_in_row = ir; cfg_in_pix = ip; cfg_out_base = ob; cfg_out_row = orow; cfg_out_pix = op;
        start = 1'b0;
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);
        start = 1'b1; @(negedge clk); start = 1'b0;
        cycles = 0;
        while (!done_seen && cycles < 3000000) begin @(negedge clk); cycles = cycles + 1; end
        repeat (4) @(negedge clk);
        mism = 0;
        for (i = 0; i < out_size; i = i + 1)
            if (out_mem[i] !== exp_mem[i]) begin
                mism = mism + 1;
                if (mism <= 8) $display("MISMATCH %0s byte %0d: got %02x expected %02x", prefix, i, out_mem[i], exp_mem[i]);
            end
        macs = h_i * w_i * cout_i * cin_i * ((k3_i != 0) ? 9 : 1);
        if (!done_seen) begin mism = mism + 1; $display("MISMATCH %0s: done never came (timeout)", prefix); end
        if (n_writes != h_i * w_i * cout_i) begin mism = mism + 1; $display("MISMATCH %0s: %0d writes, expected %0d", prefix, n_writes, h_i * w_i * cout_i); end
        if (n_oob != 0 || (n_double != 0 && pool_i == 0)) begin mism = mism + 1; $display("MISMATCH %0s: %0d writes outside the image, %0d addresses written twice", prefix, n_oob, n_double); end
        if (pool_i != 0) begin                                       // every pooled element is written once per pixel of its 2x2 window = 4 times
            n_double = 0;
            for (i = 0; i < OUT_DEPTH; i = i + 1) if (wcnt[i] != 8'd0 && wcnt[i] != 8'd4) n_double = n_double + 1;
            if (n_double != 0) begin mism = mism + 1; $display("MISMATCH %0s: %0d pooled elements were not written exactly 4 times", prefix, n_double); end
        end
        if (busy) begin mism = mism + 1; $display("MISMATCH %0s: busy still high", prefix); end
        if (mism == 0) $display("TB_RESULT: PASS tb_yolo_conv %0s lanes=%0d clocks=%0d macs=%0d utilisation=%0d.%02d%%", prefix, LANES, cycles, macs,
                                (macs * 100) / (cycles * LANES), ((macs * 10000) / (cycles * LANES)) % 100);
        else           $display("TB_RESULT: FAIL tb_yolo_conv %0s mismatches=%0d", prefix, mism);
        $finish;
    end

endmodule
