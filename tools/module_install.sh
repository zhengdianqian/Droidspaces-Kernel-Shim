#!/system/bin/sh
Z=/data/local/tmp/droidspaces_shim-1.1.zip
M=/data/adb/modules/droidspaces_shim
echo "== zip sha256 =="
sha256sum $Z
echo "== install =="
ksud module install $Z 2>&1
sleep 4
echo "== 安装后目录 =="
ls -la $M
echo "== module.prop =="
cat $M/module.prop
echo "== ko sha (必须仍是 b710cca3...) =="
sha256sum $M/droid_lkm.ko
echo "== service.sh sha =="
sha256sum $M/service.sh
echo "== ksud module list 中本模块 =="
ksud module list 2>/dev/null | tr ',' '\n' | grep -A2 -B6 'droidspaces_shim' | head -30
echo "== 已加载模块（安装不影响运行态） =="
grep -E '^droid_lkm |^kernelsu ' /proc/modules
