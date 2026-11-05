#!/system/bin/sh
# B18b（同一开机，模块 B18 已在位）：
#   1) start 容器并让它保持运行
#   2) 直接 stop（不先 kill PID1）——真正的用户场景
#   3) droidspaces check
#   4) unshare --pid（CONFIG_PID_NS=n 应返回 EINVAL 且不复位）
export PATH=/system/bin:/system/xbin:/vendor/bin:/sbin
D=/data/local/tmp
S=$D/kB18b_state.txt
R=/data/local/Droidspaces/rootfs/UBUNTU26

m() { echo "[$1] uptime=$(cut -d' ' -f1 /proc/uptime) epoch=$(date +%s)" >> $S; echo "M18B:$1 uptime=$(cut -d' ' -f1 /proc/uptime) epoch=$(date +%s)" > /dev/kmsg; sync; }

rm -f $S
m B18B_START
nohup /data/local/Droidspaces/bin/droidspaces -n UBUNTU26 start --init=/keepalive.sh > $D/ds_startB18b.log 2>&1 &
sleep 12
m B18B_STARTED
P1=$(ps -A -o PID,PPID,ARGS 2>/dev/null | awk '$3=="sh" && $4=="/keepalive.sh" {print $1; exit}')
echo "P1=$P1 p1_exists=$([ -d /proc/$P1 ] && echo yes || echo no)" >> $S

m B18B_UNSHARE_BEFORE
OUT=$(unshare --pid /system/bin/echo unshare_ok 2>&1)
RC=$?
echo "unshare_pid_rc=$RC out=$OUT" >> $S
m B18B_UNSHARE_AFTER

m B18B_STOP_RUNNING
nohup /data/local/Droidspaces/bin/droidspaces -n UBUNTU26 stop > $D/ds_stopB18b.log 2>&1 &
sleep 5
m B18B_STOP_AFTER5
sleep 20
m B18B_STOP_AFTER25
echo "p1_exists_after=$([ -d /proc/$P1 ] && echo yes || echo no)" >> $S

m B18B_CHECK_BEGIN
/data/local/Droidspaces/bin/droidspaces check > $D/ds_checkB18b.log 2>&1
echo "check_rc=$?" >> $S
m B18B_CHECK_DONE
sync
echo b18b_done
