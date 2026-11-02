#!/usr/bin/env python3
"""Mutation test for the three testbenches.

For every mutant (one deliberately injected, typical bug in an RTL module) the
matching testbench is compiled and run with Icarus Verilog. A mutant is
KILLED when the testbench prints TB_RESULT: FAIL (or aborts with mismatches).
A mutant that still ends in TB_RESULT: PASS SURVIVED: the testbench cannot see
that bug, which is a coverage gap (or an equivalent mutant, which must be
argued case by case).

Before any mutant is run, every unmutated module must PASS (control run).
Mutants are written to logs_custom/mutation_work/, rtl_custom is never changed.

Usage:  python mutation_test.py [name-substring ...]     (default: all mutants)
Output: logs_custom/mutation_report.txt (env MUT_REPORT / MUT_TAG rename it / tag the work files for parallel runs) ; exit code 0 = all killed, 1 = survivors/problems
"""
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

TB = Path(__file__).resolve().parent
ROOT = TB.parent
RTL = ROOT / "rtl_custom"
LOGS = ROOT / "logs_custom"
WORK = LOGS / "mutation_work"
RUN_TAG = os.environ.get("MUT_TAG", "")                                    # lets several runs work in parallel
REPORT = LOGS / os.environ.get("MUT_REPORT", "mutation_report.txt")

UIVTC = ROOT / "lab1" / "user_source" / "hdl_source" / "vtc" / "uivtc.v"   # unmodified baseline file, only read

TESTS = {  # module -> (testbench, extra source files that are always compiled with it)
    "rgb_to_gray": ("tb_rgb_to_gray.v", []),
    "color_segment": ("tb_color_segment.v", []),
    "frame_bbox": ("tb_frame_bbox.v", []),
    "video_pos_adapter": ("tb_video_pos_adapter.v", [TB / "tb_vtc_chk.v", UIVTC]),
    "osd_overlay": ("tb_osd_overlay.v", [RTL / "osd_bin2bcd.v", RTL / "osd_font_rom.v", RTL / "osd_logo_rom.v"]),
    "osd_bin2bcd": ("tb_osd_aux.v", [RTL / "view_mux.v", RTL / "sync_delay.v"]),
    "view_mux": ("tb_osd_aux.v", [RTL / "osd_bin2bcd.v", RTL / "sync_delay.v"]),
    "sync_delay": ("tb_osd_aux.v", [RTL / "osd_bin2bcd.v", RTL / "view_mux.v"]),
    "cross_counter": ("tb_cross_counter.v", []),
    "frame_commit": ("tb_frame_commit.v", []),
    "target_track": ("tb_target_track.v", []),
    "awb_frame": ("tb_awb_frame.v", [RTL / "div_seq.v"]),
    "div_seq": ("tb_awb_frame.v", [RTL / "awb_frame.v"]),
    # the integration block that is wired into contest_work: all other modules + the real uivtc
    "contest_vision_path": ("tb_vision_path.v", [RTL / "video_pos_adapter.v", RTL / "rgb_to_gray.v", RTL / "color_segment.v",
                                                  RTL / "frame_bbox.v", RTL / "view_mux.v", RTL / "sync_delay.v", RTL / "osd_overlay.v",
                                                  RTL / "osd_bin2bcd.v", RTL / "osd_font_rom.v", RTL / "osd_logo_rom.v", UIVTC]),
}

# (module, mutant name, text that must occur exactly once, replacement)
M = []


def mut(module, name, old, new):
    M.append((module, name, old, new))


# Mutants that cannot change observable behaviour (argued by hand). They are reported
# separately and are not counted as testbench gaps. A claimed-equivalent mutant that a
# testbench DOES kill would be reported as killed (and the claim would be wrong).
EQUIVALENT = {
    "af_clamp_min_plus1": "gain 1025 instead of 1024 changes (1025 * x) >> 12 only if x/4 + x/4096 crosses an integer; for 8-bit x the fraction x/4096 < 1/16 "
                          "can never complete the missing 1/4 step, so every output byte is identical",
    "af_tuser_gated_by_valid": "O_tuser differs only for a tuser that is asserted without tvalid or together with tlast (a non-compliant stream); the "
                               "stream of uial2axis has tuser only on the first valid beat of a line that is longer than one beat",
    "cc_reset_keeps_cand_only": "after reset ccnt is 0, and with ccnt = 0 the expression (cand == z) ? ccnt + 1 : 1 gives 1 for every cand, "
                                "so a stale cand alone is unobservable (the combined stale cand AND ccnt is mutant cc_reset_keeps_candidate_and_count)",
    "cc_lost_counter_unsaturated": "lcnt is not an output; once lcnt > LOST_MAX the side is already unknown and stays unknown until "
                                   "a valid frame resets lcnt, so letting lcnt grow (and wrap after 65536 lost frames) changes no output",
    "tt_age_wrap_hold": "in S_HOLD the age is at most COAST_MAX (< 255 for every configuration that is simulated or built) before the state "
                        "becomes S_LOST, so removing the 255 saturation guard of the HOLD branch cannot change any output",
    "bbox_hit_without_de": "hit_v is only used inside 'if (consume)' and consume already contains "
                           "in_de, so dropping in_de from hit_v cannot change any register or output",
}


# ---------------------------------------------------------------- rgb_to_gray
mut("rgb_to_gray", "gray_coeff_R_77_to_78", "16'd77;", "16'd78;")
mut("rgb_to_gray", "gray_coeff_G_150_to_149", "16'd150;", "16'd149;")
mut("rgb_to_gray", "gray_coeff_B_29_to_30", "16'd29;", "16'd30;")
mut("rgb_to_gray", "gray_wrong_shift_16_9", "s1_de ? s1_sum[15:8] : 8'd0;", "s1_de ? s1_sum[16:9] : 8'd0;")
mut("rgb_to_gray", "gray_rounding_added", "+ {1'b0, s1_pb};", "+ {1'b0, s1_pb} + 17'd128;")
mut("rgb_to_gray", "gray_no_de_gate", "out_gray <= s1_de ? s1_sum[15:8] : 8'd0;", "out_gray <= s1_sum[15:8];")
mut("rgb_to_gray", "gray_x_not_gated", "out_x    <= s1_de ? s1_x         : 12'd0;", "out_x    <= s1_x;")
mut("rgb_to_gray", "gray_eol_not_gated", "out_eol  <= s1_de & s1_eol;", "out_eol  <= s1_eol;")
mut("rgb_to_gray", "gray_sof_latency_short", "out_sof  <= s1_de & s1_sof;", "out_sof  <= in_de & in_sof;")
mut("rgb_to_gray", "gray_eol_eof_swapped", "out_eol  <= s1_de & s1_eol;", "out_eol  <= s1_de & s1_eof;")
mut("rgb_to_gray", "gray_y_one_cycle_late", "out_y    <= s1_de ? s1_y         : 12'd0;", "out_y    <= s1_de ? in_y         : 12'd0;")
mut("rgb_to_gray", "gray_reset_not_clearing_out", "            out_gray <= 8'd0;\n", "")

