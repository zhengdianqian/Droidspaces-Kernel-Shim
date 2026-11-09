#!/system/bin/sh
# orphan_watch.sh v3 —— 容器残留进程看门狗（init 存活事件驱动，确定性清零）
#
# 背景（已实测）：内核 5.10 + droid_lkm no_teardown=1，容器 PID1 退出时内核不回收该
# pidns 的其它进程。droidspaces 原生 stop 只杀 init，然后一直等 pidns 排空，等不到就
# 一直挂着（实测 8.4 s），期间 kwin_wayland 被 ds-zap 收养后挂在 Anland socket 上空转
# ~100% CPU。App 点 Stop 走的就是这条原生路径，脚本包不住，所以必须有常驻看门狗。
#
# v3 相对 v2 的关键改动（v2 的检测延迟最高到 5.6 s，被老板实测为“退很久”）：
#   1) 不再每轮全树扫描：记住每个容器 cgroup 的 init PID，正常运行时每 0.3 s 只做
#      [ -d /proc/$pid ]，开销近似 0；init 一消失立刻进入排空，检测延迟 <= 0.3 s。
#   2) 排空改为“单次列进程 -> kill -9 -> 0.15 s 复验”循环（最多 20 轮），不再重复
#      find -exec 多次，实测清理时间从 3 s 降到亚秒级。
#   3) 每次排空后立刻做确定性校验：/droidspaces cgroup 下的 kwin/plasmashell/dbus 等
#      必须为 0；不达标就再杀，最多 VERIFY_MAX 轮，并把结果写日志。
#   4) 空闲每 10 s 做一次全局校验（只在没有任何容器持有 init 时执行，不会误杀运行中的
#      容器），覆盖“cgroup 目录已被 droidspaces 提前删掉、看门狗看不见”的场景。
#   5) 防止用旧的 init PID 误杀新容器：排空前先确认该 cgroup 里没有新的活 init。

DSROOT=/sys/fs/cgroup/droidspaces
DS=/data/local/Droidspaces/bin/droidspaces
LOG=/data/adb/droidspaces_watchdog.log
MARK=/data/local/tmp/.wd
INTERVAL=${INTERVAL:-0.3}
VERIFY_MAX=${VERIFY_MAX:-3}
IDLE_VERIFY=${IDLE_VERIFY:-10}
mkdir -p "$MARK" 2>/dev/null

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }
trim() { [ -f "$LOG" ] && tail -n 400 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"; }

# 枚举整棵 cgroup 树里的进程。必须用 xargs 批量 cat：容器下有 53 个 cgroup.procs，
# 逐个 -exec cat 要 1.3 s，xargs -0 cat 只要 0.08 s（实测），这是 stop 尾延迟的主要来源。
cprocs() { [ -d "$1" ] || return 0; find "$1" -name cgroup.procs -print0 2>/dev/null | xargs -0 cat 2>/dev/null | sort -u; }
is_init() {
	[ -n "$1" ] && [ -d "/proc/$1" ] || return 1
	case "$(cat "/proc/$1/comm" 2>/dev/null)" in
		init|systemd)
			[ "$(awk '/^NSpid:/{print $NF}' "/proc/$1/status" 2>/dev/null)" = "1" ] && return 0
			;;
	esac
	return 1
}
# 定位容器 PID1。注意：PID1 不在 cgroup 顶层（实测顶层是 droidspaces 的 monitor），
# 必须在整棵树里找。做法：xargs 一次枚举全树 pid（0.08 s）+ 单次 ps 取候选（0.11 s），
# 只对 comm 为 init/systemd 的少数进程读 /proc/pid/status 验 NSpid 末位=1。
find_init() {
	pids=$(cprocs "$1" | tr '\n' ' ')
	[ -z "$pids" ] && return 1
	for p in $(ps -A -o pid,comm 2>/dev/null | awk '$2=="init"||$2=="systemd"{print $1}'); do
		case " $pids " in *" $p "*) ;; *) continue ;; esac
		[ "$(awk '/^NSpid:/{print $NF}' "/proc/$p/status" 2>/dev/null)" = "1" ] && { echo "$p"; return 0; }
	done
	return 1
}
zap_pid() { ps -A -o pid,comm 2>/dev/null | awk '$2=="[ds-zap]"{print $1; exit}'; }
strays() {
	z=$(zap_pid); [ -z "$z" ] && return 0
	ps -A -o pid,ppid 2>/dev/null | awk -v z="$z" -v me="$$" 'NR>1 && $2==z && $1!=me {print $1}'
}
disp_procs() {
	ps -A -o pid,comm 2>/dev/null | awk '$2 ~ /^(kwin_wayland|kwin_wayland_wrapper|plasmashell|startplasma|startplasma-wayland|konsole|Xwayland|kded5|kactivitymanagerd|dbus-daemon|dbus-broker)$/ {print $1}'
}

