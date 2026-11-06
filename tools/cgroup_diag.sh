#!/system/bin/sh
# cgroup_diag.sh —— 停止后定位残留 cgroup 的持有进程，验证 kill+rmdir 能彻底清掉
DS=/data/local/Droidspaces/bin/droidspaces
CG=/sys/fs/cgroup/droidspaces/UBUNTU26
echo "== date =="; date
echo "== stop =="
$DS -n UBUNTU26 stop 2>&1
sleep 6
echo "== 残留树里各 cgroup 的 procs 与命令 =="
for f in $(find $CG -name cgroup.procs 2>/dev/null); do
	ps=$(cat $f 2>/dev/null | tr '\n' ' ')
	[ -z "$ps" ] && continue
	d=$(dirname $f)
	echo "-- $d : procs=$ps"
	for p in $ps; do
		echo "     pid=$p cg=$(cat /proc/$p/cgroup 2>/dev/null | head -1) cmd=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')"
	done
done
echo "== 顶层 cgroup.procs =="
cat $CG/cgroup.procs 2>&1
echo "== kill 所有后代成员 =="
for i in 1 2 3; do
	for f in $(find $CG -name cgroup.procs 2>/dev/null); do
		for p in $(cat $f 2>/dev/null); do kill -9 $p 2>/dev/null; done
	done
	sleep 1
	for d in $(find $CG -depth -type d 2>/dev/null); do rmdir "$d" 2>/dev/null; done
	if [ ! -d $CG ]; then echo "removed at pass $i"; break; fi
	echo "pass $i still exists"
done
echo "== 清理后 =="
ls /sys/fs/cgroup/droidspaces/ 2>&1
echo "== 重新 start（ds_start 路径） =="
sh /data/local/tmp/ds_start.sh UBUNTU26 2>&1 | tail -30
sleep 45
echo "== 本次 start 的告警行 =="
tail -n 140 /data/local/Droidspaces/Logs/UBUNTU26/log | tr -d '\000' | grep -nE '\[CGROUP\]|VirGL|Hardware access|Anland|Booting'
echo "== 容器内 plasma =="
$DS -n UBUNTU26 run -- /bin/sh -c 'systemctl is-active plasma-wayland; ls -la /run/display.sock' 2>&1 | head -6
echo "== check =="
$DS check 2>&1 | tail -8
