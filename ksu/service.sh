#!/system/bin/sh
# droidspaces_shim / service.sh  （late_start 阶段执行，纯 sh / busybox ash 语法）
# 语义：有模块 = 开机自动 insmod；删模块目录 + 重启 = 关闭。
# 任何一条前置检查不过 -> 静默跳过（日志里留一条 skip 原因），绝不注错版本的内核模块。

MODDIR=${0%/*}
LOG=/data/adb/droidspaces_shim.log
KO=$MODDIR/droid_lkm.ko
KVER="5.10.236-android12-9-00003-gfb24cf99ad97-ab14313284"
SHA="b710cca34249c6cf8b215b61c29ca9aa2e3be6919c9aac3123c1dabecc1603a5"

log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] [service] $*" >> "$LOG"
}

log "service.sh started (ko=$KO)"

# 1) 等 /proc/modules 可读（late_start 可能与之竞争）
i=0
while [ ! -r /proc/modules ] && [ $i -lt 30 ]; do
	sleep 1
	i=$((i + 1))
done
if [ ! -r /proc/modules ]; then
	log "skip: /proc/modules still unreadable after 30s"
	exit 0
fi

# 2) 已加载则跳过
if grep -q droid_lkm /proc/modules 2>/dev/null; then
	log "skip: droid_lkm already loaded"
	exit 0
fi

# 3) 内核版本必须与编译时对齐的串逐字节一致，否则说明系统更新过
now=$(uname -r)
if [ "$now" != "$KVER" ]; then
	log "skip: kernel mismatch (have '$now', built for '$KVER')"
	exit 0
fi

# 4) ko 存在 + sha256 校验
if [ ! -f "$KO" ]; then
	log "skip: module file missing ($KO)"
	exit 0
fi
chmod 644 "$KO" 2>/dev/null

got=$(sha256sum "$KO" 2>/dev/null | awk '{print $1}')
if [ -z "$got" ]; then
	got=$(busybox sha256sum "$KO" 2>/dev/null | awk '{print $1}')
fi
if [ -z "$got" ]; then
	log "skip: no sha256sum available"
	exit 0
fi
if [ "$got" != "$SHA" ]; then
	log "skip: sha256 mismatch (have $got)"
	exit 0
fi
log "checks passed (kernel=$now, sha256=$got)"

# 5) insmod
#   route=2            全 kprobe 路由
#   skip_sysvipc=0     SysV IPC 端口开
#   gate=1             只服务 droidspaces 世界
#   degrade=1          允许降级
#   zap_guard=1        拆除路径护栏
#   reaper_fix=1       容器 PID1 退出时替换 child_reaper（必需，否则内核 find_child_reaper 走 BUG）
#   tick_ms=0          关心跳（调试时可 100）
#   no_teardown=1      不做 queue_zap（CONFIG_PID_NS=n 下内核无 zap 实体）
#   disable_alloc_mode=1  BTF 真实偏移直写 pid_allocated（B18 起默认）
out=$(insmod "$KO" route=2 skip_sysvipc=0 gate=1 degrade=1 verbose=1 zap_guard=1 reaper_fix=1 tick_ms=0 no_teardown=1 skip_disable_alloc=0 disable_alloc_mode=1 2>&1)
rc=$?
if [ $rc -ne 0 ]; then
	log "insmod FAILED rc=$rc: $out"
	exit 0
fi
log "insmod rc=0 ${out}"

# 6) 结果自检
if [ -d /proc/droid_lkm ]; then
	log "loaded: $(grep droid_lkm /proc/modules 2>/dev/null)"
	log "features: $(head -6 /proc/droid_lkm/features 2>/dev/null | tr '\n' '|')"
else
	log "WARN: insmod rc=0 but /proc/droid_lkm did not appear"
fi

# 7) 树外 KO（macvlan / ip6table_nat / devtmpfs）已实测不可加载（GKI 未导出所需符号，
#    insmod 返回 ENOENT），因此不再随包分发、也不在本脚本里尝试加载。
#    证据与判定见 README 第 15 节；要补绿这 6 项只能刷带对应 CONFIG 的内核。

# 8) 启动孤儿看门狗：容器 stop 后（无论 CLI 还是 App 触发）把残留进程清干净。
#    这是 no_teardown=1 的必然副产物 —— 内核不会回收 pidns 成员。
#    用 supervisor 循环托管：看门狗进程被意外杀掉也会在 2 s 内自动重启。
#    注意：supervisor 的 cmdline 里刻意不出现脚本文件名（用 env WD 传参），
#    否则 pkill -f orphan_watch.sh 会把 supervisor 一起杀掉，自恢复就失效了。
WD=$MODDIR/orphan_watch.sh
if [ -f "$WD" ]; then
	if ps -A -o args 2>/dev/null | grep -q 'while :; do sh'; then
		log "watchdog supervisor already running"
	else
		nohup env WD="$WD" sh -c 'while :; do sh "$WD"; sleep 2; done' >/dev/null 2>&1 &
		log "orphan_watch supervisor started pid=$!"
	fi
else
	log "skip watchdog: $WD missing"
fi
exit 0
