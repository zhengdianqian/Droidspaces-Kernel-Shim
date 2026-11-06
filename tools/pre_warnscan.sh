#!/system/bin/sh
C=/data/local/Droidspaces/Containers/UBUNTU26
echo "==preAnland.bak=="
cat $C/container.config.preAnland.bak
echo "==console warn lines (whole file)=="
grep -nE "\[!\]|\[i\] \[CGROUP\]|VirGL|Hardwave|hardware|GPU\]|Anland" /data/local/Droidspaces/Logs/UBUNTU26/console
echo "==anland log tail 40=="
tail -n 40 /data/local/Droidspaces/Logs/UBUNTU26/anland
