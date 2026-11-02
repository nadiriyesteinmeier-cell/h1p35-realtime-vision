// yolo_net_syn_top.v - synthesis / place-and-route experiment top for the complete execution engine (NOT part of any product build)
//
// yolo_net_engine (8 lanes, banks sized like the 128 x 96 candidate: A 38400 B, B 26624 B, C 3328 B, D 1152 B) with the descriptor / weight / parameter ROMs of the
// mini network net_a (31 layers, 4971 weight words = 39.8 KB: the same order of magnitude as the weights of the on-chip candidate). A small host FSM loads 19404 LFSR bytes
// into bank A, starts the engine, waits for net_done, reads the 720 bytes of bank D and accumulates them into an 8-bit checksum on the output pins (nothing can be removed),
// and starts over. Purpose: real LUT / FF / DSP / ERAM numbers and the achievable clock of the whole chain, not a functional demo.
module yolo_net_syn_top (
    input  wire       I_sys_clk,
    input  wire       I_rst_n,
    output wire [7:0] O_chk
);
    wire clk = I_sys_clk;
    reg [2:0] rs;
    always @(posedge clk or negedge I_rst_n) begin
        if (!I_rst_n) rs <= 3'd0;
        else          rs <= {rs[1:0], 1'b1};
    end
    wire rst_n = rs[2];

    wire        busy, net_done, layer_done;
    wire [5:0]  desc_addr, layer_idx;
    wire [207:0] desc_data;
    wire [13:0] wt_addr;
    wire [63:0] wt_data;
    wire [10:0] pm_addr;
    wire [55:0] pm_data;
    reg         start, host_we;
    reg  [19:0] host_addr, host_raddr;
    reg  [7:0]  host_wdata;
    wire [7:0]  host_rdata;

    yolo_net_engine #(.LANES(8), .DEPTH_A(38400), .DEPTH_B(26624), .DEPTH_C(3328), .DEPTH_D(1152)) u_eng (
        .clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .net_done(net_done), .cfg_nlayers(6'd31),
        .desc_addr(desc_addr), .desc_data(desc_data), .wt_addr(wt_addr), .wt_data(wt_data), .pm_addr(pm_addr), .pm_data(pm_data),
        .host_we(host_we), .host_bank(2'd0), .host_addr(host_addr), .host_wdata(host_wdata),
        .host_rbank(2'd3), .host_raddr(host_raddr), .host_rdata(host_rdata),
        .layer_idx(layer_idx), .layer_done(layer_done)
    );
    yolo_a_desc_rom u_desc (.clk(clk), .addr(desc_addr), .data(desc_data));
    yolo_a_wt_rom   u_wt   (.clk(clk), .addr(wt_addr),   .data(wt_data));
    yolo_a_pm_rom   u_pm   (.clk(clk), .addr(pm_addr),   .data(pm_data));

    // host FSM: LOAD -> RUN -> READ -> LOAD ...
    localparam [1:0] H_LOAD = 2'd0, H_RUN = 2'd1, H_READ = 2'd2;
    reg [1:0]  hs;
    reg [31:0] lfsr;
    reg [7:0]  chk;
    reg [1:0]  rdl;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs <= H_LOAD; start <= 1'b0; host_we <= 1'b0; host_addr <= 20'd0; host_raddr <= 20'd0; host_wdata <= 8'd0; lfsr <= 32'hACE1ACE1; chk <= 8'd0; rdl <= 2'd0;
        end
        else begin
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            start <= 1'b0;
            case (hs)
                H_LOAD: begin
                    host_we <= 1'b1; host_wdata <= lfsr[7:0];
                    if (host_we) host_addr <= host_addr + 20'd1;
                    if (host_addr == 20'd19403) begin host_we <= 1'b0; hs <= H_RUN; start <= 1'b1; host_raddr <= 20'd0; rdl <= 2'd0; end
                end
                H_RUN: begin
                    if (net_done) begin hs <= H_READ; host_raddr <= 20'd0; rdl <= 2'd0; end
                end
                default: begin
                    rdl <= rdl + 2'd1;
                    if (rdl == 2'd3) begin
                        chk <= chk + host_rdata;
                        host_raddr <= host_raddr + 20'd1;
                        rdl <= 2'd0;
                        if (host_raddr == 20'd719) begin hs <= H_LOAD; host_addr <= 20'd0; end
                    end
                end
            endcase
        end
    end
    assign O_chk = chk;
endmodule
