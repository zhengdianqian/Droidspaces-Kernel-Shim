#!/bin/bash
# wsl_devtmpfs_build2.sh —— 去掉 __init/桩冲突后再编译 devtmpfs.ko
export PATH=/opt/ddk/clang/clang-r416183b/bin:$PATH
M=$HOME/devtmpfs_mod
sed -i 's/#ifdef CONFIG_DEVTMPFS/#if 1/' "$M/base.h"
sed -i 's/int __init devtmpfs_init/int devtmpfs_init/; s/int __init devtmpfs_mount/int devtmpfs_mount/; s/int __init devtmpfs_create_node/int devtmpfs_create_node/' "$M/devtmpfs_main.c"
cat > "$M/wrap.c" <<'EOF'
#include <linux/module.h>
extern int devtmpfs_init(void);
static int __init dt_init(void) { return devtmpfs_init(); }
module_init(dt_init);
MODULE_LICENSE("GPL");
EOF
cat > "$M/Makefile" <<'EOF'
obj-m := devtmpfs.o
devtmpfs-objs := devtmpfs_main.o wrap.o
ccflags-y += -I$(src) -DCONFIG_DEVTMPFS -Wno-unused-function
EOF
cd "$M" || exit 1
LOG=/tmp/build_devtmpfs2.log
make -C /opt/ddk/kdir/android12-5.10 M="$M" ARCH=arm64 CC=clang \
     READELF=readelf AS=clang LD=ld.lld AR=llvm-ar NM=llvm-nm STRIP=llvm-strip \
     OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- \
     modules > "$LOG" 2>&1
rc=$?
grep -E 'error:|undefined' "$LOG" | head -12
tail -8 "$LOG"
echo "RC=$rc"
[ -f "$M/devtmpfs.ko" ] && { modinfo "$M/devtmpfs.ko" | grep -E 'vermagic|depends|name'; sha256sum "$M/devtmpfs.ko"; }
exit 0
