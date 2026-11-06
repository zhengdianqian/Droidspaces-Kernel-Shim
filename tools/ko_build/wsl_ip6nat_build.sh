#!/bin/bash
# wsl_ip6nat_build.sh —— 树外编译 ip6table_nat.ko（仅此一个对象；masquerade ipv6 在本内核为内建）
set -o pipefail
export PATH=/opt/ddk/clang/clang-r416183b/bin:$PATH
M=$HOME/ip6nat_mod
mkdir -p "$M"
cp -f /opt/ddk/src/android12-5.10/net/ipv6/netfilter/ip6table_nat.c "$M/"
printf 'obj-m := ip6table_nat.o\n' > "$M/Makefile"
cd "$M" || exit 1
LOG=/tmp/build_ip6nat.log
make -C /opt/ddk/kdir/android12-5.10 M="$M" ARCH=arm64 CC=clang \
     READELF=readelf AS=clang LD=ld.lld AR=llvm-ar NM=llvm-nm STRIP=llvm-strip \
     OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- \
     modules > "$LOG" 2>&1
rc=$?
tail -35 "$LOG"
echo "RC=$rc"
ls -l "$M/ip6table_nat.ko" 2>/dev/null
[ -f "$M/ip6table_nat.ko" ] && { modinfo "$M/ip6table_nat.ko" | grep -E 'vermagic|depends|name'; sha256sum "$M/ip6table_nat.ko"; }
exit 0
