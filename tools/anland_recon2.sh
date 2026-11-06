#!/system/bin/sh
# anland_recon2.sh —— 只读取证第二层：真实 rootfs、systemd 单元、容器进程、socket（不改状态）
R=/data/local/Droidspaces/rootfs/UBUNTU26
OUT=/data/local/tmp/anland_recon2.txt
{
echo "== date =="; date
echo "== show =="
/data/local/Droidspaces/bin/droidspaces show 2>&1 | head -20
echo "== pid =="
/data/local/Droidspaces/bin/droidspaces -n UBUNTU26 pid 2>&1
echo "== rootfs top =="
ls -la $R 2>/dev/null | head -20
echo "== /etc/environment =="
cat $R/etc/environment 2>/dev/null
echo "== wayland sessions =="
ls -la $R/usr/share/wayland-sessions/ 2>/dev/null
echo "== systemd units anland/kwin/plasma/display =="
ls -la $R/etc/systemd/system/ 2>/dev/null | grep -iE 'kwin|plasma|anland|wayland|display|sddm'
ls -la $R/etc/systemd/system/multi-user.target.wants/ 2>/dev/null | grep -iE 'kwin|plasma|anland|wayland|display'
echo "== kwin/plasma binaries =="
ls -la $R/usr/bin/plasma* $R/usr/bin/kwin* $R/usr/bin/anland* 2>/dev/null
echo "== anland files in rootfs =="
find $R/usr $R/opt $R/etc -maxdepth 3 -iname '*anland*' 2>/dev/null | head -20
echo "== display.sock on host =="
ls -la /run/display.sock 2>/dev/null
echo "== /run dir root =="
ls -la /run 2>/dev/null | head -20
echo "== container processes =="
ps -A -o PID,PPID,RSS,NAME 2>/dev/null | grep -iE 'anland|kwin|plasma|wayland|Xwayland|systemd' | head -30
echo "== anland app process =="
ps -A -o PID,PPID,NAME 2>/dev/null | grep -i anland
echo "== dmesg tail (selinux/dri) =="
dmesg 2>/dev/null | tail -30
} > $OUT 2>&1
cat $OUT
