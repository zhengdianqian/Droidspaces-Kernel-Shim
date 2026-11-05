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
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeout) {
        $dev = (& $adb devices 2>$null) -join "`n"
        if ($dev -match "`tdevice") {
            $bc = ((& $adb shell getprop sys.boot_completed 2>$null) -join "").Trim()
            if ($bc -eq "1") {
                $up = ((& $adb shell cat /proc/uptime 2>$null) -join "").Trim()
                Log "device online boot_completed=1 uptime=$up"
                return $true
            }
        }
        Start-Sleep -Seconds 5
    }
    Log "WAIT_DEVICE_TIMEOUT"
    return $false
}

function Ensure-Root {
    $id = ((& $adb shell "su -c id" 2>$null) -join "").Trim()
    if ($id -match "uid=0") { Log "ROOT_OK $id"; return $true }

    Log "NO_ROOT -> reroot.sh"
    $r = ((& $adb shell "sh /data/local/tmp/rpproot_re/reroot.sh" 2>&1) -join "`n")
    $r -split "`n" | Select-Object -Last 8 | ForEach-Object { Log "reroot| $_" }
    Start-Sleep -Seconds 3

    $id2 = ((& $adb shell "su -c id" 2>$null) -join "").Trim()
    if ($id2 -match "uid=0") { Log "ROOT_RESTORED $id2"; return $true }
    Log "REROOT_FAILED"
    return $false
}

function Ensure-KSU {
    # 本机是 "先提权，再 late-load"：开机阶段 KSU 还没加载，post-fs-data/service 已过。
    # ksu_bringup.sh：late-load（若未加载）+ 补触发 service 阶段（让 module service.sh 自己跑 insmod）
    & $adb push (Join-Path $root "ksu_bringup.sh") /data/local/tmp/ksu_bringup_v2.sh 2>&1 | Out-Null
    $r = ((& $adb shell "su -c 'sh /data/local/tmp/ksu_bringup_v2.sh'" 2>&1) -join "`n")
    $r -split "`n" | ForEach-Object { if ($_.Trim()) { Log "ksubring| $_" } }
    if ($r -match "KSU_UP") { Log "KSU_UP"; return $true }
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
$chk = ((& $adb shell "su -c '/data/local/Droidspaces/bin/droidspaces check'" 2>&1) -join "`n")
if ($chk -match "All required features") { Log "CHECK_OK" } else { Log "CHECK_FAILED" }
Pull-Files $Round
Log "round $Round finished elapsed=$([math]::Round($sw.Elapsed.TotalSeconds,1))s"
