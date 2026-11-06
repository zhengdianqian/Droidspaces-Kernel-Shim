#!/system/bin/sh
P=$(pidof com.anland.consumer)
echo "PID=$P"
echo "== logcat for anland pid (last 200 lines) =="
logcat -d 2>/dev/null | grep -iE "anland|$P" | tail -60
echo "== logcat main errors =="
logcat -d -b main -t 120 2>/dev/null | tail -40
echo "== tombstones =="
ls -la /data/tombstones 2>/dev/null | tail -5
echo "== dmesg tail =="
dmesg 2>/dev/null | tail -20
