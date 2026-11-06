#!/system/bin/sh
# final_accept.sh —— 重启后最后一轮干净验收：check 全绿 + Anland 显示 + start/stop 不复位
DS=/data/local/Droidspaces/bin/droidspaces
OUT=/data/local/tmp/final_accept.txt
{
echo "== date/uptime =="; date; cat /proc/uptime
svc power stayon true
input keyevent KEYCODE_WAKEUP
echo "== 模块 =="; grep -E '^droid_lkm |^kernelsu ' /proc/modules
echo "== KSU 模块作者 / module.prop =="
cat /data/adb/modules/droidspaces_shim/module.prop
echo "-- service.sh sha（应与仓库 ksu/service.sh 一致：75e0dd0f…）--"
sha256sum /data/adb/modules/droidspaces_shim/service.sh
echo "-- ko sha（必须 b710cca3…）--"
sha256sum /data/adb/modules/droidspaces_shim/droid_lkm.ko
echo "== ksud module list 本模块条目 =="
/data/adb/ksu/bin/ksud module list 2>&1 | tr -d '\n' | tr '}' '\n' | grep droidspaces_shim
echo "== su_compat =="
/data/adb/ksu/bin/ksud feature get su_compat 2>&1

echo "== check（完整原文） =="
$DS check 2>&1

echo "== start（ds_start.sh 预清理 + start） =="
sh /data/local/tmp/ds_start.sh UBUNTU26 2>&1 | tail -18
sleep 40
echo "== 本次 start 的告警行（空=无 [!]/[CGROUP]/VirGL/Hardware） =="
tail -n 160 /data/local/Droidspaces/Logs/UBUNTU26/log | tr -d '\000' | grep -nE '\[CGROUP\]|VirGL|Hardware access|\[!\]'
echo "== ds_start 清理记录 =="
tail -n 6 /data/local/tmp/ds_start.log
echo "== anland socket / 容器内 plasma =="
ls -la /data/local/Droidspaces/Net/ 2>&1
$DS -n UBUNTU26 run -- /bin/sh -c 'systemctl is-active plasma-wayland; ls -la /run/display.sock; ps -eo pid,args | grep -E "kwin_wayland|plasmashell" | grep -v grep | head -3' 2>&1
echo "== Anland 日志 =="
tail -n 6 /data/local/Droidspaces/Logs/UBUNTU26/anland 2>&1

echo "== stop 测试（复位与否） =="
U1=$(cut -d' ' -f1 /proc/uptime)
$DS -n UBUNTU26 stop 2>&1 | tail -5
sleep 20
U2=$(cut -d' ' -f1 /proc/uptime)
echo "uptime_before=$U1 uptime_after=$U2 delta=$((${U2%.*} - ${U1%.*}))s"
echo "-- stop 后模块 --"; grep '^droid_lkm ' /proc/modules

echo "== 再 start（留运行态给用户验收） =="
sh /data/local/tmp/ds_start.sh UBUNTU26 2>&1 | tail -8
sleep 40
echo "-- 告警行（空=无）--"
tail -n 140 /data/local/Droidspaces/Logs/UBUNTU26/log | tr -d '\000' | grep -nE '\[CGROUP\]|VirGL|Hardware access'
echo "-- plasma --"
$DS -n UBUNTU26 run -- /bin/sh -c 'systemctl is-active plasma-wayland; ls -la /run/display.sock' 2>&1
echo "== 拉起 Anland App =="
sh /data/local/tmp/anland_up.sh
echo "== 最终 check =="
$DS check 2>&1 | tail -5
} > $OUT 2>&1
cat $OUT
