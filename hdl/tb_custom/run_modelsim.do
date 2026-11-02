# run_modelsim.do - run the self-checking testbenches in ModelSim / Questa (vsim -c).
#
# Tested with ModelSim SE-64 2020.4 at F:\medolsim (see docs/STATUS_FOR_CODEX.md for the actual results).
# The license must be configured by the owner of that ModelSim copy (LM_LICENSE_FILE).
#
# Usage (any current directory):
#     F:\medolsim\win64\vsim.exe -c -do "set TBDIR F:/fpga_s2/tb_custom; do F:/fpga_s2/tb_custom/run_modelsim.do"
# Skip the long 1280x720 chain tests: add "set SKIPCHAIN 1;" in front of "do".
# Run only one testbench:             add "set ONLY tb_vision_v2;" in front of "do".
# Exhaustive colour sweeps (slow):    add "set FULL 1;" in front of "do".
# Each testbench prints "TB_RESULT: PASS <name>" or "TB_RESULT: FAIL <name> errors=N".
# WARNING: vsim -c returns exit code 0 even when this script aborts with a Tcl error. Judge success by
# the TB_RESULT lines in the transcript, never by the exit code.

# NOTE: [info script] is NOT usable here (ModelSim runs `do` files from an internal temp path), so the
# testbench directory is passed in as TBDIR (default: the current directory, which must be tb_custom).
if {![info exists TBDIR]} { set TBDIR [pwd] }
set here [file normalize $TBDIR]
set root [file dirname $here]
# optional: WRKNAME = another work-library folder name (several runs in parallel), RTLDIR = directory (relative to the project root)
# that replaces rtl_custom (a copy with ONE deliberately broken file, used to prove that the testbench can fail)
set wrkname modelsim_work
if {[info exists WRKNAME]} { set wrkname $WRKNAME }
set wrk  [file join $root logs_custom $wrkname]
file mkdir $wrk
cd $wrk

if {![info exists FULL]}      { set FULL 0 }
if {![info exists SKIPCHAIN]} { set SKIPCHAIN 0 }
set defs {}
if {$FULL} { set defs "+define+FULL_SWEEP" }

