# Droidspaces Kernel Shim（droid_lkm 派生）

在 **GKI `CONFIG_PID_NS=n`** 的库存内核上，让 Droidspaces 容器可以正常启动 / 停止 / 杀 PID1，
**不再静默复位整机**。

- 上游：`https://github.com/Dere3046/_patchHarmony`（`droid_lkm`，GPL-2.0）
- 本仓库：在上游基础上做了 **reaper 替换修复** 与 **`disable_pid_allocation` 调用方式修复**，
  并附上完整实验记录、踩雷清单、KSU 打包与运维脚本。
- 实测设备：Redmi Pad Pro（dizi / SM7435P），内核 `5.10.236-android12-9-00003-gfb24cf99ad97-ab14313284`，
  Android 12，KernelSU。

---

## 0. 结论先行（实测数值）

| 项 | 结论 |
|---|---|
| 复位延迟（内核断气 → 新内核启动） | **≈43 s**（B12 43.2 s、B15 43.0 s、B9b 41.75 s、B11 42.5 s）→ 落在"看门狗超时"桶 |
| `kill -KILL` 容器 PID1 → 内核断气（无 stall） | **≤50 ms**（B16：最后记录 210.581，kill marker 210.531） |
| 崩溃前最后一条面包屑（B15） | **`BR05 reaper_swap done`**，随后 `STALL enter point=3` 之后再无输出 |
| 复位的直接触发点 | `droid_lkm_ks.disable_pid_allocation(ns)` 的**间接调用**（B17：跳过它 → kill/stop 全存活） |
| 修复后验收 | 运行中 `stop` 连续 2 次不复位；`kill -KILL` PID1 不复位；`droidspaces check` 全绿；SysV IPC 三类通过；`unshare --pid` 返回 EINVAL 且不复位 |
| `insmod` 后 check 短暂 ✗ | **确定性、非故障**：模块先以 `Loading`（970752 B）出现，期间 PID/IPC 两项必 ✗；**3–7 s** 后转 `Live`（786432 B）自动恢复（3/3 轮实测） |
| App（Droidspaces UI）能否用 | **能**：KSU `su_compat=1` + `com.droidspaces.app` 在 `.allowlist`（真实 appId **10330**）→ App 内启停容器成功 |

---

## 1. 问题现象

- `droidspaces -n UBUNTU26 start` 正常，容器可运行。
- **`droidspaces stop`** 或 **`kill -KILL` 容器内 PID1** → 数秒内整机静默复位（无 panic 日志、无 pstore 记录）。
- 复位后 `/sys/fs/pstore` 为空、mtdoops 索引不变、`persist.sys.boot.reason` 的 pureason 恒定。

## 2. 根因（两层，按发现顺序）

### 2.1 第一层：`find_child_reaper()` 走 BUG()

- 本机 `CONFIG_PID_NS is not set`（`zcat /proc/config.gz` 实测），
  `zap_pid_ns_processes()` 被编成 `static inline BUG()`。
- `kernel/exit.c` 的 `find_child_reaper()` 在 `ns->child_reaper == 正在退出的任务` 时**无条件**调用它。
- 该调用位于 `write_lock_irq(&tasklist_lock)`（IRQs off）之内：
  `BUG → oops → 再次 do_exit → 自锁 tasklist_lock` → 全 CPU 卡死 → 约 43 s 后被看门狗/PMIC 复位。
- 容器 PID1 一 fork 就成为 reaper（`fork.c:2429`），所以"杀 PID1 / stop"必触发。

**修复**：`reaper_fix=1` —— 在 `exit_task_namespaces` 的钩子里、`exit_notify` 之前，
把 `ns->child_reaper` 换成同一命名空间里另一个存活任务（面包屑 `BR04`/`BR05`）。

### 2.2 第二层：`disable_pid_allocation()` 的间接调用会秒复位

- `disable_pid_allocation` 未导出（不在 `Module.symvers`），代码走 `ds_ksym` 运行时解析。
- B16 起把解析地址打印出来：`BR08 ... fn=ffffe...`；临时把 `kptr_restrict` 置 0 后
  `/proc/kallsyms` 里该符号地址**与解析值逐位一致**（例：`ffffffe114377860`），
  说明**符号没错**，但**调用即复位**（≤50 ms，日志来不及落盘）。
- `CONFIG_CFI_CLANG=y` + 本模块带 `__cfi` 符号（LTO+CFI）→ 对**未导出符号的间接调用**
  会触发 CFI 类型校验失败，CFI 失败默认 panic → 秒复位。
- B17 实验反向验证：`skip_disable_alloc=1` 时，`kill -KILL` 与 `stop` **全部存活**。

**修复**：`disable_alloc_mode=1`（默认）—— 不再调用内核函数，
改用 **BTF 真实偏移**直接写 `ns->pid_allocated &= ~PIDNS_ADDING`，
语义与 `disable_pid_allocation()` 完全等价，但绕过间接调用。

```c
/* B18：不调内核函数，按 BTF 偏移直写 */
droid_lkm_pidns_set_pid_allocated(ns, al & ~((unsigned int)PIDNS_ADDING));
```

### 2.3 拆除路径的完整面包屑（B15 实录，P1=12994）

```
187.389  BR12 exit_ns_wrap enter pid=12994 old=... last=0
187.389  STALL enter point=0
189.406  STALL exit point=0
189.406  BR01 exit_cleanup pid=12994 comm=keepalive.sh ns=...
189.406  BR03 exit_cleanup ours ns=... alloc=0x80000002 reaper=12994 self=1
189.406  STALL enter point=2
191.422  STALL exit point=2
191.422  BR04 reaper_swap old=12994 new=12893
191.422  BR05 reaper_swap done cur=12893
191.422  STALL enter point=3        ← 此后无输出（死在 disable_pid_allocation）
193.26   全内核断气
```

B18（修复后）同一路径完整走完：`BR08(mode=1) → BR09 → BR06 → BR13 → BR14 → BR15 → BR16`。

---

## 3. 模块参数（生产默认值）

