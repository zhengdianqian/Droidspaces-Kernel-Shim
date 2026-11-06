#!/system/bin/sh
# check_probe.sh —— 只读：droidspaces check 每一项的判定依据（从二进制字符串取证）
B=/data/local/Droidspaces/bin/droidspaces
for k in CONFIG_MACVLAN CONFIG_IP6_NF_NAT CONFIG_CFS_BANDWIDTH CONFIG_CGROUP_PIDS CONFIG_USER_NS devtmpfs sched_cfs_bandwidth_slice_us pids.max cpu.max; do
	echo "==== $k ===="
	grep -a -o -E ".{0,90}$k.{0,90}" $B 2>/dev/null | head -6
done
