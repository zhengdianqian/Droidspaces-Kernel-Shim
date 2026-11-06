#!/system/bin/sh
# kotab_check.sh —— 逐符号核对设备内核是否导出（__ksymtab_<sym>）
F=/data/local/tmp/mv_undef.txt
miss=""
while read -r s; do
	[ -z "$s" ] && continue
	c=$(grep -c "__ksymtab_$s\$" /proc/kallsyms 2>/dev/null)
	if [ "$c" = "0" ]; then
		miss="$miss $s"
	fi
done < $F
echo "MISSING=$miss"
echo "count_missing=$(echo $miss | wc -w)"
