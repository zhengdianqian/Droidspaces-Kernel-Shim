#!/system/bin/sh
# anland_try1.sh —— 在“已运行”的容器里启动 plasma-wayland，采集真实报错（不重启容器）
OUT=/data/local/tmp/anland_try1.txt
{
echo "== date =="; date
echo "== start plasma-wayland =="
/data/local/Droidspaces/bin/droidspaces -n UBUNTU26 run -- /bin/sh -c '
systemctl start plasma-wayland 2>&1
sleep 20
echo "--- systemctl status ---"
systemctl status plasma-wayland --no-pager 2>&1 | head -25
echo "--- procs ---"
ps -eo pid,user,args 2>/dev/null | grep -Ei "kwin|plasma|Xwayland|anland" | grep -v grep
echo "--- journal plasma-wayland ---"
journalctl -u plasma-wayland --no-pager -n 40 2>&1
echo "--- journal kwin ---"
journalctl --no-pager -n 40 2>&1 | grep -Ei "kwin|wayland|drm|egl|anland" | tail -30
echo "--- display.sock ---"
ls -la /run/display.sock 2>&1
' 2>&1
} > $OUT 2>&1
cat $OUT
