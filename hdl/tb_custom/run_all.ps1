# run_all.ps1 - generate the OSD golden data (python) and run the self-checking testbenches with Icarus Verilog.
#
#   powershell -ExecutionPolicy Bypass -File F:\fpga_s2\tb_custom\run_all.ps1
#   powershell -ExecutionPolicy Bypass -File F:\fpga_s2\tb_custom\run_all.ps1 -SkipChain      (skip the three 1280x720 chain tests, several minutes each)
#   powershell -ExecutionPolicy Bypass -File F:\fpga_s2\tb_custom\run_all.ps1 -Full          (adds +define+FULL_SWEEP, slow)
#   powershell -ExecutionPolicy Bypass -File F:\fpga_s2\tb_custom\run_all.ps1 -Only cross_counter   (only the named tests)
#   powershell -ExecutionPolicy Bypass -File F:\fpga_s2\tb_custom\run_all.ps1 -IverilogDir C:\msys64\ucrt64\bin
#
# Logs go to F:\fpga_s2\logs_custom\sim_<name>.log. Exit code: 0 = all PASS,
# 1 = at least one FAIL / compile error, 2 = no simulator found (nothing was run).
param(
    [switch]$Full,
    [switch]$SkipChain,
    [string[]]$Only = @(),                 # run only these tests by name (e.g. -Only cross_counter,osd_aux)
    [string]$IverilogDir = ""
)

$ErrorActionPreference = "Continue"
$tbDir  = $PSScriptRoot
$root   = Split-Path -Parent $tbDir
$rtlDir = Join-Path $root "rtl_custom"
$logDir = Join-Path $root "logs_custom"
New-Item -ItemType Directory -Force $logDir | Out-Null

