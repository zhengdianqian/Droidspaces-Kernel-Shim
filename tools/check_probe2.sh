#!/system/bin/sh
B=/data/local/Droidspaces/bin/droidspaces
echo "== config/IKCONFIG refs =="
grep -a -o -E 'config.gz|/proc/config|IKCONFIG|BOOT_CONFIG|/proc/filesystems' $B | sort | uniq -c
echo "== unshare/newuser probes =="
grep -a -o -E '.{0,60}(unshare\(|CLONE_NEWUSER|user namespace).{0,60}' $B | head -10
echo "== ipv6 nat probe =="
grep -a -o -E '.{0,80}(ip6tables|ip6table_nat|MASQUERADE).{0,60}' $B | head -12
echo "== macvlan probe =="
grep -a -o -E '.{0,60}(RTM_NEWLINK|type=macvlan|macvlan).{0,60}' $B | head -12