# {testbench-and-top-module  {source files relative to F:/fpga_s2}}
# lab1/.../uivtc.v is the UNMODIFIED baseline timing generator, it is only read.
set uivtc lab1/user_source/hdl_source/vtc/uivtc.v
set osdsrc [list rtl_custom/osd_overlay.v rtl_custom/osd_bin2bcd.v rtl_custom/osd_font_rom.v rtl_custom/osd_logo_rom.v]
set tests [list \
    [list tb_rgb_to_gray       [list rtl_custom/rgb_to_gray.v]] \
    [list tb_color_segment     [list rtl_custom/color_segment.v]] \
    [list tb_frame_bbox        [list rtl_custom/frame_bbox.v]] \
    [list tb_video_pos_adapter [list tb_custom/tb_vtc_chk.v rtl_custom/video_pos_adapter.v $uivtc]] \
    [list tb_osd_aux           [list rtl_custom/osd_bin2bcd.v rtl_custom/view_mux.v rtl_custom/sync_delay.v]] \
    [list tb_osd_overlay       $osdsrc] \
    [list tb_cross_counter     [list rtl_custom/cross_counter.v]] \
    [list tb_seg7_scan         [list rtl_custom/seg7_scan.v]] \
    [list tb_view_mux_style    [list rtl_custom/view_mux_style.v]] \
    [list tb_camera_tone       [list rtl_custom/camera_tone.v]] \
    [list tb_frame_commit      [list rtl_custom/frame_commit.v]] \
    [list tb_target_track      [list rtl_custom/target_track.v]] \
]
if {!$SKIPCHAIN} {
    lappend tests [list tb_pos_chain [list tb_custom/tb_vtc_chk.v rtl_custom/video_pos_adapter.v \
                                           rtl_custom/color_segment.v rtl_custom/frame_bbox.v $uivtc]]
    lappend tests [list tb_osd_chain [concat [list tb_custom/tb_vtc_chk.v rtl_custom/video_pos_adapter.v \
                                           rtl_custom/color_segment.v rtl_custom/frame_bbox.v] \
                                           [lrange $osdsrc 1 end] [list rtl_custom/osd_overlay.v $uivtc]]]
    # the block that is wired into contest_work (default SKEW=2): real uivtc, bypass + 4 views
    lappend tests [list tb_vision_path [concat [list rtl_custom/contest_vision_path.v rtl_custom/video_pos_adapter.v \
                                           rtl_custom/rgb_to_gray.v rtl_custom/color_segment.v rtl_custom/frame_bbox.v \
                                           rtl_custom/view_mux.v rtl_custom/sync_delay.v] $osdsrc [list $uivtc]]]
    # v2 build (three colours, shapes, adaptive thresholds, keys, UART, 7-segment ...): real uivtc, 20 frames at 1280x720
    lappend tests [list tb_vision_v2 [concat [list rtl_custom/contest_vision_v2.v rtl_custom/video_pos_adapter.v                                            rtl_custom/rgb_to_gray.v rtl_custom/color_seg_rt.v rtl_custom/hit_open.v rtl_custom/luma_mean.v                                            rtl_custom/thr_adapt.v rtl_custom/frame_bbox.v rtl_custom/shape_classify.v                                            rtl_custom/cross_counter.v rtl_custom/view_mux_style.v rtl_custom/edge_style.v rtl_custom/sync_delay.v                                            rtl_custom/osd_ext.v rtl_custom/ui_ctrl.v rtl_custom/key_debounce.v                                            rtl_custom/pulse_to_toggle.v rtl_custom/fps_meter.v rtl_custom/byte_cdc.v                                            rtl_custom/uart_report.v rtl_custom/seg7_scan.v rtl_custom/beep_ctrl.v rtl_custom/frame_commit.v rtl_custom/target_track.v] $osdsrc [list $uivtc]]]
    # HDMI diagnostic test patterns (16 patterns, every active pixel of 16 frames compared)
    lappend tests [list tb_hdmi_testpat [list rtl_custom/hdmi_testpat.v rtl_custom/key_debounce.v $uivtc]]
    # flat-field shading diagnostic (UART text report of the cell sums, AWB mode keys): real uivtc timing, ~10 minutes
    lappend tests [list tb_shade_diag [list rtl_custom/shade_diag.v rtl_custom/flat_stats.v rtl_custom/shade_report.v rtl_custom/uart_tx8.v rtl_custom/video_pos_adapter.v rtl_custom/key_debounce.v $uivtc]]
}
# golden data of the OSD testbenches: python tb_custom/gen_osd_golden.py must have been run (run_all.ps1 does it)
set golden [file join $here osd_assets golden]

if {[file exists work]} { vdel -lib work -all }
vlib work

foreach t $tests {
    set top  [lindex $t 0]
    set srcs [lindex $t 1]
    if {[info exists ONLY] && $ONLY ne $top} { continue }
    set files {}
    foreach s $srcs {
        if {[info exists RTLDIR] && [string match "rtl_custom/*" $s]} { set s "$RTLDIR/[string range $s 11 end]" }
        lappend files [file join $root $s]
    }
    echo "#### compile $top"
    vlog -work work {*}$defs [file join $here $top.v] {*}$files
    echo "#### run $top"
    # optional parameter overrides, e.g. set GENERICS {-G/tb_vision_v2/dut/BORDER=4} in front of "do"
    if {[info exists GENERICS]} { set gopts $GENERICS } else { set gopts {} }
    vsim -c -onfinish stop {*}$gopts +GOLDEN=$golden work.$top
    run -all
    quit -sim
}
echo "#### done - look for TB_RESULT lines above"
quit -f
