// yolo_net_engine.v - layer sequencer of the detector: runs a table of layer descriptors on yolo_conv_core / yolo_aux_core over four activation banks
//
// What it is: the fixed part of the network execution. The model (layer table, weights, per-channel parameters) is data: a descriptor ROM, a weight memory
// and a parameter memory that the engine reads through plain synchronous-read ports (1-clock latency), exactly as yolo_conv_core.v expects them. The four activation
// banks (A, B, C, D) are inside; a layer reads one bank and writes another one (the convolution with the fused pool also reads its destination bank to
// merge the 2x2 window). Between two layers the engine fetches the next descriptor (3 clocks), starts the engine selected by `op` and waits for its done pulse.
//
// Host port (only while busy = 0): write one byte into a bank (the preprocessed input map, borders included) and read one byte back (synchronous, 1 clock).
// layer_done is a 1-clock pulse after the last write of a layer (the bank holds the finished tensor at that moment), net_done after the last layer.
//
// Descriptor word (208 bits, fixed widths AW = 20, WW = 14, PW = 11; the python model tools/yolo/mininet.py packs it):
//   [2:0] op  0 = convolution (h, w = INPUT size of the convolution, cin, cout, k3, act, pool as in yolo_conv_core.v; with pool = 1 the output is the pooled map)
//             1 = copy 2 = upsample x2 3 = max-pool stride 2 4 = max-pool stride 1 5 = fill with 0     (yolo_aux_core.v modes 0..4; h, w, cin(=c) = OUTPUT size)
//   [4:3] src bank  [6:5] dst bank  [18:7] h  [30:19] w  [41:31] cin / c  [52:42] cout  [53] k3  [54] act  [55] pool
//   [75:56] in_base  [95:76] in_row  [115:96] in_pix  [135:116] out_base  [155:136] out_row  [175:156] out_pix
//   [189:176] wt_base (added to the core's weight address)   [200:190] pm_base (added to the core's parameter index)
//
// Reset: control flags only (state, layer counter, pulses); the descriptor registers are loaded before use.