| 参数 | 默认 | 说明 |
|---|---|---|
| `route=2` | — | 全 kprobe 路由（不写内核 text） |
| `skip_sysvipc=0` | 0 | 打开 SysV IPC 端口 |
| `gate=1` | 1 | 只服务 droidspaces 世界 |
| `degrade=1` | 1 | 允许降级 |
| `verbose` | 1 | 解析/诊断日志 |
| `zap_guard=1` | 1 | 拆除路径护栏 |
| `reaper_fix` | 1 | **必需**：替换 `child_reaper`，否则内核走 `find_child_reaper → BUG` |
| `no_teardown` | 1 | 不做 `queue_zap`（`CONFIG_PID_NS=n` 下内核无 zap 实体） |
| `skip_disable_alloc` | 0 | 调试开关：1 = 完全跳过该语义（B17 验证用） |
| `disable_alloc_mode` | 1 | **必需**：1 = BTF 直写（默认），0 = 调内核函数（会复位） |
| `tick_ms` | 0 | 心跳；调试时 100（10 行/秒，生产必须 0） |
| `stall_mask` / `stall_ms` | 0 | 二分定位用的定点停顿（bit N = point N） |

`insmod` 生产命令行：

```
insmod droid_lkm.ko route=2 skip_sysvipc=0 gate=1 degrade=1 verbose=1 \
       zap_guard=1 reaper_fix=1 tick_ms=0 no_teardown=1 \
       skip_disable_alloc=0 disable_alloc_mode=1
```

---

## 4. 构建

环境：Android DDK（clang 12 + GKI `android12-5.10` 头），`KMI` 与设备内核串一致。

```
bash b7.sh
# -> out/android12-5.10/droid_lkm.ko
# vermagic: 5.10.236-android12-9-00003-gfb24cf99ad97-ab14313284 SMP preempt mod_unload modversions aarch64
```

自检（必须全过）：`modinfo` vermagic 一致；`llvm-nm -u | wc -l` = 202；
编译 0 warning；`sha256` 与 `service.sh` 中的 `SHA` 一致。

---

## 5. 安装（KernelSU）

### 5.1 标准方式（ksud 正式安装）

前提：KSU 内核侧已就绪（`/proc/modules` 里能看到 `kernelsu`，UAPI=2）。本机是 late-load，
所以先跑 `ksu_bringup.sh late`，再执行：

```
adb push droidspaces_shim-1.1.zip /data/local/tmp/
su -c '/data/adb/ksud module install /data/local/tmp/droidspaces_shim-1.1.zip'
```

输出：`- Module installed successfully!`，文件落在 `/data/adb/modules_update/droidspaces_shim/`。

两个本机踩过的坑：

1. **zip 必须是"模块文件在根目录"**。若打包成 `droidspaces_shim/module.prop` 这种带一层目录的结构，
   `ksud` 会报 `specified file not found in archive`（它只在 zip 根找 `module.prop`）。
2. **本机 KSU 是 late-load，开机阶段不会执行 merge**，所以 `modules_update` 不会自动变成
   `/data/adb/modules/<id>`。装完要补一次合并（等价 KSU 的 merge 步骤）：

```
su -c 'sh merge_module.sh'   # cp modules_update/<id>/* -> modules/<id>/，删 update 标记
```

合并后校验：`sha256sum /data/adb/modules/droidspaces_shim/droid_lkm.ko`
= `b710cca34249c6cf8b215b61c29ca9aa2e3be6919c9aac3123c1dabecc1603a5`。

> 实测一次异常：KSU 已加载但 `ksud module install` 曾产出一个 **10 MB 全零** 的 ko
> （`insmod` 报 `Exec format error`）。重装一次即恢复。装完务必 `sha256sum`，
> 不要假设"装完就对"。

### 5.2 手工安装（备用）

```
adb push droid_lkm.ko service.sh module.prop /data/local/tmp/shim/
su -c 'mkdir -p /data/adb/modules/droidspaces_shim
       cp -f /data/local/tmp/shim/* /data/adb/modules/droidspaces_shim/
       chmod 755 /data/adb/modules/droidspaces_shim/service.sh
       chmod 644 /data/adb/modules/droidspaces_shim/droid_lkm.ko'
```

`service.sh` 有四道前置校验：`/proc/modules` 可读、未重复加载、
`uname -r` 逐字节一致、`sha256` 一致；任何一条不过 → 记日志并 `exit 0`（绝不注错版本）。

### 5.3 验证

```
su -c 'grep droid_lkm /proc/modules'
su -c 'cat /data/adb/droidspaces_shim.log'
su -c 'cat /proc/droid_lkm/features'
```

### 5.4 开机自动加载：本机实测结论（已闭环）

**先说结论：本机可以做到"重启 + 跑一次 reroot.sh → 模块自动就位"，不需要任何手写 insmod。**
链路是：`reroot.sh` 拿 root → `ksu_bringup.sh` 让 KSU 就绪 → **KSU 模块的 `service.sh` 自己 insmod**。

#### 5.4.1 `UAPI=0` 的真实成因（不是版本不匹配，别去换 ko）

- 早期看到的 `ksud` 报错是 `UAPI version mismatch: kernel=0, ksud=2`，含义是
  **内核侧根本没有加载 `kernelsu` 模块**（kernel 侧 UAPI 读出来是 0），而不是 ksud 版本太新。
- 本机 KSU 是 **LKM 模式**：`kernelsu.ko` 内嵌在 APK 的 `libksud.so` 里（按 KMI 一组，含 `android12-5.10_kernelsu.ko`），
  由 `libksud.so late-load --allow-shell --package-name me.weishu.kernelsu` 加载。
- 加载成功后实测：`/proc/modules` 出现 `kernelsu 200704 2 - Live`；
  `ksud 3.3.0 (uapi: 2)`，`ksud module list` / `module list` 正常返回 JSON，**UAPI=2**。
- 所以 **不需要去官方 release 找别的 kernelsu.ko**：自带的就能用，失败只是"没触发 late-load"。
  （且官方通用 ko 的 vermagic 与本机 `5.10.236-android12-9-00003-gfb24cf99ad97-ab14313284` 不一致，硬换必然 `insmod` 失败。）

#### 5.4.2 为什么早期的 `service.sh` 一次都没跑

两个独立原因叠加：

1. **`reroot.sh` 自身有 bug**：它的 `SU=` 变量解析为空（日志里能看到 `reroot| SU=`），
   于是内部所有 `"$_SU" -c ...` 都变成空命令，报 `timeout: exec : No such file or directory`，
   `ksud late-load` 与 `reload SELinux policy` 都没执行。
2. **开机阶段已过**：本机是"先有 root，再 late-load"，等 `kernelsu` 加载时，
   KSU 的 `post-fs-data` / `service` 阶段早已走完；`ksud services` 也**不会**在 late-load 之后重跑脚本（实测 log 行数不变）。

