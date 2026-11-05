# 无人值守一轮：等设备 -> 自提权 -> 校验 -> 拉取上一轮现场
# 用法： powershell -ExecutionPolicy Bypass -File round.ps1 -Round b17_round
param(
    [string]$Round = "manual",
    [int]$TimeoutSec = 1200
)

$ErrorActionPreference = "Continue"
$root = "C:\Users\Administrator\Documents\Trae-CN\temp_20261105_01\auto"
$adb  = "C:\jdk-25\platform-tools\adb.exe"
if (!(Test-Path $adb)) { $adb = "C:\Users\Administrator\AppData\Local\Android\Sdk\platform-tools\adb.exe" }
$logDir = Join-Path $root "logs\$Round"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()

function Log([string]$m) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m
    $line | Tee-Object -Append -FilePath (Join-Path $root "auto.log") | Out-Null
    Write-Host $line
}

function Wait-Device([int]$timeout) {
    # 不等 boot_completed：adb 一上线就开始提权，能省下 20-40 s；
    # 提权本身有重试（Ensure-Root），系统没起好时会自动再试。
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeout) {
        $dev = (& $adb devices 2>$null) -join "`n"
        if ($dev -match "`tdevice") {
            $up = ((& $adb shell cat /proc/uptime 2>$null) -join "").Trim()
            $bc = ((& $adb shell getprop sys.boot_completed 2>$null) -join "").Trim()
            Log "device online uptime=$up boot_completed=$bc"
            return $true
        }
        Start-Sleep -Seconds 2
    }
    Log "WAIT_DEVICE_TIMEOUT"
    return $false
}

function Ensure-Root {
    for ($try = 0; $try -lt 5; $try++) {
        $id = ((& $adb shell "su -c id" 2>$null) -join "").Trim()
        if ($id -match "uid=0") { Log "ROOT_OK $id"; return $true }

        Log "NO_ROOT -> reroot.sh try=$try"
        $r = ((& $adb shell "sh /data/local/tmp/rpproot_re/reroot.sh" 2>&1) -join "`n")
        $r -split "`n" | Select-Object -Last 6 | ForEach-Object { if ($_.Trim()) { Log "reroot| $_" } }
        Start-Sleep -Seconds 5

        $id2 = ((& $adb shell "su -c id" 2>$null) -join "").Trim()
        if ($id2 -match "uid=0") { Log "ROOT_RESTORED $id2"; return $true }
        Log "REROOT_RETRY_FAILED try=$try"
        Start-Sleep -Seconds 10
    }
    Log "REROOT_FAILED"
    return $false
}

function Ensure-KSU {
    # 本机是 "先提权，再 late-load"：开机阶段 KSU 还没加载，post-fs-data/service 已过。
    # 关键：late-load 必须用**独立的一次** su 命令直接执行；若包在脚本里跑，
    # 会把该 su 会话掉进 shell 域，并且下一次 su 会阻塞 ~3 分钟（实测）。
    $k = ((& $adb shell "grep -c kernelsu /proc/modules" 2>$null) -join "").Trim()
    if ($k -ne "1") {
        Log "KSU_KERNEL_ABSENT -> late-load"
        & $adb shell "su -c '/data/local/tmp/libksud.so late-load --allow-shell --package-name me.weishu.kernelsu'" 2>&1 | Out-Null
        Start-Sleep -Seconds 3
    } else {
        Log "KSU_KERNEL_PRESENT"
    }

    & $adb push (Join-Path $root "ksu_boot.sh") /data/local/tmp/ksu_boot_v1.sh 2>&1 | Out-Null
    $r2 = ((& $adb shell "su -c 'sh /data/local/tmp/ksu_boot_v1.sh'" 2>&1) -join "`n")
    $r2 -split "`n" | ForEach-Object { if ($_.Trim()) { Log "ksu-boot| $_" } }

    # su_compat 必须在 late-load 之后补到 1：否则 App 打开即“页面被禁用”，
    # 且 shell 的 su 也会一起消失。ksu_boot.sh 已内置这步，这里再兜一层（防旧脚本）。
    $sc = ((& $adb shell "su -c '/data/adb/ksu/bin/ksud feature get su_compat'" 2>&1) -join "`n")
    if ($sc -notmatch "Value:\s*1") {
        Log "SU_COMPAT_NOT_1 -> set 1"
        & $adb shell "su -c '/data/adb/ksu/bin/ksud feature set su_compat 1'" 2>&1 | Out-Null
        $sc = ((& $adb shell "su -c '/data/adb/ksu/bin/ksud feature get su_compat'" 2>&1) -join "`n")
        Log ("SU_COMPAT_AFTER=" + ($sc -replace "`n", " "))
    } else {
        Log "SU_COMPAT_OK"
    }

    if ($r2 -match "KSU_UP") { Log "KSU_UP"; return $true }
    Log "KSU_BRINGUP_FAILED"
    return $false
}

