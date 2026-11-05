#!/system/bin/sh
# 以应用 uid(10123) 身份调用 su，看是否被拒；用于定位 App 拿不到 root 的原因
BB=/data/adb/ksu/bin/busybox
echo "== as app uid 10123 =="
$BB setuidgid 10123 sh -c '/system/xbin/su -c id 2>&1; echo RC=$?'
echo "== as shell uid 2000 =="
$BB setuidgid 2000 sh -c '/system/xbin/su -c id 2>&1; echo RC=$?'
