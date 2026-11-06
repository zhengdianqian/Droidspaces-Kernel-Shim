#!/system/bin/sh
L=/data/local/Droidspaces/Logs/UBUNTU26/log
echo "==log warn lines=="
grep -nE "\[!\]|\[i\] \[CGROUP\]|VirGL|Hardwave|hardware|GPU\]|Anland" $L | tail -60
echo "==log head 15=="
head -15 $L
echo "==log size/lines=="
wc -l $L