# -------------------------------------------------------------- color_segment
mut("color_segment", "seg_G_plus_DELTA_8bit_wrap",
    "wire [10:0] s0_gd = {3'b000, in_rgb[15:8]} + {1'b0, DELTA};",
    "wire [10:0] s0_gd = {3'b000, in_rgb[15:8] + DELTA[7:0]};")
mut("color_segment", "seg_B_plus_DELTA_8bit_wrap",
    "wire [10:0] s0_bd = {3'b000, in_rgb[7:0]}  + {1'b0, DELTA};",
    "wire [10:0] s0_bd = {3'b000, in_rgb[7:0] + DELTA[7:0]};")
mut("color_segment", "seg_Rmin_strict", "(s0_r >= {1'b0, R_MIN})", "(s0_r > {1'b0, R_MIN})")
mut("color_segment", "seg_RG_strict", "(s0_r >= s0_gd)", "(s0_r > s0_gd)")
mut("color_segment", "seg_RB_strict", "(s0_r >= s0_bd)", "(s0_r > s0_bd)")
mut("color_segment", "seg_X1_inclusive", "(s0_x13 < X1)", "(s0_x13 <= X1)")
mut("color_segment", "seg_X0_exclusive", "(s0_x13 >= X0)", "(s0_x13 > X0)")
mut("color_segment", "seg_Y1_inclusive", "(s0_y13 < Y1)", "(s0_y13 <= Y1)")
mut("color_segment", "seg_Y0_exclusive", "(s0_y13 >= Y0)", "(s0_y13 > Y0)")
mut("color_segment", "seg_hit_not_de_gated",
    "s1_de & s1_c_rmin & s1_c_rg & s1_c_rb & s1_c_roi;", "s1_c_rmin & s1_c_rg & s1_c_rb & s1_c_roi;")
mut("color_segment", "seg_Rmin_dropped",
    "s1_de & s1_c_rmin & s1_c_rg & s1_c_rb & s1_c_roi;", "s1_de & s1_c_rg & s1_c_rb & s1_c_roi;")
mut("color_segment", "seg_B_condition_dropped",
    "s1_de & s1_c_rmin & s1_c_rg & s1_c_rb & s1_c_roi;", "s1_de & s1_c_rmin & s1_c_rg & s1_c_roi;")
mut("color_segment", "seg_roi_dropped",
    "s1_de & s1_c_rmin & s1_c_rg & s1_c_rb & s1_c_roi;", "s1_de & s1_c_rmin & s1_c_rg & s1_c_rb;")
mut("color_segment", "seg_mask_wrong_white", "out_hit ? 24'hFFFFFF : 24'h000000", "out_hit ? 24'hFFFFFE : 24'h000000")
mut("color_segment", "seg_rgb_rotated", "out_rgb <= s1_de ? s1_rgb : 24'd0;", "out_rgb <= s1_de ? {s1_rgb[7:0], s1_rgb[23:8]} : 24'd0;")
mut("color_segment", "seg_rgb_not_de_gated", "out_rgb <= s1_de ? s1_rgb : 24'd0;", "out_rgb <= s1_rgb;")
mut("color_segment", "seg_eof_not_de_gated", "out_eof <= s1_de & s1_eof;", "out_eof <= s1_eof;")
mut("color_segment", "seg_y_latency_short", "out_y   <= s1_de ? s1_y   : 12'd0;", "out_y   <= s1_de ? in_y   : 12'd0;")

# ----------------------------------------------------------------- frame_bbox
mut("frame_bbox", "bbox_sof_pixel_not_counted",
    "wire hit_v     = consume & in_hit;", "wire hit_v     = consume & in_hit & ~start_new;")
mut("frame_bbox", "bbox_eof_pixel_not_counted",
    "wire hit_v     = consume & in_hit;", "wire hit_v     = consume & in_hit & ~in_eof;")
mut("frame_bbox", "bbox_eol_treated_as_eof", "if (in_eof) begin", "if (in_eof | in_eol) begin")
mut("frame_bbox", "bbox_box_not_zeroed_when_invalid",
    "res_xmin     <= n_valid ? n_xmin       : 12'd0;", "res_xmin     <= n_xmin;")
mut("frame_bbox", "bbox_center_not_zeroed_when_invalid",
    "res_cx       <= n_valid ? n_sumx[12:1] : 12'd0;", "res_cx       <= n_sumx[12:1];")
mut("frame_bbox", "bbox_min_pixels_strict", "(n_cnt >= MIN_PIX_C)", "(n_cnt > MIN_PIX_C)")
mut("frame_bbox", "bbox_valid_without_nonzero_check",
    "(n_cnt != {CNT_W{1'b0}}) & (n_cnt >= MIN_PIX_C)", "(n_cnt >= MIN_PIX_C)")
mut("frame_bbox", "bbox_midframe_sof_ignored",
    "wire start_new = in_de & in_sof;", "wire start_new = in_de & in_sof & ~acc_active;")
mut("frame_bbox", "bbox_count_wraps_no_saturation",
    "(hit_v & ~cnt_full) ? (b_cnt", "(hit_v) ? (b_cnt")
mut("frame_bbox", "bbox_sat_flag_missing", "wire             n_sat  = b_sat | (hit_v & cnt_full);", "wire             n_sat  = 1'b0;")
mut("frame_bbox", "bbox_active_not_cleared_at_eof",
    "                    acc_active   <= 1'b0;\n                    frame_done   <= 1'b1;",
    "                    acc_active   <= 1'b1;\n                    frame_done   <= 1'b1;")
mut("frame_bbox", "bbox_abort_pulse_missing", "frame_abort <= start_new & acc_active;", "frame_abort <= 1'b0;")
mut("frame_bbox", "bbox_center_not_halved", "n_sumx[12:1]", "n_sumx[11:0]")
mut("frame_bbox", "bbox_center_sum_12bit",
    "wire [12:0]      n_sumx  = {1'b0, n_xmin} + {1'b0, n_xmax};",
    "wire [12:0]      n_sumx  = {1'b0, n_xmin + n_xmax};")
mut("frame_bbox", "bbox_eof_without_de_accepted",
    "wire consume   = in_de & (in_sof | acc_active);", "wire consume   = (in_de | in_eof) & (in_sof | acc_active);")
mut("frame_bbox", "bbox_hit_without_de",
    "wire hit_v     = consume & in_hit;", "wire hit_v     = (in_sof | acc_active) & in_hit;")
mut("frame_bbox", "bbox_consume_without_de",
    "wire consume   = in_de & (in_sof | acc_active);", "wire consume   = (in_sof | acc_active);")
