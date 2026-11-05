#!/bin/bash
export PATH=/opt/ddk/clang/clang-r416183b/bin:$PATH
cd ~/ph/out/android12-5.10 || exit 1
KO=droid_lkm.ko
ls -l $KO
sha256sum $KO
echo "== vermagic"
strings $KO | grep -e vermagic
echo "== B5 vermagic (对照)"
strings /mnt/c/Users/Administrator/Documents/Trae-CN/temp_20261105_01/droid_lkm/droid_lkm_B5.ko | grep -e vermagic
echo "== warning count in build log"
grep -c -i "warning" /tmp/build_b6.log 2>/dev/null || echo 0
echo "== undefined (U) symbols not exported by kernel: check Module.symvers CRC match"
llvm-nm -u $KO | wc -l
echo "== new params"
strings $KO | grep -e "clean_init" -e "zap_guard" -e "pin_kref" -e "no_teardown"
echo "== nsdump present"
strings $KO | grep -e nsdump
