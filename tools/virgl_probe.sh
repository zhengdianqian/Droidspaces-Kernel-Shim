#!/system/bin/sh
# virgl_probe.sh —— 只读：Termux 里是否存在 virgl 相关包/二进制（不安装）
P=/data/data/com.termux/files/usr
echo "== termux bin(virgl) =="
ls -la $P/bin 2>/dev/null | grep -i virgl
echo "== apt lists 命中 virgl =="
ls $P/var/lib/apt/lists/ 2>/dev/null | head -5
for f in $P/var/lib/apt/lists/*Packages*; do
	[ -f "$f" ] || continue
	echo "--- $f"
	grep -a -i -E '^Package: .*virgl|^Package: .*virglrenderer' "$f" 2>/dev/null | head -5
	grep -a -i -E 'virgl_test_server' "$f" 2>/dev/null | head -5
done
echo "== dpkg installed(virgl) =="
grep -a -i -E 'virgl' $P/var/lib/dpkg/status 2>/dev/null | head -10
echo "== prefix bin 总数 =="
ls $P/bin 2>/dev/null | wc -l
echo "== termux uid =="
stat -c '%u %U' /data/data/com.termux 2>/dev/null