mut("frame_bbox", "bbox_reset_keeps_active",
    "            acc_active   <= 1'b0;\n            acc_cnt      <= {CNT_W{1'b0}};",
    "            acc_active   <= acc_active;\n            acc_cnt      <= {CNT_W{1'b0}};")
mut("frame_bbox", "bbox_frame_id_stuck",
    "res_frame_id <= res_frame_id + 16'd1;", "res_frame_id <= res_frame_id;")
mut("frame_bbox", "bbox_ymax_ignores_end_of_line_pixel",
    "(hit_v & (in_y > b_ymax))", "(hit_v & (in_y > b_ymax) & ~in_eol)")
mut("frame_bbox", "bbox_xmin_init_not_max", "start_new ? 12'hFFF       : acc_xmin;", "start_new ? 12'h800       : acc_xmin;")
mut("frame_bbox", "bbox_results_overwritten_by_next_frame",
    "                acc_cnt  <= n_cnt;", "                acc_cnt  <= n_cnt;\n                res_count <= n_cnt;")


# ---------------------------------------------------------------- video_pos_adapter
A = "video_pos_adapter"
mut(A, "adapter_y_stale_in_first_line",          # the real bug found while writing the testbench
    "                    y_nxt  <= y_cur;            // after a frame start y_cur is 0, y_nxt must follow\n", "")
mut(A, "adapter_y_never_increments", "y_nxt  <= y_cur + 12'd1;", "y_nxt  <= y_cur;")
mut(A, "adapter_x_never_increments", "x_nxt  <= x_cur + 12'd1;", "x_nxt  <= x_cur;")
mut(A, "adapter_x_not_reset_at_user", "wire [11:0] x_cur  = start ? 12'd0 : x_nxt;", "wire [11:0] x_cur  = x_nxt;")
mut(A, "adapter_y_not_reset_at_user", "wire [11:0] y_cur  = start ? 12'd0 : y_nxt;", "wire [11:0] y_cur  = y_nxt;")
mut(A, "adapter_user_without_de_starts", "wire        start  = s_de & s_user;", "wire        start  = s_user;")
mut(A, "adapter_wide_off_by_one", "({1'b0, x_cur} >= W_C)", "({1'b0, x_cur} > W_C)")
mut(A, "adapter_short_compares_width", "({1'b0, x_cur} != W_LAST)", "({1'b0, x_cur} != W_C)")
mut(A, "adapter_short_line_not_flagged", "wire        viol    = run & (v_wide | v_short);", "wire        viol    = run & v_wide;")
mut(A, "adapter_long_line_not_flagged", "wire        viol    = run & (v_wide | v_short);", "wire        viol    = run & v_short;")
mut(A, "adapter_violation_passes_pixel", "wire        pass    = run & ~viol;", "wire        pass    = run;")
mut(A, "adapter_violation_keeps_frame",
    "            if (viol) begin\n                active <= 1'b0;\n            end\n            else if (pass) begin",
    "            if (viol) begin\n                active <= active;\n            end\n            else if (pass) begin")
mut(A, "adapter_frame_never_ends", "active <= ~last_ln;", "active <= 1'b1;")
mut(A, "adapter_eof_on_every_line", "out_eof  <= pass & s_last & last_ln;", "out_eof  <= pass & s_last;")
mut(A, "adapter_stray_pixels_pass", "wire        run    = s_de & (s_user | active);", "wire        run    = s_de;")
mut(A, "adapter_run_without_de", "wire        run    = s_de & (s_user | active);", "wire        run    = (s_user | active);")
mut(A, "adapter_restart_not_flagged", "geom_err <= (start & active) | viol;", "geom_err <= viol;")
mut(A, "adapter_only_restart_flagged", "geom_err <= (start & active) | viol;", "geom_err <= (start & active);")
mut(A, "adapter_sof_on_every_pixel", "out_sof  <= pass & s_user;", "out_sof  <= pass;")
mut(A, "adapter_eol_by_position_not_last", "out_eol  <= pass & s_last;", "out_eol  <= pass & ({1'b0, x_cur} == W_LAST);")
mut(A, "adapter_rgb_not_gated", "out_rgb  <= pass ? vid_rgb : 24'd0;", "out_rgb  <= vid_rgb;")
mut(A, "adapter_x_not_gated", "out_x    <= pass ? x_cur   : 12'd0;", "out_x    <= x_cur;")
mut(A, "adapter_de_not_dropping", "out_de   <= pass;", "out_de   <= s_de;")
mut(A, "adapter_delay_chain_too_short",
    "assign {s_de, s_user, s_last} = sr[3*SYNC_DELAY-1:3*SYNC_DELAY-3];", "assign {s_de, s_user, s_last} = sr[2:0];")
mut(A, "adapter_delay1_last_is_user", "else        sr <= {vid_de, vid_user, vid_last};", "else        sr <= {vid_de, vid_user, vid_user};")
mut(A, "adapter_reset_keeps_active",
    "            active       <= 1'b0;\n            out_de       <= 1'b0;", "            active       <= active;\n            out_de       <= 1'b0;")
mut(A, "adapter_rgb_rotated", "out_rgb  <= pass ? vid_rgb : 24'd0;", "out_rgb  <= pass ? {vid_rgb[7:0], vid_rgb[23:8]} : 24'd0;")


# --------------------------------------------------------------------------------- OSD modules
O = "osd_overlay"
mut(O, "osd_darken_shift_2", "{1'b0, r1_rgb[23:17], 1'b0, r1_rgb[15:9], 1'b0, r1_rgb[7:1]}",
    "{2'b0, r1_rgb[23:18], 2'b0, r1_rgb[15:10], 2'b0, r1_rgb[7:2]}")