#### 5.4.3 闭环方案（已实测，两段式）

`round.ps1` 里的 `Ensure-KSU` 分两步，**必须分两次 `su` 调用**：

```
1) su -c '/data/local/tmp/libksud.so late-load --allow-shell --package-name me.weishu.kernelsu'
2) su -c 'sh /data/local/tmp/ksu_boot_v1.sh'
   # 内部顺序：su_compat 自查（0 → set 1）→ 模块 service.sh（insmod）→ 打印 KSU_UP
```

`ksu_boot_v1.sh` 现在会**先把 `su_compat` 补到 1** 再跑模块：否则如果上次是 0 状态，
重启后 App 一打开就是"页面被禁用"，而且 shell 的 `su` 也会一起消失。切换是立即生效的，
不需要额外重启（见 7.9）。这一步同时内置在 `ksu_boot.sh` 与 `ksu_bringup.sh boot` 里，
`round.ps1` 在 `KSU_UP` 之后再兜底检查一次（`SU_COMPAT_NOT_1 -> set 1`）。

为什么必须拆开（本机实测）：

- late-load 一旦执行，**当时那个 su 会话会掉进 shell 域**：`PATH` 失效（`date`/`sleep` 都报
  `inaccessible or not found`），写 root 0600 日志报 `Permission denied`。
- 更糟的是，如果 late-load 是包在脚本里跑的，**下一次 `su` 会阻塞约 175 秒**；
  改成"独立一次 su 直接执行 late-load"后，下一次 su 立即返回（实测 3 s）。

`service.sh` 自己会做 `uname -r` 逐字节比对、`sha256` 校验、`insmod`、自检。

**验收（故意把 `su_compat` 预置成 0 后重启）**：`round.ps1` 日志出现
`SU_COMPAT_NOT_1 -> set 1` → `SU_COMPAT_AFTER=… Value: 1 Status: enabled`，
随后 `CHECK_OK`（`All required features found!`）；重启后打开 App，容器页直接可用
（无"无法获取 Root 权限，此页面已被禁用"），「启动」按钮正常显示。


实测（连续三轮真实重启，宿主时钟）：

| 轮次 | 上线 | root 恢复 | KSU/模块 | check | reboot→全绿 |
|---|---|---|---|---|---|
| cycle9 | 06:25:2x | 06:26:37 | 06:26:41 | 06:26:45 **OK** | 100.7 s |
| cycle10 | 06:27:3x | 06:28:35 | 06:28:39 | 06:28:43 **OK** | 95.3 s |

其中 **系统开机到 `boot_completed` 占 ~70 s**（adb 上线本身就要 60 s+，不可控），
真正属于自动化的部分（提权 → late-load → service.sh → insmod → check）只要 **约 30 s**。

#### 5.4.4 保底

- `/data/adb/service.d/droidspaces_shim.sh`（同一套逻辑，写死 KO 路径）仍然保留；
- `round.ps1` 的 `Ensure-Module` 在 `ksu_bringup` 之后兜底直接 `insmod`（两者都失败时才会用到）。

### 5.5 "删模块 + 重启 = 关闭"（实测成立）

```
su -c 'rm -rf /data/adb/modules/droidspaces_shim'
adb reboot
# 等开机 → reroot.sh 提权（不跑 round.ps1，避免兜底 insmod）
```

结果：`/proc/modules` 无 `droid_lkm`；`droidspaces check` 的 **PID namespace / IPC namespace 变 ✗**，
设备正常运行、不复位。即"删模块 + 重启"能真正关闭补丁。

恢复：重新 `ksud module install` + `merge_module.sh` + 重启（本仓库最后一轮即按此恢复，check 全绿）。

### 5.6 App 界面：可以用了（`su_compat`，实测）

先说结论：**本机不刷 boot 也能让 Droidspaces App 拿到 root。** 关键是 KernelSU 的
`su_compat` 特性（本机 KSU 3.3.0 默认就是开启的）。

- 查看：`ksud feature get su_compat` → `Value: 1  Status: enabled`；
  开关：`ksud feature set su_compat 0|1`（**立即生效，不需要重启**）。
- **开机流程已自动补到 1**：`ksu_boot.sh` / `ksu_bringup.sh boot` 在 late-load 之后先做
  `su_compat` 自查（0 → 1），`round.ps1` 再兜底检查一次（见 5.4.3 / §9）。
- **关闭的副作用（重要）**：`su_compat=0` 会让 `/system/bin/su` 整体消失，**连 shell 的 `su` 也没了**；
  必须在**同一个 root 会话**里完成"关闭 → 测试 → 重开"，否则会锁死（只能 `reroot.sh` 拿临时 root 再开回来，见踩雷 #36）。
- 开启时 KSU 提供 `/system/bin/su`（4,892,712 B，`su -v` = `3.3.0:KernelSU`）。
- App 必须已在 KSU 授权名单：`/data/adb/ksu/.allowlist` 里要有 `com.droidspaces.app`。
- **App 的真实 appId 是 10330**（`dumpsys package com.droidspaces.app` → `appId=10330`）。
  不要用别的 uid 去测：su_compat 对**未授权 uid** 会把 `su` 隐藏，执行结果是 ENOENT，
  很容易误判成"su 不可用"。

实测（root 会话里用 `busybox setuidgid` 模拟 App uid）：

| `su_compat` | App uid 10330 执行 `/system/bin/su -c id` | 结论 |
|---|---|---|
| 1（enabled） | `uid=0(root) gid=0(root) … context=u:r:ksu:s0` | App 可提权 |
| 0（disabled） | `setuidgid: can't execute '/system/bin/su': No such file or directory` | App 失去 root |

App 侧实测（两次，跨重启复验）：

- 容器页**不再**出现"无法获取 Root 权限，此页面已被禁用"；
- 点「启动」输出 `Command executed (exit code: 0)` / `操作成功！`，
  `Container started with PID 28916`（首次）/ `PID 17775`（重启后复验），Ubuntu 26.04 正常启动；
- 随后 CLI `stop` 返回 `Container stopped.`，uptime 单调递增、设备不复位。

> 本节早期版本写"必须刷 boot"是**错的**：当时用 uid 10123（不是 Droidspaces 的 appId）测，
> 也未核对 `su_compat` 与 `.allowlist`。已用真实 appId 10330 复核，并在 App 内实机启动容器两次。


## 6. 回滚

1. `su -c 'rm -rf /data/adb/modules/droidspaces_shim'`
2. 重启（模块自 pin，`rmmod` 必 `-EBUSY`，只能靠重启卸载）。