function Find-Tool([string]$name) {
    $cands = @()
    if ($IverilogDir -ne "") { $cands += (Join-Path $IverilogDir "$name.exe") }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { $cands += $cmd.Source }
    $cands += (Join-Path $root "tools\iverilog\ucrt64\bin\$name.exe")      # private copy, see docs/STATUS_FOR_CODEX.md
    $cands += @("C:\msys64\ucrt64\bin\$name.exe", "C:\msys64\mingw64\bin\$name.exe",
                "C:\iverilog\bin\$name.exe", "C:\Program Files\iverilog\bin\$name.exe")
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

$iverilog = Find-Tool "iverilog"
$vvp      = Find-Tool "vvp"
if (-not $iverilog -or -not $vvp) {
    Write-Host "SIMULATION NOT RUN: iverilog/vvp not found (PATH, -IverilogDir, msys64, C:\iverilog)."
    exit 2
}

$env:PATH = (Split-Path -Parent $iverilog) + ";" + $env:PATH      # runtime DLLs sit next to the tool

function Run-Native([string]$exe, [string[]]$argList, [string]$outFile, [string]$workDir) {
    $q = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $p = Start-Process -FilePath $exe -ArgumentList $q -WorkingDirectory $workDir -NoNewWindow -PassThru `
         -RedirectStandardOutput $outFile -RedirectStandardError ($outFile + ".err") -Wait
    if (Test-Path ($outFile + ".err")) {
        Add-Content -Path $outFile -Value (Get-Content ($outFile + ".err") -Raw)
        Remove-Item ($outFile + ".err") -Force
    }
    return $p.ExitCode
}

# srcs are relative to F:\fpga_s2. uivtc.v is the UNMODIFIED lab1 baseline file, only read.
$uivtc = "lab1\user_source\hdl_source\vtc\uivtc.v"
$tests = @(
    @{ name = "rgb_to_gray";       tb = "tb_rgb_to_gray.v";       srcs = @("rtl_custom\rgb_to_gray.v") },
    @{ name = "color_segment";     tb = "tb_color_segment.v";     srcs = @("rtl_custom\color_segment.v") },
    @{ name = "frame_bbox";        tb = "tb_frame_bbox.v";        srcs = @("rtl_custom\frame_bbox.v") },
    @{ name = "video_pos_adapter"; tb = "tb_video_pos_adapter.v"; srcs = @("tb_custom\tb_vtc_chk.v", "rtl_custom\video_pos_adapter.v", $uivtc) },
    @{ name = "osd_aux";           tb = "tb_osd_aux.v";           srcs = @("rtl_custom\osd_bin2bcd.v", "rtl_custom\view_mux.v", "rtl_custom\sync_delay.v") },
    @{ name = "osd_overlay";       tb = "tb_osd_overlay.v";       srcs = @("rtl_custom\osd_overlay.v", "rtl_custom\osd_bin2bcd.v", "rtl_custom\osd_font_rom.v", "rtl_custom\osd_logo_rom.v") },
    @{ name = "cross_counter";     tb = "tb_cross_counter.v";     srcs = @("rtl_custom\cross_counter.v") },
    @{ name = "seg7_scan";         tb = "tb_seg7_scan.v";         srcs = @("rtl_custom\seg7_scan.v") },
    @{ name = "view_mux_style";    tb = "tb_view_mux_style.v";    srcs = @("rtl_custom\view_mux_style.v") },
    @{ name = "camera_tone";       tb = "tb_camera_tone.v";       srcs = @("rtl_custom\camera_tone.v") },
    @{ name = "frame_commit";      tb = "tb_frame_commit.v";      srcs = @("rtl_custom\frame_commit.v") },
    @{ name = "target_track";      tb = "tb_target_track.v";      srcs = @("rtl_custom\target_track.v") },
    # white-balance page (docs/WB_MODE_2026-10-25.md)
    @{ name = "awb_frame";         tb = "tb_awb_frame.v";         srcs = @("rtl_custom\awb_frame.v", "rtl_custom\div_seq.v") },
    @{ name = "wb_ctrl";           tb = "tb_wb_ctrl.v";           srcs = @("rtl_custom\wb_ctrl.v", "rtl_custom\key_debounce.v") },
    @{ name = "wb_osd";            tb = "tb_wb_osd.v";            srcs = @("rtl_custom\wb_osd.v") },
    # diagnostic copy of the vendor HDMI serializer lane (selectable capture phase); it lives in the hdmidiag project only
    @{ name = "tmds_lane";         tb = "tb_tmds_lane.v";         srcs = @("contest_work_v2_hdmidiag\user_source\hdl_source\lane_lvds_10_1.v") }
)
if (-not $SkipChain) {
    $tests += @{ name = "pos_chain"; tb = "tb_pos_chain.v"
                 srcs = @("tb_custom\tb_vtc_chk.v", "rtl_custom\video_pos_adapter.v", "rtl_custom\color_segment.v",
                          "rtl_custom\frame_bbox.v", $uivtc) }
    $tests += @{ name = "osd_chain"; tb = "tb_osd_chain.v"
                 srcs = @("tb_custom\tb_vtc_chk.v", "rtl_custom\video_pos_adapter.v", "rtl_custom\color_segment.v",
                          "rtl_custom\frame_bbox.v", "rtl_custom\osd_overlay.v", "rtl_custom\osd_bin2bcd.v",
                          "rtl_custom\osd_font_rom.v", "rtl_custom\osd_logo_rom.v", $uivtc) }
    # the block that is actually wired into contest_work (default SKEW=2), real uivtc, bypass + 4 views
    $tests += @{ name = "vision_path"; tb = "tb_vision_path.v"
                 srcs = @("rtl_custom\contest_vision_path.v", "rtl_custom\video_pos_adapter.v", "rtl_custom\rgb_to_gray.v",
                          "rtl_custom\color_segment.v", "rtl_custom\frame_bbox.v", "rtl_custom\view_mux.v", "rtl_custom\sync_delay.v",
                          "rtl_custom\osd_overlay.v", "rtl_custom\osd_bin2bcd.v", "rtl_custom\osd_font_rom.v",
                          "rtl_custom\osd_logo_rom.v", $uivtc) }
    # HDMI diagnostic test patterns: 16 full frames (slow in iverilog; ModelSim about 1 minute)
    $tests += @{ name = "hdmi_testpat"; tb = "tb_hdmi_testpat.v"
                 srcs = @("rtl_custom\hdmi_testpat.v", "rtl_custom\key_debounce.v", $uivtc) }
}

if ($Only.Count -gt 0) { $tests = @($tests | Where-Object { $Only -contains $_.name }) }

# OSD golden frames: independent Python model (needs python + numpy; assets are tb_custom\osd_assets\*.npy)
$gold = Join-Path $tbDir "gen_osd_golden.py"
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { Write-Host "python not found: cannot generate the OSD golden data (tb_custom\gen_osd_golden.py)"; exit 2 }
$gl = Join-Path $logDir "gen_osd_golden.log"
$gp = Start-Process -FilePath $py.Source -ArgumentList ('"' + $gold + '"') -WorkingDirectory $tbDir -NoNewWindow -PassThru -Wait `
      -RedirectStandardOutput $gl -RedirectStandardError ($gl + ".err")
if ($gp.ExitCode -ne 0) { Write-Host "gen_osd_golden.py failed, see $gl"; exit 1 }

$verText = & $iverilog -V 2>&1 | Select-Object -First 1
$summary = @()
$allOk = $true
foreach ($t in $tests) {
    $vvpFile = Join-Path $logDir ("sim_" + $t.name + ".vvp")
    $log     = Join-Path $logDir ("sim_" + $t.name + ".log")
    $cargs = @("-g2005", "-Wall")
    if ($Full) { $cargs += "-DFULL_SWEEP" }
    # testbench first: its `timescale then also applies to the RTL file (which has none)
    $cargs += @("-o", $vvpFile, (Join-Path $tbDir $t.tb))
    foreach ($s in $t.srcs) { $cargs += (Join-Path $root $s) }

    $header = @("# date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "# tool: $verText",
                "# compile: $iverilog $($cargs -join ' ')", "# run: $vvp $vvpFile", "")
    Set-Content -Path $log -Value $header -Encoding ASCII

    $cLog = $log + ".compile"
    $rc = Run-Native $iverilog $cargs $cLog $tbDir
    Add-Content -Path $log -Value "## compile output (exit $rc)"
    if (Test-Path $cLog) { Add-Content -Path $log -Value (Get-Content $cLog -Raw); Remove-Item $cLog -Force }
    if ($rc -ne 0) {
        $summary += [pscustomobject]@{ test = $t.name; result = "COMPILE-ERROR"; detail = "see $log" }
        $allOk = $false
        continue
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $rLog = $log + ".run"
    $rc = Run-Native $vvp @($vvpFile) $rLog $tbDir
    $sw.Stop()
    Add-Content -Path $log -Value "## run output (vvp exit $rc, $([math]::Round($sw.Elapsed.TotalSeconds,1)) s)"
    $runText = ""
    if (Test-Path $rLog) { $runText = Get-Content $rLog -Raw; Add-Content -Path $log -Value $runText; Remove-Item $rLog -Force }

    $pass = ($runText -match "TB_RESULT: PASS") -and ($runText -notmatch "TB_RESULT: FAIL") -and ($rc -eq 0)
    $line = ($runText -split "`r?`n" | Where-Object { $_ -match "TB_RESULT" } | Select-Object -First 1)
    $summary += [pscustomobject]@{ test = $t.name; result = $(if ($pass) { "PASS" } else { "FAIL" }); detail = $line }
    if (-not $pass) { $allOk = $false }
}

Write-Host ""
$summary | Format-Table -AutoSize | Out-String | Write-Host
if ($allOk) { Write-Host "ALL TESTBENCHES PASSED"; exit 0 } else { Write-Host "AT LEAST ONE TESTBENCH FAILED"; exit 1 }