module yolo_net_engine #(
    parameter integer LANES   = 8,
    parameter integer DEPTH_A = 65536,
    parameter integer DEPTH_B = 65536,
    parameter integer DEPTH_C = 16384,
    parameter integer DEPTH_D = 4096,
    parameter integer NLW     = 6
)(
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 start,
    output wire                 busy,
    output reg                  net_done,
    input  wire [NLW-1:0]       cfg_nlayers,          // number of descriptors to run (>= 1)

    output wire [NLW-1:0]       desc_addr,
    input  wire [207:0]         desc_data,            // synchronous read, valid one clock after desc_addr

    output wire [13:0]          wt_addr,
    input  wire [8*LANES-1:0]   wt_data,
    output wire [10:0]          pm_addr,
    input  wire [55:0]          pm_data,

    input  wire                 host_we,
    input  wire [1:0]           host_bank,
    input  wire [19:0]          host_addr,
    input  wire [7:0]           host_wdata,
    input  wire [1:0]           host_rbank,
    input  wire [19:0]          host_raddr,
    output wire [7:0]           host_rdata,

    output wire [NLW-1:0]       layer_idx,
    output reg                  layer_done
);

    localparam integer AW = 20;
    localparam integer WW = 14;
    localparam integer PW = 11;

    localparam [2:0] S_IDLE  = 3'd0;
    localparam [2:0] S_FETCH = 3'd1;
    localparam [2:0] S_LATCH = 3'd2;
    localparam [2:0] S_GO    = 3'd3;
    localparam [2:0] S_WAIT  = 3'd4;

    reg [2:0]     state;
    reg [NLW-1:0] layer;
    reg           conv_start, aux_start;
    wire          conv_done, aux_done;
    assign busy       = (state != S_IDLE);
    assign desc_addr  = layer;
    assign layer_idx  = layer;

    // ------------------------------------------------------------------ descriptor registers (loaded in S_LATCH, stable while the layer runs)
    reg [2:0]    c_op;
    reg [1:0]    c_src, c_dst;
    reg [11:0]   c_h, c_w;
    reg [10:0]   c_cin, c_cout;
    reg          c_k3, c_act, c_pool;
    reg [AW-1:0] c_in_base, c_in_row, c_in_pix, c_out_base, c_out_row, c_out_pix;
    reg [WW-1:0] c_wt_base;
    reg [PW-1:0] c_pm_base;
    always @(posedge clk) begin
        if (state == S_LATCH) begin
            c_op <= desc_data[2:0];       c_src <= desc_data[4:3];       c_dst <= desc_data[6:5];
            c_h <= desc_data[18:7];       c_w <= desc_data[30:19];       c_cin <= desc_data[41:31];     c_cout <= desc_data[52:42];
            c_k3 <= desc_data[53];        c_act <= desc_data[54];        c_pool <= desc_data[55];
            c_in_base <= desc_data[75:56];  c_in_row <= desc_data[95:76];   c_in_pix <= desc_data[115:96];
            c_out_base <= desc_data[135:116]; c_out_row <= desc_data[155:136]; c_out_pix <= desc_data[175:156];
            c_wt_base <= desc_data[189:176]; c_pm_base <= desc_data[200:190];
        end
    end
    wire cv = (c_op == 3'd0);

    // ------------------------------------------------------------------ sequencer
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; layer <= {NLW{1'b0}}; conv_start <= 1'b0; aux_start <= 1'b0; net_done <= 1'b0; layer_done <= 1'b0;
        end
        else begin
            conv_start <= 1'b0; aux_start <= 1'b0; net_done <= 1'b0; layer_done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        layer <= {NLW{1'b0}};
                        state <= S_FETCH;
                    end
                end
                S_FETCH: state <= S_LATCH;
                S_LATCH: state <= S_GO;
                S_GO: begin
                    conv_start <= cv;
                    aux_start  <= !cv;
                    state <= S_WAIT;
                end
                default: begin                                  // S_WAIT
                    if (cv ? conv_done : aux_done) begin
                        layer_done <= 1'b1;
                        if (layer == cfg_nlayers - 1'b1) begin
                            net_done <= 1'b1;
                            state <= S_IDLE;
                        end
                        else begin
                            layer <= layer + 1'b1;
                            state <= S_FETCH;
                        end
                    end
                end
            endcase
        end
    end

    // ------------------------------------------------------------------ the two engines
    wire [AW-1:0] act_addr, out_rd_addr, conv_out_addr, aux_rd_addr, aux_out_addr;
    wire [7:0]    conv_out_data, aux_out_data, act_data, out_rd_data, aux_rd_data;
    wire          conv_we, aux_we;
    wire [WW-1:0] core_wt_addr;
    wire [PW-1:0] core_pm_addr;

    yolo_conv_core #(.LANES(LANES), .AW(AW), .WW(WW), .PW(PW), .POOL(1)) u_conv (
        .clk(clk), .rst_n(rst_n),
        .cfg_h(c_h), .cfg_w(c_w), .cfg_cin(c_cin), .cfg_cout(c_cout), .cfg_k3(c_k3), .cfg_act(c_act), .cfg_pool(c_pool),
        .cfg_in_base(c_in_base), .cfg_in_row(c_in_row), .cfg_in_pix(c_in_pix),
        .cfg_out_base(c_out_base), .cfg_out_row(c_out_row), .cfg_out_pix(c_out_pix),
        .start(conv_start), .busy(), .done(conv_done),
        .act_addr(act_addr), .act_data(act_data), .wt_addr(core_wt_addr), .wt_data(wt_data), .pm_addr(core_pm_addr), .pm_data(pm_data),
        .out_we(conv_we), .out_addr(conv_out_addr), .out_data(conv_out_data), .out_rd_addr(out_rd_addr), .out_rd_data(out_rd_data)
    );

    yolo_aux_core #(.AW(AW)) u_aux (
        .clk(clk), .rst_n(rst_n),
        .cfg_h(c_h), .cfg_w(c_w), .cfg_c(c_cin), .cfg_mode(c_op - 3'd1),
        .cfg_in_base(c_in_base), .cfg_in_row(c_in_row), .cfg_in_pix(c_in_pix),
        .cfg_out_base(c_out_base), .cfg_out_row(c_out_row), .cfg_out_pix(c_out_pix),
        .start(aux_start), .busy(), .done(aux_done),
        .rd_addr(aux_rd_addr), .rd_data(aux_rd_data), .out_we(aux_we), .out_addr(aux_out_addr), .out_data(aux_out_data)
    );

    assign wt_addr = c_wt_base + core_wt_addr;
    assign pm_addr = c_pm_base + core_pm_addr;

    // ------------------------------------------------------------------ banks and their port multiplexers
    wire [7:0] rd0, rd1, rd2, rd3;
    wire [AW-1:0] w_addr = cv ? conv_out_addr : aux_out_addr;
    wire [7:0]    w_data = cv ? conv_out_data : aux_out_data;
    wire          w_we   = cv ? conv_we : aux_we;

    // read address of bank b: the source bank gets the activation / copy address, the destination bank the merge address of the fused pool
    function [AW-1:0] ra_sel;
        input [1:0] b;
        input       busy_i;
        input [1:0] src_i;
        input [1:0] dst_i;
        input       cv_i;
        input [AW-1:0] a_act;
        input [AW-1:0] a_aux;
        input [AW-1:0] a_merge;
        input [AW-1:0] a_host;
        begin
            if (!busy_i)         ra_sel = a_host;
            else if (b == src_i) ra_sel = cv_i ? a_act : a_aux;
            else if (b == dst_i) ra_sel = cv_i ? a_merge : {AW{1'b0}};
            else                 ra_sel = {AW{1'b0}};
        end
    endfunction

    wire [AW-1:0] ra0 = ra_sel(2'd0, busy, c_src, c_dst, cv, act_addr, aux_rd_addr, out_rd_addr, host_raddr);
    wire [AW-1:0] ra1 = ra_sel(2'd1, busy, c_src, c_dst, cv, act_addr, aux_rd_addr, out_rd_addr, host_raddr);
    wire [AW-1:0] ra2 = ra_sel(2'd2, busy, c_src, c_dst, cv, act_addr, aux_rd_addr, out_rd_addr, host_raddr);
    wire [AW-1:0] ra3 = ra_sel(2'd3, busy, c_src, c_dst, cv, act_addr, aux_rd_addr, out_rd_addr, host_raddr);

    wire we0 = busy ? (w_we && c_dst == 2'd0) : (host_we && host_bank == 2'd0);
    wire we1 = busy ? (w_we && c_dst == 2'd1) : (host_we && host_bank == 2'd1);
    wire we2 = busy ? (w_we && c_dst == 2'd2) : (host_we && host_bank == 2'd2);
    wire we3 = busy ? (w_we && c_dst == 2'd3) : (host_we && host_bank == 2'd3);
    wire [AW-1:0] wa = busy ? w_addr : host_addr;
    wire [7:0]    wd = busy ? w_data : host_wdata;

    yolo_bank_ram #(.DEPTH(DEPTH_A), .AW(AW)) u_bank0 (.clk(clk), .we(we0), .waddr(wa), .wdata(wd), .raddr(ra0), .rdata(rd0));
    yolo_bank_ram #(.DEPTH(DEPTH_B), .AW(AW)) u_bank1 (.clk(clk), .we(we1), .waddr(wa), .wdata(wd), .raddr(ra1), .rdata(rd1));
    yolo_bank_ram #(.DEPTH(DEPTH_C), .AW(AW)) u_bank2 (.clk(clk), .we(we2), .waddr(wa), .wdata(wd), .raddr(ra2), .rdata(rd2));
    yolo_bank_ram #(.DEPTH(DEPTH_D), .AW(AW)) u_bank3 (.clk(clk), .we(we3), .waddr(wa), .wdata(wd), .raddr(ra3), .rdata(rd3));

    function [7:0] rd_sel;
        input [1:0] b;
        input [7:0] d0, d1, d2, d3;
        begin
            case (b)
                2'd0: rd_sel = d0;
                2'd1: rd_sel = d1;
                2'd2: rd_sel = d2;
                default: rd_sel = d3;
            endcase
        end
    endfunction

    wire [7:0] src_rdata = rd_sel(c_src, rd0, rd1, rd2, rd3);
    assign act_data    = src_rdata;
    assign aux_rd_data = src_rdata;
    assign out_rd_data = rd_sel(c_dst, rd0, rd1, rd2, rd3);

    reg [1:0] hrb;
    always @(posedge clk) hrb <= host_rbank;
    assign host_rdata = rd_sel(hrb, rd0, rd1, rd2, rd3);

endmodule