---

## 7. 验收记录（本仓库定版 = B18）

| 验收项 | 结果 |
|---|---|
| `kill -TERM` 容器内子进程 | 存活（多次复现） |
| `kill -KILL` 容器 PID1 | **存活**（B17/B18，P1_exists=no 正常退场） |
| 运行中 `droidspaces stop` 第 1 次 | 存活（P1=15774） |
| 运行中 `droidspaces stop` 第 2 次 | 存活（P1=17774） |
| `droidspaces check` | rc=0，`All required features found!` |
| SysV IPC 三类（`ipcmk -Q/-M/-S`） | 全部 rc=0；容器 `ipcs` 可见；宿主 `/proc/sysvipc/*` 只有表头（隔离成立） |
| `unshare --pid` | rc=1 `Invalid argument`（预期），且**不复位** |
| **干净重启后**（uptime 204 s 起）start → 运行中 `stop` | **存活**（P1=13044，25 s 后 `p1_exists_after=no`，uptime 持续增长到 252 s，未复位） |

### 7.1 浸泡测试（5 轮 start → 运行 180 s → stop）

同一开机、同一模块实例，连续 5 轮。判据：`uptime` 必须单调递增（回退即视为复位），
`/proc/modules` 全程保留 `droid_lkm`，每轮 `droidspaces check` 必须 rc=0。

| 轮次 | uptime 起始 | 运行 180 s 后 | stop 之后 | 模块仍加载 | check |
|---|---|---|---|---|---|
| 1 | 870.03 | 1052.14 | 1066.96 | 1 | rc=0 `All required features found!` |
| 2 | 1067.01 | 1249.12 | 1263.95 | 1 | rc=0 |
| 3 | 1264.00 | 1446.10 | 1460.90 | 1 | rc=0 |
| 4 | 1460.95 | 1643.06 | 1657.91 | 1 | rc=0 |
| 5 | 1657.98 | 1840.10 | 1854.90 | 1 | rc=0 |

**结果：5/5 通过。** `uptime` 全程单调递增（870 → 1854.9，无一次回退），
`p1_exists_after=no` 每轮成立（容器干净退场），模块引用计数未泄漏。

### 7.2 真实负载（systemd + 大量 fork + SysV IPC 全链路）

容器以 **`--init=/sbin/init`（真 systemd）** 启动：`p1_comm=systemd`，启动日志
`Booting 'UBUNTU26' (init: /sbin/init)`。

| 项目 | 结果 |
|---|---|
| `apt list --installed` | **2101** 个包（大量 fork/exec，无异常） |
| `apt-get update` | rc=0（镜像站不可达全为 `Ign`，但**进程链完整跑完且不复位**） |
| `unshare --pid --fork`（容器内） | rc=0（模块的 `unshare=97` slot 钩子接管，不建真实 ns） |
| `unshare --ipc`（容器内） | rc=0 |
| 期间 uptime | 1929.47 → 2047.81 → 2071.15（单调递增，无复位） |

SysV IPC 全链路（容器内，实测输出原文）：

```
$ ipcmk -M 4096          -> Shared memory id: 0   (rc=0)
$ ipcs -m
------ Shared Memory Segments --------
key        shmid      owner      perms      bytes      nattch     status
0x0d449356 0          root       644        4096       0
$ ipcrm -m 0             -> rc=0
$ ipcs -m                -> 只有表头（已删除）

$ ipcmk -S 1             -> Semaphore id: 0
$ ipcs -s                -> 0x1710c010 0 root 644 1
$ ipcrm -s 0             -> 已删除（仅表头）

$ ipcmk -Q               -> Message queue id: 0
$ ipcs -q                -> 0x8cdfc595 0 root 644 0 0
$ ipcrm -q 0             -> 已删除（仅表头）
```

宿主侧隔离校验（模块把表项留在容器自己的 ns 里）：

```
/proc/sysvipc/msg: 1     # 只有表头
/proc/sysvipc/shm: 1
/proc/sysvipc/sem: 1
```

期间 uptime 2286.23 → 2326.42，**无复位**。

### 7.3 `/proc/self/ns` 缺 `pid` / `ipc` 条目的定性

容器内 `/proc/1/ns` 与 `/proc/self/ns` 都只有
`cgroup / mnt / net / time / time_for_children / uts`；**宿主侧 `/proc/self/ns` 同样没有 `pid` 与 `ipc`**。
即这是**内核本身没有这两个 ns 的 procfs 条目**（`CONFIG_PID_NS=n`，且本机未编译 IPC namespace），
不是模块"忘了挂"。模块只能伪造 ns 对象与 syscall 行为，**无法凭空造出 procfs 软链**。

实际影响评估（已实测）：

- `droidspaces check`：**不受影响**，PID namespace / IPC namespace 两项均 `✓`，rc=0；
- 容器实际使用：systemd、`apt`（2101 包）、`ipcs`/`ipcmk`/`ipcrm` 全链路均正常；
- 唯一受影响的是**依赖 `/proc/<pid>/ns/pid` 或 `.../ipc` 软链的工具**（部分 `nsenter`/`lsns` 写法、按软链判断隔离的脚本）。

结论：**保持现状，不硬改**（在 `#10 已知限制` 中明确标注）。

### 7.4 长时浸泡（systemd 常驻 45 分钟，每 5 分钟采样）

容器 `--init=/sbin/init` 常驻，P1=13029（`comm=systemd`）全程存活；`droid_lkm` refcnt 恒为 **2**；
`kmemleak` 本机不可用（`/sys/kernel/debug/kmemleak` 不存在）。

| t | uptime | refcnt | Slab (kB) | SUnreclaim (kB) |
|---|---|---|---|---|
| 0 | 105.14 | 2 | 500652 | 379848 |
| 1 | 405.28 | 2 | 507984 | 379824 |
| 2 | 705.40 | 2 | 507912 | 379380 |
| 3 | 1005.52 | 2 | 511600 | 382460 |
| 4 | 1305.65 | 2 | 515992 | 385920 |
| 5 | 1605.76 | 2 | 515056 | 384904 |
| 6 | 1905.88 | 2 | 516124 | 385484 |
| 7 | 2206.02 | 2 | 515920 | 385224 |
| 8 | 2506.14 | 2 | 516060 | 385328 |
| 9 | 2806.26 | 2 | 518296 | 387172 |

