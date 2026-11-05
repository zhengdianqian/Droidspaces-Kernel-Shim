#!/system/bin/sh
export PATH=/data/adb/ksu/bin:/system/bin:/system/xbin
KSUD=/data/adb/ksu/bin/ksud
LOG=/data/local/tmp/su_compat_appuid.txt
: > $LOG
say() { echo "$*" >> $LOG; echo "$*"; }
say "# ON  uid10330: $(/data/adb/ksu/bin/busybox setuidgid 10330 /system/bin/su -c id 2>&1 | tr '\n' ' ')"
$KSUD feature set su_compat 0 >> $LOG 2>&1
say "# OFF uid10330: $(/data/adb/ksu/bin/busybox setuidgid 10330 /system/bin/su -c id 2>&1 | tr '\n' ' ')"
say "# OFF ls_su  : $(ls -l /system/bin/su 2>&1)"
say "# OFF uid2000: $(/data/adb/ksu/bin/busybox setuidgid 2000 /system/bin/su -c id 2>&1 | tr '\n' ' ')"
$KSUD feature set su_compat 1 >> $LOG 2>&1
say "# BACK get   : $($KSUD feature get su_compat | grep -E 'Value|Status' | tr '\n' ' ')"
say "# BACK uid10330: $(/data/adb/ksu/bin/busybox setuidgid 10330 /system/bin/su -c id 2>&1 | tr '\n' ' ')"
echo DONE
