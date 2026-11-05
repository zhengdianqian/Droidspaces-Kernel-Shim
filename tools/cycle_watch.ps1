param([string]$Tag = "c1")
$ErrorActionPreference = "Continue"
$root = "C:\Users\Administrator\Documents\Trae-CN\temp_20261105_01\auto"
$adb  = "C:\jdk-25\platform-tools\adb.exe"
$logDir = Join-Path $root "logs\cycle_$Tag"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
function Log([string]$m) { $l = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m; $l | Tee-Object -Append -FilePath (Join-Path $logDir "cycle.log") | Out-Null; Write-Host $l }

function Wait-Dev([int]$sec = 600) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $sec) {
        $d = (& $adb devices 2>$null) -join "`n"
        if ($d -match "`tdevice") {
            $u = ((& $adb shell cat /proc/uptime 2>$null) -join "").Trim()
            $b = ((& $adb shell getprop sys.boot_completed 2>$null) -join "").Trim()
            Log "device_online uptime=$u boot_completed=$b"
            return $true
        }
        Start-Sleep -Seconds 2
    }
    Log "WAIT_DEV_TIMEOUT"
    return $false
}

Log "=== cycle $Tag start ==="
& $adb reboot 2>&1 | Out-Null
Start-Sleep -Seconds 5
if (-not (Wait-Dev 600)) { exit 2 }

$r = ((& $adb shell "sh /data/local/tmp/rpproot_re/reroot.sh" 2>&1) -join "`n")
$r -split "`n" | Select-Object -Last 10 | ForEach-Object { if ($_.Trim()) { Log "reroot| $_" } }
$dev = (& $adb devices 2>$null) -join "`n"
if ($dev -notmatch "`tdevice") {
    Log "DEVICE_LOST_DURING_REROOT"
    if (-not (Wait-Dev 600)) { exit 3 }
}

$id = ((& $adb shell "su -c id" 2>$null) -join "").Trim()
Log "after_reroot id=$id"
if ($id -notmatch "uid=0") { Log "NO_ROOT"; exit 4 }

Log "late-load begin uptime=$(((& $adb shell cat /proc/uptime) -join '').Trim())"
& $adb shell "su -c '/data/local/tmp/libksud.so late-load --allow-shell --package-name me.weishu.kernelsu'" 2>&1 | Out-Null
Start-Sleep -Seconds 5
$kc = 0
for ($i = 0; $i -lt 8; $i++) {
    $kraw = ((& $adb shell "grep -c '^kernelsu ' /proc/modules" 2>$null) -join "").Trim()
    if ($kraw -match '^\d+') { $kc = [int]$kraw }
    if ($kc -ge 1) { break }
    Start-Sleep -Seconds 3
}
Log "kernelsu_count=$kc"
# late-load 后 su 会话可能短暂掉进 shell 域，等它稳定回到 root 再采集
$ok = $false
for ($i = 0; $i -lt 10; $i++) {
    $u = ((& $adb shell "su -c 'id -u'" 2>$null) -join "").Trim()
    if ($u -eq "0") { $ok = $true; Log "su_ready try=$i"; break }
    Log "su_not_ready try=$i out=$u"
    Start-Sleep -Seconds 3
}
if (-not $ok) { Log "SU_NOT_READY_GIVE_UP"; exit 5 }

& $adb push (Join-Path $root "boot_watch.sh") /data/local/tmp/boot_watch.sh 2>&1 | Out-Null
$w = ((& $adb shell "su -c 'sh /data/local/tmp/boot_watch.sh $Tag'" 2>&1) -join "`n")
$w -split "`n" | ForEach-Object { if ($_.Trim()) { Log "watch| $_" } }
& $adb pull "/data/local/tmp/boot_watch_$Tag.txt" $logDir 2>&1 | Out-Null

Log "post uptime=$(((& $adb shell cat /proc/uptime) -join '').Trim())"
$f = ((& $adb shell "su -c '/data/adb/ksu/bin/ksud feature get su_compat'" 2>&1) -join " ") -replace "`n"," "
Log "su_compat $f"
Log "modules=$(((& $adb shell "grep -E 'droid_lkm|kernelsu' /proc/modules" 2>&1) -join '|').Trim())"
Log "=== cycle $Tag end ==="
