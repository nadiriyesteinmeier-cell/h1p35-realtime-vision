# shade_capture.ps1 - record the flat-field report that the shade diagnostic build prints on the UART (COM3, 115200 8N1)
#
#   powershell -ExecutionPolicy Bypass -File F:\fpga_s2\tools\shade\shade_capture.ps1 -Port COM3 -Seconds 60 -Out F:\fpga_s2\logs_custom\shade_capture\run1.txt
#
# The log is the raw text (HDR / C.... / END lines). Nothing is sent to the board. Run shade_analyze.py on the log afterwards.
param(
    [string]$Port = 'COM3',
    [int]$Baud = 115200,
    [int]$Seconds = 60,
    [string]$Out = 'F:\fpga_s2\logs_custom\shade_capture\run1.txt',
    [int]$MaxReports = 0          # stop after this many END lines (0 = run for -Seconds)
)
$dir = Split-Path -Parent $Out
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.NewLine = "`n"
$sp.ReadTimeout = 500
$sp.Open()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$ends = 0
$w = New-Object System.IO.StreamWriter($Out, $false, [System.Text.Encoding]::ASCII)
try {
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        try { $line = $sp.ReadLine() } catch [System.TimeoutException] { continue }
        $line = $line.TrimEnd("`r")
        $w.WriteLine($line)
        if ($line.StartsWith('END,')) { $ends++; if ($MaxReports -gt 0 -and $ends -ge $MaxReports) { break } }
    }
}
finally {
    $w.Close()
    $sp.Close()
}
Write-Output ("captured {0} complete reports in {1:N1} s -> {2}" -f $ends, $sw.Elapsed.TotalSeconds, $Out)
