#!/system/bin/sh
export PATH=/system/bin:/system/xbin:/vendor/bin:/sbin
K=/data/adb/ksu/bin/ksud
L=/data/adb/droidspaces_shim.log
echo "before_lines=$(wc -l < $L 2>/dev/null)"
timeout 20 $K services > /data/local/tmp/ksvc.out 2>&1
echo "services_rc=$?"
sleep 2
echo "after_lines=$(wc -l < $L 2>/dev/null)"
echo "--- new log lines ---"
tail -4 $L 2>/dev/null
echo "--- ksvc.out ---"
tail -10 /data/local/tmp/ksvc.out 2>/dev/null
