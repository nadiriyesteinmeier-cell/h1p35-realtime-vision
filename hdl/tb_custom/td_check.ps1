# td_check.ps1 - tool-based checks that need NO simulator and NO board, using the installed TD:
#   1. read_verilog + optimize_rtl on each module in rtl_custom (parse, elaborate, RTL optimize, latch count)
#   2. analyze of each testbench together with its module (syntax / binding check of the testbench)
#   3. negative control: a deliberately broken testbench copy must be REJECTED, so check 2 is not vacuous
# This is NOT a simulation and says nothing about functional correctness or timing.
# It does not open any .al project and does not touch lab1/lab2/lab3.
#
#   powershell -ExecutionPolicy Bypass -File F:\fpga_s2\tb_custom\td_check.ps1
# Output: F:\fpga_s2\logs_custom\td_check\  (per-run .out files and td_check_summary.txt). Exit 0 = all as expected.
param([string]$TdDir = "F:\TD")

$ErrorActionPreference = "Continue"
$tbDir  = $PSScriptRoot
$root   = Split-Path -Parent $tbDir
$out    = Join-Path $root "logs_custom\td_check"
$work   = Join-Path $out "work"
$exe    = Join-Path $TdDir "bin\td_commands_prompt.exe"
if (-not (Test-Path $exe)) { Write-Host "TD not found at $exe"; exit 2 }
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Force $work | Out-Null

