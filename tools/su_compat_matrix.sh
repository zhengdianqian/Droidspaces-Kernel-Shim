#!/system/bin/sh
# su_compat_matrix.sh —— su_compat 开/关对 droid_lkm 与 App uid 的影响（同一 root 会话内完成，避免锁死）
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin
KSUD=/data/adb/ksu/bin/ksud
BIN=/data/local/Droidspaces/bin/droidspaces
LOG=/data/local/tmp/su_compat_matrix.txt
: > $LOG
up() { cut -d' ' -f1 /proc/uptime; }
say() { echo "$*" >> $LOG; echo "$*"; }
chk() { "$BIN" check 2>&1 | grep -E 'PID namespace|IPC namespace|All required features' >> $LOG; }

say "# ===== T0 baseline (su_compat: $($KSUD feature get su_compat | grep -E 'Value|Status' | tr '\n' ' ')) uptime=$(up)"
chk

say "# ----- set su_compat=0 -----"
$KSUD feature set su_compat 0 >> $LOG 2>&1
say "get: $($KSUD feature get su_compat | grep -E 'Value|Status' | tr '\n' ' ')"
say "ls_su: $(ls -l /system/bin/su 2>&1)"
say "appuid_su_off: $(setuidgid 10330 /system/bin/su -c id 2>&1 | tr '\n' ' ')"
say "check_off:"; chk

say "# ----- container start/stop with su_compat=0 (uptime=$(up)) -----"
"$BIN" -n UBUNTU26 start >> $LOG 2>&1
sleep 10
say "uptime_after_start=$(up)"; chk
"$BIN" -n UBUNTU26 stop >> $LOG 2>&1
sleep 5
say "uptime_after_stop=$(up)"; chk
say "modules: $(grep -E 'droid_lkm|kernelsu' /proc/modules | tr '\n' ' ')"

say "# ----- set su_compat=1 -----"
$KSUD feature set su_compat 1 >> $LOG 2>&1
say "get: $($KSUD feature get su_compat | grep -E 'Value|Status' | tr '\n' ' ')"
say "ls_su: $(ls -l /system/bin/su 2>&1)"
say "appuid_su_on: $(setuidgid 10330 /system/bin/su -c id 2>&1 | tr '\n' ' ')"
say "check_on:"; chk

say "# ----- container start/stop with su_compat=1 (uptime=$(up)) -----"
"$BIN" -n UBUNTU26 start >> $LOG 2>&1
sleep 10
say "uptime_after_start=$(up)"; chk
"$BIN" -n UBUNTU26 stop >> $LOG 2>&1
sleep 5
say "uptime_after_stop=$(up)"; chk
say "modules: $(grep -E 'droid_lkm|kernelsu' /proc/modules | tr '\n' ' ')"
say "# ===== END uptime=$(up)"
echo "DONE $LOG"
