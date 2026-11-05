#!/system/bin/sh
# B17: skip_disable_alloc=1, 无 stall。
#   判据：kill -KILL 容器 PID1 后
#   - 存活 -> disable_pid_allocation 调用就是复位触发点（下一步改成 BTF 直写 pid_allocated）
#   - 仍复位 -> 死点不在该调用，转查 BR12 之前（exit_sem/exit_shm/信号投递）
export PATH=/system/bin:/system/xbin:/vendor/bin:/sbin
D=/data/local/tmp
R=/data/local/Droidspaces/rootfs/UBUNTU26
L=$D/kB17.log
HB=$D/kb17_hb.log
S=$D/kB17_state.txt

rm -f $L $HB $S
nohup tee -a $L < /dev/kmsg >/dev/null 2>&1 &
nohup sh -c 'while :; do sync; sleep 1; done' >/dev/null 2>&1 &
nohup sh -c 'while :; do echo "HB $(cut -d" " -f1 /proc/uptime)" >> /data/local/tmp/kb17_hb.log; sleep 0.1; done' >/dev/null 2>&1 &
sleep 3
m() { echo "[$1] uptime=$(cut -d' ' -f1 /proc/uptime) epoch=$(date +%s)" >> $S; echo "M17:$1 uptime=$(cut -d' ' -f1 /proc/uptime) epoch=$(date +%s)" > /dev/kmsg; sync; }
m BOOT_ANCHOR
sleep 1
C1=$(grep -a -c 'M17:BOOT_ANCHOR' $L 2>/dev/null)
echo "capture_marker_hits=$C1 hb_lines=$(wc -l < $HB)" >> $S
if [ "$C1" -eq 0 ]; then echo "CAPTURE_FAIL"; m CAPTURE_FAIL_ABORT; exit 9; fi

printf '#!/bin/sh\nwhile :; do sleep 600; done\n' > $R/keepalive.sh
chmod 755 $R/keepalive.sh
sync
m KEEPALIVE_READY

insmod /data/local/tmp/droid_lkm_B17.ko route=2 skip_sysvipc=0 gate=1 degrade=1 verbose=1 zap_guard=1 reaper_fix=1 tick_ms=100 no_teardown=1 skip_disable_alloc=1 stall_mask=0 stall_ms=0
echo "insmod_rc=$?" >> $S
m INSMOD_DONE
sleep 3
echo "skip_disable_alloc=$(cat /sys/module/droid_lkm/parameters/skip_disable_alloc 2>/dev/null) stall_mask=$(cat /sys/module/droid_lkm/parameters/stall_mask 2>/dev/null)" >> $S

nohup /data/local/Droidspaces/bin/droidspaces -n UBUNTU26 start --init=/keepalive.sh > $D/ds_startB17.log 2>&1 &
sleep 12
m START_RETURNED
P1=$(ps -A -o PID,PPID,ARGS 2>/dev/null | awk '$3=="sh" && $4=="/keepalive.sh" {print $1; exit}')
CHILD=$(ps -A -o PID,PPID,ARGS 2>/dev/null | awk -v p="$P1" '$2==p {print $1; exit}')
echo "P1=$P1 CHILD=$CHILD" >> $S
m DUMP_DONE

m STEP4_TERM_CHILD
[ -n "$CHILD" ] && kill -TERM $CHILD 2>/dev/null
sleep 5
m STEP4_AFTER
echo "child_exists=$([ -d /proc/$CHILD ] && echo yes || echo no)" >> $S

T0=$(date +%s); U0=$(cut -d' ' -f1 /proc/uptime); H0=$(tail -1 $HB)
echo "KILL_ANCHOR epoch=$T0 uptime=$U0 last_hb=$H0" >> $S
sync
m STEP5_KILL_PID1
[ -n "$P1" ] && kill -KILL $P1 2>/dev/null
sleep 5
m STEP5_AFTER5
sleep 40
m STEP5_AFTER45
echo "p1_exists=$([ -d /proc/$P1 ] && echo yes || echo no)" >> $S
sync

m STEP6_STOP_BEGIN
nohup /data/local/Droidspaces/bin/droidspaces -n UBUNTU26 stop > $D/ds_stopB17.log 2>&1 &
sleep 25
m STEP6_STOP_AFTER
sync
echo b17_done
