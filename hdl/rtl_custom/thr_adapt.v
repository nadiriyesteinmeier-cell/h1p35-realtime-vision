// thr_adapt.v - maps the measured scene brightness to the segmentation noise floor
//
//   adaptive = 0 or no brightness measured yet : thr_rmin = fixed_rmin, thr_delta = fixed_delta      (fixed thresholds)
//   adaptive = 1 and mean_valid = 1            : thr_rmin = 32 + mean/2  (32..159),  thr_delta = fixed_delta
//
// 'mean' is the previous frame's mean luminance (luma_mean.v). A dark scene lowers the minimum red level a pixel
// needs (a red object is darker when the light is dim) and a bright scene raises it (so bright reflections and
// over-exposed areas must really be red). The channel-ratio rule of color_seg_rt.v (adaptive = 1) keeps the colour
// decision itself independent of the overall brightness; thr_delta only matters for the fixed rule.
// The mapping is a design choice, NOT tuned on real camera images: the slope and offset may need adjusting on the board.
// Purely combinational (registered by the consumer).

module thr_adapt (
    input  wire [7:0] mean,
    input  wire       mean_valid,
    input  wire       adaptive,
    input  wire [7:0] fixed_rmin,
    input  wire [7:0] fixed_delta,
    output wire [7:0] thr_rmin,
    output wire [7:0] thr_delta
);

    wire        use_ad = adaptive & mean_valid;
    wire [7:0]  ad_min = 8'd32 + {1'b0, mean[7:1]};

    assign thr_rmin  = use_ad ? ad_min : fixed_rmin;
    assign thr_delta = fixed_delta;

endmodule
