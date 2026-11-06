#!/system/bin/sh
DS=/data/local/Droidspaces/bin/droidspaces
$DS -n UBUNTU26 run -- /bin/sh -c 'echo "--users--"; loginctl list-sessions 2>&1; echo "--ps--"; ps -eo pid,args | grep -E "kwin|plasmashell|plasma|Xwayland" | grep -v grep; echo "--journal plasma--"; journalctl -u plasma-wayland -n 40 --no-pager 2>&1; echo "--kwin log--"; ls -la /home/*/.local/share/sddm 2>/dev/null; tail -n 30 /home/*/.local/state/*.log 2>/dev/null' 2>&1 | head -80
