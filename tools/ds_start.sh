#!/system/bin/sh
# ds_start.sh —— 分阶段计时 + 自动接上 Anland consumer（问题 1）
#
# 时序要点（实测）：
#   · 容器 init 起来后 kwin 连上 /run/display.sock，但拿不到 surface fds，会一直等；
#   · 必须由 com.anland.consumer 连上同一 socket 并把 5 个 fd 交给 producer，kwin 才继续，
#     plasmashell 才会被拉起 —— 所以 consumer 要在 start 后立刻连，不能等 20 s；
#   · socket 名每次 start 都变，且 App 已在运行时会忽略新的 intent extra，
#     必须先 am force-stop 再 am start，否则 consumer 会连到上一轮的旧 socket（桌面不出来）。
#
# 用法：sh ds_start.sh [容器名]

NAME=${1:-UBUNTU26}
DS=/data/local/Droidspaces/bin/droidspaces
CG=/sys/fs/cgroup/droidspaces/$NAME
LA=/data/local/Droidspaces/Logs/$NAME/anland
now() { cut -d' ' -f1 /proc/uptime; }
T0=$(now)
el() { awk -v a=$T0 -v b=$(now) 'BEGIN{printf "%.2f", b-a}'; }
mark() { echo "  [T$1 +$(el)s] $2"; }

# 守卫：必须 root + ksu/su 域（SELinux 落在 shell 域时 droidspaces 会被拒）
DOM=$(cat /proc/self/attr/current 2>/dev/null | tr -d '\000')
echo "DOM=$DOM uid=$(id -u)"
if [ "$(id -u)" != "0" ]; then echo "ERROR: 需要 root"; exit 2; fi
case "$DOM" in
	u:r:ksu:s0*|u:r:su:s0*) ;;
	*) echo "ERROR: SELinux 域=$DOM，不是 ksu/su —— 请重开 root 会话再试"; exit 3;;
esac

echo "===== START $NAME $(date '+%F %T') ====="

# 1) 预清理残留 cgroup（消 [CGROUP] left over）
if [ -d "$CG" ]; then
	for pass in 1 2 3 4 5; do
		for f in $(find "$CG" -name cgroup.procs 2>/dev/null); do
			for p in $(cat "$f" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
		done
		sleep 0.5
		for d in $(find "$CG" -depth -type d 2>/dev/null); do rmdir "$d" 2>/dev/null; done
		[ ! -d "$CG" ] && break
	done
	echo "  预清理: $([ -d "$CG" ] && echo 'cgroup 仍在' || echo 'cgroup 已清') [+$(el)s]"
fi

# 记录日志基线：只看本次新增行（日志是累积的）
LINES=$(wc -l < "$LA" 2>/dev/null || echo 0)
newlog() { tail -n +$((LINES + 1)) "$LA" 2>/dev/null; }

# 2) start
$DS -n "$NAME" start --init=/sbin/init 2>&1 | sed 's/^/  | /'
mark 1 "start 命令返回"

# 3) 等新的 anland socket，再 force-stop + 拉起 consumer
i=0
SOCK=""
while [ $i -lt 60 ]; do
	SOCK=$(newlog | grep -a 'listening on' | tail -1 | sed 's/.*listening on //')
	if [ -n "$SOCK" ] && [ -S "$SOCK" ]; then break; fi
	sleep 0.25; i=$((i+1))
done
mark 2 "anland socket 就绪: $SOCK"

am force-stop com.anland.consumer >/dev/null 2>&1
am start -n com.anland.consumer/.MainActivity --es socket_path "$SOCK" >/dev/null 2>&1
mark 3 "已（重）拉起 Anland consumer"

# 4) 等本次的 consumer 连上并把 fd 交付给 producer
j=0
while [ $j -lt 160 ]; do
	newlog | grep -aq 'fds delivered to producer' && break
	sleep 0.25; j=$((j+1))
done
mark 4 "fds delivered to producer"

# 5) 等 plasmashell（桌面真正开始画）
k=0
while [ $k -lt 240 ]; do
	ps -A -o comm 2>/dev/null | grep -q '^plasmashell$' && break
	sleep 0.25; k=$((k+1))
done
mark 5 "plasmashell 起来（桌面可用）"

echo "== 本次 start 的告警/关键行 =="
tail -n 80 /data/local/Droidspaces/Logs/$NAME/log | tr -d '\000' | grep -E '\[!\]|VirGL|CGROUP|left over|Booting|DHCP|Anland' | sed 's/^/  | /'
echo "== anland（本次新增） =="
newlog | tail -n 8 | sed 's/^/  | /'
echo "== 总耗时 $(el)s =="
