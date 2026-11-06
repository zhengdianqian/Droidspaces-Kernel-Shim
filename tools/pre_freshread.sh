#!/system/bin/sh
C=/data/local/Droidspaces/Containers/UBUNTU26
R=/data/local/Droidspaces/rootfs/UBUNTU26
echo "==config=="
cat $C/container.config
echo "==config files=="
ls -la $C/
echo "==plasma unit files=="
ls -la $R/etc/systemd/system/plasma-wayland.service* 2>&1
echo "==unit body=="
cat $R/etc/systemd/system/plasma-wayland.service 2>&1
echo "==wants=="
ls -la $R/etc/systemd/system/graphical.target.wants/ 2>&1
ls -la $R/etc/systemd/system/multi-user.target.wants/ 2>&1 | head -20
echo "==logs tail=="
ls -la /data/local/Droidspaces/Logs/UBUNTU26/
echo "==cgroup now=="
find /sys/fs/cgroup/droidspaces -maxdepth 2 2>/dev/null
echo "==droidspaces ps=="
ps -eo pid,args 2>/dev/null | grep -E 'droidspaces|anland' | grep -v grep
