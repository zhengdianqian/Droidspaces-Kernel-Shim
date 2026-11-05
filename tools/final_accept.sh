#!/system/bin/sh
# FINAL：新开机（干净启动）下的最终验收 —— start 后运行中 stop，必须存活
export PATH=/system/bin:/system/xbin:/vendor/bin:/sbin
D=/data/local/tmp
S=$D/kFINAL_state.txt
L=$D/kFINAL.log
DS=/data/local/Droidspaces/bin/droidspaces
R=/data/local/Droidspaces/rootfs/UBUNTU26

rm -f $S $L
nohup tee -a $L < /dev/kmsg >/dev/null 2>&1 &
nohup sh -c 'while :; do sync; sleep 1; done' >/dev/null 2>&1 &
sleep 3
m() { echo "[$1] uptime=$(cut -d' ' -f1 /proc/uptime) epoch=$(date +%s)" >> $S; echo "MF:$1 uptime=$(cut -d' ' -f1 /proc/uptime)" > /dev/kmsg; sync; }

m BOOT_ANCHOR
sleep 1
C1=$(grep -a -c 'MF:BOOT_ANCHOR' $L 2>/dev/null)
echo "capture_marker_hits=$C1" >> $S
if [ "$C1" -eq 0 ]; then echo "CAPTURE_FAIL"; exit 9; fi

printf '#!/bin/sh\nwhile :; do sleep 600; done\n' > $R/keepalive.sh
chmod 755 $R/keepalive.sh
sync
m KEEPALIVE_READY

m START_BEGIN
nohup $DS -n UBUNTU26 start --init=/keepalive.sh > $D/ds_startFINAL.log 2>&1 &
sleep 12
P1=$($DS -n UBUNTU26 pid 2>/dev/null)
echo "P1=$P1 exists=$([ -d /proc/$P1 ] && echo yes || echo no)" >> $S
m DUMP_DONE

m CHECK_BEGIN
$DS check >> $S 2>&1
echo "check_rc=$?" >> $S
m CHECK_DONE

m STOP_BEGIN
nohup $DS -n UBUNTU26 stop > $D/ds_stopFINAL.log 2>&1 &
sleep 5
m STOP_AFTER5
sleep 20
m STOP_AFTER25
echo "p1_exists_after=$([ -d /proc/$P1 ] && echo yes || echo no)" >> $S
echo "stop_log=$(cat $D/ds_stopFINAL.log 2>/dev/null | tr '\n' '|')" >> $S
sync

m UNMOUNT_BEGIN
UNMOUNT_OK=no
[ -f $R/../unshare_probe ] && UNMOUNT_OK=yes
m FINAL_DONE
sync
echo kfinal_done
