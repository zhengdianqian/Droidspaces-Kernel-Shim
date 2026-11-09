#!/system/bin/sh
# cleanup_orphans.sh —— 清理 droidspaces 残留进程（保守匹配，绝不碰宿主进程）
# 匹配三条件之一：cgroup 含 droidspaces / ppid 是 ds-zap / exe 或 root 在容器 rootfs 下
VERBOSE=${1:-1}
log() { [ "$VERBOSE" = 1 ] && echo "$*"; }

list_targets() {
	for d in /proc/[0-9]*; do
		p=${d#/proc/}
		[ "$p" = "$$" ] && continue
		hit=0
		grep -qa droidspaces $d/cgroup 2>/dev/null && hit=1
		if [ $hit = 0 ]; then
			pp=$(awk '/^PPid:/{print $2}' $d/status 2>/dev/null)
			[ "$pp" = "$DSZAP" ] && hit=1
		fi
		if [ $hit = 0 ]; then
			r=$(readlink $d/root 2>/dev/null)
			case "$r" in /data/local/Droidspaces/rootfs/*) hit=1;; esac
			e=$(readlink $d/exe 2>/dev/null)
			case "$e" in /data/local/Droidspaces/rootfs/*) hit=1;; esac
		fi
		[ $hit = 1 ] && echo "$p"
	done
}

DSZAP=$(for d in /proc/[0-9]*; do [ "$(cat $d/comm 2>/dev/null)" = "ds-zap" ] && echo ${d#/proc/}; done | head -1)
log "ds-zap pid=$DSZAP（不杀它，只杀它收养的容器进程）"

# 1) 统计
n0=$(list_targets | wc -l)
log "清理前目标进程数=$n0"

# 2) TERM 一轮
for p in $(list_targets); do kill -TERM $p 2>/dev/null; done
sleep 2
n1=$(list_targets | wc -l)
log "TERM 后剩余=$n1"

# 3) KILL，最多 6 轮
round=0
while [ $round -lt 6 ]; do
	cur=$(list_targets)
	[ -z "$cur" ] && break
	for p in $cur; do kill -9 $p 2>/dev/null; done
	sleep 1
	round=$((round+1))
	log "KILL 第 $round 轮：本轮杀 $(echo "$cur" | wc -l)，剩余 $(list_targets | wc -l)"
done

# 4) 递归 rmdir cgroup
for name in $(ls /sys/fs/cgroup/droidspaces/ 2>/dev/null); do
	CG=/sys/fs/cgroup/droidspaces/$name
	for pass in 1 2 3; do
		for d in $(find $CG -depth -type d 2>/dev/null); do
			for p in $(cat $d/cgroup.procs 2>/dev/null); do kill -9 $p 2>/dev/null; done
			rmdir "$d" 2>/dev/null
		done
		[ ! -d "$CG" ] && break
	done
	log "cgroup $name -> $([ -d $CG ] && echo 仍存在 || echo 已删除)"
done

# 5) 零残留校验
n2=$(list_targets | wc -l)
log "清理后目标进程数=$n2"
log "== 校验 =="
ps -A -o pid,ppid,stat,pcpu,comm 2>/dev/null | grep -iE 'kwin|plasma|konsole|Xwayland' | grep -v grep || echo "无 kwin/plasma/konsole 进程"
echo "cgroup 残留: $(ls /sys/fs/cgroup/droidspaces/ 2>/dev/null | tr '\n' ' ')"
echo "containers: $(/data/local/Droidspaces/bin/droidspaces show 2>&1 | tail -2)"
[ "$n2" = "0" ] && echo "RESULT=ZERO_LEAK" || echo "RESULT=LEAK_LEFT n=$n2"