# 确定性校验：/droidspaces cgroup 下的显示栈进程 + ds-zap 收养链都必须为 0
verify() {
	i=0; bad=""
	while [ $i -lt "$VERIFY_MAX" ]; do
		bad=""
		for p in $(disp_procs); do
			grep -q '/droidspaces' "/proc/$p/cgroup" 2>/dev/null && bad="$bad $p"
		done
		for p in $(strays); do bad="$bad $p"; done
		[ -z "$bad" ] && return 0
		for p in $bad; do kill -9 "$p" 2>/dev/null; done
		i=$((i + 1)); sleep 0.3
	done
	log "VERIFY FAIL 仍有残留:$(echo $bad | wc -w) 个 (retry=$i)"
	return 1
}

# 排空一个 cgroup：kill 全部进程 -> 复验 -> 自底向上删目录
drain() {
	cg=$1; name=$2
	t0=$(date +%s)
	set -- $(cprocs "$cg")
	log "DRAIN cgroup=$name procs=$#"
	round=0; tries=0; n=$#
	while [ $round -lt 3 ]; do
		while [ "$n" != "0" ] && [ $tries -lt 20 ]; do
			set -- $(cprocs "$cg"); n=$#
			[ "$n" = "0" ] && break
			for p in "$@"; do kill -9 "$p" 2>/dev/null; done
			tries=$((tries + 1)); sleep 0.1
		done
		for d in $(find "$cg" -depth -type d 2>/dev/null); do rmdir "$d" 2>/dev/null; done
		n=$(cprocs "$cg" | wc -l)
		[ "$n" = "0" ] && [ ! -d "$cg" ] && break
		round=$((round + 1)); sleep 0.2
	done
	log "  drain done: procs=$n tries=$tries round=$round elapsed=$(( $(date +%s) - t0 ))s dir=$([ -d "$cg" ] && echo 1 || echo 0)"
	rm -f "$MARK/$name.init" "$MARK/$name.seen" "$MARK/$name.empty" "$MARK/$name.orphan"
}

log "watchdog v3 started (interval=${INTERVAL}s verifymax=${VERIFY_MAX} pid=$$)"
trim

last_idle_verify=0

while true; do
	now=$(date +%s)
	any_init=0
	drained=0

	for cg in $DSROOT/*/; do
		[ -d "$cg" ] || continue
		name=$(basename "$cg")
		pf="$MARK/$name.init"
		ip=$(cat "$pf" 2>/dev/null)

		# 已知 init：热路径只做一次 /proc 存在性 + comm 校验（0.3 s 周期内近零开销）
		if [ -n "$ip" ] && is_init "$ip"; then any_init=1; continue; fi

		# 缓存缺失或已失效：先判空（xargs 0.08 s），非空再定位 init（约 0.2 s）
		set -- $(cprocs "$cg")
		if [ $# -eq 0 ]; then
			# 空 cgroup：静置 30 s 后回收目录，避免与 start 抢时序
			last=$(cat "$MARK/$name.empty" 2>/dev/null || echo 0)
			if [ "$last" = "0" ]; then
				echo "$now" > "$MARK/$name.empty"
			elif [ $((now - last)) -gt 30 ]; then
				for d in $(find "$cg" -depth -type d 2>/dev/null); do rmdir "$d" 2>/dev/null; done
				rm -f "$MARK/$name.empty" "$MARK/$name.seen" "$MARK/$name.orphan"
			fi
			continue
		fi

		p=$(find_init "$cg")
		if [ -n "$p" ]; then
			echo "$p" > "$pf"; echo "$now" > "$MARK/$name.seen"
			rm -f "$MARK/$name.empty" "$MARK/$name.orphan"
			any_init=1; continue
		fi

		# 有进程、没有 init。两条独立判据，任一成立即排空：
		#   (a) 此前确实见过 init 且已消失 ≥1 s
		#   (b) 该 cgroup 的“有进程无 init”状态持续 ≥10 s（覆盖看门狗启动晚/lost init 的场景；
		#       实测容器 init 在 start 后 0.6 s 就能识别，10 s 不会误伤正常启动）
		seen=$(cat "$MARK/$name.seen" 2>/dev/null || echo 0)
		os=$(cat "$MARK/$name.orphan" 2>/dev/null || echo 0)
		[ "$os" = "0" ] && { echo "$now" > "$MARK/$name.orphan"; os=$now; }
		if { [ "$seen" != "0" ] && [ $((now - seen)) -ge 1 ]; } || [ $((now - os)) -ge 10 ]; then
			drain "$cg" "$name"
			drained=1
		fi
	done

	# 全局校验：只在没有任何容器持有 init 时执行（排空后立即一次，空闲每 IDLE_VERIFY 秒一次）
	if [ "$any_init" = "0" ]; then
		if [ "$drained" = "1" ] || [ $((now - last_idle_verify)) -ge "$IDLE_VERIFY" ]; then
			last_idle_verify=$now
			verify && trim
		fi
	fi

	sleep "$INTERVAL"
done