mut(O, "osd_plate_weight_11", "parameter integer PLATE_A     = 12,", "parameter integer PLATE_A     = 11,")
mut(O, "osd_line_3px_wide", "(xw == {1'b0, c_linex} + 13'd1)", "(xw == {1'b0, c_linex} + 13'd2)")
mut(O, "osd_line_not_gated", "wire        line_hit = en_line & (", "wire        line_hit = (")
mut(O, "osd_box_outer_left_1px", "(xw + 13'd2 >= bxmin)", "(xw + 13'd1 >= bxmin)")
mut(O, "osd_box_outer_bottom_3px", "(yw <= bymax + 13'd2)", "(yw <= bymax + 13'd3)")
mut(O, "osd_box_inner_excludes_xmin", "wire        box_in  = (xw >= bxmin) & (xw <= bxmax)", "wire        box_in  = (xw > bxmin) & (xw <= bxmax)")
mut(O, "osd_box_filled", "wire        box_hit = en_box & c_valid & box_out & ~box_in;", "wire        box_hit = en_box & c_valid & box_out;")
mut(O, "osd_box_without_valid", "wire        box_hit = en_box & c_valid & box_out & ~box_in;", "wire        box_hit = en_box & box_out & ~box_in;")
mut(O, "osd_cross_arm_longer", "(xw + ARM >= ccx)", "(xw + ARM + 13'd1 >= ccx)")
mut(O, "osd_cross_thin", "(yw + 13'd1 >= ccy)", "(yw >= ccy)")
mut(O, "osd_cross_without_valid", "wire        cross_hit = en_cross & c_valid & (arm_h | arm_v);", "wire        cross_hit = en_cross & (arm_h | arm_v);")
mut(O, "osd_cross_no_vertical_arm", "wire        cross_hit = en_cross & c_valid & (arm_h | arm_v);", "wire        cross_hit = en_cross & c_valid & arm_h;")
mut(O, "osd_logo_not_gated", "wire        logo_in = en_logo & (xw >= LX0)", "wire        logo_in = (xw >= LX0)")
mut(O, "osd_plate_margin_7", "(xw + 13'd6 >= LX0)", "(xw + 13'd7 >= LX0)")
mut(O, "osd_plate_not_gated", "wire        plate_in = en_logo & ", "wire        plate_in = ")
mut(O, "osd_logo_addr_missing_term", "{ldy[6:0], 7'd0} + {2'd0, ldy[6:0], 5'd0} + {1'b0, ldx}", "{ldy[6:0], 7'd0} + {1'b0, ldx}")
mut(O, "osd_blend_weight_15", "p = v * (5'd16 - a) + c * a;", "p = v * (5'd15 - a) + c * a;")
mut(O, "osd_blend_wrong_shift", "blend8 = p[11:4];", "blend8 = p[12:5];")
mut(O, "osd_logo_colours_swapped", "wire [23:0] lcol  = r2_cls ? LOGO_RED : LOGO_NAVY;", "wire [23:0] lcol  = r2_cls ? LOGO_NAVY : LOGO_RED;")
mut(O, "osd_logo_navy_value", "localparam [23:0] LOGO_NAVY = 24'h1C2D4E;", "localparam [23:0] LOGO_NAVY = 24'h1C2D4F;")
mut(O, "osd_text_dropped", "wire [23:0] v_out = r2_glyph ? TEXT_COLOR : v_logo;", "wire [23:0] v_out = v_logo;")
mut(O, "osd_plate_ignored", "wire [23:0] v_line  = r1_line  ? LINE_COLOR  : v_plate;", "wire [23:0] v_line  = r1_line  ? LINE_COLOR  : v_dark;")
mut(O, "osd_glyph_bit_order", "font_q[3'd7 - r1_gx]", "font_q[r1_gx]")
mut(O, "osd_glyph_x_shifted", "r1_gx <= tgx;", "r1_gx <= tgx + 3'd1;")
mut(O, "osd_text_column_not_scaled", "wire [12:0] tcx    = tdx >> (3 + SCALE);", "wire [12:0] tcx    = tdx >> 3;")
mut(O, "osd_glyph_row_flipped", "wire [3:0]  tgy    = tpy[3:0];", "wire [3:0]  tgy    = tpy[3:0] ^ 4'd1;")
mut(O, "osd_text_col_off_by_one", "wire [4:0]  tcol   = tcx[4:0];", "wire [4:0]  tcol   = tcx[4:0] + 5'd1;")
mut(O, "osd_text_region_narrower", "localparam [12:0] TW  = (COLS * 8)  << SCALE;", "localparam [12:0] TW  = (COLS * 8 - 8) << SCALE;")
mut(O, "osd_backing_margin_7", "(xw + 13'd8 >= TX0)", "(xw + 13'd7 >= TX0)")
mut(O, "osd_backing_not_gated", "wire        back_in = en_text & ", "wire        back_in = ")
mut(O, "osd_box_colour_value", "parameter [23:0]  BOX_COLOR   = 24'h00FF40,", "parameter [23:0]  BOX_COLOR   = 24'h00FF41,")
mut(O, "osd_mode_name_gray_typo", '(mode == 2\'d1) ? "G"', '(mode == 2\'d1) ? "H"')
mut(O, "osd_digit_offset", "dig = 8'h30 + {4'd0, n};", "dig = 8'h31 + {4'd0, n};")
mut(O, "osd_title_glyph_wrong", "5'd12: c = 8'h84;", "5'd12: c = 8'h85;")
mut(O, "osd_x_digit_wrong", "5'd2: c = valid ? dig(bx[15:12]) : \"-\";", "5'd2: c = valid ? dig(bx[11:8]) : \"-\";")
mut(O, "osd_found_lost_swapped", "5'd7:  c = valid ? \"F\" : \"L\";", "5'd7:  c = valid ? \"L\" : \"F\";")
mut(O, "osd_area_digit_wrong", "5'd5:  c = dig(bc[23:20]);", "5'd5:  c = dig(bc[19:16]);")
mut(O, "osd_start_without_de", "wire        start = in_de & in_sof;", "wire        start = in_sof;")
mut(O, "osd_controls_not_latched", "        else if (start) begin\n            r_flags <= cfg_flags;", "        else begin\n            r_flags <= cfg_flags;")
mut(O, "osd_first_pixel_old_flags", "wire [4:0]  c_flags = start ? cfg_flags : r_flags;", "wire [4:0]  c_flags = r_flags;")
mut(O, "osd_first_pixel_old_valid", "wire        c_valid = start ? tgt_valid : r_valid;", "wire        c_valid = r_valid;")
mut(O, "osd_first_pixel_old_xmin", "wire [11:0] c_xmin  = start ? tgt_xmin  : r_xmin;", "wire [11:0] c_xmin  = r_xmin;")
mut(O, "osd_first_pixel_old_linex", "wire [11:0] c_linex = start ? line_x    : r_linex;", "wire [11:0] c_linex = r_linex;")
mut(O, "osd_rgb_not_gated", "out_rgb <= r2_de ? v_out : 24'd0;", "out_rgb <= v_out;")
mut(O, "osd_latency_short", "r2_de <= r1_de;", "r2_de <= in_de;")
mut(O, "osd_eof_not_gated", "out_eof <= r2_de & r2_eof;", "out_eof <= r2_eof;")

B = "osd_bin2bcd"
mut(B, "b2b_adjust_threshold_6", "if (acc[4*d +: 4] >= 4'd5)", "if (acc[4*d +: 4] > 4'd5)")
mut(B, "b2b_adjust_plus_2", "adj[4*d +: 4] = acc[4*d +: 4] + 4'd3;", "adj[4*d +: 4] = acc[4*d +: 4] + 4'd2;")
mut(B, "b2b_no_saturation", "wire [31:0]         cap   = (bin32 > MAXI) ? MAXI : bin32;", "wire [31:0]         cap   = bin32;")
mut(B, "b2b_one_iteration_short", "if (cnt == BITS - 1) begin", "if (cnt == BITS - 2) begin")
mut(B, "b2b_publishes_before_last_shift", "bcd  <= acc_next;", "bcd  <= acc;")
mut(B, "b2b_reset_keeps_bcd", "            bcd  <= {(4*DIGITS){1'b0}};\n        end\n        else if (!busy) begin", "            bcd  <= bcd;\n        end\n        else if (!busy) begin")

