#!/system/bin/sh
# stop_test.sh —— 本轮改动的 start/stop 实测：check、stop 不复位、再 start、plasma 自愈
DS=/data/local/Droidspaces/bin/droidspaces
echo "== date =="; date
echo "== uptime / 模块 / check（start 状态）=="
cat /proc/uptime
grep -E '^droid_lkm |^kernelsu ' /proc/modules
$DS check 2>&1 | tail -6

echo "== stop =="
$DS -n UBUNTU26 stop 2>&1
sleep 6
echo "== stop 后 uptime / 模块 / 进程 =="
cat /proc/uptime
grep -E '^droid_lkm |^kernelsu ' /proc/modules
ps -A 2>/dev/null | grep -cE 'kwin|plasmashell'
echo "-- uptime 与 stop 前一致 = 未复位 --"

echo "== 再 start（ds_start 预清理） =="
sh /data/local/tmp/ds_start.sh UBUNTU26 2>&1 | grep -E 'Anland|CGROUP|started|Booting|GPU|HW access'
sleep 45
echo "== 本次 start 告警行 =="
tail -n 150 /data/local/Droidspaces/Logs/UBUNTU26/log | tr -d '\000' | grep -nE '\[CGROUP\]|VirGL|Hardware access'
echo "(以上若为空 = 无告警)"

echo "== 容器内 plasma =="
$DS -n UBUNTU26 run -- /bin/sh -c 'systemctl is-active plasma-wayland; ls -la /run/display.sock' 2>&1 | head -6
echo "== 重启 Anland consumer =="
sh /data/local/tmp/anland_up.sh
echo "== check =="
$DS check 2>&1 | tail -5
echo "== ds_start.log =="
tail -n 10 /data/local/tmp/ds_start.log
