#!/system/bin/sh
# rounds.sh —— 5 轮：start → Anland 出桌面（截图）→ stop → 0 s / 30 s 残留核查
OUT=/data/local/tmp/rounds.out
: > $OUT
DS=/data/local/Droidspaces/bin/droidspaces
CG=/sys/fs/cgroup/droidspaces/UBUNTU26
log() { echo "$*" >> $OUT; }
cgn() { [ -d "$CG" ] && find "$CG" -name cgroup.procs -exec cat {} \; 2>/dev/null | wc -l || echo 0; }
leak() {   # $1=标签
	kw=$(ps -A -o pid,pcpu,comm 2>/dev/null | awk '$3=="kwin_wayland"{printf "%s(cpu=%s%%) ",$1,$2}')
	pl=$(ps -A -o comm 2>/dev/null | grep -c '^plasmashell$')
	net=$(iptables -t nat -S 2>/dev/null | grep -c '172\.28')
	vet=$(ip -o link 2>/dev/null | grep -c 'ds-v')
	log "    [$1] kwin=[${kw:-none}] plasma=$pl cgroup_procs=$(cgn) cgdir=$([ -d "$CG" ] && echo 1 || echo 0) nat_rules=$net veth=$vet running=$($DS show 2>&1 | grep -c 'RUNNING')"
}

for r in 1 2 3 4 5; do
	log ""
	log "########## ROUND $r ##########"
	log "-- start --"
	sh /data/local/tmp/ds_start.sh UBUNTU26 2>&1 | grep -E '\[T[1-5]|总耗时|\[!\]|\[-\]|VirGL|CGROUP|left over|producer|consumer' >> $OUT
	screencap -p /data/local/tmp/round$r.png 2>/dev/null
	log "-- 运行态（桌面已出）--"
	log "    $(ps -A -o pid,pcpu,comm 2>/dev/null | grep -E 'kwin_wayland|plasmashell' | grep -v grep | tr '\n' ' ')"
	log "-- stop --"
	sh /data/local/tmp/ds_stop.sh UBUNTU26 2>&1 | grep -E '\[T|\[WD|cgroup 进程数|KILL|stop 返回|网络侧|兜底|RESULT|总耗时|cgroup procs|cgroup 目录|网络残留|显示栈' >> $OUT
	leak "stop+0s"
	sleep 30
	leak "stop+30s"
done
log ""
log "########## DONE ##########"