V = "view_mux"
mut(V, "vmux_gray_shows_mask", "2'd1:    sel = rgb_gray;", "2'd1:    sel = rgb_mask;")
mut(V, "vmux_tint_inverted", "default: sel = hit ? TINT_COLOR : rgb_orig;", "default: sel = hit ? rgb_orig : TINT_COLOR;")
mut(V, "vmux_rgb_not_gated", "out_rgb <= in_de ? sel : 24'd0;", "out_rgb <= sel;")
mut(V, "vmux_sof_not_gated", "out_sof <= in_de & in_sof;", "out_sof <= in_sof;")
mut(V, "vmux_x_not_gated", "out_x   <= in_de ? in_x : 12'd0;", "out_x   <= in_x;")

S = "sync_delay"
mut(S, "sd_many_takes_first_stage", "assign dout = sr[W*N-1:W*(N-1)];", "assign dout = sr[W-1:0];")
mut(S, "sd_one_inverts", "else        q <= din;", "else        q <= ~din;")
mut(S, "sd_reset_keeps_line", "if (!rst_n) sr <= {(W*N){1'b0}};", "if (!rst_n) sr <= sr;")


# ---------------------------------------------------------------- contest_vision_path (integration wrapper)
V = "contest_vision_path"
mut(V, "vp_proc_en_inverted", "wire proc_en = sw_b[0];", "wire proc_en = ~sw_b[0];")
mut(V, "vp_view_mode_wrong_bits", "wire [1:0] view_mode = sw_b[2:1];", "wire [1:0] view_mode = sw_b[1:0];")
mut(V, "vp_timing_delay_short", ".N(SKEW + 7), .W(2)", ".N(SKEW + 6), .W(2)")
mut(V, "vp_timing_delay_long", ".N(SKEW + 7), .W(2)", ".N(SKEW + 8), .W(2)")
mut(V, "vp_vs_de_swapped", ".din({vtc_vs, vtc_de})", ".din({vtc_de, vtc_vs})")
mut(V, "vp_orig_delay_1", "sync_delay #(.N(2), .W(24)) u_orig_dly", "sync_delay #(.N(1), .W(24)) u_orig_dly")
mut(V, "vp_adapter_skew_zero", ".SYNC_DELAY(SKEW)", ".SYNC_DELAY(0)")
mut(V, "vp_led3_stuck_on", "assign led = {proc_en,", "assign led = {1'b1,")
mut(V, "vp_bypass_data_wrong", "assign tx_data = proc_en ? o_rgb : base_data;", "assign tx_data = proc_en ? o_rgb : o_rgb;")
mut(V, "vp_bypass_vs_wrong", "assign tx_vs   = proc_en ? vd[1] : base_vs;", "assign tx_vs   = vd[1];")
mut(V, "vp_bypass_de_wrong", "assign tx_de   = proc_en ? vd[0] : base_de;", "assign tx_de   = vd[0];")
mut(V, "vp_draw_extra_ignored", ".cfg_flags({1'b1, draw_extra, draw_extra, draw_extra, 1'b1})", ".cfg_flags({1'b1, 1'b0, 1'b0, 1'b0, 1'b1})")
mut(V, "vp_line_x_shifted", ".line_x(LINE_X_C)", ".line_x(LINE_X_C + 12'd2)")
mut(V, "vp_R_MIN_off_by_one", ".R_MIN(R_MIN)", ".R_MIN(R_MIN + 1)")
mut(V, "vp_DELTA_off_by_one", "color_segment #(.R_MIN(R_MIN), .DELTA(DELTA),", "color_segment #(.R_MIN(R_MIN), .DELTA(DELTA - 1),")
mut(V, "vp_min_pixels_huge", ".MIN_PIXELS(MIN_PIXELS)", ".MIN_PIXELS(MIN_PIXELS + 900000)")

