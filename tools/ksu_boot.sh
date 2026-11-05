#!/system/bin/sh
# ksu_boot.sh —— KSU 内核已加载后的第二阶段（必须由**新的** su 会话执行）
# 目的：跑 /data/adb/modules/droidspaces_shim/service.sh，让模块自己 insmod。
# 为什么和 late-load 拆开：late-load 会把当时那个 su 会话掉进 shell 域，
# 同会话里再跑脚本会 PATH/权限全丢（实测），且会让下一次 su 阻塞上百秒。
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:/vendor/bin:/sbin
OUT=/data/local/tmp/ksu_bringup.log
log() { echo "[$(date '+%H:%M:%S')] $*" >> $OUT 2>/dev/null; }

if ! grep -q '^kernelsu ' /proc/modules 2>/dev/null; then
	echo KSU_KERNEL_MISSING
	exit 3
fi

MOD=/data/adb/modules/droidspaces_shim
if [ -x "$MOD/service.sh" ]; then
	log "MODULE_SERVICE_BEGIN"
	sh "$MOD/service.sh" >> $OUT 2>&1
	log "MODULE_SERVICE_RC=$?"
else
	log "MODULE_SERVICE_MISSING"
fi

echo KSU_UP
