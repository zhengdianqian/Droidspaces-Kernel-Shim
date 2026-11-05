#!/system/bin/sh
# soak_start.sh —— 启动 UBUNTU26（systemd）并拉起容器内持续 IO 负载
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin
D=/data/local/Droidspaces/bin/droidspaces
LOG=/data/local/tmp/soak_load.log

echo "=== $(date '+%H:%M:%S') start begin uptime=$(cut -d' ' -f1 /proc/uptime)" > $LOG
$D -n UBUNTU26 start --init=/sbin/init >> $LOG 2>&1
echo "start_rc=$? uptime=$(cut -d' ' -f1 /proc/uptime)" >> $LOG
sleep 12

nohup $D -n UBUNTU26 run -- /bin/sh -c 'while :; do dd if=/dev/zero of=/tmp/x bs=1M count=4 2>/dev/null; rm -f /tmp/x; sleep 5; done' >> $LOG 2>&1 &
echo "load_bg_pid=$!" >> $LOG

# 尝试 kmsg 落盘（失败不影响浸泡）
nohup cat /dev/kmsg > /data/local/tmp/kmsg_soak.log 2>&1 &
echo "kmsg_bg_pid=$!" >> $LOG

sleep 3
echo "=== $(date '+%H:%M:%S') after_load" >> $LOG
$D -n UBUNTU26 run -- /bin/sh -c 'ps -ef | grep -c dd' >> $LOG 2>&1
echo "DONE"