# ---------------------------------------------------------------- cross_counter (line-crossing state machine)
X = "cross_counter"
mut(X, "cc_hyst_ignored_left", "wire z_left  = valid & ((cx13 + hyst13) <  ln13);", "wire z_left  = valid & (cx13 < ln13);")
mut(X, "cc_hyst_wrong_sign_left", "wire z_left  = valid & ((cx13 + hyst13) <  ln13);", "wire z_left  = valid & ((cx13 - hyst13) <  ln13);")
mut(X, "cc_hyst_ignored_right", "wire z_right = valid & (cx13 > (ln13 + hyst13));", "wire z_right = valid & (cx13 > ln13);")
mut(X, "cc_left_inclusive", "wire z_left  = valid & ((cx13 + hyst13) <  ln13);", "wire z_left  = valid & ((cx13 + hyst13) <= ln13);")
mut(X, "cc_right_inclusive", "wire z_right = valid & (cx13 > (ln13 + hyst13));", "wire z_right = valid & (cx13 >= (ln13 + hyst13));")
mut(X, "cc_left_wraps_12bit", "wire z_left  = valid & ((cx13 + hyst13) <  ln13);", "wire z_left  = valid & (((cx13 + hyst13) & 13'h0FFF) <  ln13);")
mut(X, "cc_right_wraps_12bit", "wire z_right = valid & (cx13 > (ln13 + hyst13));", "wire z_right = valid & (cx13 > ((ln13 + hyst13) & 13'h0FFF));")
mut(X, "cc_valid_ignored", "wire z_none  = ~valid;", "wire z_none  = 1'b0;")
mut(X, "cc_confirm_off_by_one_up", "if (seen >= CONFIRM) begin", "if (seen > CONFIRM) begin")
mut(X, "cc_confirm_off_by_one_down", "if (seen >= CONFIRM) begin", "if (seen >= (CONFIRM - 1)) begin")
mut(X, "cc_deadband_keeps_candidate", "if (z == S_U) begin                                    // dead band\n                n_cand = S_U;\n                n_ccnt = 16'd0;\n", "if (z == S_U) begin                                    // dead band\n")
mut(X, "cc_same_side_keeps_candidate", "else if (z == side) begin\n                n_cand = S_U;\n                n_ccnt = 16'd0;\n", "else if (z == side) begin\n")
mut(X, "cc_lost_keeps_candidate", "n_lcnt = (lcnt > LOST_MAX) ? lcnt : (lcnt + 16'd1);\n            n_cand = S_U;\n            n_ccnt = 16'd0;\n", "n_lcnt = (lcnt > LOST_MAX) ? lcnt : (lcnt + 16'd1);\n")
mut(X, "cc_lost_never_forgets", "if (n_lcnt > LOST_MAX) n_side = S_U;", "if (1'b0) n_side = S_U;")
mut(X, "cc_lost_off_by_one", "if (n_lcnt > LOST_MAX) n_side = S_U;", "if (n_lcnt >= LOST_MAX) n_side = S_U;")
mut(X, "cc_lost_counter_not_cleared", "n_lcnt = 16'd0;\n            if (z == S_U)", "n_lcnt = lcnt;\n            if (z == S_U)")
mut(X, "cc_lost_counter_unsaturated", "n_lcnt = (lcnt > LOST_MAX) ? lcnt : (lcnt + 16'd1);", "n_lcnt = lcnt + 16'd1;")
mut(X, "cc_dir_swapped", "n_dir = (side == S_R);", "n_dir = (side == S_L);")
mut(X, "cc_counts_first_learned_side", "if (side != S_U) begin\n                        n_evt = 1'b1;", "if (1'b1) begin\n                        n_evt = 1'b1;")
mut(X, "cc_seen_not_restarted", "seen = (cand == z) ? (ccnt + 16'd1) : 16'd1;", "seen = ccnt + 16'd1;")
mut(X, "cc_side_not_updated", "n_side = z;", "n_side = side;")
mut(X, "cc_total_not_saturating", "cnt_total <= (cnt_total == CNT_MAX) ? cnt_total : (cnt_total + 1'b1);", "cnt_total <= cnt_total + 1'b1;")
mut(X, "cc_lr_not_saturating", "else       cnt_lr <= (cnt_lr == CNT_MAX) ? cnt_lr : (cnt_lr + 1'b1);", "else       cnt_lr <= cnt_lr + 1'b1;")
mut(X, "cc_rl_not_saturating", "if (n_dir) cnt_rl <= (cnt_rl == CNT_MAX) ? cnt_rl : (cnt_rl + 1'b1);", "if (n_dir) cnt_rl <= cnt_rl + 1'b1;")
mut(X, "cc_total_counts_double", "cnt_total <= (cnt_total == CNT_MAX) ? cnt_total : (cnt_total + 1'b1);", "cnt_total <= (cnt_total == CNT_MAX) ? cnt_total : (cnt_total + 2'd2);")
mut(X, "cc_lr_rl_swapped", "if (n_dir) cnt_rl <=", "if (!n_dir) cnt_rl <=")
mut(X, "cc_evt_stays_high", "            evt <= 1'b0;\n            if (upd) begin", "            if (upd) begin")
mut(X, "cc_upd_ignored", "            if (upd) begin\n                side <= n_side;", "            if (1'b1) begin\n                side <= n_side;")
mut(X, "cc_reset_keeps_cand_only", "            cand      <= S_U;\n            ccnt      <= 16'd0;", "            cand      <= cand;\n            ccnt      <= 16'd0;")
mut(X, "cc_reset_keeps_candidate_and_count", "            cand      <= S_U;\n            ccnt      <= 16'd0;", "            cand      <= cand;\n            ccnt      <= ccnt;")
mut(X, "cc_reset_keeps_side", "            side      <= S_U;\n            cand      <= S_U;", "            side      <= side;\n            cand      <= S_U;")
mut(X, "cc_reset_keeps_count", "            cnt_total <= {CNT_W{1'b0}};\n        end", "            cnt_total <= cnt_total;\n        end")

# ---------------------------------------------------------------- frame_commit (request / effective settings)
F = "frame_commit"
mut(F, "fc_pending_inverted", "assign pending = (req != eff);", "assign pending = (req == eff);")
mut(F, "fc_commit_ignored", "else if (commit) begin\n                eff <= req;", "else if (1'b1) begin\n                eff <= req;")
mut(F, "fc_never_seeded", "if (commit) seeded <= 1'b1;", "if (1'b0) seeded <= 1'b1;")
mut(F, "fc_seed_phase_holds", "eff <= req;\n                if (commit) seeded <= 1'b1;", "eff <= eff;\n                if (commit) seeded <= 1'b1;")
mut(F, "fc_changed_on_every_commit", "if (req != eff) begin\n                    changed <= 1'b1;", "if (1'b1) begin\n                    changed <= 1'b1;")
mut(F, "fc_gen_not_counted", "gen     <= gen + 8'd1;", "gen     <= gen;")
mut(F, "fc_gen_step_two", "gen     <= gen + 8'd1;", "gen     <= gen + 8'd2;")
mut(F, "fc_reset_value_zero", "eff     <= INIT;", "eff     <= {W{1'b0}};")
mut(F, "fc_reset_keeps_seeded", "seeded  <= 1'b0;\n            changed <= 1'b0;\n            gen     <= 8'd0;", "seeded  <= seeded;\n            changed <= 1'b0;\n            gen     <= 8'd0;")
mut(F, "fc_reset_keeps_gen", "            gen     <= 8'd0;\n        end\n        else begin", "            gen     <= gen;\n        end\n        else begin")
mut(F, "fc_changed_not_cleared", "            changed <= 1'b0;\n            if (!seeded) begin", "            if (!seeded) begin")
mut(F, "fc_changed_in_seed_phase", "                eff <= req;\n                if (commit) seeded <= 1'b1;", "                eff <= req;\n                if (commit) begin seeded <= 1'b1; changed <= (req != eff); end")

# ---------------------------------------------------------------- target_track
T = "target_track"
mut(T, "tt_jit_strict", "if (ad <= JIT)       follow = cur;", "if (ad <  JIT)       follow = cur;")
mut(T, "tt_jit_wider", "if (ad <= JIT)       follow = cur;", "if (ad <= JIT + 1)   follow = cur;")
mut(T, "tt_snap_inclusive_xmin", "(d_xmin > SNAP)", "(d_xmin >= SNAP)")
mut(T, "tt_snap_ymax_dropped", "| (d_ymin > SNAP) | (d_ymax > SNAP);", "| (d_ymin > SNAP);")
mut(T, "tt_snap_xmax_dropped", "| (d_xmax > SNAP) |", "|")
mut(T, "tt_step_full", "follow = cur + ad[12:1];", "follow = cur + ad[11:0];")
mut(T, "tt_step_rounds_up", "follow = cur + ad[12:1];", "follow = cur + ad[12:1] + {11'd0, ad[0]};")
mut(T, "tt_step_wrong_direction", "else                 follow = cur - ad[12:1];", "else                 follow = cur + ad[12:1];")
mut(T, "tt_centre_x_wrong", "assign t_cx = sx[12:1];", "assign t_cx = sx[11:0];")
mut(T, "tt_centre_y_uses_x", "assign t_cy = sy[12:1];", "assign t_cy = sx[12:1];")
mut(T, "tt_no_hold_state", "if (COAST_MAX >= 1) begin", "if (COAST_MAX >= 100) begin")
mut(T, "tt_coast_one_too_long", "if (age_n > COAST_MAX) begin", "if (age_n > COAST_MAX + 1) begin")
mut(T, "tt_coast_one_too_short", "if (age_n > COAST_MAX) begin", "if (age_n >= COAST_MAX) begin")
mut(T, "tt_reacquisition_smoothed",
    "                        t_xmin <= xmin; t_xmax <= xmax; t_ymin <= ymin; t_ymax <= ymax;\n                        state  <= S_TRACK;",
    "                        t_xmin <= follow(t_xmin, xmin); t_xmax <= follow(t_xmax, xmax); t_ymin <= follow(t_ymin, ymin); t_ymax <= follow(t_ymax, ymax);\n                        state  <= S_TRACK;")