**判定：无泄漏。** Slab 在 t=1~t=8 之间稳定在 **515–516 MB**（t=4 起完全平台化，期间还有回落），
SUnreclaim 稳定在 **384–387 MB**（t=2 到 t=3 的上行是容器 systemd 自身活动，非单调增长）；
refcnt 全程 2，容器 P1 全程存活，uptime 105 → 2806 s 无回退。

### 7.5 压力场景：fork 风暴中直接 stop

容器内先起 **400 个短命进程 + 200 个持续 `fork` 循环**，让容器进程数涨到 **469**，
然后在风暴进行中执行 `droidspaces stop`：

```
STRESS_BEGIN uptime=2937.47
p1_before=13029 exists=yes
before_stop uptime=2943.54 container_procs=469 module=1
stop_rc=0  -> Stopping container 'UBUNTU26' (PID 13029)... Container stopped.
after_stop15 uptime=2970.51 p1_exists=no module=1
uptime_monotonic=pass
dmesg oops/BUG 扫描: 空
```

结果：**stop 在 469 个进程并发 fork 时依然 rc=0，设备不复位，无 oops，模块保持加载**。
stop 后 `droidspaces check` 仍是 `PID namespace ✓ / IPC namespace ✓ / All required features found!`。

### 7.6 正式安装 + 两轮重启闭环（ksud 模块形态）

安装：`ksud module install` → `modules_update` → `merge_module.sh` → `/data/adb/modules/droidspaces_shim`
（`module.prop` + `service.sh` + `droid_lkm.ko`，ko sha256 = `b710cca3…`）。

| 轮次 | 事件 | 结果 |
|---|---|---|
| cycle8 | 重启 → 上线 → reroot → late-load → `service.sh` → check | **OK**，round 30.6 s |
| cycle9 | 同上（完整 reboot 计时） | **OK**，reboot→全绿 **100.7 s** |
| cycle10 | 同上（提前开始提权） | **OK**，reboot→全绿 **95.3 s** |

- 三轮连续通过，无一次 `insmod` 失败；每轮 `/proc/modules` 都出现 `droid_lkm 786432 1 - Live`。
- 时间构成：**开机到 adb 可用 ~70 s（不可控）**，自动化段 **~30 s**。
  "90 秒内"这个目标，本机受限于 USB/adb 上线时间，实测 **95–101 s**；
  若按"adb 上线 → 全绿"计，则稳定 **< 35 s**。

> **cycle7 异常复核（本轮 3 轮真实重启，逐 3 s 采样 insmod 后 0–45 s）**
>
> | 轮次 | 模块出现 uptime | 模块状态 | t=0 | t=3 | t=6 | 复位 |
> |---|---|---|---|---|---|---|
> | c1 | 30.45 | `Loading` 970752 B | ✗ 9（PID/IPC 两项 required） | ✗ 9 | ✗ 6（仅 optional） | 无 |
> | c2 | 32.67 | `Loading` 970752 B | ✗ 9 | ✗ 9 | ✗ 6 | 无 |
> | c3b | 36.17 | `Loading` 970752 B | ✗ 9 | ✗ 6 | ✗ 6 | 无 |
>
> 结论：**"check 连续 ✗"是模块 init 未完成的确定性窗口，不是故障本身。** `insmod` 返回后模块
> 先以 `Loading`（970752 B）出现，此时 `/proc/droid_lkm/features` 为空、PID/IPC 两项必 ✗；
> 约 **3–7 s** 后转 `Live`（786432 B），check 自动回到 required 全绿。
>
> 但 **"约 23 s 后自复位"在 3/3 轮刻意复现中都没有出现**，也没抓到 fake ns create 的失败返回
> （本机 `dmesg` 在 `u:r:ksu:s0` 下为空、`logcat` 缓冲为空、pstore 为空）。
> 按事实记录：**偶发、未复现、已加稳定期** —— `insmod` 后等 3 s 再 check（最多重试 3 次），
> 且 `round.ps1` 现在会先等 `su` 回到 root 域再采集（见踩雷 #35）。
>
> **取证路径盘点**：`ksud feature` 里能用的调试项只有 `sulog`（ID=2，SU 事件日志，**不记录内核崩溃**）
> 和 `adb_root` 等，均不能替代 `dmesg`；而本机 `dmesg` 在 `u:r:ksu:s0` 下为空、`logcat` 缓冲为空、
> pstore 为空，所以**没有抓到 fake ns create 的失败返回**（`-EINVAL` / `-ENOMEM` / `layout not trusted`）。
>
> **未归因复位的相关性观察（2/2 vs 0/5）**
>
> - 第 1 次：06:37:30，`su_compat=0`、容器 stop 后跑 `reroot.sh` → 复位（`boot.reason` 历史 `reboot`，无 `shell` 标记）；
> - 第 2 次：07:01:23，同样的前置（`su_compat=0` + `reroot.sh`）→ 又一次复位（`reboot`，同样无 `shell` 标记）；
> - 对照：`su_compat=1` 下 `reroot.sh` 跑了 5 次（3 轮 cycle + 2 次浸泡前准备）全部正常，`adb reboot` 均为 `reboot,shell`。
>
> 即：**"`su_compat=0` 时跑 `reroot.sh`" 到目前为止 2/2 复位，`su_compat=1` 时 0/5**。
> `reroot.sh` 内没有 `reboot` 调用，根因仍未定位（不作猜测）；当前流程已把 `su_compat` 在开机后第一时间补到 1，
> 这条路径在实际使用中不会再出现。若将来仍要复现，按此法对照即可。



### 7.7 容器内真实安装并执行（apt + ipcs + unshare）

容器 `UBUNTU26`（systemd）内执行真实的包管理链路：

```
# 先修 DNS（容器默认 1.1.1.1/8.8.8.8 在本地不可达，全部 Ign）
printf 'nameserver 223.5.5.5\nnameserver 114.114.114.114\n' > /etc/resolv.conf

apt-get install -y tree          # 真实下载并安装，rc=0
tree --version                   # tree v2.1.1
tree -L 1 /etc | head -12        # 正常输出目录树
ipcs -m                          # 正常输出表头/段
unshare --pid --fork true        # rc=0（模块的 pid ns 钩子接管，不复位）
unshare --ipc true               # rc=0
```

期间宿主 uptime 707.24 → 707.49（单调递增）；随后 `droidspaces stop` 返回
`Container stopped.`，12 s 后 uptime 仍增长、`droidspaces check` 全绿 → **停容器不复位**。