function Ensure-Module {
    $m = ((& $adb shell "grep droid_lkm /proc/modules" 2>$null) -join "").Trim()
    if ($m -match "droid_lkm") { Log "MODULE_ALREADY_LOADED"; return $true }

    $ko = "/data/adb/modules/droidspaces_shim/droid_lkm.ko"
    $args = "route=2 skip_sysvipc=0 gate=1 degrade=1 verbose=1 zap_guard=1 reaper_fix=1 tick_ms=0 no_teardown=1 skip_disable_alloc=0 disable_alloc_mode=1"
    & $adb shell "su -c `"insmod $ko $args`"" 2>&1 | ForEach-Object { Log "insmod| $_" }
    Start-Sleep -Seconds 2
    $m2 = ((& $adb shell "grep droid_lkm /proc/modules" 2>$null) -join "").Trim()
    if ($m2 -match "droid_lkm") { Log "MODULE_LOADED $m2"; return $true }
    Log "MODULE_LOAD_FAILED"
    return $false
}

function Pull-Files([string]$round) {
    $listed = ((& $adb shell "su -c 'ls /data/local/tmp'" 2>$null) -join "`n") -split "`n"
    $want = @()
    foreach ($f in $listed) {
        $f = $f.Trim()
        if ($f -match '^(kB\d|kb\d|ds_startB|ds_stopB|nsdump_B|auto_state)') { $want += "/data/local/tmp/$f" }
    }
    foreach ($p in $want) {
        & $adb pull $p $logDir 2>&1 | Out-Null
    }
    $n = (Get-ChildItem $logDir -File -ErrorAction SilentlyContinue | Measure-Object).Count
    Log "pulled files=$n -> $logDir"
}

function Write-State([string]$s) {
    & $adb shell "su -c 'echo $s > /data/local/tmp/auto_state'" 2>&1 | Out-Null
}

if (-not (Wait-Device $TimeoutSec)) { exit 2 }
$ok = Ensure-Root
if (-not $ok) {
    $exists = ((& $adb shell "ls /data/local/tmp/rpproot_re/reroot.sh" 2>&1) -join "").Trim()
    if ($exists -match "No such") { Log "REROOT_MISSING" }
    Write-State "blocked:no_root"
    Pull-Files $Round
    exit 3
}

Log "device ready: $( ((& $adb shell getprop persist.sys.boot.reason.history 2>$null) -join '' ).Trim() )"
Ensure-KSU | Out-Null
$mK = ((& $adb shell "grep -c droid_lkm /proc/modules" 2>$null) -join "").Trim()
Log "MODULE_AFTER_KSU_LOADED=$mK"
Ensure-Module | Out-Null
Start-Sleep -Seconds 3
$chk = ""
for ($i = 0; $i -lt 3; $i++) {
    $chk = ((& $adb shell "su -c '/data/local/Droidspaces/bin/droidspaces check'" 2>&1) -join "`n")
    if ($chk -match "All required features") { break }
    Log "CHECK_RETRY=$i"
    Start-Sleep -Seconds 2
}
if ($chk -match "All required features") { Log "CHECK_OK" } else {
    Log "CHECK_FAILED"
    $chk | Out-File -Encoding utf8 (Join-Path $logDir "check_failed.txt")
    $cross = [string][char]0x2717
    $miss = $chk -split "`n" | Where-Object { $_.Contains($cross) }
    foreach ($line in $miss) { Log ("check-miss: " + ($line -replace '\x1b\[[0-9;]*m','')) }
    $dm = ((& $adb shell "su -c 'dmesg | tail -20'" 2>&1) -join "`n")
    $dm | Out-File -Encoding utf8 (Join-Path $logDir "dmesg_check_failed.txt")
}
Pull-Files $Round
Log "round $Round finished elapsed=$([math]::Round($sw.Elapsed.TotalSeconds,1))s"