mut(T, "tt_age_not_cleared_on_measurement", "                    age <= 8'd0;\n                    if (state == S_TRACK) begin", "                    if (state == S_TRACK) begin")
mut(T, "tt_age_wrap_hold", "if (age != 8'd255) age <= age[7:0] + 8'd1;", "age <= age[7:0] + 8'd1;")
mut(T, "tt_age_wrap_lost", "if (age != 8'd255) age <= age + 8'd1;", "age <= age + 8'd1;")
mut(T, "tt_reset_age_zero", "age    <= 8'd255;", "age    <= 8'd0;")
mut(T, "tt_acq_reacq_swapped", "if (state == S_HOLD) begin if (n_reacq != CNT_MAX)", "if (state == S_LOST) begin if (n_reacq != CNT_MAX)")
mut(T, "tt_jitter_counts_identical", "if (any_d && all_j && !clr_stats", "if (all_j && !clr_stats")
mut(T, "tt_jitter_counts_any_change", "if (any_d && all_j && !clr_stats", "if (any_d && !clr_stats")
mut(T, "tt_hold_counter_wraps", "if (!clr_stats && n_hold != CNT_MAX) n_hold <= n_hold + 1'b1;", "if (!clr_stats) n_hold <= n_hold + 1'b1;")
mut(T, "tt_acq_counter_wraps", "if (n_acq   != CNT_MAX) n_acq   <= n_acq   + 1'b1;", "n_acq   <= n_acq   + 1'b1;")
mut(T, "tt_clr_stats_ignored", "            if (clr_stats) begin\n                n_acq", "            if (1'b0) begin\n                n_acq")
mut(T, "tt_track_to_lost_not_counted",
    "else begin\n                                state <= S_LOST;\n                                if (!clr_stats && n_lost != CNT_MAX) n_lost <= n_lost + 1'b1;",
    "else begin\n                                state <= S_LOST;")
mut(T, "tt_hold_expiry_not_counted",
    "if (age_n > COAST_MAX) begin\n                                state <= S_LOST;\n                                if (!clr_stats && n_lost != CNT_MAX) n_lost <= n_lost + 1'b1;",
    "if (age_n > COAST_MAX) begin\n                                state <= S_LOST;")
mut(T, "tt_hold_follows_garbage_box", "S_HOLD: begin\n                            if (age != 8'd255) age <= age[7:0] + 8'd1;", "S_HOLD: begin\n                            t_xmin <= xmin;\n                            if (age != 8'd255) age <= age[7:0] + 8'd1;")
mut(T, "tt_reset_keeps_state", "            state  <= S_LOST;\n            t_xmin <= 12'd0;", "            state  <= state;\n            t_xmin <= 12'd0;")
mut(T, "tt_upd_ignored", "            if (upd) begin\n                if (valid) begin", "            if (1'b1) begin\n                if (valid) begin")

# ---------------------------------------------------------------- awb_frame (frame-held gray-world AWB) and div_seq (sequential divider)
A = "awb_frame"
mut(A, "af_sum_max_inclusive", "wire       p_ok  = (p_sum < SUM_MAX) && (p_sum >= SUM_MIN);", "wire       p_ok  = (p_sum <= SUM_MAX) && (p_sum >= SUM_MIN);")
mut(A, "af_sum_max_dropped", "wire       p_ok  = (p_sum < SUM_MAX) && (p_sum >= SUM_MIN);", "wire       p_ok  = (p_sum >= SUM_MIN);")
mut(A, "af_clamp_min_value", "else if (q[15:0] < GAIN_MIN) clamp_gain = GAIN_MIN;", "else if (q[15:0] < GAIN_MIN) clamp_gain = GAIN_MIN + 16'd64;")
mut(A, "af_clamp_min_plus1", "else if (q[15:0] < GAIN_MIN) clamp_gain = GAIN_MIN;", "else if (q[15:0] < GAIN_MIN) clamp_gain = GAIN_MIN + 16'd1;")
mut(A, "af_clamp_min_dropped", "else if (q[15:0] < GAIN_MIN) clamp_gain = GAIN_MIN;", "else if (1'b0) clamp_gain = GAIN_MIN;")
mut(A, "af_clamp_max_dropped", "if (|q[43:16])           clamp_gain = GAIN_MAX;\n            else if (q[15:0] > GAIN_MAX) clamp_gain = GAIN_MAX;", "if (1'b0)           clamp_gain = GAIN_MAX;\n            else if (q[15:0] > GAIN_MAX) clamp_gain = GAIN_MAX;")
mut(A, "af_gain_scale_wrong", "d_num   <= {cap_g, 12'd0};\n                    d_den   <= cap_r;", "d_num   <= {cap_g, 11'd0, 1'b0} >> 1;\n                    d_den   <= cap_r;")
mut(A, "af_blue_uses_red_sum", "d_den   <= cap_b;", "d_den   <= cap_r;")
mut(A, "af_frame_end_early", "(lcnt == IMG_HEIGHT - 1);", "(lcnt == IMG_HEIGHT - 2);")
mut(A, "af_line_count_step", "if (I_tlast) lcnt <= lcnt + 16'd1;", "if (I_tlast) lcnt <= lcnt + 16'd2;")
mut(A, "af_init_sum_zero", "sum_r   <= 32'd1 + a_r;", "sum_r   <= 32'd0 + a_r;")
mut(A, "af_unity_mode_ignored", "wire [15:0] gu_r = (I_mode == 2'd1) ? 16'd4096 : (d_user ? nx_r : g_r);", "wire [15:0] gu_r = (I_mode == 2'd3) ? 16'd4096 : (d_user ? nx_r : g_r);")
mut(A, "af_blue_gain_from_red", "m_b[k] <= gu_b * d_data[24*k +: 8];", "m_b[k] <= gu_r * d_data[24*k +: 8];")
mut(A, "af_first_beat_old_gain", "wire [15:0] gu_r = (I_mode == 2'd1) ? 16'd4096 : (d_user ? nx_r : g_r);", "wire [15:0] gu_r = (I_mode == 2'd1) ? 16'd4096 : g_r;")
mut(A, "af_gain_never_held", "else if (d_user && d_valid) begin g_r <= nx_r; g_b <= nx_b; end", "else if (1'b0) begin g_r <= nx_r; g_b <= nx_b; end")
mut(A, "af_partial_frame_ignored", "if (!fe_seen) part_q <= 1'b1;", "")
mut(A, "af_partial_sums_not_captured", "if (!fe_seen) begin cap_r <= sum_r; cap_g <= sum_g; cap_b <= sum_b; end", "")
mut(A, "af_saturation_mask", "sat12 = (|p[23:20]) ? 8'd255 : p[19:12];", "sat12 = (|p[23:21]) ? 8'd255 : p[19:12];")
mut(A, "af_delay_short", "localparam [AW-1:0] DLY = DELAY;", "localparam [AW-1:0] DLY = DELAY - 1;")
mut(A, "af_tuser_gated_by_valid", "assign O_tuser  = I_tuser;", "assign O_tuser  = I_tuser & I_tvalid & ~I_tlast;")
mut(A, "af_valid_not_masked", "wire        d_valid = rq[96] & mem_ok;", "wire        d_valid = rq[96];")
mut(A, "af_stats_all_channels_red", "sum_g <= sum_g + a_g;\n                sum_b <= sum_b + a_b;\n                if (I_tlast)", "sum_g <= sum_g + a_r;\n                sum_b <= sum_b + a_b;\n                if (I_tlast)")
mut(A, "af_tlast_not_delayed", "m_l <= d_last;", "m_l <= 1'b0;")
D = "div_seq"
mut(D, "ds_never_subtract", "r    <= ge ? r_sub : r_sh;", "r    <= r_sh;")
mut(D, "ds_quotient_bit_zero", "quo  <= {quo[NW-2:0], ge};", "quo  <= {quo[NW-2:0], 1'b0};")
mut(D, "ds_one_iteration_short", "cnt  <= NW;", "cnt  <= NW - 1;")
mut(D, "ds_ge_inverted", "wire        ge = ~r_sub[WD];", "wire        ge = r_sub[WD];")
mut(D, "ds_remainder_wrong", "rem  <= r[WD-1:0];", "rem  <= r_sh[WD-1:0];")
mut(D, "ds_dividend_not_shifted", "n_sh <= {n_sh[NW-2:0], 1'b0};", "n_sh <= n_sh;")
mut(D, "ds_start_while_busy", "if (!busy) begin\n                if (start) begin", "if (1'b1) begin\n                if (start) begin")


