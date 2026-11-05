#!/system/bin/sh
# 压力场景：容器内大量 fork 期间直接 stop
export PATH=/system/bin:/system/xbin:/vendor/bin:/sbin
D=/data/local/tmp
DS=/data/local/Droidspaces/bin/droidspaces
S=$D/kSTRESS_state.txt

rm -f $S
U0=$(awk '{print $1}' /proc/uptime)
echo "STRESS_BEGIN uptime=$U0" >> $S

P1=$($DS -n UBUNTU26 pid 2>/dev/null)
echo "p1_before=$P1 exists=$([ -d /proc/$P1 ] && echo yes || echo no)" >> $S

# 容器内制造 fork 风暴：400 个短命进程 + 200 个持续 fork 循环，持续约 20 s
$DS -n UBUNTU26 run -- sh -c '
for i in $(seq 1 400); do ( : ) & done
for j in $(seq 1 200); do ( while :; do /bin/true; done ) & done
sleep 20
' > $D/ds_stress_fork.log 2>&1 &
FORKPID=$!
echo "fork_storm_pid=$FORKPID" >> $S

sleep 6
U1=$(awk '{print $1}' /proc/uptime)
NPROC=$($DS -n UBUNTU26 run -- sh -c 'ls /proc | grep -c "^[0-9]*$"' 2>/dev/null | tr -d '\r')
echo "before_stop uptime=$U1 container_procs=$NPROC module=$(grep -c droid_lkm /proc/modules)" >> $S

echo "--- STOP during fork storm ---" >> $S
$DS -n UBUNTU26 stop > $D/ds_stress_stop.log 2>&1
echo "stop_rc=$? log=$(tr '\n' '|' < $D/ds_stress_stop.log)" >> $S
sleep 15

U2=$(awk '{print $1}' /proc/uptime)
echo "after_stop15 uptime=$U2 p1_exists=$([ -d /proc/$P1 ] && echo yes || echo no) module=$(grep -c droid_lkm /proc/modules)" >> $S
echo "uptime_monotonic=$(awk -v a="$U0" -v b="$U1" -v c="$U2" 'BEGIN{print (b>a && c>b)?"pass":"FAIL"}')" >> $S

echo "--- dmesg tail (oops/BUG scan) ---" >> $S
dmesg | grep -i -E "oops|bug|unable to handle|died|tasklist" | tail -6 >> $S 2>&1
echo "(empty above = clean)" >> $S
echo "STRESS_END uptime=$(awk '{print $1}' /proc/uptime)" >> $S
sync
echo stress_done
