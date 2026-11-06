#!/system/bin/sh
# anland_up.sh —— 拉起 Anland consumer 连到当前容器 socket
# socket 名每次 start 都变；从 anland 日志最后一条 "listening on" 取当前 socket，
# 避免连到上一次留下的旧 socket（ls -t 在本机 su 域下 stat 被 SELinux 拒）。
LA=/data/local/Droidspaces/Logs/UBUNTU26/anland
SOCK=$(grep -a "listening on" $LA 2>/dev/null | tail -1 | sed 's/.*listening on //')
echo "SOCK=$SOCK"
[ -S "$SOCK" ] || echo "WARN: socket missing or not a socket"
am force-stop com.anland.consumer
am start -n com.anland.consumer/.MainActivity --es socket_path "$SOCK"
sleep 12
echo "== anland log tail =="
tail -n 8 $LA
echo "== consumer pid =="
ps -A 2>/dev/null | grep anland
