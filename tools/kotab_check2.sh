#!/system/bin/sh
for f in /data/local/tmp/ip6table_nat_undef.txt /data/local/tmp/devtmpfs_undef.txt; do
	echo "==== $f ===="
	miss=""
	while read -r s; do
		[ -z "$s" ] && continue
		c=$(grep -c "__ksymtab_$s\$" /proc/kallsyms 2>/dev/null)
		[ "$c" = "0" ] && miss="$miss $s"
	done < $f
	echo "MISSING=$miss"
	echo "count_missing=$(echo $miss | wc -w)"
done
