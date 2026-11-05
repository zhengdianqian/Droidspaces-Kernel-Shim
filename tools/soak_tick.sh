#!/system/bin/sh
# soak_tick.sh —— 浸泡采样：一行输出全部指标（由宿主机每 15 分钟调用一次）
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin
U=$(cut -d' ' -f1 /proc/uptime)
MOD=$(grep droid_lkm /proc/modules 2>/dev/null | awk '{print $2"/"$3"/"$5}')
KSU=$(grep -c '^kernelsu ' /proc/modules 2>/dev/null)
MEM=$(grep -E '^Slab:|^SUnreclaim:|^SReclaimable:|^MemFree:' /proc/meminfo 2>/dev/null | tr '\n' ';')
DD=$(ps -A -o PID,ARGS 2>/dev/null | grep -c 'dd if=/dev/zero')
CT=$(ps -A -o PID,ARGS 2>/dev/null | grep -c 'droidspaces -n UBUNTU26 run')
CK=$(/data/local/Droidspaces/bin/droidspaces check 2>&1 | grep -E 'All required features|required feature\(s\) missing' | tail -1)
BR=$(getprop persist.sys.boot.reason.history 2>/dev/null | tr '\n' ' ')
echo "TICK|$U|mod=$MOD|ksu=$KSU|dd=$DD|ct=$CT|$MEM|check=$CK|br=$BR"
