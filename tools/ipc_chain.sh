#!/system/bin/sh
# IPC 全链路补测（带启动等待）
export PATH=/system/bin:/system/xbin:/vendor/bin:/sbin
D=/data/local/tmp
DS=/data/local/Droidspaces/bin/droidspaces
S=$D/kIPC2_state.txt

rm -f $S
echo "IPC2_BEGIN uptime=$(awk '{print $1}' /proc/uptime)" >> $S

# 等上一次 stop 彻底收尾（"another operation is in progress" 会持续数秒）
sleep 20

nohup $DS -n UBUNTU26 start --init=/keepalive.sh > $D/ds_ipc2_start.log 2>&1 &
n=0
P=""
while [ $n -lt 20 ]; do
	P=$($DS -n UBUNTU26 pid 2>/dev/null)
	[ -n "$P" ] && [ -d /proc/$P ] && break
	n=$((n + 1)); sleep 3
done
echo "p1=$P p1_exists=$([ -d /proc/$P ] && echo yes || echo no)" >> $S
echo "start_log=$(tr '\n' '|' < $D/ds_ipc2_start.log)" >> $S

echo "--- step1 ipcmk -M 4096 ---" >> $S
$DS -n UBUNTU26 run -- sh -c 'ipcmk -M 4096; echo rc=$?' >> $S 2>&1

echo "--- step2 ipcs -m ---" >> $S
$DS -n UBUNTU26 run -- sh -c 'ipcs -m' >> $S 2>&1

ID=$($DS -n UBUNTU26 run -- sh -c 'ipcs -m | awk "NR>3 && \$1 ~ /^0x/ {print \$2; exit}"' 2>/dev/null | tr -d '\r')
echo "parsed_shmid=[$ID]" >> $S

echo "--- step3 ipcrm -m $ID ---" >> $S
$DS -n UBUNTU26 run -- sh -c "ipcrm -m $ID; echo rc=\$?" >> $S 2>&1

echo "--- step4 ipcs -m (should be empty) ---" >> $S
$DS -n UBUNTU26 run -- sh -c 'ipcs -m' >> $S 2>&1

echo "--- step5 sem/msg chain ---" >> $S
$DS -n UBUNTU26 run -- sh -c 'ipcmk -S 1; ipcs -s; ipcrm -s 0; ipcs -s' >> $S 2>&1
$DS -n UBUNTU26 run -- sh -c 'ipcmk -Q; ipcs -q; ipcrm -q 0; ipcs -q' >> $S 2>&1

echo "--- host sysvipc lines ---" >> $S
for f in /proc/sysvipc/msg /proc/sysvipc/shm /proc/sysvipc/sem; do
	echo "$f: $(wc -l < $f 2>/dev/null)" >> $S
done

$DS -n UBUNTU26 stop > $D/ds_ipc2_stop.log 2>&1
echo "stop_rc=$? log=$(tr '\n' '|' < $D/ds_ipc2_stop.log)" >> $S
sleep 10
echo "IPC2_END uptime=$(awk '{print $1}' /proc/uptime)" >> $S
sync
echo ipc2_done
