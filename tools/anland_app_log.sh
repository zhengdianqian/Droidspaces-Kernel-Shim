#!/system/bin/sh
# anland_app_log.sh —— 采集 Anland App 启动时的 logcat（定位它如何连 socket）
{
logcat -c 2>/dev/null
am force-stop com.anland.consumer
am start -W -n com.anland.consumer/.MainActivity >/dev/null 2>&1
sleep 6
echo "== logcat anland =="
logcat -d 2>/dev/null | grep -iE 'anland|display.sock|socket|droidspaces' | tail -50
} > /data/local/tmp/anland_app_log.txt 2>&1
cat /data/local/tmp/anland_app_log.txt
