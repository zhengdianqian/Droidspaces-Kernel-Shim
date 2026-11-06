#!/system/bin/sh
# anland_recon.sh —— 只读取证：Anland App / 容器配置 / wayland 依赖（不改任何状态）
OUT=/data/local/tmp/anland_recon.txt
{
echo "== date =="
date
echo "== pkgs(anland) =="
pm list packages 2>/dev/null | grep -i anland
dumpsys package com.anland.consumer 2>/dev/null | grep -E 'versionName|versionCode|userId=|codePath|firstInstallTime' | head -20
echo "== container dir =="
ls -la /data/local/Droidspaces/Containers/UBUNTU26/ 2>/dev/null
echo "== container.config =="
cat /data/local/Droidspaces/Containers/UBUNTU26/container.config 2>/dev/null
echo "== rootfs etc/environment =="
cat /data/local/Droidspaces/Containers/UBUNTU26/rootfs/etc/environment 2>/dev/null
echo "== rootfs units(kwin/plasma/anland) =="
ls -la /data/local/Droidspaces/Containers/UBUNTU26/rootfs/etc/systemd/system/ 2>/dev/null | grep -iE 'kwin|plasma|anland|wayland|display'
echo "== droidspaces anland strings =="
grep -a -o 'Anland[A-Za-z0-9 ._/:%$-]*' /data/local/Droidspaces/bin/droidspaces 2>/dev/null | sort -u | head -50
echo "== droidspaces anland-related help =="
/data/local/Droidspaces/bin/droidspaces --help 2>&1 | head -60
echo "== host sockets/dri =="
ls -la /run/display.sock 2>/dev/null
ls -la /dev/dri/ 2>/dev/null
echo "== anland data dir =="
ls -la /data/data/com.anland.consumer/ 2>/dev/null | head -20
} > $OUT 2>&1
cat $OUT
