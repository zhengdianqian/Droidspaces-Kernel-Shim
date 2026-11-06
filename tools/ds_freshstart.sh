#!/system/bin/sh
# ds_freshstart.sh —— 目标一：消 [CGROUP] / VirGL 两条 [!]；同时修复 plasma 开机自启竞态
C=/data/local/Droidspaces/Containers/UBUNTU26
R=/data/local/Droidspaces/rootfs/UBUNTU26
DS=/data/local/Droidspaces/bin/droidspaces
OUT=/data/local/tmp/freshstart.txt
{
echo "== date =="; date

echo "== 备份 container.config =="
cp -p $C/container.config $C/container.config.preVirgl.bak
echo "backup: $C/container.config.preVirgl.bak"

echo "== config: enable_virgl 1->0（enable_anland/enable_gpu_mode 保持 1） =="
sed -i 's/^enable_virgl=1$/enable_virgl=0/' $C/container.config
grep -E 'enable_virgl|enable_anland|enable_gpu_mode|enable_hw_access|enable_x11' $C/container.config

echo "== check (改动前) =="
$DS check 2>&1 | grep -E '✗|✓|required' | tail -20

echo "== 备份 + patch plasma-wayland.service（ExecStartPre sleep20 + Restart=always） =="
U=$R/etc/systemd/system/plasma-wayland.service
cp -p $U $U.prebak
sed -i 's/^Restart=no$/Restart=always/' $U
awk '/^\[Install\]/{print "RestartSec=5"; print "ExecStartPre=/bin/sleep 20"} {print}' $U > $U.new && mv $U.new $U
cat $U

echo "== stop 容器 =="
$DS -n UBUNTU26 stop 2>&1
sleep 8
echo "--- stop 后 droid_lkm / uptime ---"
grep '^droid_lkm ' /proc/modules
cat /proc/uptime

echo "== cgroup 残留复现 =="
ls -la /sys/fs/cgroup/droidspaces/ 2>&1
echo "-- 子目录树 --"
find /sys/fs/cgroup/droidspaces/UBUNTU26 -maxdepth 3 2>/dev/null
echo "-- cgroup.procs --"
cat /sys/fs/cgroup/droidspaces/UBUNTU26/cgroup.procs 2>&1
echo "-- droidspaces 原生做法：直接 rmdir 顶层 --"
rmdir /sys/fs/cgroup/droidspaces/UBUNTU26 2>&1; echo "rmdir_rc=$?"

echo "== 我们的做法：自底向上 rmdir 子组 =="
for d in $(find /sys/fs/cgroup/droidspaces/UBUNTU26 -depth -type d 2>/dev/null); do
	rmdir "$d" 2>&1
done
ls -la /sys/fs/cgroup/droidspaces/ 2>&1

echo "== 干净 start（经 ds_start.sh 预清理路径） =="
sh /data/local/tmp/ds_start.sh UBUNTU26 2>&1
sleep 40

echo "== 本次 start 日志：告警/关键行（log 文件末尾 120 行） =="
tail -n 120 /data/local/Droidspaces/Logs/UBUNTU26/log | tr -d '\000' | grep -nE '\[!\]|\[CGROUP\]|VirGL|Anland|GPU\]|Hardware access|Booting'

echo "== anland socket 文件 =="
ls -la /data/local/Droidspaces/Net/ 2>&1
echo "== 容器内 plasma / display.sock =="
$DS -n UBUNTU26 run -- /bin/sh -c 'systemctl is-active plasma-wayland; ls -la /run/display.sock; ps -eo pid,args | grep -E "kwin|plasma" | grep -v grep' 2>&1 | head -12

echo "== check (改动后) =="
$DS check 2>&1 | tail -25
} > $OUT 2>&1
cat $OUT
