#!/system/bin/sh
# 阶段 2：真实 systemd 负载 + 大量 fork + SysV IPC 全链路 + /proc/self/ns 观测
export PATH=/system/bin:/system/xbin:/vendor/bin:/sbin
D=/data/local/tmp
DS=/data/local/Droidspaces/bin/droidspaces
S=$D/kPHASE2_state.txt

rm -f $S
echo "PHASE2_BEGIN epoch=$(date +%s) uptime=$(awk '{print $1}' /proc/uptime)" >> $S

# --- 起 systemd ---
nohup $DS -n UBUNTU26 start --init=/sbin/init > $D/ds_p2_start.log 2>&1 &
sleep 25
P1=$($DS -n UBUNTU26 pid 2>/dev/null)
echo "p1=$P1 p1_exists=$([ -d /proc/$P1 ] && echo yes || echo no) p1_comm=$(cat /proc/$P1/comm 2>/dev/null)" >> $S
echo "start_log=$(tr '\n' '|' < $D/ds_p2_start.log)" >> $S

# --- 容器内 /proc/self/ns 观测（遗留问题 3） ---
echo "--- container /proc/self/ns ---" >> $S
$DS -n UBUNTU26 run -- sh -c 'ls -l /proc/self/ns /proc/1/ns 2>&1' >> $S 2>&1
echo "--- host /proc/self/ns ---" >> $S
ls -l /proc/self/ns >> $S 2>&1

# --- 大量 fork：apt ---
echo "--- apt list --installed ---" >> $S
$DS -n UBUNTU26 run -- sh -c 'apt list --installed 2>/dev/null | wc -l; apt list --installed 2>/dev/null | head -5' >> $S 2>&1
echo "--- apt-get update (timeout 90) ---" >> $S
$DS -n UBUNTU26 run -- sh -c 'timeout 90 apt-get update 2>&1 | tail -6; echo apt_rc=$?' >> $S 2>&1
echo "uptime_after_apt=$(awk '{print $1}' /proc/uptime)" >> $S

# --- unshare 行为 ---
echo "--- unshare in container ---" >> $S
$DS -n UBUNTU26 run -- sh -c 'unshare --pid --fork true; echo pid_fork_rc=$?; unshare --ipc true; echo ipc_rc=$?' >> $S 2>&1

# --- SysV IPC 全链路 ---
echo "--- sysvipc full chain ---" >> $S
$DS -n UBUNTU26 run -- sh -c '
  id=$($(command -v ipcmk) -M 4096 2>/dev/null | sed -n "s/.*id=//p")
  echo "ipcmk_M_rc=$? shmid=$id"
  ipcs -m
  ipcrm -m $id; echo "ipcrm_m_rc=$?"
  ipcs -m
' >> $S 2>&1
$DS -n UBUNTU26 run -- sh -c 'ipcmk -Q; echo q_rc=$?; ipcmk -S 1; echo s_rc=$?; ipcs -q; ipcs -s' >> $S 2>&1
echo "--- host sysvipc lines ---" >> $S
for f in /proc/sysvipc/msg /proc/sysvipc/shm /proc/sysvipc/sem; do
	echo "$f: $(wc -l < $f 2>/dev/null)" >> $S
done
echo "uptime_after_ipc=$(awk '{print $1}' /proc/uptime)" >> $S

# --- 停止 ---
echo "--- stop ---" >> $S
$DS -n UBUNTU26 stop > $D/ds_p2_stop.log 2>&1
echo "stop_rc=$? log=$(tr '\n' '|' < $D/ds_p2_stop.log)" >> $S
sleep 12
echo "p1_exists_after=$([ -d /proc/$P1 ] && echo yes || echo no)" >> $S
echo "PHASE2_END uptime=$(awk '{print $1}' /proc/uptime)" >> $S
sync
echo phase2_done
