#!/system/bin/sh
# 长时间浸泡：systemd 常驻 45 分钟，每 300 s 采一次
#   指标：uptime / droid_lkm refcnt / Slab / SUnreclaim / kmemleak / 容器 P1
export PATH=/system/bin:/system/xbin:/vendor/bin:/sbin
D=/data/local/tmp
DS=/data/local/Droidspaces/bin/droidspaces
S=$D/kLONG_state.txt

rm -f $S
echo "LONG_BEGIN epoch=$(date +%s) uptime=$(awk '{print $1}' /proc/uptime)" >> $S

nohup $DS -n UBUNTU26 start --init=/sbin/init > $D/ds_long_start.log 2>&1 &
sleep 20
P1=$($DS -n UBUNTU26 pid 2>/dev/null)
echo "p1=$P1 comm=$(cat /proc/$P1/comm 2>/dev/null) exists=$([ -d /proc/$P1 ] && echo yes || echo no)" >> $S

KMEM=/sys/kernel/debug/kmemleak
if [ -f "$KMEM" ]; then
	echo "kmemleak=available" >> $S
	echo scan > $KMEM 2>/dev/null
else
	echo "kmemleak=unavailable" >> $S
	KMEM=""
fi

i=0
while [ $i -le 9 ]; do
	U=$(awk '{print $1}' /proc/uptime)
	REF=$(awk '/droid_lkm/ {print $3}' /proc/modules)
	SLAB=$(awk '/^Slab:/ {print $2}' /proc/meminfo)
	SUN=$(awk '/^SUnreclaim:/ {print $2}' /proc/meminfo)
	SREC=$(awk '/^SlabReclaimable:/ {print $2}' /proc/meminfo)
	P=$($DS -n UBUNTU26 pid 2>/dev/null)
	PE=$([ -n "$P" ] && [ -d /proc/$P ] && echo yes || echo no)
	if [ -n "$KMEM" ]; then
		echo scan > $KMEM 2>/dev/null
		sleep 1
		KL=$(grep -c "unreferenced object" $KMEM 2>/dev/null)
	else
		KL=na
	fi
	echo "t=$i uptime=$U refcnt=$REF Slab=$SLAB SUnreclaim=$SUN SlabReclaimable=$SREC p1=$P p1_exists=$PE kmemleak=$KL" >> $S
	i=$((i + 1))
	[ $i -le 9 ] && sleep 300
done

echo "LONG_END epoch=$(date +%s) uptime=$(awk '{print $1}' /proc/uptime)" >> $S
sync
echo long_done
