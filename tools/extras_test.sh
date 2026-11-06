#!/system/bin/sh
# extras_test.sh —— 浸泡结束后：实测两个树外 KO 是否真的能补绿 check
EX=/data/local/tmp/extras
echo "== date =="; date
echo "== baseline check（本次只看 6 个 ✗ 项） =="
/data/local/Droidspaces/bin/droidspaces check 2>&1 | grep -E 'devtmpfs|Macvlan|IPv6 NAT|CPU limit|Process limit|Sandboxing|required feature'

echo "== insmod macvlan.ko =="
insmod $EX/macvlan.ko 2>&1; echo "rc=$?"
grep '^macvlan ' /proc/modules 2>&1
echo "-- ip link add macvlan 实测 --"
ip link add link wlan0 name mvprobe0 type macvlan mode bridge 2>&1; echo "ip_rc=$?"
ip link show mvprobe0 2>&1 | head -2
ip link del mvprobe0 2>/dev/null

echo "== insmod ip6table_nat.ko =="
insmod $EX/ip6table_nat.ko 2>&1; echo "rc=$?"
grep '^ip6table_nat ' /proc/modules 2>&1
echo "-- ip6tables nat 实测 --"
ip6tables -t nat -L -n 2>&1 | head -6; echo "ip6tables_rc=$?"

echo "== insmod devtmpfs.ko（预期失败，证明不可树外修复） =="
insmod $EX/devtmpfs.ko 2>&1; echo "rc=$?"
grep -c devtmpfs /proc/filesystems

echo "== after check =="
/data/local/Droidspaces/bin/droidspaces check 2>&1 | tail -30