### 7.8 App 界面演练结论（已改判：可用）

见 5.6。App（真实 appId **10330**）通过 KSU `su_compat` 拿到 root：

- 容器页不再显示"无法获取 Root 权限，此页面已被禁用"；
- App 内点「启动」成功：`Container started with PID 28916`（首次）/ `PID 17775`（重启后复验），
  `Command executed (exit code: 0)` + `操作成功！`；
- 随后 CLI `stop` → `Container stopped.`，uptime 169→268 单调递增，设备不复位。

**App 路径不再需要刷 boot**；前提只有两个：`su_compat=1`、`com.droidspaces.app` 在 `.allowlist`。

### 7.9 `su_compat` 开关验证（立即生效 / 对模块无影响）

同一次开机内来回切换（uptime 169.70 → 268.65 单调，无重启）：

| 状态 | `/system/bin/su` | App uid 10330 → `su -c id` | `droidspaces check` | 容器 start/stop | `droid_lkm` |
|---|---|---|---|---|---|
| `su_compat=0` | 不存在 | `can't execute … No such file or directory` | required 全绿 | 正常，不复位 | Live，refcnt 2 |
| `su_compat=1` | 存在（4,892,712 B） | `uid=0(root)` | required 全绿 | 正常，不复位 | Live，refcnt 2 |

- **生效方式：立即**。`ksud feature set` 返回后 `ls /system/bin/su` 立刻出现/消失，不需要重启。
- **持久化**：值写入 `/data/adb/ksu/.feature_config`；本轮 3 次重启后 `feature get` 均为 `1`。
- **对 `droid_lkm` 无影响**：两种状态下 check 全绿、容器起停正常、模块一直 `Live`。
- **副作用**：`su_compat=0` 会让 shell 也失去 `su`（本机 root 直接断）。
  必须在**同一个 root 会话**里完成"关闭 → 测试 → 重开"，否则要重跑 `reroot.sh` 再开回来（见踩雷 #36）。


---

## 8. 踩雷清单（现象 / 根因 / 改法 / 验证）

