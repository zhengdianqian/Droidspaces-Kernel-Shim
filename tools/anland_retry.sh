#!/system/bin/sh
LA=/data/local/Droidspaces/Logs/UBUNTU26/anland
SOCK=$(grep -a "listening on" $LA | tail -1 | sed 's/.*listening on //')
echo "SOCK=$SOCK"
am start -n com.anland.consumer/.MainActivity --es socket_path "$SOCK"
sleep 15
echo "== log tail =="
tail -n 6 $LA
echo "== top activity =="
dumpsys activity activities 2>/dev/null | grep -E 'mResumedActivity|topResumedActivity' | head -3
