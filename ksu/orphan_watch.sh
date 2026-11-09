#!/system/bin/sh
# orphan_watch.sh —— droidspaces 残留进程看门狗（容器已停但进程还在 -> 清空其 cgroup）
#
# 背景：内核 5.10 且 droid_lkm 以 no_teardown=1 运行 —— 容器 PID1 退出时内核不会回收
# 该 pid 命名空间的其它进程；droidspaces 自己的 stop 只杀 init，然后干等约 30 s 超时。
# 结果就是 kwin_wayland 被 ds-zap 收养后继续跑，还挂在 Anland socket 上空转 ~100% CPU。
#
# 判定：某 cgroup 里还有进程，但没有任何进程是某个 pidns 的 PID 1（NSpid 末位=1），
#      并且本看门狗此前见过它的 init（marker），才动手 —— 避免与刚创建的 cgroup 抢时序。
#
# 用法：nohup sh orphan_watch.sh &

DSROOT=/sys/fs/cgroup/droidspaces
LOG=/data/adb/droidspaces_watchdog.log
MARK=/data/local/tmp/.wd
INTERVAL=${INTERVAL:-3}
mkdir -p "$MARK" 2>/dev/null

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }
trim() { [ -f "$LOG" ] && tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"; }

log "watchdog started (interval=${INTERVAL}s pid=$$)"
trim

while true; do
	for cg in $DSROOT/*/; do
		[ -d "$cg" ] || continue
		name=$(basename "$cg")
		procs=$(find "$cg" -name cgroup.procs -exec cat {} \; 2>/dev/null | sort -u | tr '\n' ' ')

		if [ -z "$procs" ]; then
			# 空 cgroup：确认不是刚创建（>5 s）再删，免得和 start 抢
			mt=$(stat -c %Y "$cg" 2>/dev/null || echo 0)
			nt=$(date +%s)
			if [ $((nt - mt)) -gt 5 ]; then
				for d in $(find "$cg" -depth -type d 2>/dev/null); do rmdir "$d" 2>/dev/null; done
			fi
			continue
		fi

		has_init=0
		for p in $procs; do
			n=$(awk '/^NSpid:/{print $NF}' /proc/$p/status 2>/dev/null)
			[ "$n" = "1" ] && { has_init=1; break; }
		done

		if [ "$has_init" = "1" ]; then
			: > "$MARK/$name"      # 记住这个 cgroup 曾经真的跑起来过
			continue
		fi

		# 没有 init 了：只有确认过“曾经有 init”才当孤儿处理
		if [ ! -f "$MARK/$name" ]; then
			continue
		fi

		n=$(echo $procs | wc -w)
		log "LEAK cgroup=$name procs=$n -> kill+rmdir"
		for p in $procs; do kill -9 "$p" 2>/dev/null; done
		sleep 0.3
		for d in $(find "$cg" -depth -type d 2>/dev/null); do
			for p in $(cat "$d/cgroup.procs" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
			rmdir "$d" 2>/dev/null
		done
		left=$([ -d "$cg" ] && find "$cg" -name cgroup.procs -exec cat {} \; 2>/dev/null | wc -l || echo 0)
		log "  after: cgroup_exists=$([ -d "$cg" ] && echo 1 || echo 0) procs=$left"
		[ "$left" = "0" ] && rm -f "$MARK/$name"
		trim
	done
	sleep "$INTERVAL"
done
