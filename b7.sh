#!/bin/bash
set -o pipefail
export PATH=/opt/ddk/clang/clang-r416183b/bin:$PATH
cd ~/ph || exit 1
LOG=/tmp/build_b7.log
make ARCH=arm64 CC=clang READELF=readelf AS=clang LD=ld.lld AR=llvm-ar NM=llvm-nm STRIP=llvm-strip \
     OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- \
     VER=android12-5.10 KDIR=/opt/ddk/kdir/android12-5.10 V="$1" -j8 > "$LOG" 2>&1
rc=$?
tail -20 "$LOG"
echo "RC=$rc"
grep -n "droid_lkm.ko" "$LOG" | tail -3
exit $rc
