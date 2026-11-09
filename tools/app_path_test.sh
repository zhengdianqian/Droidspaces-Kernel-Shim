#!/system/bin/sh
# 验证 App 路径：原生 droidspaces stop（不经过 ds_stop.sh），看门狗应接管清理
DS=/data/local/Droidspaces/bin/droidspaces
CG=/sys/fs/cgroup/droidspaces/UBUNTU26
now() { cut -d' ' -f1 /proc/uptime; }
el() { awk -v a=$1 -v b=$(now) 'BEGIN{printf "%.2f", b-a}'; }
snap() {
	echo "  [$1] kwin=$(ps -A -o comm | grep -c '^kwin_wayland$') plasma=$(ps -A -o comm | grep -c '^plasmashell$') \
cgroup=$([ -d "$CG" ] && find "$CG" -name cgroup.procs -exec cat {} \; 2>/dev/null | wc -l || echo 0) \
cgdir=$([ -d "$CG" ] && echo 1 || echo 0) show=$($DS show 2>&1 | grep -c RUNNING)"
}
echo "== 起容器 =="
T0=$(now)
sh /data/local/tmp/ds_start.sh UBUNTU26 >/data/local/tmp/app_path_start.out 2>&1
tail -1 /data/local/tmp/app_path_start.out
snap "start 完成 +$(el $T0)s"

echo "== 原生 droidspaces stop（App 走的就是这条）=="
t=$(now)
$DS -n UBUNTU26 stop 2>&1 | sed 's/^/    /'
echo "  raw stop 耗时 = $(el $t)s"
snap "stop 返回 +0s"
echo "== 等 5 s =="
sleep 5; snap "+5s"
echo "== 等 30 s =="
sleep 25; snap "+30s"
echo "== 看门狗日志 =="
tail -12 /data/adb/droidspaces_watchdog.log 2>/dev/null
echo "== 网络残留 =="
iptables -t nat -S 2>/dev/null | grep '172\.28' || echo "NAT: 无"
ip -o link 2>/dev/null | grep 'ds-v' || echo "veth: 无"
