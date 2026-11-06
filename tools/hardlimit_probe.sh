#!/system/bin/sh
# hardlimit_probe.sh —— 只读/失败即回滚：实证 6 个 ✗ 在内核层的真实报错
echo "== date =="; date
echo "== devtmpfs =="
grep -c devtmpfs /proc/filesystems
mkdir -p /data/local/tmp/probe_mnt 2>/dev/null
mount -t devtmpfs none /data/local/tmp/probe_mnt 2>&1; echo "mount_rc=$?"
umount /data/local/tmp/probe_mnt 2>/dev/null
echo "== macvlan (ip link add 探测) =="
ip link add link wlan0 name mvprobe0 type macvlan mode bridge 2>&1; echo "ip_rc=$?"
ip link del mvprobe0 2>/dev/null
echo "-- /sys/class/net/wlan0/type --"
cat /sys/class/net/wlan0/type 2>&1
echo "== ipv6 nat (ip6tables nat 表) =="
ip6tables -t nat -L -n 2>&1 | head -5; echo "ip6tables_rc=$?"
echo "== cgroup pids =="
ls -la /sys/fs/cgroup/droidspaces/UBUNTU26/pids.max 2>&1
cat /sys/fs/cgroup/cgroup.controllers 2>&1
ls /sys/fs/cgroup/droidspaces/cgroup.controllers 2>/dev/null && cat /sys/fs/cgroup/droidspaces/cgroup.controllers 2>/dev/null
echo "== cgroup cpu =="
ls -la /proc/sys/kernel/sched_cfs_bandwidth_slice_us 2>&1
ls -la /sys/fs/cgroup/droidspaces/UBUNTU26/cpu.max 2>&1
echo "== user ns =="
unshare -U true 2>&1; echo "unshare_rc=$?"
echo "== 内核配置（同一份 config.gz 佐证） =="
zcat /proc/config.gz 2>/dev/null | grep -E '^#? ?CONFIG_(DEVTMPFS|MACVLAN|IP6_NF_NAT|IP6_NF_TARGET_MASQUERADE|CFS_BANDWIDTH|CGROUP_PIDS|USER_NS)( |_|=)' 
