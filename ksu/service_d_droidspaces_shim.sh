#!/system/bin/sh
# /data/adb/service.d/droidspaces_shim.sh
# service.d 兜底：不在本文件里重复 insmod 逻辑，直接委托给模块自己的 service.sh
# （内核版本校验 / ko sha256 校验 / insmod 参数 / 看门狗启动 都在那里面，单一来源）。
# 触发条件：KSU 的开机脚本阶段被正常执行时。若本次开机是先 late-load 再手动跑
# /data/local/tmp/bringup.sh，则由 bringup.sh 调同一个 service.sh，行为完全一致。

M=/data/adb/modules/droidspaces_shim
LOG=/data/adb/droidspaces_shim.log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [service.d] $*" >> "$LOG"; }

log "service.d script started"
if [ ! -x "$M/service.sh" ]; then
	log "skip: $M/service.sh missing"
	exit 0
fi
sh "$M/service.sh" >> "$LOG" 2>&1
log "delegate rc=$? (see [service] lines above)"
exit 0
