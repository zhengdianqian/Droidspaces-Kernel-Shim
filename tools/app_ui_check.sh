#!/system/bin/sh
# app_ui_check.sh -> 启动 Droidspaces App 并 dump 当前界面文本
export PATH=/system/bin:/system/xbin
input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
wm dismiss-keyguard >/dev/null 2>&1
am force-stop com.droidspaces.app >/dev/null 2>&1
sleep 1
am start -W -n com.droidspaces.app/.MainActivity >/dev/null 2>&1
sleep 5
uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1
echo "=== UI_HEAD ==="
sed 's/<node/\n<node/g' /data/local/tmp/ui.xml 2>/dev/null | grep -o 'text="[^"]*"' | head -60
echo "=== UI_TAIL ==="