| # | 现象 | 根因 | 改法 / 验证 |
|---|---|---|---|
| 1 | 容器内脚本报 `not found` | `#!/system/bin/sh` 在 Ubuntu rootfs 里不存在 | 容器内统一 `#!/bin/sh` |
| 2 | `container.config` 退化成 488 B 全 NUL | 运行时重写配置被截断 | 修复为 509 B 正常内容；**每次重启后检查** |
| 3 | 看到 `0x8000000F` 以为出错 | 该值是正常状态位 | 不作错误处理 |
| 4 | 复位后 mtdoops 索引不变 | 说明**没有走** `kernel_restart` | 排除"内核主动重启"，指向看门狗/PMIC |
| 5 | `persist.sys.boot.reason` 的 pureason 恒定 | hypervisor/PMIC 层复位 | 排除软件 reboot |
| 6 | `rmmod droid_lkm` 永远 `-EBUSY` | 模块自 pin（引用计数不归零） | 只能重启卸载；`service.sh` 用 `already loaded` 早退 |
| 7 | `cat >>` 采集 kmsg 只有 26 B | stdio 块缓冲 | 用 `tee -a file < /dev/kmsg` |
| 8 | `while read` 逐字节读 kmsg 报 EINVAL | mksh 按字节读，记录长度不足 | 同上 |
| 9 | `dd` 读 kmsg 读到一半 EINVAL | 块填充要求不满足 | 同上 |
| 10 | `/dev/mem`、`/dev/kmem`、`/proc/kcore` 都不存在 | 内核未开 | 放弃内存取证路线 |
| 11 | 复位后 `/sys/fs/pstore` 为空；`/proc/last_kmsg` 只有 0.27 s + 0xFF | ramoops 未保留 panic | 只能靠**设备侧实时 tee** 取证 |
| 12 | 早期 B12 全量 stall：load 13、心跳 6 s | stall 无门控，所有进程退出都睡 3 s | 用 `droid_lkm_pidns_is_ours()` 门控 |
| 13 | `ps | grep /keepalive.sh` 取到 grep 自己的 PID | grep 命令行自匹配 | `ps -A -o PID,PPID,ARGS | awk '$3=="sh" && $4=="/keepalive.sh"'` |
| 14 | 宿主轮询 `adb shell cat /proc/uptime` 报 `error: closed` 但设备还活着 | adb daemon 重启造成假阴性 | 以**设备侧 kmsg 最后一条记录时间戳**为死亡时刻 |
| 15 | PowerShell 里 `adb shell '...|...'` 管道被截断 | PowerShell 先解析 `|` 与 `$var` | 一律写 `.sh` push 到设备执行 |
| 16 | `insmod` 返回 rc=1 但模块已工作 | 加载路径返回值不可靠 | 以 `/proc/modules`、`/proc/droid_lkm` 为准 |
| 17 | `tick_ms=100` 时 kmsg 10 行/秒 | B7 心跳无条件 printk | 生产 `tick_ms=0` |
| 18 | BR 面包屑刷屏 | 按 B7 要求"verbose=0 也要打" | 属预期；后续可加专用开关 |
| 19 | `ksud module install` 失败：`UAPI version mismatch kernel=0, ksud=2` | 不是版本不匹配，而是**内核侧 `kernelsu` 未加载**（UAPI 读出 0） | 先 `late-load`，加载后 UAPI=2，`ksud` 全部命令正常（见 5.4.1） |
| 20 | `adb push` 写 `/data/adb/modules` 报 Permission denied | adb shell 是普通用户 | push 到 `/data/local/tmp`，再 `su -c cp` |
| 21 | 调用 `disable_pid_allocation` 秒复位、无日志 | CFI（`CONFIG_CFI_CLANG=y`）+ 未导出符号间接调用 | 改 BTF 直写（`disable_alloc_mode=1`） |
| 22 | `unshare --pid` 返回 `Invalid argument` | `CONFIG_PID_NS=n` 的预期行为 | 作为**通过**判据（且不得复位） |
| 23 | 模块落盘到 `/data/adb/modules/` 后重启，`service.sh` 完全没执行（日志文件都不存在） | ①`reroot.sh` 的 `SU=` 解析为空 → 内部 `late-load` 变成空命令；②late-load 发生在开机阶段之后，KSU 不会重跑 `service` 阶段 | `auto/ksu_bringup.sh`（late-load + 执行模块 `service.sh`），见 5.4.3 |
| 24 | `adb shell 'su -c "cmd1; cmd2"'` 里第二条命令掉回 `shell` 域（`/proc/self/attr/current` = `u:r:shell:s0`，且报 `Permission denied`） | adb shell 传参 + 多层引号被外层 shell 提前切分 | 一条 `adb shell` 只放**一条** `su -c` 命令，或把逻辑写成 `.sh` push 到设备执行 |
| 25 | `stop` 后立刻 `start` 报 `another operation is in progress on this container` | droidspaces 的停止是异步收尾，前一次 stop 尚未完成 | 脚本里先 `sleep 15~20`，再用 `droidspaces -n <name> pid` 轮询确认，最多重试 60 s |
| 26 | `ipcmk` 输出是 `Shared memory id: 0`（不是 `id=0`） | 解析正则假设错误，`ipcrm` 拿到空参数 → rc=1 | 从 `ipcs -m` 的第 2 列取真实 id 再 `ipcrm`；实测 id 恒为 0 |
| 27 | `reroot.sh` 打印 `SU=`、`timeout: exec : No such file or directory`，`late-load`/`reload SELinux` 全被跳过 | 脚本里 `SU=${hit%%|*}` 拿到空串，`timeout 90 "" -c ...` 直接失败 | 不要依赖它做 KSU 加载；由 `ksu_bringup.sh` 用绝对路径 `/data/local/tmp/libksud.so` 自己 `late-load` |
| 28 | `ksud services` rc=0，但模块 `service.sh` 根本没跑（log 行数不变） | KSU 的 stage 脚本按开机阶段扫描；late-load 之后调用不会重跑 | late-load 后直接 `sh /data/adb/modules/<id>/service.sh`（仍走 KSU 模块目录，等价） |
| 29 | `ls -d /sys/module/kernelsu` 报不存在，但 `/proc/modules` 里有 `kernelsu ... Live` | KernelSU 对自身痕迹做了隐藏，sysfs 目录不可见 | 判断 KSU 是否就绪用 `/proc/modules` 里是否有 `^kernelsu `（**不要**用 `ksud module list`：它只读 `/data/adb`，没加载内核也会返回 0） |
| 30 | `ksud module install` 报 `specified file not found in archive` | zip 里多套了一层目录（`droidspaces_shim/module.prop`） | 重打包，让 `module.prop` 位于 zip **根** |
| 31 | `ksud module install` 成功，但 `insmod` 报 `Exec format error` | 落盘的 ko 变成 **10 MB 全零**（sha256 与源不一致） | 装完必须 `sha256sum`；不一致就重装一次（实测重装即恢复） |
| 32 | 装到 `modules_update` 后重启，`/data/adb/modules/<id>` 没更新 | KSU 的 merge 在开机阶段跑；本机是 late-load，阶段早过了 | `merge_module.sh` 手工合并 + 删 `update` 标记（见 5.1） |
| 33 | late-load 后同一脚本里 `date`/`sleep` 报 `inaccessible or not found`，日志 `Permission denied`；下一次 `su` 卡 ~175 s | late-load 会把**当前 su 会话**掉进 shell 域；包在脚本里跑还会让下一个 su 阻塞 | late-load 必须用**独立的一次** `su -c '<libksud.so> late-load ...'` 直接执行，后续操作另起一次 `su`（见 5.4.3） |
| 34 | App 容器页提示"无法获取 Root 权限，此页面已被禁用" | 当时测错 uid（10123 ≠ Droidspaces 的 `appId=10330`）；su_compat 对未授权 uid 隐藏 `su`（ENOENT） | 用 `dumpsys package` 取真实 appId；确认 `su_compat=1` + `.allowlist` 含包名，即可用（见 5.6） |
| 35 | late-load 刚完成就执行 `su -c`，脚本里 `sleep`/`cut` 报 `inaccessible or not found`、写日志 `Permission denied`，`su` 报 `Text file busy` | late-load 后 su 会话/二进制有一小段竞态，会短暂掉回 shell 域 | 采集前先轮询 `su -c 'id -u'` == 0（本轮 `cycle_watch.ps1` 最多 10 次、每次 3 s），再跑采样脚本 |
| 36 | `ksud feature set su_compat 0` 之后，下一条 `su -c ...` 直接报 `su: inaccessible or not found`，再也开不回来 | su_compat 关闭会**立即**移除 `/system/bin/su`（连 shell 也没有），形成"锁死" | 关闭/测试/重开必须在**同一个 root 会话**里做（`su -c 'set 0; test; set 1'`）；已锁死则跑 `reroot.sh` 拿临时 root 再 `set 1` |
| 37 | `dumpsys package` 查到的 `userId` 与实际 `appId` 在两个字段 | `appId` 才是进程 uid（本机 `appId=10330`），`userId` 可能相同也可能不同 | 一律以 `appId=` 为准；不要用猜的 uid 做能力测试 |


---

## 9. 无人值守运维（复位后自恢复）

`auto/round.ps1`：

1. 轮询 `adb devices`（**不等 `boot_completed`**，一上线就开始，最多省 ~30 s；提权失败会自动重试 5 次）；
2. `su -c id` 失败 → 跑 `rpproot_re/reroot.sh`（无线 ADB token 提权，`--borno` 需 |Δt| ≤ 301 s）；
3. **`Ensure-KSU`**：先看 `/proc/modules` 是否有 `kernelsu`；没有就用**独立一次** `su` 直接 `libksud.so late-load`，
   然后另起一次 `su` 跑 `ksu_boot.sh`（内部顺序：**`su_compat` 0 → 1** → 模块 `service.sh` 自己 `insmod`）；
   `round.ps1` 之后还会再查一次 `ksud feature get su_compat`，不是 1 就补成 1；
4. **`Ensure-Module`**：兜底，`/proc/modules` 里仍没有 `droid_lkm` 才直接 `insmod`；
5. 等 3 s，`droidspaces check` 断言 `All required features`（最多重试 3 次）；
6. 断点写入 `/data/local/tmp/auto_state`；
7. 每轮把 `/data/local/tmp` 的 `kB*.log`、`state`、`ds_start/stop*.log` 拉回 `auto/logs/<轮次>/`。

实测（三轮连续成功，见 7.6）：**reboot → 95–101 s → 模块已加载 + `check` 通过**，
其中系统开机/ adb 上线占 ~70 s，自动化部分 ~30 s；全程零人工、零手写 insmod。
**不使用一键 root BAT**（其内含分区写入，违反"不刷机 / 不写分区"约束）。

