#!/system/bin/sh
# anland_recon3.sh —— 只读：App 日志、当前 Activity、容器内 Anland 状态
OUT=/data/local/tmp/anland_recon3.txt
{
echo "== date =="; date
echo "== app files =="
ls -la /data/data/com.droidspaces.app/ 2>/dev/null | head -20
echo "== app logs =="
find /data/data/com.droidspaces.app /data/local/Droidspaces -maxdepth 3 -type f \( -name '*.log' -o -name '*log*' \) 2>/dev/null | head -20
echo "== top activity =="
dumpsys activity activities 2>/dev/null | grep -E 'mResumedActivity|topResumedActivity' | head -5
echo "== logcat droidspaces(200) =="
logcat -d -t 200 2>/dev/null | grep -iE 'droidspaces|anland|virgl|droid_lkm' | tail -40
echo "== inside container: display.sock / anland / kwin =="
/data/local/Droidspaces/bin/droidspaces -n UBUNTU26 run -- /bin/sh -c 'ls -la /run/ 2>/dev/null | head -20; echo ---; ls -la /run/display.sock 2>/dev/null; echo ---; ps -ef 2>/dev/null | grep -Ei "anland|kwin|plasma|wayland" | grep -v grep; echo ---; systemctl is-active plasma-wayland 2>/dev/null; echo ---; cat /etc/environment 2>/dev/null | head' 2>&1 | head -60
echo "== ds_init.log =="
cat /data/local/Droidspaces/rootfs/UBUNTU26/ds_init.log 2>/dev/null
} > $OUT 2>&1
cat $OUT
