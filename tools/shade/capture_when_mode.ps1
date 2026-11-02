# waits until the shade_diag report shows AWB mode $Mode in its HDR line, then records $Seconds of reports to $Out
param([int]$Mode = 1, [int]$Seconds = 30, [int]$WaitMax = 600, [string]$Out)
$sp = New-Object System.IO.Ports.SerialPort 'COM3', 115200, 'None', 8, 'One'
$sp.NewLine = "`n"; $sp.ReadTimeout = 500; $sp.Open()
$w = $null; $sw = [Diagnostics.Stopwatch]::StartNew(); $rec = $null; $ends = 0
try {
    while ($true) {
        if ($rec -eq $null -and $sw.Elapsed.TotalSeconds -gt $WaitMax) { "TIMEOUT: mode $Mode not seen in $WaitMax s"; break }
        if ($rec -ne $null -and $rec.Elapsed.TotalSeconds -gt $Seconds) { break }
        try { $line = $sp.ReadLine().TrimEnd("`r") } catch [System.TimeoutException] { continue }
        if ($rec -eq $null) {
            if ($line -match '^HDR,[0-9A-F]+,([0-9A-F]+),') {
                if ([Convert]::ToInt32($Matches[1], 16) -eq $Mode) {
                    "mode $Mode seen after $([int]$sw.Elapsed.TotalSeconds) s, recording $Seconds s"
                    $w = New-Object System.IO.StreamWriter($Out, $false, [System.Text.Encoding]::ASCII)
                    $rec = [Diagnostics.Stopwatch]::StartNew()
                    $w.WriteLine($line)
                }
            }
        } else {
            $w.WriteLine($line)
            if ($line.StartsWith('END,')) { $ends++ }
        }
    }
} finally { if ($w) { $w.Close() }; $sp.Close() }
"reports recorded: $ends -> $Out"