def find_tool(name):
    cands = [ROOT / "tools" / "iverilog" / "ucrt64" / "bin" / (name + ".exe")]
    w = shutil.which(name)
    if w:
        cands.append(Path(w))
    cands += [Path(r"C:\msys64\ucrt64\bin") / (name + ".exe"), Path(r"C:\iverilog\bin") / (name + ".exe")]
    for c in cands:
        if c.exists():
            return c
    return None


IVERILOG = find_tool("iverilog")
VVP = find_tool("vvp")
if not IVERILOG or not VVP:
    print("SIMULATION NOT RUN: iverilog/vvp not found")
    sys.exit(2)
ENV = dict(os.environ)
ENV["PATH"] = str(IVERILOG.parent) + os.pathsep + ENV.get("PATH", "")


def run_case(rtl_file, test, tag, timeout=1800):
    tb_name, extras = test
    vvp_file = WORK / (tag + RUN_TAG + ".vvp")
    c = subprocess.run([str(IVERILOG), "-g2005", "-Wall", "-o", str(vvp_file), str(TB / tb_name)]
                       + [str(e) for e in extras] + [str(rtl_file)],
                       capture_output=True, text=True, env=ENV, cwd=str(TB))
    if c.returncode != 0:
        return "COMPILE-ERROR", (c.stdout + c.stderr).strip()[:300]
    try:
        r = subprocess.run([str(VVP), str(vvp_file)], capture_output=True, text=True, env=ENV, cwd=str(TB), timeout=timeout)
    except subprocess.TimeoutExpired:
        return "TIMEOUT", ""
    out = r.stdout + r.stderr
    res = re.findall(r"TB_RESULT: (PASS|FAIL)", out)
    first_mismatch = next((l for l in out.splitlines() if l.startswith("MISMATCH") or "COVERAGE" in l), "")
    if res and res[-1] == "PASS" and "FAIL" not in res:
        return "PASS", ""
    return "FAIL", first_mismatch[:200]


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    pats = sys.argv[1:]
    lines = [f"mutation_test {time.strftime('%Y-%m-%d %H:%M:%S')}  tool={IVERILOG}", ""]

    # control runs
    for mod, test in TESTS.items():
        if pats and not any(p in mod or any(p in m[1] for m in M if m[0] == mod) for p in pats):
            continue
        t0 = time.time()
        st, info = run_case(RTL / (mod + ".v"), test, "control_" + mod)
        lines.append(f"control (unmutated) {mod:14s}: {st}  ({time.time()-t0:.0f} s) {info}")
        print(lines[-1], flush=True)
        if st != "PASS":
            lines.append("ABORT: the unmutated design does not pass, mutants are meaningless")
            (REPORT).write_text("\n".join(lines) + "\n", encoding="ascii", errors="replace")
            print("\n".join(lines[-1:]))
            return 1
    lines.append("")

    survivors, invalid, equivalent, killed = [], [], [], 0
    for mod, name, old, new in M:
        if pats and not any(p in name or p in mod for p in pats):
            continue
        src = (RTL / (mod + ".v")).read_text(encoding="ascii").replace("\r\n", "\n")
        n = src.count(old)
        if n != 1:
            lines.append(f"{name:42s} INVALID (pattern found {n} times)")
            invalid.append(name)
            print(lines[-1], flush=True)
            continue
        mfile = WORK / (name + RUN_TAG + ".v")
        mfile.write_text(src.replace(old, new), encoding="ascii")
        t0 = time.time()
        st, info = run_case(mfile, TESTS[mod], "mut_" + name)       # TESTS[mod] = (testbench, extra sources)
        dt = time.time() - t0
        if st in ("FAIL", "TIMEOUT"):
            killed += 1
            verdict = "killed"
        elif st == "COMPILE-ERROR":
            verdict = "INVALID (does not compile)"
            invalid.append(name)
        elif name in EQUIVALENT:
            verdict = "equivalent"
            equivalent.append(name)
            info = "(argued) " + EQUIVALENT[name]
        else:
            verdict = "SURVIVED"
            survivors.append(name)
        lines.append(f"{name:42s} {verdict:10s} [{mod}] {dt:5.0f}s  {info}")
        print(lines[-1], flush=True)

    lines += ["", f"killed={killed} survived={len(survivors)} equivalent(argued)={len(equivalent)} invalid={len(invalid)}"]
    if survivors:
        lines.append("SURVIVORS (testbench cannot see these bugs): " + ", ".join(survivors))
    if invalid:
        lines.append("INVALID mutants (fix the pattern): " + ", ".join(invalid))
    (REPORT).write_text("\n".join(lines) + "\n", encoding="ascii", errors="replace")
    print("\n".join(lines[-3:]))
    return 0 if not survivors and not invalid else 1


if __name__ == "__main__":
    sys.exit(main())
