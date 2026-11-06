#!/system/bin/sh
# cgroup_recon.sh —— 只读：残留 cgroup 的结构与进程，预判清理障碍
echo "== date =="; date
echo "== droidspaces cgroup 根 =="
ls -la /sys/fs/cgroup/droidspaces/ 2>&1
echo "== UBUNTU26 树（最多 4 层） =="
find /sys/fs/cgroup/droidspaces/UBUNTU26 -maxdepth 4 2>/dev/null | head -40
echo "== 各子组 cgroup.procs =="
for d in $(find /sys/fs/cgroup/droidspaces/UBUNTU26 -name cgroup.procs 2>/dev/null | head -20); do
	echo "--- $d"; cat "$d" 2>&1 | head -5
done
echo "== 子组 controllers =="
for d in $(find /sys/fs/cgroup/droidspaces/UBUNTU26 -maxdepth 2 -name cgroup.controllers 2>/dev/null); do
	echo "--- $d"; cat "$d" 2>&1
done
echo "== 目录权限/属性 =="
ls -la /sys/fs/cgroup/droidspaces/UBUNTU26/ 2>&1 | head -20
echo "== cgroup 挂载 =="
mount 2>/dev/null | grep -E 'cgroup' | head -8
echo "== droidspaces 二进制里的清理相关字符串 =="
grep -a -o -E '.{0,100}left over from an earlier run.{0,80}' /data/local/Droidspaces/bin/droidspaces | head -3
grep -a -o -E '.{0,80}(cgroup\.procs|subtree_control|rmdir).{0,60}' /data/local/Droidspaces/bin/droidspaces | head -12
