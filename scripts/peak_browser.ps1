# Đo peak WorkingSet của mọi process msedge, mỗi 500 ms, trong -Seconds giây.
# Dùng khi tab annotation đang mở và đang cuộn. CSV: timestamp,ws_total_mb. In PEAK, MEDIAN, SAMPLES.
# Giới hạn: không ép GC, không tách một tab. -Label bắt buộc (cap2 hoặc cap10) nhưng không ghi vào CSV. Không đo Chrome.

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("cap2", "cap10")]
    [string]$Label,
    [int]$Seconds = 60,
    [Parameter(Mandatory = $true)]
    [string]$Out
)

$ErrorActionPreference = "Continue"
$dir = Split-Path -Parent $Out
if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir | Out-Null
}

$inv = [Globalization.CultureInfo]::InvariantCulture
$samples = New-Object System.Collections.Generic.List[double]
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("timestamp,ws_total_mb")
$sw = [Diagnostics.Stopwatch]::StartNew()

while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    $tick = $sw.Elapsed.TotalMilliseconds
    $edge = Get-Process msedge -ErrorAction SilentlyContinue
    $sum = 0.0
    if ($edge) {
        $sum = ($edge | Measure-Object WorkingSet64 -Sum).Sum / 1MB
    }
    $samples.Add($sum)
    $stamp = (Get-Date).ToString("o")
    $lines.Add(("{0},{1}" -f $stamp, $sum.ToString("0.000", $inv)))
    $spent = $sw.Elapsed.TotalMilliseconds - $tick
    $wait = 500 - $spent
    if ($wait -gt 0 -and ($sw.Elapsed.TotalSeconds + ($wait / 1000)) -lt $Seconds) {
        Start-Sleep -Milliseconds ([int]$wait)
    }
}

[IO.File]::WriteAllLines($Out, $lines)
$ordered = $samples | Sort-Object
$peak = ($samples | Measure-Object -Maximum).Maximum
$mid = [int][Math]::Floor($ordered.Count / 2)
if ($ordered.Count % 2 -eq 1) {
    $median = $ordered[$mid]
} else {
    $median = ($ordered[$mid - 1] + $ordered[$mid]) / 2
}
Write-Output ("PEAK={0} MEDIAN={1} SAMPLES={2}" -f $peak.ToString("0.0", $inv), $median.ToString("0.0", $inv), $samples.Count)
