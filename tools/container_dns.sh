#!/system/bin/sh
# 容器内 DNS 改为国内可达的阿里 DNS，并验证域名解析/联网
DS=/data/local/Droidspaces/bin/droidspaces
N=UBUNTU26

$DS -n $N run -- sh -c 'printf "nameserver 223.5.5.5\nnameserver 114.114.114.114\n" > /etc/resolv.conf; cat /etc/resolv.conf'
echo "--- resolve test ---"
$DS -n $N run -- getent hosts mirrors.tuna.tsinghua.edu.cn
echo "--- ping test ---"
$DS -n $N run -- ping -c 2 -W 3 223.5.5.5
