#!/system/bin/sh
# bringup.sh —— 重启后「一条命令」让整条链就位
#
#   late-load kernelsu.ko → 模块 service.sh（insmod droid_lkm）→ 起 orphan_watch.sh → check
#
# 用法（重点）：
#   在「非 root」的终端里执行（Termux / adb shell 都行）：
#       sh /data/local/tmp/bringup.sh
#   脚本会自己用两次 su 完成两段（late-load 会让当前 su 会话掉权，所以必须分段）。
#
#   如果当前已经是 root 会话，也可以直接跑；脚本会 late-load 后尝试用新的 su 会话继续，
#   若失败，按屏幕提示 3 秒后重跑一次即可。
#
# 分阶段手动调用（排障用）：
#       su -c 'sh /data/local/tmp/bringup.sh late'
#       su -c 'sh /data/local/tmp/bringup.sh boot'

PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:/vendor/bin:/sbin
M=/data/adb/modules/droidspaces_shim
DS=/data/local/Droidspaces/bin/droidspaces
LIB=/data/local/tmp/libksud.so
PKG=me.weishu.kernelsu
LOG=/data/local/tmp/bringup.log
SELF=/data/local/tmp/bringup.sh

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; echo "$*"; }
kup() { grep -q '^kernelsu ' /proc/modules 2>/dev/null; }
dup() { grep -q '^droid_lkm ' /proc/modules 2>/dev/null; }
wd()  { ps -A -o args 2>/dev/null | grep -q '[o]rphan_watch.sh'; }

phase_late() {
	if kup; then log "SKIP late-load：kernelsu 已在 /proc/modules"; return 0; fi
	if [ ! -s "$LIB" ]; then
		src=$(ls /data/app/*/"$PKG"*/lib/arm64/libksud.so 2>/dev/null | head -1)
		[ -n "$src" ] && cp "$src" "$LIB" && chmod 755 "$LIB"
	fi
	if [ ! -s "$LIB" ]; then log "FAIL：找不到 libksud.so（$LIB）"; return 3; fi
	log "late-load 开始..."
	"$LIB" late-load --allow-shell --package-name "$PKG" >> "$LOG" 2>&1
	log "late-load 返回 rc=$?"
	return 0
}

phase_boot() {
	if ! kup; then log "FAIL：kernelsu 未加载，先做 late-load"; return 4; fi

	# su_compat=0 会让 /system/bin/su 整体消失，这里补回
	if [ -x /data/adb/ksu/bin/ksud ]; then
		v=$(/data/adb/ksu/bin/ksud feature get su_compat 2>/dev/null | grep '^Value:' | awk '{print $2}')
		if [ "$v" = "0" ]; then
			/data/adb/ksu/bin/ksud feature set su_compat 1 >> "$LOG" 2>&1
			log "su_compat: 0 -> 1"
		else
			log "su_compat=${v:-unknown}"
		fi
	fi

	# 模块 service.sh：内含内核/ko sha 校验 + insmod（已加载会 skip）+ 起看门狗
	if [ ! -x "$M/service.sh" ]; then log "FAIL：缺 $M/service.sh"; return 5; fi
	sh "$M/service.sh" >> "$LOG" 2>&1
	log "module service.sh rc=$?"

	if ! dup; then log "FAIL：droid_lkm 未加载，见 $LOG"; return 6; fi
	log "droid_lkm: $(grep '^droid_lkm ' /proc/modules)"

	# service.sh 里已尝试起看门狗，这里再兜一次
	if ! wd; then nohup sh "$M/orphan_watch.sh" >/dev/null 2>&1 & sleep 1; fi
	if wd; then
		log "看门狗: $(ps -A -o pid,args 2>/dev/null | grep '[o]rphan_watch.sh' | head -1)"
	else
		log "WARN：看门狗没起来（$M/orphan_watch.sh）"
	fi

	if [ -x "$DS" ]; then
		if "$DS" check 2>&1 | grep -q 'All required features found'; then
			log "check: All required features found（6 项 ✗ 为内核编译期硬限制，见 README §15）"
		else
			log "check: 有必需项未通过，请执行 droidspaces check 查看"
		fi
	fi
	log "READY"
	return 0
}

case "$1" in
late) phase_late; exit $? ;;
boot) phase_boot; exit $? ;;
esac

if kup; then
	echo "== kernelsu 已加载，直接进入 boot 阶段 =="
	if [ "$(id -u)" = "0" ]; then
		phase_boot
	else
		su -c "sh $SELF boot"
	fi
	exit $?
fi

if [ "$(id -u)" = "0" ]; then
	echo "== 当前是 root 会话：先 late-load（本会话可能掉权），随后尝试新会话继续 =="
	phase_late
	sleep 2
	if command -v su >/dev/null 2>&1; then
		su -c "sh $SELF boot"
	else
		echo "!! late-load 后本会话的 su 不可用，请重新打开终端再执行一次："
		echo "   sh $SELF"
	fi
	exit 0
fi

echo "== 非 root 会话：分两段用 su 完成 =="
if ! command -v su >/dev/null 2>&1; then
	echo "!! 没有 su 可用。请先在提权 App 里完成一次授权（拿到临时 root），再重跑："
	echo "   sh $SELF"
	exit 7
fi
su -c "sh $SELF late"
sleep 3
su -c "sh $SELF boot"
