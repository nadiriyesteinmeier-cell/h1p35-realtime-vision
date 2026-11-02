// tb_yolo_decode.v - bit-exact comparison of rtl_custom/yolo_decode.v (head decode, candidate memory, NMS) with tools/yolo/decode_ref.py
//
// +CASE=<prefix of the files written by tools/yolo/gen_decode_vectors.py>:  <prefix>_heads.hex (bank D bytes: head 1 then head 2), <prefix>_exp.hex (box count, then one
// 60-bit word per box). The testbench models the read memory with the contract of the module (rd_addr registered in the module, the memory samples it on the next clock),
// starts the decoder twice (the second run on the same data must give the same boxes: restart without reset), waits for done and compares res_n and every box.
// Final line: TB_RESULT: PASS tb_yolo_decode <case> boxes=<n> clocks=<first run>   or   FAIL

`timescale 1ns / 1ps

module tb_yolo_decode;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    reg         start;
    wire        busy, done;
    wire [19:0] rd_addr;
    reg  [7:0]  rd_q;
    reg  [3:0]  res_idx;
    wire [59:0] res_data;
    wire [3:0]  res_n;

    yolo_decode dut (.clk(clk), .rst_n(rst_n), .anc1({8'd40, 8'd32, 8'd28, 8'd20, 8'd16, 8'd12}), .anc2({8'd12, 8'd14, 8'd10, 8'd8, 8'd6, 8'd4}), .start(start), .busy(busy), .done(done), .rd_addr(rd_addr), .rd_data(rd_q),
                     .res_idx(res_idx), .res_data(res_data), .res_n(res_n));

    reg [7:0]  mem [0:2047];
    reg [59:0] exp_box [0:7];
    always @(posedge clk) rd_q <= mem[rd_addr[10:0]];

    reg [8*200-1:0] prefix;
    reg [8*220-1:0] fn;
    integer fd, r, i, n_exp, mism, cycles, pass, first_cycles;
    reg [59:0] w;
    reg        done_seen;
    always @(posedge clk) if (done) done_seen <= 1'b1;
    initial begin
        if (!$value$plusargs("CASE=%s", prefix)) begin $display("TB_RESULT: FAIL tb_yolo_decode (no +CASE=)"); $finish; end
        for (i = 0; i < 2048; i = i + 1) mem[i] = 8'h00;
        $sformat(fn, "%0s_heads.hex", prefix); $readmemh(fn, mem);
        $sformat(fn, "%0s_exp.hex", prefix);
        fd = $fopen(fn, "r");
        if (fd == 0) begin $display("TB_RESULT: FAIL tb_yolo_decode cannot open %0s", fn); $finish; end
        r = $fscanf(fd, "%d", n_exp);
        for (i = 0; i < n_exp; i = i + 1) begin r = $fscanf(fd, "%h", w); exp_box[i] = w; end
        $fclose(fd);
        mism = 0; first_cycles = 0; done_seen = 1'b0;
        start = 1'b0; res_idx = 4'd0;
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);
        for (pass = 0; pass < 2; pass = pass + 1) begin
            done_seen = 1'b0;
            start = 1'b1; @(negedge clk); start = 1'b0;
            cycles = 0;
            while (!done_seen && cycles < 400000) begin @(negedge clk); cycles = cycles + 1; end
            if (pass == 0) first_cycles = cycles;
            repeat (3) @(negedge clk);
            if (!done_seen) begin mism = mism + 1; $display("MISMATCH %0s pass %0d: done never came (timeout)", prefix, pass); end
            if (busy) begin mism = mism + 1; $display("MISMATCH %0s pass %0d: busy still high", prefix, pass); end
            if (res_n !== n_exp[3:0]) begin mism = mism + 1; $display("MISMATCH %0s pass %0d: %0d boxes, expected %0d", prefix, pass, res_n, n_exp); end
            for (i = 0; i < n_exp; i = i + 1) begin
                res_idx = i; @(negedge clk); @(negedge clk);
                if (res_data !== exp_box[i]) begin
                    mism = mism + 1;
                    if (mism <= 8) $display("MISMATCH %0s pass %0d box %0d: got %015x expected %015x", prefix, pass, i, res_data, exp_box[i]);
                end
            end
        end
        if (mism == 0) $display("TB_RESULT: PASS tb_yolo_decode %0s boxes=%0d clocks=%0d", prefix, n_exp, first_cycles);
        else           $display("TB_RESULT: FAIL tb_yolo_decode %0s mismatches=%0d", prefix, mism);
        $finish;
    end

endmodule
