# run_conv_modelsim.ps1 - second-simulator check of the detector cores in ModelSim SE-64 2020.4: the same vectors as the Icarus runners
#   yolo_conv_core (run_conv_tests.py), yolo_aux_core (run_aux_tests.py), yolo_net_engine (run_net_tests.py), yolo_decode (run_decode_tests.py), yolo_box_down (run_box_tests.py)
#
# Prerequisite: the five Icarus runners have been run once (they write the vectors into logs_custom/yolo_vec/L<lanes>/, auxops/, net<lanes>/, decode/, box/).
# Usage:  powershell -ExecutionPolicy Bypass -File tools/yolo/run_conv_modelsim.ps1
# Prints one TB_RESULT line per case and a summary per core; vsim -c returns exit code 0 even on errors, so only the TB_RESULT lines count.
$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ms = 'F:\medolsim\win64'
$env:LM_LICENSE_FILE = [Environment]::GetEnvironmentVariable('LM_LICENSE_FILE', 'User')
$work = Join-Path $root 'logs_custom\yolo_ms'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
foreach ($lib in 'work', 'work_aux', 'work_net', 'work_dec', 'work_box') { if (Test-Path $lib) { Remove-Item -Recurse -Force $lib } }

function Compile-Lib($lib, $files) {
    & "$ms\vlib.exe" $lib | Out-Null
    & "$ms\vlog.exe" -work $lib $files 2>&1 | Select-String -Pattern 'Error|Warning' | ForEach-Object { $_.Line }
}
function Case-Names($dir) {
    Get-ChildItem $dir -Filter '*_cfg.txt' | ForEach-Object { $_.Name -replace '_cfg\.txt$', '' } | Sort-Object
}
function Run-Case($label, $top, $tbname, $gens, $prefix) {
    $out = & "$ms\vsim.exe" -c -quiet @gens $top "+CASE=$prefix" -do 'run -all; quit -f' 2>&1 | Out-String
    $m = [regex]::Match($out, "TB_RESULT: (PASS|FAIL) $tbname \S+ [^\r\n]*")
    if ($m.Success) { Write-Output ("$label : " + $m.Value) } else { Write-Output ("NORESULT $label`n" + $out.Substring([Math]::Max(0, $out.Length - 1200))) }
    return ($m.Success -and $m.Groups[1].Value -eq 'PASS')
}

# ---------------------------------------------------------------- yolo_conv_core (8 and 16 lanes)
Compile-Lib 'work' @("$root\rtl_custom\yolo_conv_core.v", "$root\tb_custom\tb_yolo_conv.v")
$total = 0; $pass = 0
foreach ($lanes in 8, 16) {
    $vec = Join-Path $root "logs_custom\yolo_vec\L$lanes"
    foreach ($c in (Case-Names $vec)) {
        $prefix = ((Join-Path $vec $c) -replace '\\', '/')
        $total++
        if (Run-Case "L$lanes $c" 'work.tb_yolo_conv' 'tb_yolo_conv' @("-GLANES=$lanes") $prefix) { $pass++ }
    }
}
Write-Output "ModelSim yolo_conv_core: $total cases, $pass passed, $($total - $pass) failed"

# ---------------------------------------------------------------- yolo_aux_core
Compile-Lib 'work_aux' @("$root\rtl_custom\yolo_aux_core.v", "$root\tb_custom\tb_yolo_aux.v")
$total = 0; $pass = 0
$vec = Join-Path $root 'logs_custom\yolo_vec\auxops'
foreach ($c in (Case-Names $vec)) {
    $prefix = ((Join-Path $vec $c) -replace '\\', '/')
    $total++
    if (Run-Case "aux $c" 'work_aux.tb_yolo_aux' 'tb_yolo_aux' @() $prefix) { $pass++ }
}
Write-Output "ModelSim yolo_aux_core: $total cases, $pass passed, $($total - $pass) failed"

# ---------------------------------------------------------------- yolo_net_engine (sequencer + both cores + banks), 8 and 16 lanes
Compile-Lib 'work_net' @("$root\rtl_custom\yolo_net_engine.v", "$root\rtl_custom\yolo_conv_core.v", "$root\rtl_custom\yolo_aux_core.v", "$root\rtl_custom\yolo_bank_ram.v", "$root\tb_custom\tb_yolo_net.v")
$total = 0; $pass = 0
foreach ($lanes in 8, 16) {
    $vec = Join-Path $root "logs_custom\yolo_vec\net$lanes"
    foreach ($c in (Case-Names $vec)) {
        $prefix = ((Join-Path $vec $c) -replace '\\', '/')
        $total++
        if (Run-Case "net L$lanes $c" 'work_net.tb_yolo_net' 'tb_yolo_net' @("-GLANES=$lanes") $prefix) { $pass++ }
    }
}
Write-Output "ModelSim yolo_net_engine: $total cases, $pass passed, $($total - $pass) failed"

# ---------------------------------------------------------------- yolo_decode
Compile-Lib 'work_dec' @("$root\rtl_custom\yolo_decode.v", "$root\rtl_custom\yolo_lut_rom.v", "$root\tb_custom\tb_yolo_decode.v")
$total = 0; $pass = 0
$vec = Join-Path $root 'logs_custom\yolo_vec\decode'
foreach ($f in (Get-ChildItem $vec -Filter '*_heads.hex' | Sort-Object Name)) {
    $c = $f.Name -replace '_heads\.hex$', ''
    $prefix = ((Join-Path $vec $c) -replace '\\', '/')
    $total++
    if (Run-Case "decode $c" 'work_dec.tb_yolo_decode' 'tb_yolo_decode' @() $prefix) { $pass++ }
}
Write-Output "ModelSim yolo_decode: $total cases, $pass passed, $($total - $pass) failed"

# ---------------------------------------------------------------- yolo_box_down (the testbench parameters differ per case: compiled once, overridden with -G)
Compile-Lib 'work_box' @("$root\rtl_custom\yolo_box_down.v", "$root\tb_custom\tb_yolo_box.v")
$total = 0; $pass = 0
$vec = Join-Path $root 'logs_custom\yolo_vec\box'
foreach ($c in (Case-Names $vec)) {
    $prefix = ((Join-Path $vec $c) -replace '\\', '/')
    $gens = (Get-Content (Join-Path $vec "${c}_params.txt")).Split(' ') | Where-Object { $_ } | ForEach-Object { "-G$_" }
    $total++
    if (Run-Case "box $c" 'work_box.tb_yolo_box' 'tb_yolo_box' $gens $prefix) { $pass++ }
}
Write-Output "ModelSim yolo_box_down: $total cases, $pass passed, $($total - $pass) failed"
