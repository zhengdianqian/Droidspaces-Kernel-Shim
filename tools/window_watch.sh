#!/system/bin/sh
# window_watch.sh —— insmod 后 0..40s 的 check 序列观察（cycle7 现象取证用）
# 输出格式：<uptime>\t<t+sec>\t<rc>\t<cross_count>\t<green_count>\t<special>
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin
OUT=/data/local/tmp/window_$(date +%H%M%S).txt
BIN=/data/local/Droidspaces/bin/droidspaces
MOD=/data/adb/modules/droidspaces_shim/service.sh

echo "# begin uptime=$(cut -d' ' -f1 /proc/uptime) date=$(date '+%Y-%m-%d %H:%M:%S')" > $OUT

# 若模块未加载则执行 service.sh 完成 insmod
if ! grep -q 'droid_lkm' /proc/modules 2>/dev/null; then
    sh "$MOD" >> /data/local/tmp/ksu_bringup.log 2>&1
    echo "# insmod_done uptime=$(cut -d' ' -f1 /proc/uptime)" >> $OUT
else
    echo "# already_loaded uptime=$(cut -d' ' -f1 /proc/uptime)" >> $OUT
fi

i=0
while [ $i -le 40 ]; do
    U=$(cut -d' ' -f1 /proc/uptime)
    R=$(grep -c 'droid_lkm' /proc/modules 2>/dev/null)
    CHK=$("$BIN" check 2>&1)
    RC=$?
    X=$(echo "$CHK" | grep -c '✗')
    G=$(echo "$CHK" | grep -c '✓')
    LAST=$(echo "$CHK" | tail -1 | tr -d '\r')
    echo -e "$U\t$i\t$RC\t$X\t$G\tmod=$R\t$LAST" >> $OUT
    sleep 3
    i=$((i + 3))
done
echo "# end uptime=$(cut -d' ' -f1 /proc/uptime)" >> $OUT
echo "WROTE $OUT"
