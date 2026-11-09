========================================================
Droidspaces 模块：重启后怎么用（老板专用，2 步）
========================================================

【第 1 步】开机后，在 KernelSU 管理器里点一次授权，拿到临时 root。
           （界面显示"未安装 / 点击安装"，点这张卡片按他的老流程拿 root 即可；
             这一步必须手动，没有 root 什么都做不了。）

           ★ 拿到 root 的瞬间，下面这些会**自动**完成，不需要你跑任何脚本：
               /data/adb/service.d/droidspaces_shim.sh  →  模块 service.sh
               → insmod droid_lkm（内核模块，约 5 秒内 Live）
               → 起 orphan_watch 看门狗（常驻，负责 stop 后清残留）

           想确认有没有生效：grep droid_lkm /proc/modules   （要能看到 Live）

【第 2 步】正常用就行：起容器 → 用 Anland 出桌面。
           停止时 App 点 Stop 或跑 ds_stop.sh 都可以，残留看门狗自动处理，
           **不需要每次跑完去看进程**。

--------------------------------------------------------
只有一种情况才需要手动跑兜底脚本
--------------------------------------------------------
   如果 grep droid_lkm /proc/modules 是空的（说明这次开机 KSU 没触发开机脚本），
   才需要执行一次：

              sh /data/local/tmp/bringup.sh

           （不需要先 su，脚本自己用 su；最后一行 READY 即就位。幂等，可反复跑。）

--------------------------------------------------------
起停容器（推荐用法）
--------------------------------------------------------
   起：  su -c 'sh /data/local/tmp/ds_start.sh UBUNTU26'
         桌面会自动拉起（约 4 秒），不需要手动开 Anland App。
         ⚠ 测启动耗时必须亮屏：息屏时拉起 consumer 会被系统延迟（实测可到 49 秒）。
   停：  su -c 'sh /data/local/tmp/ds_stop.sh UBUNTU26'
         约 3 秒结束，最后一行应为 RESULT=ZERO_LEAK。
   App 里点 Stop：走 droidspaces 原生路径，实测 1.2~1.4 秒返回，
                 看门狗同步清掉 kwin/plasmashell，零残留。

--------------------------------------------------------
验证/排障（可选）
--------------------------------------------------------
   模块日志：        cat /data/adb/droidspaces_shim.log
   看门狗日志：      tail -20 /data/adb/droidspaces_watchdog.log
                    （正常每轮 stop 会有 DRAIN … drain done: procs=0 dir=0）
   看门狗是否在跑：  ps -A -o pid,args | grep orphan_watch
   功能自检：        /data/local/Droidspaces/bin/droidspaces check
                     → 看 "All required features found!"
                       （余下 6 项 ✗ 是内核编译期限制，修不了，README §15 有说明）

--------------------------------------------------------
注意
--------------------------------------------------------
   · 不要替换 /data/adb/modules/droidspaces_shim/droid_lkm.ko
     （sha256 必须一直是 b710cca3...603a5）。
   · 容器运行中不要覆盖模块文件；要换先 stop，再换，再重启。
   · 备份：GitHub 仓库 zhengdianqian/Droidspaces-Kernel-Shim 的 prebuilt/ 目录。
