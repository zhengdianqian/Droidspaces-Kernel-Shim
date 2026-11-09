========================================================
Droidspaces 模块：重启后怎么用（老板专用，3 步）
========================================================

【第 1 步】开机后，先在提权 App（KernelSU 管理器）里点一次授权，
           拿到临时 root。什么都不用改。

【第 2 步】打开任意终端（Termux 或 adb），执行这一条命令：

              sh /data/local/tmp/bringup.sh

           （不需要先 su，脚本会自己用 su 跑两段：
             late-load kernelsu.ko → 加载 droid_lkm → 起 orphan_watch 看门狗）

           看到最后一行 READY 就说明整条链就位了。
           屏幕会同时打印 droid_lkm 是否 Live、看门狗 PID、check 结果。

【第 3 步】正常用就行：起容器 → 用 Anland 出桌面。

--------------------------------------------------------
验证/排障（可选）
--------------------------------------------------------
   完整流程日志：  cat /data/local/tmp/bringup.log
   模块日志：      cat /data/adb/droidspaces_shim.log
   模块是否加载：  grep droid_lkm /proc/modules      （要能看到 Live）
   看门狗是否在跑：ps -A -o pid,args | grep orphan_watch
   功能自检：      /data/local/Droidspaces/bin/droidspaces check
                   → 看 "All required features found!"
                     （余下 6 项 ✗ 是内核编译期限制，修不了，README §15 有说明）

--------------------------------------------------------
起停容器（本轮修复后的推荐用法）
--------------------------------------------------------
   起：  su -c 'sh /data/local/tmp/ds_start.sh UBUNTU26'
         桌面会自动拉起（约 4~5 秒），不需要手动开 Anland App。
   停：  su -c 'sh /data/local/tmp/ds_stop.sh UBUNTU26'
         约 3 秒结束，最后一行应为 RESULT=ZERO_LEAK。

   如果是在 App 里点 Stop 也可以：orphan_watch 看门狗会在 3 秒内把
   kwin_wayland / plasmashell 等残留清干净，不会再出现 100% CPU 空转。

--------------------------------------------------------
注意
--------------------------------------------------------
   · 不要替换 /data/adb/modules/droidspaces_shim/droid_lkm.ko
     （sha256 必须一直是 b710cca3...603a5）。
   · 容器运行中不要覆盖模块文件；要换先 stop，再换，再重启。
   · 备份：GitHub 仓库 zhengdianqian/Droidspaces-Kernel-Shim 的 prebuilt/ 目录。
