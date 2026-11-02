# waits until the centre cell (row 4, column 7) of the shade_diag report is dark (G mean < 20 of 255), then records $Seconds of reports
param([int]$Seconds = 20, [int]$WaitMax = 300, [string]$Out)
$sp = New-Object System.IO.Ports.SerialPort 'COM3', 115200, 'None', 8, 'One'
$sp.NewLine = "`n"; $sp.ReadTimeout = 500; $sp.Open()
$w = $null; $sw = [Diagnostics.Stopwatch]::StartNew(); $rec = $null; $ends = 0; $hdr = $null
try {
    while ($true) {
        if ($rec -eq $null -and $sw.Elapsed.TotalSeconds -gt $WaitMax) { "TIMEOUT: no dark frame in $WaitMax s"; break }
        if ($rec -ne $null -and $rec.Elapsed.TotalSeconds -gt $Seconds) { break }
        try { $line = $sp.ReadLine().TrimEnd("`r") } catch [System.TimeoutException] { continue }
        if ($rec -eq $null) {
            if ($line.StartsWith('HDR,')) { $hdr = $line }
            if ($line -match '^C0407,([0-9A-F]+),([0-9A-F]+),([0-9A-F]+)') {
                $g = [Convert]::ToInt32($Matches[2], 16) / 6400.0
                if ($g -lt 20) {
                    "dark seen after $([int]$sw.Elapsed.TotalSeconds) s (centre G mean $([math]::Round($g,1))), recording $Seconds s from the next report"
                    $w = New-Object System.IO.StreamWriter($Out, $false, [System.Text.Encoding]::ASCII)
                    $rec = [Diagnostics.Stopwatch]::StartNew()
                }
            }
        } else {
            $w.WriteLine($line)
            if ($line.StartsWith('END,')) { $ends++ }
        }
    }
} finally { if ($w) { $w.Close() }; $sp.Close() }
"reports recorded: $ends -> $Out"
