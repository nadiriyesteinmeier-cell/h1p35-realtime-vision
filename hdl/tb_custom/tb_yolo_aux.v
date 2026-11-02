// tb_yolo_aux.v - bit-exact comparison of rtl_custom/yolo_aux_core.v (copy / upsample x2 / max-pool s2 / s1) with the integer reference (tools/yolo/qref.py)
//
// One run checks one case: +CASE=<path prefix of the files written by tools/yolo/gen_aux_vectors.py>:
//   <prefix>_cfg.txt  mode h w c in_base in_row in_pix out_base out_row out_pix in_size out_size   (decimal; h / w / c = OUTPUT map)
//   <prefix>_in.hex   input memory (one byte per line)
//   <prefix>_exp.hex  expected content of the output memory: the reference output at the stored positions, 0x55 everywhere else
// The testbench models the read memory with the contract of the core (1-clock synchronous read), pre-fills the output memory with 0x55 (a stray write shows as a
// mismatch), starts the core, waits for done, compares EVERY byte of the output memory, checks that every output element was written exactly once
// (h * w * c writes, none twice, none outside the memory) and that busy is low again.
// Final line: TB_RESULT: PASS tb_yolo_aux <case> mode=<m> clocks=<n>   or   FAIL

`timescale 1ns / 1ps

module tb_yolo_aux;

    localparam integer AW = 20;
    localparam integer DEPTH = 1 << 16;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    reg  [11:0] cfg_h, cfg_w;
    reg  [10:0] cfg_c;
    reg  [2:0]  cfg_mode;
    reg  [AW-1:0] cfg_in_base, cfg_in_row, cfg_in_pix, cfg_out_base, cfg_out_row, cfg_out_pix;
    reg         start;
    wire        busy, done;
    wire [AW-1:0] rd_addr;
    wire [7:0]  rd_data;
    wire        out_we;
    wire [AW-1:0] out_addr;
    wire [7:0]  out_data;

    yolo_aux_core #(.AW(AW)) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_h(cfg_h), .cfg_w(cfg_w), .cfg_c(cfg_c), .cfg_mode(cfg_mode),
        .cfg_in_base(cfg_in_base), .cfg_in_row(cfg_in_row), .cfg_in_pix(cfg_in_pix),
        .cfg_out_base(cfg_out_base), .cfg_out_row(cfg_out_row), .cfg_out_pix(cfg_out_pix),
        .start(start), .busy(busy), .done(done),
        .rd_addr(rd_addr), .rd_data(rd_data), .out_we(out_we), .out_addr(out_addr), .out_data(out_data)
    );

    reg [7:0] in_mem  [0:DEPTH-1];
    reg [7:0] out_mem [0:DEPTH-1];
    reg [7:0] exp_mem [0:DEPTH-1];
    reg [7:0] wcnt    [0:DEPTH-1];
    reg [7:0] in_q;
    assign rd_data = in_q;

    integer n_writes, n_oob, n_double, i;
    reg     done_seen;
    integer n_at_done;                                   // writes performed when done is first seen (sampled on the falling edge: no race with the write counter)
    initial begin done_seen = 1'b0; n_at_done = -1; end
    always @(posedge clk) if (done) done_seen <= 1'b1;
    always @(negedge clk) if (done && n_at_done < 0) n_at_done = n_writes;
    always @(posedge clk) begin
        in_q <= in_mem[rd_addr[15:0]];
        if (out_we) begin
            n_writes = n_writes + 1;
            if (out_addr >= DEPTH) n_oob = n_oob + 1;
            else begin
                out_mem[out_addr] <= out_data;
                if (wcnt[out_addr] != 8'd0) n_double = n_double + 1;
                wcnt[out_addr] <= wcnt[out_addr] + 8'd1;
            end
        end
    end

    reg [8*200-1:0] prefix;
    reg [8*220-1:0] fn;
    integer fd, r, in_size, out_size, mism, cycles, mode_i, h_i, w_i, c_i, ib, ir, ip, ob, orow, op;
    initial begin
        if (!$value$plusargs("CASE=%s", prefix)) begin $display("TB_RESULT: FAIL tb_yolo_aux (no +CASE=)"); $finish; end
        $sformat(fn, "%0s_cfg.txt", prefix);
        fd = $fopen(fn, "r");
        if (fd == 0) begin $display("TB_RESULT: FAIL tb_yolo_aux cannot open %0s", fn); $finish; end
        r = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d", mode_i, h_i, w_i, c_i, ib, ir, ip, ob, orow, op, in_size, out_size);
        $fclose(fd);
        for (i = 0; i < DEPTH; i = i + 1) begin in_mem[i] = 8'h00; out_mem[i] = 8'h55; exp_mem[i] = 8'h55; wcnt[i] = 8'd0; end
        $sformat(fn, "%0s_in.hex", prefix);  $readmemh(fn, in_mem);
        $sformat(fn, "%0s_exp.hex", prefix); $readmemh(fn, exp_mem);
        n_writes = 0; n_oob = 0; n_double = 0;
        cfg_mode = mode_i; cfg_h = h_i; cfg_w = w_i; cfg_c = c_i;
        cfg_in_base = ib; cfg_in_row = ir; cfg_in_pix = ip; cfg_out_base = ob; cfg_out_row = orow; cfg_out_pix = op;
        start = 1'b0;
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);
        start = 1'b1; @(negedge clk); start = 1'b0;
        cycles = 0;
        while (!done_seen && cycles < 1000000) begin @(negedge clk); cycles = cycles + 1; end
        repeat (4) @(negedge clk);
        mism = 0;
        for (i = 0; i < out_size; i = i + 1)
            if (out_mem[i] !== exp_mem[i]) begin
                mism = mism + 1;
                if (mism <= 8) $display("MISMATCH %0s byte %0d: got %02x expected %02x", prefix, i, out_mem[i], exp_mem[i]);
            end
        if (!done_seen) begin mism = mism + 1; $display("MISMATCH %0s: done never came (timeout)", prefix); end
        if (n_writes != h_i * w_i * c_i) begin mism = mism + 1; $display("MISMATCH %0s: %0d writes, expected %0d", prefix, n_writes, h_i * w_i * c_i); end
        if (done_seen && n_at_done != h_i * w_i * c_i) begin mism = mism + 1; $display("MISMATCH %0s: done came after %0d of %0d writes", prefix, n_at_done, h_i * w_i * c_i); end
        // throughput guard: one tap per clock (1 tap per element for copy / upsample, 4 for the pools) plus a fixed pipeline latency
        if (done_seen && cycles > h_i * w_i * c_i * ((mode_i == 2 || mode_i == 3) ? 4 : 1) + 12) begin mism = mism + 1; $display("MISMATCH %0s: %0d clocks, more than one tap per clock allows", prefix, cycles); end
        if (n_oob != 0 || n_double != 0) begin mism = mism + 1; $display("MISMATCH %0s: %0d writes outside the memory, %0d addresses written twice", prefix, n_oob, n_double); end
        if (busy) begin mism = mism + 1; $display("MISMATCH %0s: busy still high", prefix); end
        if (mism == 0) $display("TB_RESULT: PASS tb_yolo_aux %0s mode=%0d clocks=%0d", prefix, mode_i, cycles);
        else           $display("TB_RESULT: FAIL tb_yolo_aux %0s mismatches=%0d", prefix, mism);
        $finish;
    end

endmodule
