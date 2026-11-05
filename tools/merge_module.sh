#!/system/bin/sh
# 把 KSU `modules_update/<id>` 合并进 `/data/adb/modules/<id>`（等价 KSU 开机 merge 步骤）。
# 本机 KSU 是 late-load，开机阶段不会跑 merge，所以要手动补一次。
ID=droidspaces_shim
U=/data/adb/modules_update/$ID
M=/data/adb/modules/$ID

if [ -d "$U" ]; then
  mkdir -p "$M"
  cp -f "$U/module.prop" "$M/module.prop" 2>/dev/null
  cp -f "$U/service.sh" "$M/service.sh" 2>/dev/null
  cp -f "$U/droid_lkm.ko" "$M/droid_lkm.ko" 2>/dev/null
  cp -f "$U/README.md" "$M/README.md" 2>/dev/null
  chmod 755 "$M/service.sh" 2>/dev/null
  chmod 644 "$M/droid_lkm.ko" "$M/module.prop" "$M/README.md" 2>/dev/null
  rm -rf "$U"
  rm -f "$M/update"
  echo "MERGED"
else
  echo "NO_UPDATE_DIR"
fi

ls -la "$M"
echo "--- modules_update ---"
ls -la /data/adb/modules_update 2>/dev/null
