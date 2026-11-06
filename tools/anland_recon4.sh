#!/system/bin/sh
# anland_recon4.sh —— 只读：容器内 plasma-wayland 日志与当前进程（不改状态）
OUT=/data/local/tmp/anland_recon4.txt
{
echo "== date =="; date
echo "== journal plasma-wayland =="
/data/local/Droidspaces/bin/droidspaces -n UBUNTU26 run -- /bin/sh -c 'journalctl -u plasma-wayland --no-pager 2>&1 | tail -60' 2>&1 | tail -65
echo "== last logins / who launched =="
/data/local/Droidspaces/bin/droidspaces -n UBUNTU26 run -- /bin/sh -c 'ps -eo pid,ppid,user,args 2>/dev/null | grep -Ei "kwin|plasma|wayland|anland" | grep -v grep; echo ---; systemctl status plasma-wayland --no-pager 2>&1 | head -20' 2>&1 | tail -40
echo "== journal tail (all) =="
/data/local/Droidspaces/bin/droidspaces -n UBUNTU26 run -- /bin/sh -c 'journalctl --no-pager -n 40 2>&1' 2>&1 | tail -45
} > $OUT 2>&1
cat $OUT
