// tb_frame_commit.v - self-check of rtl_custom/frame_commit.v (request / effective settings, commit at the frame boundary)
//
// The checks do not copy the RTL algorithm; they state the contract on every clock:
//   * before the first commit after reset eff follows req (one clock later), after it eff changes ONLY on a clock that has commit = 1,
//     and then becomes exactly the req that was present at that clock edge;
//   * pending = (req != eff) at all times;
//   * changed = 1 exactly one clock after a commit that changed eff (not for the first, seeding commit), gen counts those;
//   * a request that appears and goes away between two commits never reaches eff;
//   * a level commit (several clocks) is allowed; reset (also in the middle of a run) returns eff to INIT, gen to 0 and un-seeds.
// Stimulus: directed sequences, then 60,000 clocks of random requests (single-bit flips and whole-word changes at any clock, including
// the clock of a commit) with single-clock and multi-clock commits, and random resets.
//
// Run: iverilog -g2005 -o sim_fc.vvp tb_frame_commit.v ../rtl_custom/frame_commit.v ; vvp sim_fc.vvp
//      final line: TB_RESULT: PASS tb_frame_commit  or  FAIL

`timescale 1ns / 1ps

module tb_frame_commit;

    localparam [7:0] INIT = 8'h5A;

    reg        clk, rst_n, commit;
    reg  [7:0] req;
    wire [7:0] eff;
    wire       pending, changed;
    wire [7:0] gen;

    frame_commit #(.W(8), .INIT(INIT)) dut (
        .clk(clk), .rst_n(rst_n), .commit(commit), .req(req),
        .eff(eff), .pending(pending), .changed(changed), .gen(gen)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---------------- what the TB saw at the last rising edge (stimulus only changes at falling edges, so this is stable)
    reg [7:0] req_at, eff_before;
    reg       commit_at, seeded_tb, seeded_before, was_reset;
    integer   gen_tb;
    integer   errors, n_change, n_nochange, n_glitch, n_levels, n_resets, n_seed;

    always @(posedge clk) begin
        req_at        <= req;
        commit_at     <= commit & rst_n;
        eff_before    <= eff;
        seeded_before <= seeded_tb;
        was_reset     <= ~rst_n;
        if (rst_n && commit) seeded_tb <= 1'b1;
    end

    always @(negedge rst_n) begin seeded_tb <= 1'b0; gen_tb = 0; end

    task bad;
        input [8*48-1:0] what;
        input [15:0]     e;
        input [15:0]     a;
        begin
            errors = errors + 1;
            if (errors <= 20) $display("MISMATCH t=%0t %0s expected=%0h actual=%0h (req=%0h eff=%0h commit=%0b)", $time, what, e, a, req, eff, commit);
        end
    endtask

    // ---------------- per-clock contract check (at the falling edge, after the registers settled)
    reg prim;
    initial prim = 1'b0;
    always @(negedge clk) begin
        if (prim) begin
            if (pending !== (req !== eff)) bad("pending == (req != eff)", {15'd0, (req !== eff)}, {15'd0, pending});
            if (!rst_n) begin
                if (eff !== INIT)   bad("eff during reset", {8'd0, INIT}, {8'd0, eff});
                if (gen !== 8'd0)   bad("gen during reset", 16'd0, {8'd0, gen});
                if (changed !== 1'b0) bad("changed during reset", 16'd0, {15'd0, changed});
            end
            else if (!was_reset) begin
                if (!seeded_before) begin
                    if (eff !== req_at) bad("eff follows req before the first commit", {8'd0, req_at}, {8'd0, eff});
                    if (changed !== 1'b0) bad("changed before seeding", 16'd0, {15'd0, changed});
                end
                else begin
                    if (commit_at) begin
                        if (eff !== req_at) bad("eff == req at the commit edge", {8'd0, req_at}, {8'd0, eff});
                        if (changed !== (req_at !== eff_before)) bad("changed pulse", {15'd0, (req_at !== eff_before)}, {15'd0, changed});
                        if (req_at !== eff_before) begin gen_tb = gen_tb + 1; n_change = n_change + 1; end
                        else n_nochange = n_nochange + 1;
                    end
                    else begin
                        if (eff !== eff_before) bad("eff changed without commit", {8'd0, eff_before}, {8'd0, eff});
                        if (changed !== 1'b0) bad("changed without commit", 16'd0, {15'd0, changed});
                    end
                    if (gen !== gen_tb[7:0]) bad("gen", gen_tb[15:0], {8'd0, gen});
                end
            end
        end
    end

    // ---------------- stimulus helpers (all at the falling edge)
    task tick; begin @(negedge clk); #1; end endtask       // stimulus 1 ns after the falling edge, where the checks run

    task commit1;                          // single-clock commit
        begin commit = 1'b1; tick; commit = 1'b0; end
    endtask

    task commit_level;                     // commit held for n clocks
        input integer n;
        integer q;
        begin commit = 1'b1; for (q = 0; q < n; q = q + 1) tick; commit = 1'b0; n_levels = n_levels + 1; end
    endtask

    integer seed, r, i, k;
    reg [7:0] t8;
    initial begin
        errors = 0; n_change = 0; n_nochange = 0; n_glitch = 0; n_levels = 0; n_resets = 0; n_seed = 0; gen_tb = 0;
        seeded_tb = 1'b0; seeded_before = 1'b0; commit_at = 1'b0; was_reset = 1'b1; req_at = 8'd0; eff_before = INIT;
        rst_n = 1'b0; commit = 1'b0; req = 8'h00;
        repeat (3) tick;
        prim = 1'b1;
        rst_n = 1'b1;

        // ---- before the first commit the effective value just follows
        req = 8'h11; tick; tick;
        if (eff !== 8'h11) bad("pass-through 1", 16'h11, {8'd0, eff});
        req = 8'h22; tick; tick;
        if (eff !== 8'h22) bad("pass-through 2", 16'h22, {8'd0, eff});
        commit1;                                           // seeding commit: no 'changed'
        n_seed = n_seed + 1;
        tick;

        // ---- now requests wait
        req = 8'hA5; tick; tick; tick;
        if (eff !== 8'h22) bad("request must wait", 16'h22, {8'd0, eff});
        if (pending !== 1'b1) bad("pending while waiting", 1, {15'd0, pending});
        commit1; tick;
        if (eff !== 8'hA5) bad("request committed", 16'hA5, {8'd0, eff});
        if (pending !== 1'b0) bad("pending cleared", 0, {15'd0, pending});
        if (gen !== 8'd1) bad("gen after one change", 1, {8'd0, gen});

        // ---- glitch: request and revert between two commits
        req = 8'h3C; tick; tick; req = 8'hA5; tick; tick; commit1; tick; n_glitch = n_glitch + 1;
        if (eff !== 8'hA5) bad("glitch must not reach eff", 16'hA5, {8'd0, eff});
        if (gen !== 8'd1) bad("gen after a glitch", 1, {8'd0, gen});

        // ---- commit with an unchanged request: no 'changed', no gen
        commit1; tick;
        if (gen !== 8'd1) bad("gen after commit without change", 1, {8'd0, gen});

        // ---- level commit: every clock copies req (change inside the level is taken)
        req = 8'h01; commit = 1'b1; tick; req = 8'h02; tick; req = 8'h04; tick; commit = 1'b0; req = 8'h08; tick; tick;
        if (eff !== 8'h04) bad("level commit takes the last request inside the level", 4, {8'd0, eff});
        n_levels = n_levels + 1;

        // ---- the commit takes the req that is present at ITS clock edge (here: set in the same cycle, one cycle after 0x10)
        req = 8'h10; tick; tick;
        commit = 1'b1; req = 8'h20; tick;                  // the commit edge sees req = 0x20 (set at the falling edge before it)
        commit = 1'b0; tick;
        if (eff !== 8'h20) bad("req present at the commit edge", 16'h20, {8'd0, eff});
        req = 8'h30; tick; tick;
        if (eff !== 8'h20) bad("later request waits", 16'h20, {8'd0, eff});

        // ---- reset in the middle: INIT, gen 0, un-seeded
        rst_n = 1'b0; n_resets = n_resets + 1; tick; tick;
        if (eff !== INIT) bad("reset value", {8'd0, INIT}, {8'd0, eff});
        rst_n = 1'b1; req = 8'h77; tick; tick;
        if (eff !== 8'h77) bad("pass-through after reset", 16'h77, {8'd0, eff});
        commit1; tick;
        req = 8'h78; tick; tick; tick;
        if (eff !== 8'h77) bad("waits again after the seeding commit", 16'h77, {8'd0, eff});
        commit1; tick;

        // ---- random phase
        seed = 12345;
        for (i = 0; i < 60000; i = i + 1) begin
            r = $random(seed);
            if (r[4:0] == 5'd0) begin                                  // whole-word change
                req = $random(seed);
            end
            else if (r[7:5] == 3'd0) begin                             // single-bit flip
                t8 = 8'd1 << r[10:8];
                req = req ^ t8;
            end
            if (r[18:12] == 7'd0) commit_level(1 + (r[21:19] % 6));    // multi-clock commit (the ticks inside advance time)
            else if (r[23:19] == 5'd0) begin commit = 1'b1; end         // single-clock commit
            else commit = 1'b0;
            if (r[29:24] == 6'd1 && r[31:30] == 2'd0) begin             // occasional reset
                rst_n = 1'b0; n_resets = n_resets + 1; tick; rst_n = 1'b1;
            end
            tick;
            if (commit) commit = 1'b0;
        end
        commit = 1'b0;
        repeat (5) tick;
        prim = 1'b0;

        $display("tb_frame_commit: commits that changed eff=%0d, commits without change=%0d, glitches=%0d, level commits=%0d, resets=%0d errors=%0d",
                 n_change, n_nochange, n_glitch, n_levels, n_resets, errors);
        if (n_change < 200 || n_nochange < 100 || n_levels < 50 || n_resets < 3) begin
            errors = errors + 1;
            $display("COVERAGE too low: the test would be vacuous");
        end
        if (errors == 0) $display("TB_RESULT: PASS tb_frame_commit");
        else             $display("TB_RESULT: FAIL tb_frame_commit errors=%0d", errors);
        $finish;
    end

endmodule
