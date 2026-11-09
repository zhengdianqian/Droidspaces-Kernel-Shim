#!/system/bin/sh
# 残留检查：NAT 规则 / veth / DHCP / anland daemon / 显示栈进程
echo "== iptables nat 172.28 =="
iptables -t nat -S 2>&1 | grep -i '172\.28' || echo "none"
echo "== ip6tables nat =="
ip6tables -t nat -S 2>&1 | head -3
echo "== ds-v* link =="
ip -o link 2>&1 | grep -i 'ds-v' || echo "none"
echo "== ip rule =="
ip rule 2>&1 | grep -E '172\.28|lookup' | head -10
echo "== route =="
ip route 2>&1 | grep -i '172\.28' || echo "none"
echo "== anland/dhcp procs =="
ps -A -o pid,ppid,comm 2>&1 | grep -iE 'anland|dhcp' || echo "none"
echo "== cgroup =="
find /sys/fs/cgroup/droidspaces -name cgroup.procs -exec sh -c 'echo "$1 $(wc -l < "$1")"' _ {} \; 2>/dev/null || echo "none"
echo "== show =="
/data/local/Droidspaces/bin/droidspaces show 2>&1 | tail -3
