#!/bin/bash
# wsl_macvlan_build.sh —— 树外编译 macvlan.ko（不改设备，仅本地构建）
set -o pipefail
export PATH=/opt/ddk/clang/clang-r416183b/bin:$PATH
M=$HOME/macvlan_mod
mkdir -p "$M"
cp -f /opt/ddk/src/android12-5.10/drivers/net/macvlan.c "$M/macvlan.c"
cat > "$M/Makefile" <<'EOF'
obj-m := macvlan.o
EOF
cd "$M" || exit 1
LOG=/tmp/build_macvlan.log
make -C /opt/ddk/kdir/android12-5.10 M="$M" ARCH=arm64 CC=clang \
     READELF=readelf AS=clang LD=ld.lld AR=llvm-ar NM=llvm-nm STRIP=llvm-strip \
     OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- \
     modules > "$LOG" 2>&1
rc=$?
tail -30 "$LOG"
echo "RC=$rc"
ls -l "$M/macvlan.ko" 2>/dev/null && modinfo "$M/macvlan.ko" 2>/dev/null | head -12
sha256sum "$M/macvlan.ko" 2>/dev/null
exit $rc
