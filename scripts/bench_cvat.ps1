# Đo high-water RAM của stack Docker: cgroup memory.peak từng container, tổng đó, WorkingSet của vmmem, và Available MBytes.
# Dùng sau một phiên chạy, khi container vẫn sống. -Seconds chỉ ngủ trước lúc đọc, không lấy mẫu lặp.
# Giới hạn: memory.peak tính từ lúc container start và không reset được. PEAK stack là tổng high-water, không phải một mẫu đồng thời. Không gồm RAM trình duyệt. {0:N1} theo locale máy.

param(
    [string]$Run = "baseline",
    [int]$Seconds = 0
)

$ErrorActionPreference = "Continue"

if ($Seconds -gt 0) {
    Start-Sleep -Seconds $Seconds
}

$names = @(docker ps --format "{{.Names}}")
$peak = @{}
$sum = 0.0

foreach ($name in $names) {
    $raw = docker exec $name cat /sys/fs/cgroup/memory.peak 2>$null
    if (-not $raw) { continue }
    $text = ($raw | Out-String).Trim()
    if ($text -notmatch '^\d+$') { continue }
    $mb = [double]$text / 1MB
    $peak[$name] = $mb
    $sum += $mb
    Write-Output ("run={0} cgroup_memory_peak_mib {1} {2:N1}" -f $Run, $name, $mb)
}

Write-Output ("PEAK cvat_worker_utils {0:N1}" -f $peak["cvat_worker_utils"])
Write-Output ("PEAK cvat_server {0:N1}" -f $peak["cvat_server"])
Write-Output ("PEAK kvrocks {0:N1}" -f $peak["cvat_redis_ondisk"])
Write-Output ("PEAK stack {0:N1}" -f $sum)

$vmmem = Get-Process | Where-Object { $_.ProcessName -like "vmmem*" }
if ($vmmem) {
    foreach ($proc in $vmmem) {
        $ws = $proc.WorkingSet64 / 1MB
        Write-Output ("VMMEM {0} {1:N1}" -f $proc.ProcessName, $ws)
    }
} else {
    Write-Output "VMMEM none"
}

$available = (Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue
Write-Output ("AVAILABLE_MB {0:N0}" -f $available)
