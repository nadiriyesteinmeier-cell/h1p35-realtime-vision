# program_sram.ps1 - PROGRAM_SRAM download of a RELEASED bitstream through the BitWriter command line (TD 6.2.1, no GUI). Never Flash.
#
#   powershell -ExecutionPolicy Bypass -File F:\fpga_s2\tools\board\program_sram.ps1 -Bit F:\fpga_s2\release\<name>.bit [-DryRun]
#
# Guards (any failure stops before the cable is touched):
#   1. the file lies directly in F:\fpga_s2\release and its SHA-256 matches its line in release\SHA256SUMS.txt;
#   2. the USB-JTAG of the board (FTDI VID_0403 PID_6042) is present in Windows;
#   3. the command is exactly the one the BitWriter GUI issues for PROGRAM_SRAM: download -bit <file> -mode jtag -spd <7 = 5 MHz> -cable <0>.
# The Tcl file, stdout and stderr of bw_commands_prompt.exe land in logs_custom\bw_cli\download_<time>.*; the result line says whether the tool reported
# success. A success here means "the bitstream reached the FPGA SRAM" - what the picture does on the screen still needs the user's eyes.
# SRAM content is lost at power-off; nothing is written to the configuration Flash. Does not start or stop hwserver / bw.exe.
param(
    [Parameter(Mandatory = $true)][string]$Bit,
    [int]$Cable = 0,
    [int]$Speed = 7,
    [int]$TimeoutSec = 180,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$root   = 'F:\fpga_s2'
$rel    = Join-Path $root 'release'
$bw     = 'F:\TD\bin\bw_commands_prompt.exe'
$logDir = Join-Path $root 'logs_custom\bw_cli'

# 1. released bitstream with a matching checksum
$full = (Resolve-Path -LiteralPath $Bit).Path
if ((Split-Path -Parent $full) -ne $rel) { throw "only bitstreams directly in $rel are downloaded: $full" }
if ([System.IO.Path]::GetExtension($full) -ne '.bit') { throw "not a .bit file: $full" }
$name = Split-Path -Leaf $full
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash.ToLower()
$line = Get-Content (Join-Path $rel 'SHA256SUMS.txt') | Where-Object { ($_ -split '\s+')[-1] -eq $name }
if (-not $line) { throw "$name is not listed in release\SHA256SUMS.txt" }
if ((($line | Select-Object -First 1) -split '\s+')[0].ToLower() -ne $hash) { throw "SHA-256 of $name ($hash) does not match release\SHA256SUMS.txt" }
Write-Output "bitstream : $full"
Write-Output "sha256    : $hash (matches SHA256SUMS.txt)"

# 2. cable present
$dev = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_0403&PID_6042' })
if ($dev.Count -eq 0) { throw 'USB-JTAG (VID_0403 PID_6042) is not present: connect the board USB cable and power the board' }
Write-Output ("cable     : " + (($dev | ForEach-Object { $_.FriendlyName + ' [' + $_.Status + ']' }) -join '; '))
if (-not (Test-Path $bw)) { throw "BitWriter command line not found: $bw" }

# 3. the PROGRAM_SRAM command
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$tcl = Join-Path $logDir "download_$stamp.tcl"
$out = Join-Path $logDir "download_$stamp.out.txt"
$err = Join-Path $logDir "download_$stamp.err.txt"
$cmd = 'download -bit {' + ($full -replace '\\', '/') + '} -mode jtag -spd ' + $Speed + ' -cable ' + $Cable
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
# the same cable session the BitWriter GUI opens before a download (F:\TD\bin\log\bw_*.log): hwserver on 127.0.0.1:5555, closed afterwards.
# Without it the command line reports "PRG-9505 USB device open error".
# (the GUI also passes -usr_args {-r -s 5555 -f 12 -i 0}; typed into the Tcl shell that option is rejected as empty, and it is not needed)
$open  = 'connect_cable -host_name 127.0.0.1:5555 -open'
$close = 'connect_cable -close'
Set-Content -Encoding ascii -Path $tcl -Value @($open, $cmd, $close, 'exit')
Write-Output "command   : $cmd"
if ($DryRun) { Write-Output "dry run: nothing sent ($tcl written)"; exit 0 }

# the Tcl file is passed by its bare name (bw's Tcl shell would read backslashes in a full Windows path as escapes)
$p = Start-Process -FilePath $bw -ArgumentList (Split-Path -Leaf $tcl) -WorkingDirectory $logDir -NoNewWindow -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    Write-Output "bw_commands_prompt did not finish within $TimeoutSec s (process $($p.Id) left running; check the cable / hwserver)"
    exit 3
}
$text = (Get-Content $out -Raw) + (Get-Content $err -Raw)
Write-Output '----- BitWriter output -----'
Write-Output $text
Write-Output '----------------------------'
# the command line does not print the GUI's "Downloading succeeded!": success = chip validated + the download command finished + no error line
$okMsg  = ($text -match 'Chip validation success') -and ($text -match 'finish command "download')
$errMsg = $text -match '(?i)\b(error|fail(ed)?)\b'
if ($okMsg -and -not $errMsg) { Write-Output "RESULT: PROGRAM_SRAM reported success ($name). Log: $out"; exit 0 }
Write-Output "RESULT: no success message from BitWriter (exit code $($p.ExitCode)). Log: $out"
exit 1
