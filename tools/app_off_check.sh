#!/system/bin/sh
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin
KSUD=/data/adb/ksu/bin/ksud
LOG=/data/local/tmp/app_off_check.txt
: > $LOG

dump_texts() {
    uiautomator dump /data/local/tmp/ui_x.xml >/dev/null 2>&1
    sed 's/<node/\n<node/g' /data/local/tmp/ui_x.xml 2>/dev/null | grep -o 'text="[^"]*"' >> $LOG
}

$KSUD feature set su_compat 0 >> $LOG 2>&1
am force-stop com.droidspaces.app >/dev/null 2>&1
sleep 1
am start -W -n com.droidspaces.app/.MainActivity >/dev/null 2>&1
sleep 5
echo "# OFF_HOME" >> $LOG
dump_texts
input tap 801 2478 >/dev/null 2>&1
sleep 3
echo "# OFF_CONTAINER_PAGE" >> $LOG
dump_texts

$KSUD feature set su_compat 1 >> $LOG 2>&1
echo "# RESTORED $( $KSUD feature get su_compat | grep -E 'Value' )" >> $LOG
echo DONE
