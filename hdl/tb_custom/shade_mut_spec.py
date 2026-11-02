# mutants for tb_shade_diag (shade_diag + flat_stats + shade_report + uart_tx8), used by ms_mutants.py
MUT = [
    ("sd_skew_wrong", "shade_diag.v", ".SYNC_DELAY(SKEW)", ".SYNC_DELAY(SKEW + 1)"),
    ("sd_mode_wrap_wrong", "shade_diag.v", "awb_mode <= (awb_mode == 2'd2) ? 2'd0 : (awb_mode + 2'd1);", "awb_mode <= (awb_mode == 2'd3) ? 2'd0 : (awb_mode + 2'd1);"),
    ("sd_key2_ignored", "shade_diag.v", "if (diag_active && press[1]) rep_en <= ~rep_en;", "if (diag_active && press[1]) rep_en <= rep_en;"),
    ("sd_key1_without_active", "shade_diag.v", "if (diag_active && press[0]) begin", "if (press[0]) begin"),
    ("sd_key2_without_active", "shade_diag.v", "if (diag_active && press[1]) rep_en", "if (press[1]) rep_en"),
    ("sd_report_without_active", "shade_diag.v", "if (diag_active && rep_en && !st_busy && !rep_busy) begin", "if (rep_en && !st_busy && !rep_busy) begin"),
    ("sd_rep_count_not_incr", "shade_diag.v", "rep_count <= rep_count + 8'd1;", "rep_count <= rep_count;"),
    ("fs_cell_width_off", "flat_stats.v", "wire        run_end = (xc == CELL_W - 1) || in_eol;", "wire        run_end = (xc == CELL_W - 2) || in_eol;"),
    ("fs_row_base_step", "flat_stats.v", "row_base <= row_base + GRID_W;", "row_base <= row_base + GRID_W + 1;"),
    ("fs_cell_height_off", "flat_stats.v", "if (yc == CELL_H - 1) begin", "if (yc == CELL_H) begin"),
    ("fs_clear_skipped", "flat_stats.v", "if (clr_cnt == NCELL - 1) state <= S_WAIT;", "if (1'b1) state <= S_WAIT;"),
    ("fs_rmw_wrong_channel", "flat_stats.v", "wire [20:0] n_g = q_g + {6'd0, p_g};", "wire [20:0] n_g = q_g + {6'd0, p_r};"),
    ("fs_flush_addr_off", "flat_stats.v", "f_addr <= cell_addr;", "f_addr <= cell_addr + 8'd1;"),
    ("fs_read_addr_in_fin", "flat_stats.v", "assign ra = (state == S_ACC || state == S_FIN) ? f_addr : ext_addr;", "assign ra = (state == S_ACC) ? f_addr : ext_addr;"),
    ("fs_g_sum_uses_r", "flat_stats.v", "wire [14:0] sg_n = sg + {7'd0, in_rgb[15:8]};", "wire [14:0] sg_n = sg + {7'd0, in_rgb[23:16]};"),
    ("sr_r_digit_wrong", "shade_report.v", "6'd7:  cell_ch = hexc(d[19:16]);", "6'd7:  cell_ch = hexc(d[15:12]);"),
    ("sr_checksum_not_added", "shade_report.v", "if (pos == 6'd0) chk <= chk + cell_sum;", "if (pos == 6'd0) chk <= chk;"),
    ("sr_checksum_off_by_one", "shade_report.v", "chk <= chk + cell_sum;", "chk <= chk + cell_sum + 16'd1;"),
    ("sr_row_step", "shade_report.v", "crow    <= crow + 4'd1;", "crow    <= crow + 4'd2;"),
    ("sr_mode_field", "shade_report.v", "6'd7:  hdr_ch = hexc(mode_q);", "6'd7:  hdr_ch = hexc(4'd0);"),
    ("sr_frame_no_field", "shade_report.v", "frame_q <= frame_no;", "frame_q <= 8'd0;"),
    ("sr_ram_wait_zero", "shade_report.v", "wait_n <= 4'd2;", "wait_n <= 4'd0;"),
    ("sr_b_digit_wrong", "shade_report.v", "6'd25: cell_ch = hexc(d[45:42]);", "6'd25: cell_ch = hexc(d[49:46]);"),
    ("ut_stop_bit_short", "uart_tx8.v", "if (bitn == 4'd9) begin", "if (bitn == 4'd8) begin"),
    ("ut_bit_order", "uart_tx8.v", "sh   <= {1'b1, data, 1'b0};", "sh   <= {1'b1, data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7], 1'b0};"),
]

EQUIV = {
    "sd_report_without_active": "the capture then runs but is never printed: C_CAP still requires diag_active && rep_en before it starts a report, "
                                "so nothing observable (UART, outputs) changes; only the internal measurement activity differs",
    "sr_ram_wait_zero": "the 2-clock wait in S_WAIT is a safety margin: rd_addr is already stable one clock before S_ADDR, the RAM output is valid "
                        "at the first clock of S_WAIT, so a wait of 0 returns the same data",
}
