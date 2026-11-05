#!/system/bin/sh
# /data/adb/service.d/droidspaces_shim.sh
# 兜底：某些 KSU/Magisk 变体只执行 service.d，不执行 modules/<id>/service.sh。
# 逻辑与 modules/droidspaces_shim/service.sh 完全一致，只是 MODDIR 固定。
# 任何一个前置检查不过 -> 静默跳过并记录原因，绝不 insmod 错版本模块。

KO=/data/adb/modules/droidspaces_shim/droid_lkm.ko
LOG=/data/adb/droidspaces_shim.log
KVER="5.10.236-android12-9-00003-gfb24cf99ad97-ab14313284"
SHA="b710cca34249c6cf8b215b61c29ca9aa2e3be6919c9aac3123c1dabecc1603a5"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [service.d] $*" >> "$LOG"; }

log "service.d script started (ko=$KO)"

i=0
while [ ! -r /proc/modules ] && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
[ -r /proc/modules ] || { log "skip: /proc/modules unreadable"; exit 0; }

grep -q droid_lkm /proc/modules 2>/dev/null && { log "skip: already loaded"; exit 0; }

now=$(uname -r)
[ "$now" = "$KVER" ] || { log "skip: kernel mismatch ('$now' != '$KVER')"; exit 0; }
[ -f "$KO" ] || { log "skip: module file missing"; exit 0; }

got=$(sha256sum "$KO" 2>/dev/null | awk '{print $1}')
[ -n "$got" ] || got=$(busybox sha256sum "$KO" 2>/dev/null | awk '{print $1}')
[ "$got" = "$SHA" ] || { log "skip: sha256 mismatch (have ${got:-none})"; exit 0; }

out=$(insmod "$KO" route=2 skip_sysvipc=0 gate=1 degrade=1 verbose=1 zap_guard=1 reaper_fix=1 tick_ms=0 no_teardown=1 skip_disable_alloc=0 disable_alloc_mode=1 2>&1)
rc=$?
if [ $rc -ne 0 ]; then
	log "insmod FAILED rc=$rc: $out"
	exit 0
fi
log "insmod rc=0 ${out}"
log "loaded: $(grep droid_lkm /proc/modules 2>/dev/null)"
exit 0
