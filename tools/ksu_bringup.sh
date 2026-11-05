#!/system/bin/sh
# ksu_bringup.sh —— 让 KernelSU（LKM 模式）在“已提权但未加载”状态下就绪
#   1) 已就绪（ksud module list rc=0）直接返回
#   2) 否则用 APK 自带的 libksud.so 做 late-load（其中内嵌 android12-5.10_kernelsu.ko）
#   3) 就绪后触发一次 service 阶段，让 /data/adb/modules/*/service.sh 跑起来
#      （本机是“先有 root 再 late-load”，开机阶段的 post-fs-data 已过，必须手动补触发）
export PATH=/system/bin:/system/xbin:/vendor/bin:/sbin
K=/data/adb/ksu/bin/ksud
LIB=/data/local/tmp/libksud.so
OUT=/data/local/tmp/ksu_bringup.log

log() { echo "[$(date '+%H:%M:%S')] $*" >> $OUT; }
: > $OUT

# 1) 已就绪？
if $K module list >/dev/null 2>&1; then
	log "ALREADY_UP"
	UP=1
else
	UP=0
fi

if [ "$UP" = "0" ]; then
	# 2) 找 libksud.so
	if [ ! -s "$LIB" ]; then
		src=$(ls /data/app/*/me.weishu.kernelsu*/lib/arm64/libksud.so 2>/dev/null | head -1)
		[ -n "$src" ] && cp "$src" "$LIB" && chmod 755 "$LIB"
	fi
	if [ ! -s "$LIB" ]; then
		log "NO_LIBKSUD"
		echo KSU_NO_LIBKSUD
		exit 1
	fi

	log "LATE_LOAD_BEGIN"
	$LIB late-load --allow-shell --package-name me.weishu.kernelsu >> $OUT 2>&1
	log "LATE_LOAD_RC=$?"

	# 3) 等就绪（最多 20 s）
	i=0
	while [ $i -lt 20 ]; do
		if $K module list >/dev/null 2>&1; then
			log "UP_AFTER=${i}s"
			break
		fi
		sleep 1
		i=$((i + 1))
	done
	if ! $K module list >/dev/null 2>&1; then
		log "NOT_UP_AFTER_20s"
		echo KSU_LATE_LOAD_FAILED
		exit 2
	fi
fi

# 4) 补触发 service 阶段（限时 25 s，超时不影响退出码）
#    本机开机的 post-fs-data/service 阶段早于 late-load，必须补一次
log "SERVICES_BEGIN"
timeout 25 $K services >> $OUT 2>&1
log "SERVICES_RC=$?"

# 5) KSU 的 services 是“按开机阶段扫描”的，late-load 之后再触发通常不会重跑脚本
#    （实测 log 行数不变）。这里直接执行本模块的 service.sh —— 仍走 KSU 模块目录，
#    只是由本脚本代替 KSU 的 stage 触发，效果等价且不依赖开机时序。
MOD=/data/adb/modules/droidspaces_shim
if [ -x "$MOD/service.sh" ]; then
	log "MODULE_SERVICE_BEGIN"
	sh "$MOD/service.sh" >> $OUT 2>&1
	log "MODULE_SERVICE_RC=$?"
else
	log "MODULE_SERVICE_MISSING"
fi

echo KSU_UP
exit 0
