# program_flash.ps1 - PROGRAM_FLASH (configuration SPI flash) of a RELEASED bitstream through the BitWriter command line (TD 6.2.1, no GUI).
# Writing the flash replaces what the board loads at power-on. Only with the user's explicit consent for that bitstream.
#
#   powershell -ExecutionPolicy Bypass -File F:\fpga_s2\tools\board\program_flash.ps1 -Bit F:\fpga_s2\release\<name>.bit -IConfirmFlash [-DryRun]
#
# Guards (any failure stops before the cable is touched): as program_sram.ps1 (file directly in release\, SHA-256 matches release\SHA256SUMS.txt,
# USB-JTAG VID_0403 PID_6042 present) plus the switch -IConfirmFlash.
# Command: the BitWriter GUI's template for PROGRAM_FLASH (strings in F:\TD\bin\bw.exe: 'download -%0 "%1" -mode %2 -spd %3 -cable %4' with mode
# "program_spi -v"; the usage text says -v = verify the flash after programming): download -bit <file> -mode program_spi -v -spd 7 -cable 0.
# Success = chip validated + the download command finished + no error line. Then power-cycle the board WITHOUT the PC download to see it boot.
param(
    [Parameter(Mandatory = $true)][string]$Bit,
    [int]$Cable = 0,
    [int]$Speed = 7,
    [int]$TimeoutSec = 600,
    [int]$EraseWait = 0,         # download -wait <s>: time BitWriter waits for the sector erase (its default is 20 s; a flash full of old data
                                 # needs longer - 2026-10-27 the default gave verify errors "read 0x00 ref 0x01" = pages not erased yet)
    [switch]$IConfirmFlash,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$root   = 'F:\fpga_s2'
$rel    = Join-Path $root 'release'
$bw     = 'F:\TD\bin\bw_commands_prompt.exe'
$logDir = Join-Path $root 'logs_custom\bw_cli'

$full = (Resolve-Path -LiteralPath $Bit).Path
if ((Split-Path -Parent $full) -ne $rel) { throw "only bitstreams directly in $rel are written: $full" }
if ([System.IO.Path]::GetExtension($full) -ne '.bit') { throw "not a .bit file: $full" }
$name = Split-Path -Leaf $full
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash.ToLower()
$line = Get-Content (Join-Path $rel 'SHA256SUMS.txt') | Where-Object { ($_ -split '\s+')[-1] -eq $name }
if (-not $line) { throw "$name is not listed in release\SHA256SUMS.txt" }
if ((($line | Select-Object -First 1) -split '\s+')[0].ToLower() -ne $hash) { throw "SHA-256 of $name ($hash) does not match release\SHA256SUMS.txt" }
Write-Output "bitstream : $full"
Write-Output "sha256    : $hash (matches SHA256SUMS.txt)"

$dev = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_0403&PID_6042' })
if ($dev.Count -eq 0) { throw 'USB-JTAG (VID_0403 PID_6042) is not present: connect the board USB cable and power the board' }
Write-Output ("cable     : " + (($dev | ForEach-Object { $_.FriendlyName + ' [' + $_.Status + ']' }) -join '; '))
if (-not (Test-Path $bw)) { throw "BitWriter command line not found: $bw" }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$tcl = Join-Path $logDir "flash_$stamp.tcl"
$out = Join-Path $logDir "flash_$stamp.out.txt"
$err = Join-Path $logDir "flash_$stamp.err.txt"
$cmd = 'download -bit {' + ($full -replace '\\', '/') + '} -mode program_spi -v -spd ' + $Speed + ' -cable ' + $Cable
if ($EraseWait -gt 0) { $cmd += ' -wait ' + $EraseWait }
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$open  = 'connect_cable -host_name 127.0.0.1:5555 -open'
$close = 'connect_cable -close'
Set-Content -Encoding ascii -Path $tcl -Value @($open, $cmd, $close, 'exit')
Write-Output "command   : $cmd"
if ($DryRun) { Write-Output "dry run: nothing sent ($tcl written)"; exit 0 }
if (-not $IConfirmFlash) { Write-Output 'not written: add -IConfirmFlash (the user consented to flashing this bitstream)'; exit 2 }

$p = Start-Process -FilePath $bw -ArgumentList (Split-Path -Leaf $tcl) -WorkingDirectory $logDir -NoNewWindow -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    Write-Output "bw_commands_prompt did not finish within $TimeoutSec s (process $($p.Id) left running; do not power off the board, check the log)"
    exit 3
}
$text = (Get-Content $out -Raw) + (Get-Content $err -Raw)
Write-Output '----- BitWriter output -----'
Write-Output $text
Write-Output '----------------------------'
$okMsg  = ($text -match 'Chip validation success') -and ($text -match 'finish command "download')
$errMsg = $text -match '(?i)\b(error|fail(ed)?)\b'
if ($okMsg -and -not $errMsg) { Write-Output "RESULT: PROGRAM_FLASH reported success ($name). Log: $out"; exit 0 }
Write-Output "RESULT: no success message from BitWriter (exit code $($p.ExitCode)). Log: $out"
exit 1
