#!/system/bin/sh
# ds_start.sh —— 预清理上一次残留的 cgroup，再 start（消除 [CGROUP] left over 告警）
# 用法：sh ds_start.sh [容器名] [额外 start 参数...]
# 说明：droidspaces stop 只会杀容器 init/master，user session 里的 kwin/plasmashell/dbus 等
#       进程会成为孤儿并继续挂在 /sys/fs/cgroup/droidspaces/<name> 下，导致 rmdir 一直 EBUSY。
NAME=${1:-UBUNTU26}
[ $# -gt 0 ] && shift
DS=/data/local/Droidspaces/bin/droidspaces
CG=/sys/fs/cgroup/droidspaces/$NAME
LOG=/data/local/tmp/ds_start.log

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }

if [ -d "$CG" ]; then
	for pass in 1 2 3 4 5; do
		killn=0
		for f in $(find "$CG" -name cgroup.procs 2>/dev/null); do
			for p in $(cat "$f" 2>/dev/null); do
				kill -9 "$p" 2>/dev/null && killn=$((killn+1))
			done
		done
		sleep 1
		for d in $(find "$CG" -depth -type d 2>/dev/null); do
			rmdir "$d" 2>/dev/null
		done
		log "pass $pass killed=$killn exists=$([ -d "$CG" ] && echo 1 || echo 0)"
		[ ! -d "$CG" ] && break
	done
	if [ -d "$CG" ]; then
		log "WARN: cgroup still exists after cleanup: $(find "$CG" -maxdepth 2 2>/dev/null | tr '\n' ' ')"
	else
		log "cgroup leftover cleaned: $CG"
	fi
fi

exec "$DS" -n "$NAME" start --init=/sbin/init "$@"