function Fwd([string]$p) { return $p.Replace('\', '/') }

function Run-Td([string]$name, [string]$tclBody) {
    $tcl = Join-Path $work "$name.tcl"
    $o   = Join-Path $out  "$name.out"
    Set-Content -Path $tcl -Value $tclBody -Encoding ASCII
    $p = Start-Process -FilePath $exe -ArgumentList "$name.tcl" -WorkingDirectory $work -NoNewWindow -PassThru `
         -RedirectStandardOutput $o -RedirectStandardError ($o + ".err")
    if (-not $p.WaitForExit(240000)) { $p.Kill(); return "TIMEOUT" }
    return (Get-Content $o -Raw -Encoding UTF8)
}

$dev = "import_device ph1_35p.db -package PH1P35MDG324 -speed 3"
# m  = module in rtl_custom checked with read_verilog + optimize_rtl
# tb = testbench analyzed together with its sources (extra = other files it needs, relative to F:\fpga_s2)
$uivtc = "lab1\user_source\hdl_source\vtc\uivtc.v"        # unmodified baseline file, only read
$mods = @(
    @{ m = "rgb_to_gray";       tb = "tb_rgb_to_gray";       extra = @() },
    @{ m = "color_segment";     tb = "tb_color_segment";     extra = @() },
    @{ m = "frame_bbox";        tb = "tb_frame_bbox";        extra = @() },
    @{ m = "video_pos_adapter"; tb = "tb_video_pos_adapter"; extra = @("tb_custom\tb_vtc_chk.v", $uivtc) },
    @{ m = "cross_counter";     tb = "tb_cross_counter";     extra = @() }
)
# the chain testbench needs several modules at once; it is analyzed as its own entry (no module of its own)
$chain = @{ tb = "tb_pos_chain"; extra = @("tb_custom\tb_vtc_chk.v", "rtl_custom\video_pos_adapter.v", "rtl_custom\color_segment.v",
                                          "rtl_custom\frame_bbox.v", $uivtc) }
# TD's analyzer does not accept hierarchical references into a child module (u_vtc.hcnt / u_vtc.vcnt in
# tb_vtc_chk.v), which iverilog and ModelSim accept. For the TD syntax check only, a patched COPY with those two
# references replaced by constants is analyzed; the real file is never changed.
$vcSrc = [IO.File]::ReadAllText((Join-Path $tbDir "tb_vtc_chk.v"))
$vcTd  = $vcSrc.Replace("u_vtc.hcnt", "12'd0").Replace("u_vtc.vcnt", "12'd0")
$vcTdFile = Join-Path $work "tb_vtc_chk_td.v"
[IO.File]::WriteAllText($vcTdFile, $vcTd)
function Extra-Path([string]$e) {
    if ($e -like "*tb_vtc_chk.v") { return (Fwd $vcTdFile) }
    return (Fwd (Join-Path $root $e))
}
$lines = @("td_check $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  TD=$exe", "",
           "note: tb_vtc_chk.v is analyzed as a patched copy (hierarchical refs u_vtc.hcnt/vcnt -> constants), TD limitation", "")
$ok = $true

foreach ($x in $mods) {
    $rtl = Fwd (Join-Path $root ("rtl_custom\" + $x.m + ".v"))
    $tb  = Fwd (Join-Path $tbDir ($x.tb + ".v"))

    # 1. read + optimize_rtl
    $txt = Run-Td ("syn_" + $x.m) "$dev`nread_verilog -file `"$rtl`" -top $($x.m)`noptimize_rtl`nreport_area -file $($x.m)_rtl.area`nputs `"#### FINISHED`"`nexit`n"
    $errs   = ([regex]::Matches($txt, "ERROR")).Count
    $warns  = ([regex]::Matches($txt, "\bWARNING\b")).Count      # upper case only: the banner contains 'hdl_warning_level'
    $latch  = [regex]::Match($txt, "#LATCH\s+(\d+)").Groups[1].Value
    $fin    = $txt -match "#### FINISHED"
    $good   = ($errs -eq 0) -and $fin -and ($latch -eq "0")
    if (-not $good) { $ok = $false }
    $lines += ("{0,-14} read_verilog+optimize_rtl : {1}  errors={2} warnings={3} latches={4} finished={5}" -f $x.m, $(if ($good) {"OK"} else {"PROBLEM"}), $errs, $warns, $latch, $fin)

    # 2. analyze testbench with its module and the other files it needs
    $an = ""
    foreach ($e in $x.extra) { $an += "analyze -file `"$(Extra-Path $e)`"`n" }
    $txt = Run-Td ("tb_" + $x.m) ("$dev`nanalyze -file `"$rtl`"`n$an" + "analyze -file `"$tb`"`nputs `"#### FINISHED`"`nexit`n")
    $errs = ([regex]::Matches($txt, "ERROR")).Count
    $good = ($errs -eq 0) -and ($txt -match "#### FINISHED")
    if (-not $good) { $ok = $false }
    $lines += ("{0,-18} analyze testbench        : {1}  errors={2}" -f $x.tb, $(if ($good) {"OK"} else {"PROBLEM"}), $errs)
}

# 2b. the chain testbench with all modules it instantiates
$an = ""
foreach ($e in $chain.extra) { $an += "analyze -file `"$(Extra-Path $e)`"`n" }
$tbc = Fwd (Join-Path $tbDir ($chain.tb + ".v"))
$txt = Run-Td ("tb_" + $chain.tb) ("$dev`n$an" + "analyze -file `"$tbc`"`nputs `"#### FINISHED`"`nexit`n")
$errs = ([regex]::Matches($txt, "ERROR")).Count
$good = ($errs -eq 0) -and ($txt -match "#### FINISHED")
if (-not $good) { $ok = $false }
$lines += ("{0,-18} analyze testbench        : {1}  errors={2}" -f $chain.tb, $(if ($good) {"OK"} else {"PROBLEM"}), $errs)

# 2c. OSD: single-file helpers, then the multi-file OSD blocks taken through technology mapping (optimize_gate)
#     so that the block-RAM (ERAM) inference of the generated ROMs is visible. A ROM written in TD's template style
#     ((*rom_style="bram"*) array + initial + synchronous read) triggers the expected HDL-5314 'mem does not have
#     a driver' warning although the initial values ARE used as ERAM contents (verified in the netlist INIT data).
function Rtl([string]$f) { return (Fwd (Join-Path $root ("rtl_custom\" + $f + ".v"))) }
function Run-Block([string]$name, [string[]]$files, [string]$top, [bool]$gate) {
    $body = "$dev`n"
    foreach ($f in $files) { $body += "analyze -file `"$(Rtl $f)`"`n" }
    $body += "elaborate -top $top`noptimize_rtl`nreport_area -file ${name}_rtl.area`n"
    if ($gate) { $body += "optimize_gate -packarea ${name}_gate.area`nreport_area -file ${name}_gate_rpt.area`n" }
    $body += "puts `"#### FINISHED`"`nexit`n"
    $txt = Run-Td ("blk_" + $name) $body
    $errs  = ([regex]::Matches($txt, "ERROR")).Count
    $warn  = ([regex]::Matches($txt, "\bWARNING\b")).Count
    $w5314 = ([regex]::Matches($txt, "HDL-5314 WARNING")).Count
    $latch = [regex]::Match($txt, "#LATCH\s+(\d+)").Groups[1].Value
    $eram  = ""
    $rtl_rpt = Join-Path $work "${name}_rtl.area"
    if (Test-Path $rtl_rpt) {
        $rt = Get-Content $rtl_rpt -Raw
        $m = [regex]::Match($rt, "#DFF\s+(\d+)"); if ($m.Success) { $eram += "DFF $($m.Groups[1].Value)  " }
    }
    $rpt = Join-Path $work "${name}_gate_rpt.area"
    if ($gate -and (Test-Path $rpt)) {
        $m = [regex]::Match((Get-Content $rpt -Raw), "#eram\s+(\d+)\s+out of\s+(\d+)"); if ($m.Success) { $eram = "ERAM $($m.Groups[1].Value)/$($m.Groups[2].Value)" }
        $m = [regex]::Match((Get-Content $rpt -Raw), "#lut\s+(\d+)"); if ($m.Success) { $eram += "  LUT $($m.Groups[1].Value)" }
    }
    $good = ($errs -eq 0) -and ($txt -match "#### FINISHED") -and (($latch -eq "0") -or ($latch -eq ""))
    return @{ good = $good; line = ("{0,-18} analyze+elaborate+optimize_rtl{1}: {2}  errors={3} warnings={4} (of which HDL-5314: {5}) latches={6} {7}" -f `
              $name, $(if ($gate) {"+optimize_gate"} else {""}), $(if ($good) {"OK"} else {"PROBLEM"}), $errs, $warn, $w5314, $latch, $eram) }
}
$blocks = @(
    @{ n = "osd_bin2bcd";   f = @("osd_bin2bcd");                                                     t = "osd_bin2bcd";   g = $false },
    @{ n = "view_mux";      f = @("view_mux");                                                        t = "view_mux";      g = $false },
    @{ n = "sync_delay";    f = @("sync_delay");                                                      t = "sync_delay";    g = $false },
    @{ n = "osd_font_rom";  f = @("osd_font_rom");                                                    t = "osd_font_rom";  g = $true  },
    @{ n = "osd_logo_rom";  f = @("osd_logo_rom");                                                    t = "osd_logo_rom";  g = $true  },
    @{ n = "osd_overlay";   f = @("osd_bin2bcd", "osd_font_rom", "osd_logo_rom", "osd_overlay");      t = "osd_overlay";   g = $false },  # ~250 ports: as a stand-alone chip it exceeds the 160 device IOs in Map IO (not a design problem)
    @{ n = "contest_vision_path"; f = @("sync_delay", "view_mux", "rgb_to_gray", "color_segment", "frame_bbox", "video_pos_adapter",
                                        "osd_bin2bcd", "osd_font_rom", "osd_logo_rom", "osd_overlay", "contest_vision_path");
                                  t = "contest_vision_path"; g = $false },  # the block wired into contest_work; RTL level only (>160 ports)
    # ---- v2 modules (contest_work_v2)
    @{ n = "color_seg_rt";    f = @("color_seg_rt");                  t = "color_seg_rt";    g = $false },
    @{ n = "hit_open";        f = @("sync_delay", "hit_open");        t = "hit_open";        g = $false },
    @{ n = "luma_mean";       f = @("luma_mean");                     t = "luma_mean";       g = $false },
    @{ n = "thr_adapt";       f = @("thr_adapt");                     t = "thr_adapt";       g = $false },
    @{ n = "shape_classify";  f = @("shape_classify");                t = "shape_classify";  g = $false },
    @{ n = "cross_counter";   f = @("cross_counter");                 t = "cross_counter";   g = $false },
    @{ n = "edge_style";      f = @("edge_style");                    t = "edge_style";      g = $true  },   # optimize_gate: the two line buffers must become block RAM
    @{ n = "view_mux_style";  f = @("view_mux_style");                t = "view_mux_style";  g = $false },
    @{ n = "key_debounce";    f = @("key_debounce");                  t = "key_debounce";    g = $false },
    @{ n = "ui_ctrl";         f = @("key_debounce", "ui_ctrl");       t = "ui_ctrl";         g = $false },
    @{ n = "pulse_to_toggle"; f = @("pulse_to_toggle");               t = "pulse_to_toggle"; g = $false },
    @{ n = "fps_meter";       f = @("fps_meter");                     t = "fps_meter";       g = $false },
    @{ n = "byte_cdc";        f = @("byte_cdc");                      t = "byte_cdc";        g = $false },
    @{ n = "uart_report";     f = @("osd_bin2bcd", "uart_report");    t = "uart_report";     g = $false },
    @{ n = "seg7_scan";       f = @("seg7_scan");                     t = "seg7_scan";       g = $false },
    @{ n = "beep_ctrl";       f = @("beep_ctrl");                     t = "beep_ctrl";       g = $false },
    @{ n = "osd_ext";         f = @("osd_bin2bcd", "osd_font_rom", "osd_ext"); t = "osd_ext"; g = $false },
    @{ n = "contest_vision_v2"; f = @("sync_delay", "video_pos_adapter", "rgb_to_gray", "color_seg_rt", "hit_open", "luma_mean", "thr_adapt",
                                      "frame_bbox", "shape_classify", "cross_counter", "edge_style", "view_mux_style", "osd_bin2bcd",
                                      "osd_font_rom", "osd_logo_rom", "osd_overlay", "osd_ext", "key_debounce", "ui_ctrl", "pulse_to_toggle",
                                      "fps_meter", "byte_cdc", "uart_report", "seg7_scan", "beep_ctrl", "contest_vision_v2");
                                t = "contest_vision_v2"; g = $false }   # the v2 block; RTL level only (>160 ports)
)
foreach ($b in $blocks) {
    $r = Run-Block $b.n $b.f $b.t $b.g
    if (-not $r.good) { $ok = $false }
    $lines += $r.line
}
# testbenches of the OSD modules, analyzed together with everything they instantiate
$osdTbs = @(
    @{ tb = "tb_osd_aux";     f = @("osd_bin2bcd", "view_mux", "sync_delay"); extra = @() },
    @{ tb = "tb_osd_overlay"; f = @("osd_bin2bcd", "osd_font_rom", "osd_logo_rom", "osd_overlay"); extra = @() },
    @{ tb = "tb_osd_chain";   f = @("video_pos_adapter", "color_segment", "frame_bbox", "osd_bin2bcd", "osd_font_rom", "osd_logo_rom", "osd_overlay");
                              extra = @("tb_custom\tb_vtc_chk.v", $uivtc) }
)
foreach ($t in $osdTbs) {
    $body = "$dev`n"
    foreach ($f in $t.f) { $body += "analyze -file `"$(Rtl $f)`"`n" }
    foreach ($e in $t.extra) { $body += "analyze -file `"$(Extra-Path $e)`"`n" }
    $body += "analyze -file `"$(Fwd (Join-Path $tbDir ($t.tb + '.v')))`"`nputs `"#### FINISHED`"`nexit`n"
    $txt = Run-Td ("tb_" + $t.tb) $body
    $errs = ([regex]::Matches($txt, "ERROR")).Count
    $good = ($errs -eq 0) -and ($txt -match "#### FINISHED")
    if (-not $good) { $ok = $false }
    $lines += ("{0,-18} analyze testbench        : {1}  errors={2}" -f $t.tb, $(if ($good) {"OK"} else {"PROBLEM"}), $errs)
}

# the integration testbench uses hierarchical references into uivtc (u_vtc.hcnt / u_vtc.vcnt): analyzed as a patched copy
$vpSrc = [IO.File]::ReadAllText((Join-Path $tbDir "tb_vision_path.v"))
$vpTdFile = Join-Path $work "tb_vision_path_td.v"
[IO.File]::WriteAllText($vpTdFile, $vpSrc.Replace("u_vtc.hcnt", "12'd0").Replace("u_vtc.vcnt", "12'd0"))
$body = "$dev`n"
foreach ($f in @("sync_delay", "view_mux", "rgb_to_gray", "color_segment", "frame_bbox", "video_pos_adapter", "osd_bin2bcd", "osd_font_rom", "osd_logo_rom", "osd_overlay", "contest_vision_path")) {
    $body += "analyze -file `"$(Rtl $f)`"`n"
}
$body += "analyze -file `"$(Fwd (Join-Path $root $uivtc))`"`nanalyze -file `"$(Fwd $vpTdFile)`"`nputs `"#### FINISHED`"`nexit`n"
$txt = Run-Td "tb_tb_vision_path" $body
$errs = ([regex]::Matches($txt, "ERROR")).Count
$good = ($errs -eq 0) -and ($txt -match "#### FINISHED")
if (-not $good) { $ok = $false }
$lines += ("{0,-18} analyze testbench        : {1}  errors={2}  (patched copy: hierarchical refs -> constants)" -f "tb_vision_path", $(if ($good) {"OK"} else {"PROBLEM"}), $errs)

# 3. negative control on one testbench
$src = [IO.File]::ReadAllText((Join-Path $tbDir "tb_rgb_to_gray.v"))
$bad = $src.Replace("nz_gray = nz_gray + 1;", "nz_gray = nz_gray + 1")
if ($bad -eq $src) { $lines += "negative control: could not build the broken copy"; $ok = $false }
else {
    $negFile = Join-Path $work "neg_tb.v"
    [IO.File]::WriteAllText($negFile, $bad)
    $rtl = Fwd (Join-Path $root "rtl_custom\rgb_to_gray.v")
    $txt = Run-Td "neg_control" "$dev`nanalyze -file `"$rtl`"`nanalyze -file `"$(Fwd $negFile)`"`nexit`n"
    $caught = ([regex]::Matches($txt, "HDL-8007 ERROR")).Count -gt 0
    if (-not $caught) { $ok = $false }
    $lines += ("negative control (missing semicolon in testbench copy): {0}" -f $(if ($caught) {"REJECTED by TD as expected"} else {"NOT DETECTED - check is vacuous"}))
}

$lines += ""
$lines += $(if ($ok) { "RESULT: all TD checks as expected (parse/elaborate/optimize_rtl only; not a simulation)" } else { "RESULT: PROBLEM, see .out files" })
$lines | Set-Content -Path (Join-Path $out "td_check_summary.txt") -Encoding ASCII
$lines | ForEach-Object { Write-Host $_ }
if ($ok) { exit 0 } else { exit 1 }
