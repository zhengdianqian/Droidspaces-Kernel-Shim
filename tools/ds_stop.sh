#!/system/bin/sh
# ds_stop.sh —— droidspaces stop 的快速干净包装（问题 2 + 问题 3）
#
# 背景（实测）：
#   · droid_lkm 以 no_teardown=1 运行（内核 CONFIG_PID_NS=n），容器 PID1 退出时内核
#     不会回收该 pidns 的其余进程。droidspaces 原生 stop 只杀 init，然后干等约 30 s
#     超时；kwin_wayland / plasmashell / systemd --user 等被 ds-zap 收养后继续跑，
#     kwin_wayland 还挂在 Anland socket 上空转 ~100% CPU。
#   · 原生 stop 的主流程里有一次 ip6tables 'nat' 表操作，内核缺 CONFIG_IP6_NF_NAT，
#     get_table 失败后固定等 ~5 s。这段等待无法从脚本层消除。
#
# 快速路径（本脚本）：
#   1) 一次性 KILL cgroup 内全部进程（含 init）—— 不留给内核慢慢超时
#   2) 调一次 droidspaces stop（init 已死时会立即返回，作为幂等收尾/元数据清理）
#   3) 轮询等待网络侧真正拆完（NAT 规则 / ds-v* veth / anland daemon），最多 5 s
#   4) 按父链兜底：cgroup 外但父进程是 ds-zap 的（收养的孤儿）一并清掉
#   5) 递归 rmdir cgroup（5.10 无 cgroup.kill，只能自底向上删）
#   6) 零残留校验并输出结果
#
# 用法：sh ds_stop.sh [容器名]

NAME=${1:-UBUNTU26}
DS=/data/local/Droidspaces/bin/droidspaces
CG=/sys/fs/cgroup/droidspaces/$NAME
now() { cut -d' ' -f1 /proc/uptime; }
T0=$(now)
el() { awk -v a=$T0 -v b=$(now) 'BEGIN{printf "%.2f", b-a}'; }

# 守卫：必须 root 且在 ksu/su 域，否则 droidspaces / kill 会被 SELinux 拒，
# 脚本却会继续打印“成功”——这种静默失败最危险，直接报错退出。
DOM=$(cat /proc/self/attr/current 2>/dev/null | tr -d '\000')
echo "DOM=$DOM uid=$(id -u)"
if [ "$(id -u)" != "0" ]; then
	echo "ERROR: 需要 root（当前 uid=$(id -u)）"; exit 2
fi
case "$DOM" in
	u:r:ksu:s0*|u:r:su:s0*) ;;
	*) echo "ERROR: SELinux 域=$DOM，不是 ksu/su —— 请重开 root 会话再试"; exit 3;;
esac

# cgroup 内所有进程（find -exec cat 比逐个 cat 少起进程）
cgroup_pids() {
	[ -d "$CG" ] || return 0
	find "$CG" -name cgroup.procs -exec cat {} \; 2>/dev/null | sort -u
}

# cgroup 外、但父进程是 ds-zap 的孤儿（pidns 不回收 -> 被 kthreadd 收养链收走）
zap_pid() {
	ps -A -o pid,comm 2>/dev/null | awk '$2=="[ds-zap]"||$2=="ds-zap"{print $1; exit}'
}
stray_pids() {
	Z=$(zap_pid)
	[ -z "$Z" ] && return 0
	ps -A -o pid,ppid 2>/dev/null | awk -v z="$Z" -v me="$$" 'NR>1 && $2==z && $1!=me{print $1}'
}

# 返回 0 = 还有网络残留，返回 1 = 已拆干净
net_residue() {
	iptables -t nat -S 2>/dev/null | grep -q '172\.28' && return 0
	ip -o link 2>/dev/null | grep -q 'ds-v' && return 0
	ps -A -o comm 2>/dev/null | grep -q 'anland' && return 0
	return 1
}

echo "===== STOP $NAME $(date '+%F %T') ====="
INIT=$($DS pid "$NAME" 2>/dev/null | tr -d '[:space:]')
ALL=$(cgroup_pids)
echo "[+$(el)s] cgroup 进程数=$(echo $ALL | wc -w) init=${INIT:-无,只清残留}"

# 1) 一次性 KILL（含 init）
if [ -n "$ALL" ]; then
	for p in $ALL; do kill -9 "$p" 2>/dev/null; done
fi
echo "[+$(el)s] 已 KILL cgroup 内全部进程"

# 2) 幂等收尾（init 已死时通常立即返回 not running）
$DS -n "$NAME" stop 2>&1 | sed 's/^/    /'
echo "[+$(el)s] droidspaces stop 返回"

# 3) 等网络侧拆完（NAT / veth / anland）
i=0
while [ $i -lt 20 ]; do
	net_residue || break
	sleep 0.25; i=$((i+1))
done
echo "[+$(el)s] 网络侧: $(net_residue && echo '仍有残留' || echo '已清空')"

# 4) 父链兜底：ds-zap 收养的孤儿
S=$(stray_pids)
if [ -n "$S" ]; then
	for p in $S; do kill -9 "$p" 2>/dev/null; done
	echo "[+$(el)s] 兜底清掉 ds-zap 孤儿 $(echo $S | wc -w) 个"
else
	echo "[+$(el)s] 兜底: 无 ds-zap 孤儿"
fi

# 5) 递归 rmdir（5.10 无 cgroup.kill）
if [ -d "$CG" ]; then
	for pass in 1 2 3; do
		for d in $(find "$CG" -depth -type d 2>/dev/null); do
			for p in $(cat "$d/cgroup.procs" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
			rmdir "$d" 2>/dev/null
		done
		[ ! -d "$CG" ] && break
	done
fi

# 6) 零残留校验
LEFT=$(cgroup_pids | wc -l)
DISP=$(ps -A -o pid,pcpu,comm 2>/dev/null | grep -iE 'kwin|plasmashell|startplasma|konsole|Xwayland' | grep -v grep)
echo "== 校验 =="
echo "cgroup procs: $LEFT"
echo "cgroup 目录: $([ -d "$CG" ] && echo 仍在 || echo 已删除)"
net_residue && echo "网络残留: 有" || echo "网络残留: 无"
[ -n "$DISP" ] && { echo "!! 仍有显示栈进程:"; echo "$DISP"; } || echo "显示栈进程: 无"
echo "droidspaces show: $($DS show 2>&1 | tail -2 | tr -d '\n')"
if [ "$LEFT" = "0" ] && [ ! -d "$CG" ] && [ -z "$DISP" ]; then
	echo "RESULT=ZERO_LEAK"
else
	echo "RESULT=LEAK"
fi
echo "== 总耗时 $(el)s =="
