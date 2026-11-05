#!/bin/bash
ko=/home/ubuntu/ph/out/android12-5.10/droid_lkm.ko
ls -l "$ko"
sha256sum "$ko"
modinfo "$ko" | grep -E 'vermagic|stall|reaper_fix|tick_ms'
echo "--- undefined count:"
/opt/ddk/clang/clang-r416183b/bin/llvm-nm -u "$ko" | wc -l
echo "--- build warnings:"
grep -ci warning /tmp/build_b7.log || true
