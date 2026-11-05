#!/system/bin/sh
# B18c：容器运行中做 SysV IPC 三类测试 + 第二次运行中 stop
export PATH=/system/bin:/system/xbin:/vendor/bin:/sbin
D=/data/local/tmp
S=$D/kB18c_state.txt
DS=/data/local/Droidspaces/bin/droidspaces
m() { echo "[$1] uptime=$(cut -d' ' -f1 /proc/uptime) epoch=$(date +%s)" >> $S; echo "M18C:$1 uptime=$(cut -d' ' -f1 /proc/uptime)" > /dev/kmsg; sync; }

rm -f $S
m IPC_BEGIN
echo "--- container ipcmk ---" >> $S
$DS -n UBUNTU26 run -- sh -c 'ipcmk -Q; echo "q_rc=$?"; ipcmk -M 4096; echo "m_rc=$?"; ipcmk -S 1; echo "s_rc=$?"' >> $S 2>&1
echo "--- container ipcs ---" >> $S
$DS -n UBUNTU26 run -- sh -c 'ipcs -q; ipcs -m; ipcs -s' >> $S 2>&1
echo "--- host /proc/sysvipc ---" >> $S
ls -l /proc/sysvipc >> $S 2>&1
for f in /proc/sysvipc/msg /proc/sysvipc/shm /proc/sysvipc/sem; do
  echo "$f: $(wc -l < $f 2>/dev/null)" >> $S
done
m IPC_DONE

m STOP2_BEGIN
P1=$($DS -n UBUNTU26 pid 2>/dev/null)
echo "P1_before_stop=$P1 exists=$([ -d /proc/$P1 ] && echo yes || echo no)" >> $S
nohup $DS -n UBUNTU26 stop > $D/ds_stopB18c.log 2>&1 &
sleep 5
m STOP2_AFTER5
sleep 20
m STOP2_AFTER25
echo "p1_exists_after=$([ -d /proc/$P1 ] && echo yes || echo no)" >> $S
sync
echo b18c_done
