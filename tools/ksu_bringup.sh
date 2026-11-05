#!/system/bin/sh
# ksu_bringup.sh —— 让 KernelSU（LKM 模式）在“已提权但未加载”状态下就绪
#
# 用法：
#   sh ksu_bringup.sh late   # 只做 late-load（可能丢失当前 shell 的 root/环境，故单独一次调用）
#   sh ksu_bringup.sh boot   # 加载 KSU 模块的 service.sh（insmod），并回报 KSU_UP
#   sh ksu_bringup.sh        # 兼容旧用法：late + boot 一次做完（同会话可能失效，慎用）
#
# 为什么拆两段：本机实测，libksud.so late-load 执行后，**当前 su 会话**会掉回 shell 域
# （PATH 丢失、写 root 0600 文件 Permission denied），但**新的** `su -c ...` 仍正常。
# 因此 late-load 与后续操作必须分两次 `su` 调用（round.ps1 已按两段调用）。
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:/vendor/bin:/sbin
K=/data/adb/ksu/bin/ksud
LIB=/data/local/tmp/libksud.so
OUT=/data/local/tmp/ksu_bringup.log
SLEEP=/system/bin/sleep

log() { echo "[$(date '+%H:%M:%S')] $*" >> $OUT 2>/dev/null; }

kernel_up() { grep -q '^kernelsu ' /proc/modules 2>/dev/null; }

do_late() {
	if kernel_up; then
		log "ALREADY_UP"
		echo KSU_KERNEL_PRESENT
		return 0
	fi

	if [ ! -s "$LIB" ]; then
		src=$(ls /data/app/*/me.weishu.kernelsu*/lib/arm64/libksud.so 2>/dev/null | head -1)
		[ -n "$src" ] && cp "$src" "$LIB" && chmod 755 "$LIB"
	fi
	if [ ! -s "$LIB" ]; then
		log "NO_LIBKSUD"
		echo KSU_NO_LIBKSUD
		return 1
	fi

	log "LATE_LOAD_BEGIN"
	"$LIB" late-load --allow-shell --package-name me.weishu.kernelsu >> $OUT 2>&1
	log "LATE_LOAD_RC=$?"

	# 注意：late-load 之后本会话可能掉进 shell 域（连 /system/bin/sleep 都会 EACCES），
	# 所以这里不做轮询，直接检查一次；等待由调用方（round.ps1）在宿主机侧完成。
	if kernel_up; then
		log "UP_AFTER_LATE"
		echo KSU_KERNEL_UP
		return 0
	fi
	log "NOT_UP_AFTER_LATE"
	echo KSU_LATE_LOAD_FAILED
	return 2
}

do_boot() {
	if ! kernel_up; then
		echo KSU_KERNEL_MISSING
		return 3
	fi

	# KSU 自己的 services 是“按开机阶段扫描”的，late-load 后不会重跑模块脚本（实测）。
	# 直接执行本模块 service.sh：仍走 KSU 模块目录，只是由本脚本代替 stage 触发。
	MOD=/data/adb/modules/droidspaces_shim
	if [ -x "$MOD/service.sh" ]; then
		log "MODULE_SERVICE_BEGIN"
		sh "$MOD/service.sh" >> $OUT 2>&1
		log "MODULE_SERVICE_RC=$?"
	else
		log "MODULE_SERVICE_MISSING"
	fi

	echo KSU_UP
	return 0
}

case "$1" in
late)
	do_late
	exit $?
	;;
boot)
	do_boot
	exit $?
	;;
*)
	do_late || exit $?
	do_boot
	exit $?
	;;
esac
