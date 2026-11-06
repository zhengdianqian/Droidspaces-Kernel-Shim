#!/system/bin/sh
L=/data/local/Droidspaces/Logs/UBUNTU26/log
echo "==all warn lines (grep -a)=="
grep -anE "\[!\]|\[i\] \[CGROUP\]|VirGL|Hardwave|hardware access|GPU\]|Anland" $L | tail -80
echo "==last start block=="
ln=$(grep -an "Starting container" $L | tail -1 | cut -d: -f1)
echo "line=$ln"
if [ -n "$ln" ]; then sed -n "${ln},$((ln+80))p" $L | tr -d '\000'; fi
