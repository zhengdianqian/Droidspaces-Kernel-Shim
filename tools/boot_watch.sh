#!/system/bin/sh
# boot_watch.sh —— 冷启动后从"模块出现"开始记录 0..45 s 的 check 序列
# 目的：抓 cycle7 式「check 连续 ✗ → 约 23 s 后自复位」的窗口
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin
SLEEP=/system/bin/sleep
[ "$(id -u)" = "0" ] || { echo "NO_ROOT"; exit 9; }
BIN=/data/local/Droidspaces/bin/droidspaces
LOG=/data/local/tmp/boot_watch_${1:-x}.txt
: > $LOG
up() { cut -d' ' -f1 /proc/uptime; }
say() { echo "$*" >> $LOG; echo "$*"; }

say "# wait_start uptime=$(up)"

n=0
while [ $n -lt 120 ]; do
    if grep -q 'droid_lkm' /proc/modules 2>/dev/null; then
        say "# MODULE_APPEAR uptime=$(up) after=${n}s"
        break
    fi
    $SLEEP 1
    n=$((n + 1))
done
if [ $n -ge 120 ]; then
    say "# MODULE_NEVER_APPEARED uptime=$(up)"
fi

say "# modules: $(grep -E 'droid_lkm|kernelsu' /proc/modules | tr '\n' '|')"
say "# features: $(cat /proc/droid_lkm/features 2>/dev/null | tr '\n' '|')"

i=0
while [ $i -le 45 ]; do
    U=$(up)
    CHK=$("$BIN" check 2>&1)
    RC=$?
    X=$(echo "$CHK" | grep -c '✗')
    G=$(echo "$CHK" | grep -c '✓')
    MISS=$(echo "$CHK" | grep '✗' | tr '\n' ';')
    MODS=$(grep 'droid_lkm' /proc/modules 2>/dev/null | awk '{print $2"/"$3"/"$5}' | tr '\n' ';')
    say "$U|$i|rc=$RC|x=$X|g=$G|mod=$MODS|miss=$MISS"
    $SLEEP 3
    i=$((i + 3))
done

say "# end uptime=$(up)"
say "# bootreason=$(getprop ro.boot.bootreason) hist=$(getprop persist.sys.boot.reason.history | tr '\n' '|')"
say "WROTE $LOG"
