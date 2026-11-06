#!/system/bin/sh
L=/data/local/Droidspaces/Logs/UBUNTU26/log
echo "==CGROUP=="
grep -an "CGROUP" $L | tail -10
echo "==ardware/suid/tmpfs=="
grep -anE "ardware|suid|isolated tmpfs|left over" $L | tail -10
echo "==last start section (from line 4040)=="
sed -n '4040,4150p' $L | tr -d '\000'