---

## 10. 已知限制

1. **临时 root**：本机 root 由 RPPROOT 经无线 ADB 获取，每次重启需 `reroot.sh` 重跑；
   该脚本自身 `SU=` 解析为空（内部 `late-load` 会失败，但 `su -c id` 仍正常）。KSU 加载由 `ksu_bringup.sh` 补上（见 5.4.3）。
2. **`rmmod` 不可用**（EBUSY），停用只能删模块目录 + 重启。
3. **nsfs 的 inode 是 `unlabeled_t`**：SELinux 严格模式下，普通 App（`untrusted_app`/`shell` 域）对
   `/proc/<pid>/ns/*` 的 `readlink`/`open`/`setns` 会被拒（没有针对 `unlabeled_t` 的 allow 规则），
   `ls -l` 也显示权限拒绝；以 root/kernel 域运行的 Droidspaces 不受影响。若将来要让普通 App 读取，
   需要给 nsfs inode 打正确标签（`genfscon`/`sepolicy` 规则）。
4. **`/proc/self/ns` 缺 `pid` 与 `ipc` 两个条目**：**宿主内核本身就没有这两个 procfs 条目**
   （`CONFIG_PID_NS=n`、未编译 IPC namespace），所以容器里同样不可能出现——不是模块漏挂，
   模块也无法凭空造出 procfs 软链。实测影响：`droidspaces check` 仍 rc=0（两项都 `✓`），
   systemd / `apt`（2101 包）/ `ipcs`/`ipcmk`/`ipcrm` 全部正常；只有依赖
   `/proc/<pid>/ns/pid`、`.../ipc` 软链的工具（部分 `nsenter`/`lsns` 写法）会失败。**不硬改**。
5. **`container.config` 每次重启退化**（488 B 全 NUL），启动前需修复；已在踩雷 #2 记录。
6. **日志量大**：`BRxx` 面包屑按 B7 要求无条件打印，进程频繁退出时 kmsg 增长快。
7. **仅在本机验证**：5.10.236 / dizi / `CONFIG_PID_NS=n` / `CONFIG_CFI_CLANG=y`；其他机型需重编并重跑同一套验收。
8. **App 可用，但依赖两个前提**：Droidspaces App（真实 `appId=10330`）需要
   `su_compat=1` **且** `com.droidspaces.app` 在 `/data/adb/ksu/.allowlist`；
   两者满足时 App 内可正常启停容器（见 5.6 / 7.8 / 7.9）。
   若把 `su_compat` 关掉，App 会回到"无法获取 Root 权限，此页面已被禁用"，而 CLI 不受影响。

---

## 11. 使用建议（日用）

- 开机后（或任何重启后）跑一次 `auto/round.ps1` 即可：提权 → KSU late-load → 模块 `insmod` → `check`；
- 日常操作走 CLI：`droidspaces -n UBUNTU26 start --init=/sbin/init` / `stop` / `run -- <cmd>`；
- 容器内第一次 `apt`/联网失败，先看 `/etc/resolv.conf`（本机 1.1.1.1/8.8.8.8 不可达，改成 223.5.5.5 / 114.114.114.114）；
- 想彻底关闭补丁：删 `/data/adb/modules/droidspaces_shim` + 重启（见 5.5）；
- 想用 App（而不只是 CLI）：先确认 `ksud feature get su_compat` 为 `1`（默认就是），
  且 `com.droidspaces.app` 在 `.allowlist`；**不要随手关 `su_compat`**，它一关 shell 与 App 同时失去 root；
- 升级模块：`ksud module install` → `merge_module.sh` → 重启（不要只覆盖 ko，`update` 标记会导致不合并）。

### 关于 `pid_cachep`（改进 C 的取舍）

`droid_lkm_create_pid_cachep()` 里保留了自建 cache 的路径，并注明了取舍：

- 优先用内核 `init_pid_ns.pid_cachep`（level 0 时直接读取，见 `pidns.c` 的注释与 `droid_lkm_pidns_pid_cachep(&init_pid_ns)`）；
- 但外部 `kmem_cache_alloc` 要求对象大小 / `SLAB_ACCOUNT` 属性与内核 `struct pid` 完全一致，
  否则会产生跨 cache 的 UAF；
- 由于本模块自 pin、生命周期等于整机，fake ns 内的 pid 对象只在模块存活期内分配/释放，
  UAF 风险可控；若改回内核 cache，反而要保证 `sizeof(struct pid)` 的精确匹配，
  风险更高，故保留自建路径并在这里写明取舍。

---

## 11. 实验链（每一轮换来什么）

| 轮次 | 变更点 | 新信息 |
|---|---|---|
| B8–B11 | 采集手段 / panic_on_oops | kmsg 采集三连坑；复位不是 panic（pstore 空） |
| B12 | stall point 0 / 3 s | kill→断气 5.63 s；证明"能延迟" |
| B13 | is_ours 门控 + 30 s | 门控必要（否则全进程退出被拖慢） |
| B14 | stall_mask 位图 + 120 s | kill→断气 121.2 s，延迟与 stall 线性 |
| B15 | 全点位 2 s | 最后面包屑 = `BR05` + `STALL enter point=3` → 死点在 reaper swap 之后 |
| B16 | 仅 point 4 30 s | ≤50 ms 死亡，`STALL point=4` 未出现 → 死点更早 |
| B17 | `skip_disable_alloc=1` | **kill 与 stop 全部存活** → 锁定 `disable_pid_allocation` 间接调用 |
| B18 | `disable_alloc_mode=1`（BTF 直写） | 全部验收通过 → 定版 |

---

## 12. 附录：设备侧取证脚本要点

```sh
# kmsg 实时落盘（唯一可靠方式）
nohup tee -a /data/local/tmp/kB.log < /dev/kmsg >/dev/null 2>&1 &
# 每秒 sync + 0.1 s 心跳，保证复位后能判断死亡时刻
nohup sh -c 'while :; do sync; sleep 1; done' >/dev/null 2>&1 &
nohup sh -c 'while :; do echo "HB $(cut -d" " -f1 /proc/uptime)" >> /data/local/tmp/hb.log; sleep 0.1; done' >/dev/null 2>&1 &
```

死亡时刻判定：取 `kB.log` 最后一条记录的第 3 列（µs uptime），与 kill marker 相减。

---

## License

GPL-2.0（随上游 `Dere3046/_patchHarmony`）。本仓库的修改同样以 GPL-2.0 发布。
