#!/system/bin/sh
# 容器内真实使用：tree 执行、ipcs、unshare；并记录宿主 uptime
DS=/data/local/Droidspaces/bin/droidspaces
N=UBUNTU26

echo "== uptime before =="
cat /proc/uptime
echo "== tree --version =="
$DS -n $N run -- tree --version
echo "== tree -L 1 /etc (head) =="
$DS -n $N run -- sh -c 'tree -L 1 /etc | head -12'
echo "== ipcs -m =="
$DS -n $N run -- ipcs -m
echo "== unshare --pid (expected EINVAL) =="
$DS -n $N run -- unshare --pid --fork true; echo "rc=$?"
echo "== unshare --ipc =="
$DS -n $N run -- unshare --ipc true; echo "rc=$?"
echo "== uptime after =="
cat /proc/uptime
