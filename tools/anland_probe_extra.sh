#!/system/bin/sh
# anland_probe_extra.sh —— 试探 Anland App 的 intent extra key（只起 App，不动容器）
SOCK=$(ls /data/local/Droidspaces/Net/anland-*.sock 2>/dev/null | head -1)
LOG=/data/local/Droidspaces/Logs/UBUNTU26/anland
echo "SOCK=$SOCK"
for k in socket_path extra_socket_path anland_socket_path path sock display_socket socketPath; do
	before=$(wc -l < $LOG 2>/dev/null)
	am force-stop com.anland.consumer >/dev/null 2>&1
	am start -n com.anland.consumer/.MainActivity --es $k "$SOCK" >/dev/null 2>&1
	sleep 3
	after=$(wc -l < $LOG 2>/dev/null)
	hit=$(tail -n $((after-before+1)) $LOG 2>/dev/null | grep -c 'consumer connected')
	echo "KEY=$k lines_added=$((after-before)) consumer_connected=$hit"
done
echo "== tail =="
tail -n 6 $LOG
