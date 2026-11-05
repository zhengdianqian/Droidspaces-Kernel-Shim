param(
    [double]$Hours = 3.5,
    [int]$IntervalMin = 15,
    [string]$Tag = "soak1"
)
$ErrorActionPreference = "Continue"
$root = "C:\Users\Administrator\Documents\Trae-CN\temp_20261105_01\auto"
$adb  = "C:\jdk-25\platform-tools\adb.exe"
$logDir = Join-Path $root "logs\$Tag"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$csv = Join-Path $logDir "timeline.csv"
$md  = Join-Path $logDir "timeline.md"
$sw  = [Diagnostics.Stopwatch]::StartNew()
function Log([string]$m) {
    $l = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
    $l | Tee-Object -Append -FilePath (Join-Path $logDir "soak.log") | Out-Null
    Write-Host $l
}

"time,uptime_s,module,ksu,dd_procs,container_procs,Slab,SUnreclaim,SReclaimable,MemFree,check,reset_event" |
    Out-File -Encoding utf8 $csv
"| 时刻 | uptime(s) | droid_lkm | dd 进程 | 容器进程 | Slab | SUnreclaim | check |" |
    Out-File -Encoding utf8 $md
"|---|---|---|---|---|---|---|---|" | Out-File -Encoding utf8 -Append $md

Log "=== soak $Tag start hours=$Hours interval=${IntervalMin}min ==="
& $adb push (Join-Path $root "soak_tick.sh") /data/local/tmp/soak_tick.sh 2>&1 | Out-Null
& $adb push (Join-Path $root "soak_start.sh") /data/local/tmp/soak_start.sh 2>&1 | Out-Null

$prevUp = 0.0
$n = 0
$resets = 0
while ($sw.Elapsed.TotalHours -lt $Hours) {
    $n++
    $dev = (& $adb devices 2>$null) -join "`n"
    if ($dev -notmatch "`tdevice") {
        Log "TICK${n}: DEVICE_OFFLINE -> wait"
        Start-Sleep -Seconds 20
        $dev = (& $adb devices 2>$null) -join "`n"
        if ($dev -notmatch "`tdevice") {
            $resets++
            Log "TICK${n}: RESET_DETECTED last_uptime=$prevUp"
            ("{0},RESET,last_uptime={1}" -f (Get-Date -Format "HH:mm:ss"), $prevUp) | Add-Content -Encoding utf8 $csv
            & powershell -ExecutionPolicy Bypass -File (Join-Path $root "round.ps1") -Round ("${Tag}_recover$resets") 2>&1 |
                ForEach-Object { Log "recover| $_" }
            Log "restart container+load after reset"
            ((& $adb shell "su -c 'sh /data/local/tmp/soak_start.sh'" 2>&1) -join "`n") | ForEach-Object { if ($_.Trim()) { Log "restart| $_" } }
            $prevUp = 0.0
        }
    }

    if ($dev -match "`tdevice") {
        $raw = ((& $adb shell "su -c 'sh /data/local/tmp/soak_tick.sh'" 2>&1) -join "`n").Trim()
        if ($raw -notmatch "TICK\|") {
            Log "TICK${n}: NO_TICK_DATA raw=$raw"
        } else {
            $f = $raw -split '\|'
            $up = [double]($f[1])
            $mod = $f[2]
            $ksu = $f[3]
            $dd = $f[4]
            $ct = $f[5]
            $memParts = $f[6] -split ';'
            $slab = ($memParts | Where-Object { $_ -like 'Slab:*' }) -replace 'Slab:','' -replace 'kB',''
            $sun  = ($memParts | Where-Object { $_ -like 'SUnreclaim:*' }) -replace 'SUnreclaim:','' -replace 'kB',''
            $srec = ($memParts | Where-Object { $_ -like 'SReclaimable:*' }) -replace 'SReclaimable:','' -replace 'kB',''
            $free = ($memParts | Where-Object { $_ -like 'MemFree:*' }) -replace 'MemFree:','' -replace 'kB',''
            $ck = $f[7]
            $ok = if ($ck -match "All required features") { "OK" } else { "FAIL" }
            if ($up -lt $prevUp) {
                $resets++
                Log "TICK${n}: UPTIME_REGRESSED prev=$prevUp now=$up"
            }
            $prevUp = $up
            $ts = Get-Date -Format "HH:mm:ss"
            "$ts,$up,$mod,$ksu,$dd,$ct,$($slab.Trim()),$($sun.Trim()),$($srec.Trim()),$($free.Trim()),$ok,$resets" |
                Add-Content -Encoding utf8 $csv
            "| $ts | $up | $mod | $dd | $ct | $($slab.Trim()) kB | $($sun.Trim()) kB | $ok |" |
                Add-Content -Encoding utf8 $md
            Log "TICK${n}: up=$up $mod ksu=$ksu dd=$dd ct=$ct slab=$($slab.Trim())kB sun=$($sun.Trim())kB free=$($free.Trim())kB check=$ok"
        }
    }

    if ($sw.Elapsed.TotalHours -lt $Hours) { Start-Sleep -Seconds ($IntervalMin * 60) }
}

Log "=== soak $Tag end tick=$n resets=$resets elapsed_h=$([math]::Round($sw.Elapsed.TotalHours,2)) ==="
& $adb pull /data/local/tmp/kmsg_soak.log $logDir 2>&1 | Out-Null
& $adb pull /data/local/tmp/soak_load.log $logDir 2>&1 | Out-Null
(& $adb shell "su -c 'cat /proc/uptime'" 2>&1) | ForEach-Object { Log "final_uptime| $_" }
