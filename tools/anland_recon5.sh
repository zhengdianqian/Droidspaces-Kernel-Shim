#!/system/bin/sh
# anland_recon5.sh —— 只读：console 里的 kwin/wayland 报错、当前前台、屏幕截图
OUT=/data/local/tmp/anland_recon5.txt
{
echo "== date =="; date
echo "== console: kwin/wayland/egl/drm 报错（最近） =="
grep -a -n -iE 'kwin|wayland|startplasma|egl|drm|renderD128|kgsl|segmentation|Aborted' /data/local/Droidspaces/Logs/UBUNTU26/console 2>/dev/null | tail -40
echo "== console tail =="
tail -n 25 /data/local/Droidspaces/Logs/UBUNTU26/console 2>/dev/null
echo "== anland app process =="
ps -A -o PID,PPID,NAME,ARGS 2>/dev/null | grep -E 'com\.anland|com\.droidspaces' | head -10
echo "== current focus =="
dumpsys window 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp' | head -5
echo "== screencap =="
screencap -p /data/local/tmp/now.png 2>&1
ls -la /data/local/tmp/now.png 2>/dev/null
} > $OUT 2>&1
cat $OUT
