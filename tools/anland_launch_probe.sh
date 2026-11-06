#!/system/bin/sh
B=/data/local/Droidspaces/bin/droidspaces
echo "== com.anland refs =="
grep -a -o -E 'com\.anland[A-Za-z0-9._/:$-]*' $B | sort -u | head -10
echo "== am start / monkey refs =="
grep -a -o -E '.{0,40}(am start|monkey|startActivity|Intent).{0,60}' $B | head -8
echo "== consumer/EXTRA refs =="
grep -a -o -E '.{0,50}(consumer|EXTRA_|socket_path|display_daemon).{0,50}' $B | head -12
