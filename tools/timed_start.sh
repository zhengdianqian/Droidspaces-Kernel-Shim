#!/system/bin/sh
# timed_start.sh —— 分阶段计时 start（不改配置，纯测量）
DS=/data/local/Droidspaces/bin/droidspaces
LA=/data/local/Droidspaces/Logs/UBUNTU26/anland
NAME=UBUNTU26
now() { cut -d' ' -f1 /proc/uptime; }
T0=$(now)
mark() { echo "  [$1] +$(awk -v a=$T0 -v b=$(now) 'BEGIN{printf "%.2f", b-a}')s  $2"; }

echo "===== START $(date '+%F %T') ====="
echo "T0=$T0 uptime=$(now)"

echo "-- 执行 droidspaces start --"
$DS -n $NAME start --init=/sbin/init 2>&1 | sed 's/^/  | /'
mark T1 "start 命令返回"

grep -c 'listening on' $LA > /tmp/_anl0 2>/dev/null
B0=$(cat /tmp/_anl0 2>/dev/null || echo 0)

# 等 producer connected 新增
i=0
while [ $i -lt 480 ]; do
	c=$(grep -ac 'producer connected' $LA 2>/dev/null || echo 0)
	if [ "$c" -gt "${P0:-0}" ] 2>/dev/null; then :; fi
	if grep -aq 'producer connected' $LA 2>/dev/null; then
		last=$(grep -a 'producer connected' $LA | tail -1)
		case "$last" in *"$(date '+%Y-%m-%d')"*) break;; esac
	fi
	sleep 0.5; i=$((i+1))
	[ -n "$(ps -A -o comm | grep -m1 '^kwin_wayland$')" ] && break
done
mark T2 "kwin_wayland 进程出现"

k=0
while [ $k -lt 480 ]; do
	ps -A -o comm 2>/dev/null | grep -q '^plasmashell$' && break
	sleep 0.5; k=$((k+1))
done
mark T3 "plasmashell 进程出现（桌面开始画）"

# 拉起 consumer
SOCK=$(grep -a 'listening on' $LA | tail -1 | sed 's/.*listening on //')
echo "-- consumer socket: $SOCK --"
am start -n com.anland.consumer/.MainActivity --es socket_path "$SOCK" >/dev/null 2>&1
mark T4 "已发出 am start consumer"

j=0
while [ $j -lt 240 ]; do
	grep -a 'consumer connected' $LA 2>/dev/null | tail -1 | grep -q "$(date '+%Y-%m-%d')" && break
	sleep 0.5; j=$((j+1))
done
mark T5 "anland consumer connected"

sleep 3
mark T6 "截图点"
echo "== 关键日志（本次 start 起） =="
tail -n 60 /data/local/Droidspaces/Logs/UBUNTU26/log | tr -d '\000' | grep -E '\[!\]|virgl|VirGL|CGROUP|GPU\]|Anland|Booting|DHCP|left over' | sed 's/^/  | /'
echo "== 进程快照 =="
ps -A -o pid,ppid,pcpu,comm 2>/dev/null | grep -E 'kwin_wayland|plasmashell|startplasma' | grep -v grep
echo "== anland 日志尾 =="
tail -n 8 $LA
echo "== check =="
$DS check 2>&1 | tail -3
echo "===== END $(date '+%F %T') ====="
