#!/system/bin/sh
# 浸泡测试：start -> 运行 180 s -> stop，连续 5 轮
# 每轮记录 uptime 前后、/proc/modules、droidspaces check rc
export PATH=/system/bin:/system/xbin:/vendor/bin:/sbin
D=/data/local/tmp
DS=/data/local/Droidspaces/bin/droidspaces
R=/data/local/Droidspaces/rootfs/UBUNTU26
S=$D/kSOAK_state.txt
L=$D/kSOAK.log

rm -f $S
nohup tee -a $L < /dev/kmsg >/dev/null 2>&1 &
nohup sh -c 'while :; do sync; sleep 1; done' >/dev/null 2>&1 &
sleep 2

printf '#!/bin/sh\nwhile :; do sleep 600; done\n' > $R/keepalive.sh
chmod 755 $R/keepalive.sh
sync

echo "SOAK_BEGIN epoch=$(date +%s)" >> $S

i=1
while [ $i -le 5 ]; do
	U0=$(awk '{print $1}' /proc/uptime)
	M0=$(grep -c droid_lkm /proc/modules 2>/dev/null)
	echo "=== ROUND $i ===" >> $S
	echo "start_uptime_before=$U0 module_loaded_before=$M0" >> $S

	nohup $DS -n UBUNTU26 start --init=/keepalive.sh > $D/ds_soak_start_$i.log 2>&1 &
	sleep 8
	echo "start_log=$(tr '\n' '|' < $D/ds_soak_start_$i.log)" >> $S
	P1=$($DS -n UBUNTU26 pid 2>/dev/null)
	echo "p1=$P1 p1_exists=$([ -d /proc/$P1 ] && echo yes || echo no)" >> $S

	sleep 174
	U1=$(awk '{print $1}' /proc/uptime)
	M1=$(grep -c droid_lkm /proc/modules 2>/dev/null)
	echo "running_uptime_after_180s=$U1 module_loaded_running=$M1" >> $S

	$DS check > $D/ds_soak_check_$i.log 2>&1
	RC=$?
	SUM=$(grep -a 'All required features' $D/ds_soak_check_$i.log | tail -1)
	echo "check_rc=$RC check_summary=$SUM" >> $S

	$DS -n UBUNTU26 stop > $D/ds_soak_stop_$i.log 2>&1
	echo "stop_rc=$? stop_log=$(tr '\n' '|' < $D/ds_soak_stop_$i.log)" >> $S
	sleep 12

	U2=$(awk '{print $1}' /proc/uptime)
	M2=$(grep -c droid_lkm /proc/modules 2>/dev/null)
	echo "stop_uptime_after=$U2 module_loaded_after=$M2 p1_exists_after=$([ -d /proc/$P1 ] && echo yes || echo no)" >> $S
	echo "DELTA round$i: $U0 -> $U1 -> $U2" >> $S

	# 判定：uptime 必须单调递增（回退即视为复位）
	BAD=$(awk -v a="$U0" -v b="$U1" -v c="$U2" 'BEGIN{print (b>a && c>=b) ? 0 : 1}')
	echo "round$i_monotonic=$([ $BAD -eq 0 ] && echo pass || echo FAIL)" >> $S

	i=$((i + 1))
done

echo "SOAK_END epoch=$(date +%s) final_uptime=$(awk '{print $1}' /proc/uptime)" >> $S
sync
echo soak_done
