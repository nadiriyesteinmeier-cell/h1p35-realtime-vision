// tb_yolo_net.v - the whole execution chain of the detector in simulation: yolo_net_engine (descriptor sequencer, yolo_conv_core, yolo_aux_core, four banks)
// against the integer reference (tools/yolo/mininet.py + qref.py)
//
// +CASE=<prefix of the files written by mininet.py>. The testbench
//   * loads the descriptor ROM, the weight and parameter memories and the padded input map (through the engine's host port into bank A),
//   * starts the engine and, at the moment every layer reports layer_done, compares the finished tensor in its bank with the expected image of that layer
//     (hierarchical read of the bank arrays; an unwritten byte is X and fails the comparison),
//   * checks that net_done comes, busy goes low again and prints the clocks of every layer (LAYER <n> <name-less> clocks=...).
// Run: python tools/yolo/run_net_tests.py   (generates the vectors, compiles for LANES = 8 and 16 with Icarus Verilog, runs all cases)
// Final line: TB_RESULT: PASS tb_yolo_net <case> lanes=<l> layers=<n> checked=<bytes> clocks=<total>   or   FAIL

`timescale 1ns / 1ps

module tb_yolo_net;

    parameter integer LANES = 8;
    localparam integer EXP_MAX = 1 << 18;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    reg         start;
    wire        busy, net_done, layer_done;
    reg  [5:0]  cfg_nlayers;
    wire [5:0]  desc_addr, layer_idx;
    reg  [207:0] desc_q;
    wire [13:0] wt_addr;
    reg  [8*LANES-1:0] wt_q;
    wire [10:0] pm_addr;
    reg  [55:0] pm_q;
    reg         host_we;
    reg  [1:0]  host_bank, host_rbank;
    reg  [19:0] host_addr, host_raddr;
    reg  [7:0]  host_wdata;
    wire [7:0]  host_rdata;

    yolo_net_engine #(.LANES(LANES), .DEPTH_A(32768), .DEPTH_B(32768), .DEPTH_C(8192), .DEPTH_D(2048)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .net_done(net_done), .cfg_nlayers(cfg_nlayers),
        .desc_addr(desc_addr), .desc_data(desc_q), .wt_addr(wt_addr), .wt_data(wt_q), .pm_addr(pm_addr), .pm_data(pm_q),
        .host_we(host_we), .host_bank(host_bank), .host_addr(host_addr), .host_wdata(host_wdata),
        .host_rbank(host_rbank), .host_raddr(host_raddr), .host_rdata(host_rdata),
        .layer_idx(layer_idx), .layer_done(layer_done)
    );

    reg [207:0]        desc_mem [0:63];
    reg [8*LANES-1:0]  wt_mem   [0:16383];
    reg [55:0]         pm_mem   [0:2047];
    reg [7:0]          in_mem   [0:65535];
    reg [47:0]         exp_mem  [0:EXP_MAX-1];
    always @(posedge clk) begin
        desc_q <= desc_mem[desc_addr];
        wt_q   <= wt_mem[wt_addr];
        pm_q   <= pm_mem[pm_addr];
    end

    function [8:0] bank_byte;                                   // {valid, value}; valid = 0 when the address is outside the bank
        input [3:0]  bank;
        input [27:0] addr;
        begin
            case (bank)
                4'd0: bank_byte = (addr < 32768) ? {1'b1, dut.u_bank0.mem[addr]} : 9'h000;
                4'd1: bank_byte = (addr < 32768) ? {1'b1, dut.u_bank1.mem[addr]} : 9'h000;
                4'd2: bank_byte = (addr < 8192)  ? {1'b1, dut.u_bank2.mem[addr]} : 9'h000;
                4'd3: bank_byte = (addr < 2048)  ? {1'b1, dut.u_bank3.mem[addr]} : 9'h000;
                default: bank_byte = 9'h000;
            endcase
        end
    endfunction

    // ---------------- per-layer check on layer_done (falling clock edge: the registered pulse is stable, the next layer has not started writing)
    integer lcount, exp_ptr, n_exp, n_checked, n_bad, k, last_cycle_mark, total_cycles;
    reg [47:0] e;
    reg [8:0]  bb;
    reg        net_done_seen, show_layers;
    initial begin lcount = 0; exp_ptr = 0; n_checked = 0; n_bad = 0; net_done_seen = 1'b0; end
    always @(posedge clk) if (net_done) net_done_seen <= 1'b1;
    always @(negedge clk) begin
        if (layer_done) begin
            if (show_layers) $display("LAYER %0d clocks=%0d", lcount, total_cycles - last_cycle_mark);
            last_cycle_mark = total_cycles;
            e = exp_mem[exp_ptr];
            while (exp_ptr < n_exp && e[47:40] == lcount) begin
                bb = bank_byte(e[39:36], e[35:8]);
                n_checked = n_checked + 1;
                if (!bb[8] || bb[7:0] !== e[7:0]) begin
                    n_bad = n_bad + 1;
                    if (n_bad <= 12) $display("MISMATCH layer %0d bank %0d addr %0d: got %02x expected %02x", lcount, e[39:36], e[35:8], bb[7:0], e[7:0]);
                end
                exp_ptr = exp_ptr + 1;
                e = exp_mem[exp_ptr];
            end
            lcount = lcount + 1;
        end
    end

    // ---------------- run
    reg [8*200-1:0] prefix;
    reg [8*220-1:0] fn;
    integer fd, r, nl, in_size, nwt, npm, i, pass, kd, n_host;
    integer pass_cycles [0:1];
    reg [47:0] ee;
    initial begin
        total_cycles = 0; last_cycle_mark = 0; n_host = 0;
        if (!$value$plusargs("CASE=%s", prefix)) begin $display("TB_RESULT: FAIL tb_yolo_net (no +CASE=)"); $finish; end
        $sformat(fn, "%0s_cfg.txt", prefix);
        fd = $fopen(fn, "r");
        if (fd == 0) begin $display("TB_RESULT: FAIL tb_yolo_net cannot open %0s", fn); $finish; end
        r = $fscanf(fd, "%d %d %d %d %d", nl, n_exp, in_size, nwt, npm);
        $fclose(fd);
        for (i = 0; i < EXP_MAX; i = i + 1) exp_mem[i] = 48'hFFFFFFFFFFFF;
        $sformat(fn, "%0s_desc.hex", prefix); $readmemh(fn, desc_mem);
        $sformat(fn, "%0s_wt.hex", prefix);   $readmemh(fn, wt_mem);
        $sformat(fn, "%0s_pm.hex", prefix);   $readmemh(fn, pm_mem);
        $sformat(fn, "%0s_in.hex", prefix);   $readmemh(fn, in_mem);
        $sformat(fn, "%0s_exp.hex", prefix);  $readmemh(fn, exp_mem);
        cfg_nlayers = nl;
        start = 1'b0; host_we = 1'b0; host_bank = 2'd0; host_addr = 20'd0; host_wdata = 8'd0; host_rbank = 2'd0; host_raddr = 20'd0;
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);
        for (pass = 0; pass < 2; pass = pass + 1) begin
            // pass 0 right after reset, pass 1 without a reset on top of the leftovers of pass 0 (restart, layer counter, border clearing of reused banks)
            lcount = 0; exp_ptr = 0; net_done_seen = 1'b0; last_cycle_mark = 0; total_cycles = 0; show_layers = (pass == 0);
            // the host loads the padded input map into bank A
            for (i = 0; i < in_size; i = i + 1) begin
                host_we = 1'b1; host_bank = 2'd0; host_addr = i; host_wdata = in_mem[i];
                @(negedge clk);
            end
            host_we = 1'b0;
            @(negedge clk);
            // host readback sanity (port test): first and last byte of the input map
            host_rbank = 2'd0; host_raddr = 20'd0; @(negedge clk); @(negedge clk);
            if (host_rdata !== in_mem[0]) begin n_bad = n_bad + 1; $display("MISMATCH host readback byte 0: got %02x expected %02x", host_rdata, in_mem[0]); end
            host_raddr = in_size - 1; @(negedge clk); @(negedge clk);
            if (host_rdata !== in_mem[in_size - 1]) begin n_bad = n_bad + 1; $display("MISMATCH host readback last byte: got %02x expected %02x", host_rdata, in_mem[in_size - 1]); end
            start = 1'b1; @(negedge clk); start = 1'b0;
            while (!net_done_seen && total_cycles < 2000000) begin @(negedge clk); total_cycles = total_cycles + 1; end
            repeat (4) @(negedge clk);
            if (!net_done_seen) begin n_bad = n_bad + 1; $display("MISMATCH %0s pass %0d: net_done never came (timeout)", prefix, pass); end
            if (lcount != nl) begin n_bad = n_bad + 1; $display("MISMATCH %0s pass %0d: %0d layers finished, expected %0d", prefix, pass, lcount, nl); end
            if (exp_ptr != n_exp) begin n_bad = n_bad + 1; $display("MISMATCH %0s pass %0d: %0d of %0d expected entries checked", prefix, pass, exp_ptr, n_exp); end
            if (busy) begin n_bad = n_bad + 1; $display("MISMATCH %0s pass %0d: busy still high", prefix, pass); end
            pass_cycles[pass] = total_cycles;
            // the head tensors (bank D) read back through the host port
            for (kd = 0; kd < n_exp; kd = kd + 1) begin
                ee = exp_mem[kd];
                if (ee[39:36] == 4'd3) begin
                    host_rbank = 2'd3; host_raddr = ee[35:8]; @(negedge clk); @(negedge clk);
                    if (host_rdata !== ee[7:0]) begin n_bad = n_bad + 1; if (n_bad <= 12) $display("MISMATCH host readback bank D addr %0d: got %02x expected %02x", ee[35:8], host_rdata, ee[7:0]); end
                    n_host = n_host + 1;
                end
            end
        end
        if (n_bad == 0) $display("TB_RESULT: PASS tb_yolo_net %0s lanes=%0d layers=%0d checked=%0d host_readback=%0d clocks=%0d clocks_pass2=%0d", prefix, LANES, nl, n_checked / 2, n_host / 2,
                                 pass_cycles[0], pass_cycles[1]);
        else            $display("TB_RESULT: FAIL tb_yolo_net %0s mismatches=%0d", prefix, n_bad);
        $finish;
    end

endmodule
