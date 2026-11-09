# Droidspaces Kernel Shim（droid_lkm 派生）

在 **GKI `CONFIG_PID_NS=n`** 的库存内核上，让 Droidspaces 容器可以正常启动 / 停止 / 杀 PID1，
**不再静默复位整机**。

- 上游：`https://github.com/Dere3046/_patchHarmony`（`droid_lkm`，GPL-2.0）
- 本仓库：在上游基础上做了 **reaper 替换修复** 与 **`disable_pid_allocation` 调用方式修复**，
  并附上完整实验记录、踩雷清单、KSU 打包与运维脚本。
- 实测设备：Redmi Pad Pro（dizi / SM7435P），内核 `5.10.236-android12-9-00003-gfb24cf99ad97-ab14313284`，
  Android 12，KernelSU。
- 作者：**默默的阿文**（`module.prop` 的 `author=` 同名；`droid_lkm.ko` 二进制未改动，见 §16）

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
| Anland 显示 | **通过**：KDE Plasma 桌面/任务栏/时钟实际渲染，点击可开窗（§13） |
| `droidspaces check` | MUST/RECOMMENDED/OPTIONAL 除 6 项内核编译期硬限制外全 ✓（§15） |

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

## 13. Anland 显示（硬性验收：容器必须在 Anland 上正常显示 / 正常操作）

**结论：已通过。** KDE Plasma（`plasmashell` + `kwin_wayland` + `Xwayland`）在容器内正常渲染，
画面经 Droidspaces 的 Anland daemon 送到 `com.anland.consumer`，在平板上**可见、可点击**。
证据：`docs/anland-desktop.png`（桌面 + 图标 + 任务栏 + 时钟 11:08 2026/11/6）、
`docs/anland-interaction.png`（`input tap` 点开 Konsole 后窗口出现、有菜单栏与标题）。

### 13.1 配置（改前均已备份）

`/data/local/Droidspaces/Containers/UBUNTU26/container.config`（511 B）：

```
enable_anland=1        # 打开 Anland 显示
enable_gpu_mode=1      # 把宿主 GPU 节点（含 /dev/dri/renderD128）镜像进容器，渲染必需
enable_hw_access=0     # 不做全量 /dev 直通（内核无 devtmpfs，见 §14.3）
enable_x11=0           # 不用 X11 模式；Anland 走 Wayland
enable_virgl=0         # 关掉 VirGL（Termux 侧没有 virglrenderer，见 §14.2）
net_mode=nat / disable_ipv6=1 / run_at_boot=0 / rootfs_path=/data/local/Droidspaces/rootfs/UBUNTU26
```

备份文件（全部保留在原目录）：

| 文件 | 含义 |
|---|---|
| `container.config.preH.bak` | 最早的原文件（`enable_anland=0`） |
| `container.config.preAnland.bak` | 打开 Anland 之前的状态（= preH，`enable_anland=0`） |
| `container.config.preVirgl.bak` | 本轮把 `enable_virgl` 置 0 之前的状态（10:47） |

### 13.2 启动顺序（有日志佐证）

1. `droidspaces start` 先在宿主起 **Anland display daemon**：
   `[Anland] launching display daemon on /data/local/Droidspaces/Net/anland-<hash>.sock` +
   `Anland: daemon pid=<pid> launched`；
2. daemon 把 socket **bind-mount 进容器**：`[Anland] display socket bind-mounted to /run/display.sock`；
3. 容器 init 起来后 `kwin_wayland`（producer）连上 `/run/display.sock` → daemon 记 `producer connected`；
4. Android 侧 `com.anland.consumer`（consumer）连同一 socket：
   `consumer connected` → `consumer deposited 5 fds` → `screen info 1600x2560 fmt=1` →
   `fds delivered to producer`；此后 kwin 才真正出图。

**consumer 必须拿到 socket 路径**，intent extra key 是 `socket_path`（从 APK DEX 的
`EXTRA_SOCKET_PATH` 实测）。socket 名**每次 start 都变**，取值必须用“最后一次 listening”：

```sh
SOCK=$(grep -a "listening on" /data/local/Droidspaces/Logs/UBUNTU26/anland | tail -1 | sed 's/.*listening on //')
am start -n com.anland.consumer/.MainActivity --es socket_path "$SOCK"
```

> 注意：不要用 `ls -t /data/local/Droidspaces/Net/*.sock | head -1` —— 在 `su` 域下
> `ls -t` 需要逐项 `stat`，会被 SELinux 拒（`Permission denied`），结果拿到空值或旧 socket，
> 表现就是“consumer 连上 0.5 s 就 disconnected、屏幕全黑”。本仓库 `tools/anland_up.sh` 已改为读日志。

### 13.3 容器内依赖 / 开机自启修复

- `plasma-wayland.service`（`/etc/systemd/system/`）：`ExecStart=/usr/bin/bash -lc /usr/bin/startplasma-wayland`；
- 单元已打补丁（原文件备份为 `plasma-wayland.service.prebak`）：
  `Restart=no → always`，并在 `[Install]` 前插入 `RestartSec=5` 与 `ExecStartPre=/bin/sleep 20`；
- `kwin_wayland`（Anland 补丁版）+ `plasmashell --no-respawn` + `Xwayland`；
- `/etc/environment`：`ANLAND=1`、`ANLAND_SOCKET=/run/display.sock`、`ANLAND_DRM_DEVICE=/dev/dri/renderD128`。

> 时序：容器 `start` 后 `plasma-wayland` 约 20 s（ExecStartPre）开始拉 plasma，
> **再过 ~40–70 s 桌面才画全**（图标 + 任务栏）。截图要等够，否则只有壁纸 —— 这不是故障。

### 13.4 实测结果（最后一轮，11:04–11:08）

| 检查 | 结果 |
|---|---|
| daemon 起来 | `daemon: listening on …/anland-a275f4c2d9e665ae6d5b50173f6096c9.sock` |
| `/run/display.sock` | 容器内 `srw-rw-rw-+ root root 0 Nov 6 11:06 /run/display.sock` |
| producer | `producer connected`（kwin，11:06:41） |
| consumer | `consumer connected` + `deposited 5 fds` + `screen info 1600x2560`（11:07:01） |
| 画面 | 桌面/图标/任务栏/时钟实际渲染（`docs/anland-desktop.png`） |
| 交互 | `input tap` 打开 Konsole，窗口出现且可交互（`docs/anland-interaction.png`） |
| 与模块共存 | `droid_lkm 786432 2 - Live`，`check` 仍 `All required features found` |
| `stop` | 不复位（`uptime_before=693.45` → `uptime_after=737.25`，差值 44 s = 脚本里 `sleep 20` + 采样开销） |

### 13.5 已知限制

1. 平板**息屏后** Anland 会断开（`consumer disconnected`），截图会全黑（21 KB PNG）——
   这是 Android 休眠导致 App 暂停，不是 Anland 故障。验收前先 `svc power stayon true` + `input keyevent KEYCODE_WAKEUP`。
2. App 必须被显式拉起（带 `socket_path`）；只起容器不拉 App 时 daemon 只有 producer，屏幕是黑的。
3. 容器 `stop` 后再 `start`，socket 名会变，必须重新拉起 App（脚本 `tools/anland_up.sh` 已处理）。
4. Anland 与 VirGL 目标重叠，本机取舍为 **Anland 优先**（`enable_virgl=0`）。

### 13.6 回滚

```sh
C=/data/local/Droidspaces/Containers/UBUNTU26
# 回到 Anland 打开之前（enable_anland=0）
cp -p $C/container.config.preAnland.bak $C/container.config
droidspaces -n UBUNTU26 stop && droidspaces -n UBUNTU26 start --init=/sbin/init
# 回到 VirGL 打开之前
cp -p $C/container.config.preVirgl.bak $C/container.config
# 纯 CLI：不需要 Anland App，stop/start/run 全部照旧
```

---

## 14. start 日志里的 `[!]` / `[i]` 逐条处置

| 日志行 | 成因 | 处置 | 状态 |
|---|---|---|---|
| `[i] [CGROUP] /sys/fs/cgroup/droidspaces/UBUNTU26 is left over from an earlier run and could not be cleaned up` | droidspaces 只对**顶层**目录做 `rmdir`；上一次容器 systemd 的子组（`system.slice`/`user.slice`/`init.scope`/…）仍非空 → `ENOTEMPTY`。更深一层：**`stop` 只杀容器 init/master，user session 里的 kwin/plasmashell/dbus/systemd-networkd 会变成孤儿**并继续挂在同一 cgroup 下 | `tools/ds_start.sh`：逐层读 `cgroup.procs` 把成员 `kill -9`，再**自底向上** `rmdir`，最多重试 5 轮，最后才 `start` | **已消除**（见 §14.1） |
| `[!] VirGL: server binary not found at /data/data/com.termux/files/usr/bin/virgl_test_server_android - skipping start` | Termux 没有 `virgl_test_server_android`（`$PREFIX/bin` 无 virgl 二进制、apt lists 为空、dpkg 未装 `virglrenderer`） | `enable_virgl=0`（Anland + GPU 节点镜像已提供渲染，VirGL 非必需） | **已消除** |
| `[!] VirGL: socket not found at /.old_root/data/data/com.termux/files/usr/tmp/.virgl_test - skipping socket bridge` | 同上（server 没起，socket 自然不存在） | 同上 | **已消除** |
| `[!] Hardwave access disabled: using isolated tmpfs` | 该行只在 `enable_hw_access=0` **且未开 GPU 模式**时出现；本内核 `CONFIG_DEVTMPFS=n`，无法整块 `/dev` 直通 | `enable_gpu_mode=1`：日志改为 `[GPU] --gpu mode: mirroring host GPU nodes into isolated tmpfs` / `Setting up GPU-only access...` | **已消除**（11:04 / 11:06 两次 start 均无此行） |
| `[i] Ensuring /data is mounted with suid support...` | 正常信息行（保证容器内 suid 程序可执行），不是告警 | 无需处理 | 保留 |

> 判定口径：`[!]` / `[i]` 只是 Droidspaces App 终端里的**前缀标记**，日志文件本身没有这两个字符。
> 最后一轮两次 `start` 里 `grep -E '[CGROUP]|VirGL|Hardware access|\[!\]'` 输出为空（见 §18）。

### 14.1 cgroup 清理：为什么必须“杀进程 + 递归 rmdir”

实测（10:49 停止后）：

- `rmdir /sys/fs/cgroup/droidspaces/UBUNTU26` → **Device or resource busy**；
- 树里仍有进程，且是**多代残留**：`systemd-networkd`(pid 11236)、`polkitd`(15612)、`dbus`(18779)、
  `kwin/plasmashell`(22926…) 等 —— 前几轮容器的子进程没有随容器退出，一直挂在同名 cgroup 下；
- 逐层 `kill -9` 后再 `find … -depth | rmdir`，**第 1 轮即成功**（`pass 1 killed=32 exists=0`）。

清理记录（`/data/local/tmp/ds_start.log` 实录）：

```
[10:49:55] pass 1 killed=32 exists=0
[10:49:55] cgroup leftover cleaned: /sys/fs/cgroup/droidspaces/UBUNTU26
[10:57:33] pass 1 killed=22 exists=0
[10:57:33] cgroup leftover cleaned: /sys/fs/cgroup/droidspaces/UBUNTU26
[11:04:52] pass 1 killed=36 exists=1
[11:04:53] pass 2 killed=5  exists=0
[11:04:53] cgroup leftover cleaned: /sys/fs/cgroup/droidspaces/UBUNTU26
```

本内核 5.10 没有 `cgroup.kill`（v2 的“一键杀空”文件），所以只能在 wrapper 里做。

### 14.2 为什么不是“装个 VirGL 就完了”

- Termux 侧 `$PREFIX/var/lib/apt/lists` 空、`$PREFIX/bin` 无任何 virgl 二进制、`dpkg -l` 无 `virglrenderer`；
- VirGL 是给 X11/Hybrid 模式做 GL 转发；本机用 Anland（Wayland + `/dev/dri/renderD128`），
  两套显示栈目标重叠。为消两条 `[!]` 再装一套栈属于反向优化，正确取舍是 **`enable_virgl=0`**。

### 14.3 devtmpfs 这一层是硬限制

`CONFIG_DEVTMPFS=n`（`/proc/filesystems` 无 `devtmpfs`），`mount -t devtmpfs` 返回 **ENODEV**；
`devtmpfs` 在 Kconfig 里是 `bool`，不能编成模块（树外尝试见 §15 判定表第 1 行）。
因此“整块 `/dev` 直通”不可能用模块补出来，能做的只有 `enable_gpu_mode=1` 的**节点级镜像**（已做）。

---

## 15. `droidspaces check` 剩余 ✗ 的一次性判定表

口径：只看“**不刷 boot、不改内核分区**”能否变绿；每一项都用“真编 ko → 真 insmod → 看返回码”实测定性。

| 项 | check 判定依据 | 现状（实测） | 树外 KO 尝试 | 结论 |
|---|---|---|---|---|
| devtmpfs support | `/proc/filesystems` 含 `devtmpfs` | 无；`mount -t devtmpfs` → `No such device` | `devtmpfs.ko` 编出（398880 B，vermagic 一致），`insmod` → **ENOENT**；45 个未定义符号中 **17 个本机未导出**：`ksys_unshare init_mount reconfigure_single shmem_init_fs_context device_get_devnode vfs_kern_mount vfs_mkdir vfs_mknod vfs_rmdir vfs_unlink kern_path_create kern_path_locked done_path_create init_chdir init_chroot shmem_fs_parameters block_class` | **需刷带 `CONFIG_DEVTMPFS=y` 的内核** |
| Macvlan | 能否 `ip link add … type macvlan` | `RTNETLINK answers: Operation not supported` | `macvlan.ko` 编出（813536 B，vermagic 一致），`insmod` → **ENOENT**；85 个未定义符号中 **17 个未导出**：`dev_change_proto_down_generic __dev_forward_skb dev_forward_skb dev_mc_add_excl dev_mc_del dev_mc_sync dev_queue_xmit_accel dev_set_allmulti dev_set_promiscuity dev_uc_add dev_uc_add_excl dev_uc_del dev_uc_sync ip_check_defrag linkwatch_fire_event ndo_dflt_fdb_dump netdev_is_rx_handler_busy` | **需刷带 `CONFIG_MACVLAN=m/y` 的内核** |
| IPv6 NAT | `ip6tables -t nat` 表是否存在 | `can't initialize ip6tables table 'nat': Table does not exist` | `ip6table_nat.ko` 编出（519032 B），`insmod` → **ENOENT**；11 个未定义符号中 **7 个未导出**：`ip6t_alloc_initial_table ip6t_do_table ip6t_register_table ip6t_unregister_table ip6t_unregister_table_exit nf_nat_ipv6_register_fn nf_nat_ipv6_unregister_fn` | **需刷带 `CONFIG_IP6_NF_NAT=y` 的内核** |
| CPU limit | `/proc/sys/kernel/sched_cfs_bandwidth_slice_us` / cgroup2 `cpu.max` | 两者都不存在 | 无模块化接口（CFS 带宽是调度器编译期代码） | **需刷带 `CONFIG_CFS_BANDWIDTH=y` 的内核** |
| Process limit | cgroup 里 `pids.max` | 无 `pids.max`，`cgroup.controllers` 不含 `pids` | cgroup 子系统必须静态注册，`cgroup_init_subsys()` 未导出 | **需刷带 `CONFIG_CGROUP_PIDS=y` 的内核** |
| Sandboxing（user ns） | `unshare -U` 是否成功 | `Operation not permitted` | 涉及 cred/mm/nsproxy 核心结构，不可模块化 | **需刷带 `CONFIG_USER_NS=y` 的内核** |

**一句话结论：6 项全部是内核编译期能力，树外 KO 一条也补不绿 —— 必须刷一个带对应 `CONFIG_*` 的内核。**
本轮的“真做”部分：3 个 KO 都编出来了、都推到设备上 `insmod` 过了、失败原因逐符号定位到 GKI 符号裁剪，
证据在 `extras/SHA256SUMS`、`extras/*.ko` 与 `tools/ko_build/`（含未导出符号清单）。

> 为什么 `insmod` 报的是 `No such file or directory` 而不是 `Unknown symbol in module`：
> 内核在加载阶段解析 `__ksymtab` 失败时直接返回 `-ENOENT`；而 `dmesg` 在本机 `su` 域下读不到，
> 所以判定改用 `/proc/kallsyms` 里的 `__ksymtab_<sym>`（`kptr_restrict=2` 下符号名仍可读，9794 个）。

### 15.1 树外 KO 构建（可复现）

```sh
make -C /opt/ddk/kdir/android12-5.10 M=$PWD ARCH=arm64 CC=clang \
     LD=ld.lld AR=llvm-ar NM=llvm-nm STRIP=llvm-strip OBJCOPY=llvm-objcopy \
     OBJDUMP=llvm-objdump LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- modules
```

- 源码取自 DDK 源树 `/opt/ddk/src/android12-5.10`（`drivers/net/macvlan.c`、
  `net/ipv6/netfilter/ip6table_nat.c`、`drivers/base/devtmpfs.c`）；
- 三个 ko 的 `vermagic` 均为 `5.10.236-android12-9-00003-gfb24cf99ad97-ab14313284`；
- **注意 PATH 顺序**：DDK 的 `clang-r416183b` 必须前置，否则系统 clang 会撞 `__LITTLE_ENDIAN_BITFIELD redefined`；
- 脚本：`tools/ko_build/wsl_macvlan_build.sh`、`wsl_ip6nat_build.sh`、`wsl_devtmpfs_build2.sh`。

### 15.2 为什么没有把这些 ko 打进模块包

`service.sh` **不做**自动 `insmod extras/`：三个 ko 在本机必失败，开机每次打印失败只会污染日志。
它们保留在 `extras/` 作为“已尝试、已失败、原因已定位”的证据（sha256 见 §16.2）。
若要给未来机型用，把 `extras/<name>.ko` 放进模块目录并自行 `insmod` 即可，主模块不受影响。

---

## 16. 作者与产物

### 16.1 作者 = 默默的阿文

- `ksu/module.prop`：`author=默默的阿文`；
- 模块内 `README.md`（`ksu/README-module.md`）顶部：`作者：默默的阿文`；
- 根 README（本文件）署名同步；
- **ko 本身未改动**：`droid_lkm.ko` sha256 仍是
  `b710cca34249c6cf8b215b61c29ca9aa2e3be6919c9aac3123c1dabecc1603a5`，
  `service.sh` 里的 `SHA=` 校验链因此不需要改（改名不影响校验链）；
- 设备重装后 `ksud module list` 的 `author` 字段为 `默默的阿文`（原始输出见 §18）。

### 16.2 产物 sha256（本轮定版）

| 文件 | 大小 | sha256 |
|---|---|---|
| `prebuilt/droid_lkm_B18.ko`（= zip 内 `droid_lkm.ko`） | 10086568 | `b710cca34249c6cf8b215b61c29ca9aa2e3be6919c9aac3123c1dabecc1603a5` |
| `ksu/service.sh`（= zip 内 `service.sh`） | — | `75e0dd0f0c8f738ca45b7347450e35cb9de65b1c1c9703edaa232f0bdff91f55` |
| `prebuilt/droidspaces_shim-1.1.zip` | 2409665 | `eae7cf22a557181fbf9c95c853d1dd06fc8b02a598c46dab890b21e06783c968` |
| `extras/macvlan.ko`（证据，不随包安装） | 813536 | `dc7b77f8216573d49cf1f48d656b24e9b75e99ccd8f36aa94dd34b5a7d846f3e` |
| `extras/ip6table_nat.ko`（证据，不随包安装） | 519032 | `63607db55a1f21159b2d4e943ef0ae74ad472c345171ac36de122bc1011dd092` |
| `extras/devtmpfs.ko`（反例，不可加载） | 398880 | `3c80c5be98eded1ef1a9a230c3909807475bc71ba0981c847935ace9cabff7b7` |

zip 根目录结构：`module.prop` / `service.sh` / `droid_lkm.ko` / `README.md`（无子目录，KSud 要求）。

---

## 17. 重启 / 复位统计（明确数字）

**总数：28 次。**

口径：`persist.sys.boot.reason.history`（最近 8 条）+ 本地 adb 操作日志的并集，按时间戳去重。
可核对窗口 `02:59:01`–`11:04:13`（11:04:13 是最后一次 `adb reboot`，用于最终验收）。

| 分类 | 次数 | 说明 |
|---|---|---|
| 脚本重启（`reboot,shell`，含本轮收尾的 `adb reboot`） | **22** | 换 ko、`round.ps1`/`cycle_watch.ps1` 验收轮次、浸泡前准备、最后一轮干净验收 |
| 未归因复位（`reboot`，无 shell 标记） | **6** | `02:59:01`、`03:02:57`、`03:07:11`、`06:11:32`、`06:37:43`、`07:01:23` |
| 人为手动（长按电源） | **0** | 全程无人值守，无人工重启记录 |

逐条时间戳：`docs/reboot_events.txt`。

> **未归因的 6 次**：前 3 次在 B16/B17 的 stop/kill 实验期（与 `disable_pid_allocation` 直接相关，
> 换 `disable_alloc_mode=1` 后不再出现）；后 3 次与“`su_compat=0` 状态下跑 `reroot.sh`”时间相关，
> 但 `reroot.sh` 内无 `reboot` 调用，根因**未定位**（`su_compat=1` 下 reroot 5/5 无复位）。
>
> **口径限制**：系统只保留最近 8 条 boot reason，`02:59` 之前的 B7–B16 阶段重启已被覆盖，
> 无法精确还原。28 是**设备可核对**的确定值，不含被覆盖的更早记录。

### 17.1 时间线

| 时间（宿主 CST） | 轮次 | 做了什么 | 结果 |
|---|---|---|---|
| 02:59–03:07 | B16/B17 | stall 点位二分 + `skip_disable_alloc=1` | 3 次未归因复位；锁定 `disable_pid_allocation` 间接调用 |
| 03:25 / 03:42 | B18 | `disable_alloc_mode=1`（BTF 直写）换 ko | 定版；kill/stop 不再复位 |
| 04:31–04:36 | round 调试 | 自动提权 / late-load / insmod 链路 | 3 次脚本重启，确认两段式 `su` 必要 |
| 05:33–05:51 | 自动恢复 | `ksu_bringup.sh` + `service.sh` 自加载 | reboot → 全绿 ~95–101 s |
| 05:55–06:10 | cycle 系列 | 多轮重启验收 + App/容器 apt | 稳定；App 可用（`su_compat=1`） |
| 06:11:32 / 06:37:43 / 07:01:23 | — | 未归因复位 | 与 `su_compat=0` + reroot 时间相关，未复现 |
| 06:23–06:52 | cycle9/10 + cycle7 复核 | 真实重启验收 | 100.7 s / 95.3 s 到全绿；`check` ✗ 窗口 3–7 s |
| 07:04:33–10:34:44 | **浸泡** | 容器 systemd 常驻 3.5 h（14 tick/15 min） | 14/14 `check=OK`、`droid_lkm Live`、**resets=0**；TICK10 起 `dd=1 ct=1`（09:19 容器被 App 侧改写配置后重起，非复位） |
| 09:19 | Anland 首测 | App 写入 `enable_anland=1`/`enable_gpu_mode=1` 并 start | 管线通；plasma 21 s 后退出（开机竞态） |
| 09:25–09:42 | Anland 定版 | 手动 `systemctl start plasma-wayland` + `am start --es socket_path` | 桌面稳定渲染 + 点击可用（首张截图） |
| 10:35 | 目标二 | 三个树外 ko 推到设备并 `insmod` | 全部 ENOENT；逐符号定位到 17/7/17 个未导出符号 |
| 10:47–10:49 | 目标一 | `enable_virgl=0` + plasma 单元补丁 + `ds_start.sh` 预清理 | VirGL/Hardware 两条告警消失；cgroup 残留清干净 |
| 10:52 | Anland 复验 | 新容器 + App | 桌面/交互正常；期间发现“息屏导致黑屏截图”的假故障 |
| 10:54–10:57 | 目标三 | 重打包（改名、去 extras）→ `ksud module install` | `author=默默的阿文`；ko sha 不变；reboot 应用更新 |
| 11:04:13 | 最终验收 | `adb reboot` → `round.ps1` 自动恢复 → 全流程 | **28 次**；76.5 s 到全绿（见 §18） |

### 17.2 试错 / 失败方案（含被推翻的假设）

| # | 错误假设或做法 | 怎么发现 | 怎么改 |
|---|---|---|---|
| 1 | “App 拿不到 root 必须刷 boot” | 用错 uid（10123，不是 Droidspaces 的 10330）测 `su` | 用真实 appId 10330 + `su_compat=1` → App 可用，假设推翻 |
| 2 | “`UAPI=0` 是 ksud 版本太新” | 换 ko 后仍 0 | 实为内核侧 `kernelsu` 没加载；走 `libksud.so late-load` → UAPI=2 |
| 3 | “`ksud services` 会在 late-load 后重跑模块脚本” | 日志行数不变 | 不会；必须自己 `sh service.sh`（两段式） |
| 4 | late-load 与后续 `su` 放同一个脚本 | 下一次 `su` 阻塞 ~175 s、PATH 全丢 | 拆成两次独立 `su`，并轮询 `su -c 'id -u'` |
| 5 | 关闭 `su_compat` 只影响 App | 关闭后 shell 的 `su` 一起消失，测试锁死 | 同一 root 会话内“关→测→开”，并写入自动流程 |
| 6 | zip 可以带一层目录 | `ksud module install` → `specified file not found in archive` | `module.prop` 必须在根目录（本轮已按此重打包） |
| 7 | 装完即可用 | 曾产出 10 MB 全零 ko → `insmod: Exec format error` | 装完必须 `sha256sum` 比对 |
| 8 | PowerShell 直接 `adb shell "su -c '… \| …'"` | 引号被吞、`\|` 变管道、`$?` 被 PowerShell 求值成 `True` | 一律写设备侧 `.sh` push 后执行 |
| 9 | “`/proc/kallsyms` 在 `kptr_restrict=2` 下查不到导出符号” | 本机实测 9794 个 `__ksymtab_*` 可读 | 用 `__ksymtab_<sym>` 判定导出（本轮 6 项判定靠它） |
| 10 | “VirGL 装个包就行” | Termux `$PREFIX` 无 virgl 二进制、apt lists 空 | 关 `enable_virgl`，Anland/GPU 优先 |
| 11 | “macvlan / ip6nat / devtmpfs 都能树外补绿” | 三个 ko 都能编出，但 `insmod` 全 ENOENT | 逐个核对未导出符号（17/7/17）→ **全部硬限制**，判断推翻 |
| 12 | “plasma 开机自动起就行” | 容器 boot 时 21 s 后 `status=0` 退出，kwin crash-loop | 单元加 `ExecStartPre sleep 20` + `Restart=always` |
| 13 | “`ls -t *.sock \| head -1` 能拿当前 socket” | 新版 socket 明明存在却拿到空/旧值，App 连上 0.5 s 即断、屏幕黑 | 改为读 anland 日志最后一条 `listening on`（SELinux 不让 `ls -t` 做 stat） |
| 14 | “Anland 黑屏 = 显示坏了” | 截图 21 KB 全黑、`mWakefulness=Asleep` | 只是平板息屏；`svc power stayon true` + `KEYCODE_WAKEUP` 后恢复 |
| 15 | “容器 start 完就能截图” | 只有壁纸、没有图标/任务栏 | plasmashell 要 ~40–70 s 才画全，验收脚本需等待 |

### 17.3 仍未解决（清单）

1. **6 项 `check` ✗ 全为内核配置硬限制**：devtmpfs / Macvlan / IPv6 NAT / CPU limit / Process limit / Sandboxing ——
   树外 KO 不可行，必须刷带对应 `CONFIG_*` 的内核（逐项符号证据见 §15）。
2. **未归因复位根因**：6 次中后 3 次与 `su_compat=0` + `reroot.sh` 相关，但脚本内无 `reboot`；
   `su_compat=1` 下未复现。
3. **`stop` 不回收容器 user session 进程**：kwin/plasmashell/dbus/systemd-networkd 会成为孤儿并挂在原 cgroup，
   导致下一次 `start` 报 `[CGROUP] left over`；只能由 `ds_start.sh` 外部清理（本内核无 `cgroup.kill`）。
4. **Anland 依赖显式拉起 App**：容器 `stop/start` 后 socket 名会变，必须重新 `am start --es socket_path`；
   平板息屏会断开 consumer。
5. **Termux VirGL 未安装**（不是必须，已由 Anland 取代）。
6. **`/proc/<pid>/ns/pid|ipc` 缺失**：宿主 `CONFIG_PID_NS=n`，procfs 条目本就不存在，模块无法凭空造。

---

## 18. 最后一轮干净验收（原始输出）

设备：`11:04:13 adb reboot` → `round.ps1` 自动恢复（提权 / KSU late-load / `su_compat=1` / 模块已由
`service.sh` 自加载）→ **76.5 s 后 `CHECK_OK`**。随后 `final_accept.sh`（11:04:48 起）：

```
== date/uptime ==
Fri Nov  6 11:04:48 CST 2026
647.48 3683.05
== 模块 ==
droid_lkm 786432 2 - Live 0x0000000000000000 (O)
kernelsu 200704 1 - Live 0x0000000000000000 (O)
== KSU 模块作者 / module.prop ==
id=droidspaces_shim
name=Droidspaces Kernel Shim
version=1.1 (android12-5.10 / 5.10.236-dizi)
versionCode=2
author=默默的阿文
description=Loads droid_lkm.ko at boot so Droidspaces sees PID/IPC namespace + SysV IPC. The module pins itself, so disabling means deleting the module dir and rebooting.
-- service.sh sha（应与仓库 ksu/service.sh 一致：75e0dd0f…）--
75e0dd0f0c8f738ca45b7347450e35cb9de65b1c1c9703edaa232f0bdff91f55  /data/adb/modules/droidspaces_shim/service.sh
-- ko sha（必须 b710cca3…）--
b710cca34249c6cf8b215b61c29ca9aa2e3be6919c9aac3123c1dabecc1603a5  /data/adb/modules/droidspaces_shim/droid_lkm.ko
== ksud module list 本模块条目 ==
{ "versionCode": "2", "enabled": "true", "action": "false", "mount": "false",
  "author": "默默的阿文", "id": "droidspaces_shim", "web": "false",
  "name": "Droidspaces Kernel Shim", "remove": "false", "update": "false",
  "version": "1.1 (android12-5.10 / 5.10.236-dizi)" }
== su_compat ==
Feature: su_compat (0)
Value: 1
Status: enabled
== check（完整原文，摘要） ==
[MUST HAVE]  Root privileges / Linux version / PID namespace / Mount namespace / UTS namespace /
             IPC namespace / pivot_root / /proc / /sys / Seccomp          → 10/10 ✓
[RECOMMENDED] epoll / signalfd / PTY / devpts / Loop / ext4 / Cgroup v2 / Cgroup ns → 8/8 ✓
              devtmpfs support                                        → ✗（硬限制，见 §15）
[OPTIONAL]   FUSE / TUN-TAP / OverlayFS / Net ns / Bridge / Veth / Memory / Swap /
             CPU accounting                                           → 9/9 ✓
             Macvlan / IPv6 NAT / CPU limit / Process limit / Sandboxing → ✗（硬限制，见 §15）
Summary: [✓] All required features found!
== start（ds_start.sh 预清理 + start） ==
Container: UBUNTU26 (RUNNING)  PID: 32191  OS: Ubuntu 26.04 LTS
  Networking: NAT / NAT IP 172.28.106.33 / Disable IPv6: yes
  Android storage: enabled / HW access: GPU / Anland: enabled / SELinux: Enforcing
== 本次 start 的告警行（空=无 [!]/[CGROUP]/VirGL/Hardware） ==
（空）
== ds_start 清理记录 ==
[10:49:55] pass 1 killed=32 exists=0
[10:57:33] pass 1 killed=22 exists=0
[11:04:52] pass 1 killed=36 exists=1
[11:04:53] pass 2 killed=5  exists=0
== anland socket / 容器内 plasma ==
srw-rw-rw- 1 root root 0 2026-11-06 11:04 anland-5e202eaa74b1998d04419b497fdcf820.sock
active
srw-rw-rw-+ 1 root root 0 Nov  6 11:04 /run/display.sock
  227 /usr/bin/kwin_wayland_wrapper --xwayland
  240 /usr/bin/kwin_wayland --wayland-fd 7 --socket wayland-0 --xwayland-fd 8 …
== stop 测试（复位与否） ==
[+] Stopping container 'UBUNTU26' (PID 32191)...
[+] Container 'UBUNTU26' stopped.
uptime_before=693.45 uptime_after=737.25 delta=44s
-- stop 后模块 --
droid_lkm 786432 2 - Live 0x0000000000000000 (O)
== 再 start（留运行态） ==
Anland: enabled / HW access: GPU / Container 'UBUNTU26' is running in background.
-- 告警行（空=无）--
（空）
-- plasma --
active
srw-rw-rw-+ 1 root root 0 Nov  6 11:06 /run/display.sock
== 拉起 Anland App ==
SOCK=/data/local/Droidspaces/Net/anland-a275f4c2d9e665ae6d5b50173f6096c9.sock
== anland log tail ==
[11:06:19] listening on …/anland-a275f4c2d9e665ae6d5b50173f6096c9.sock
[11:06:41] producer connected
[11:07:01] consumer connected
[11:07:01] consumer deposited 5 fds
[11:07:01] screen info 1600x2560 fmt=1
[11:07:01] fds delivered to producer
== 最终 check ==
Summary: [✓] All required features found!
```

截图（11:08，`docs/anland-desktop.png`）：KDE 桌面 + 22 个图标 + 底部任务栏 + 时钟 `11:08 2026/11/6`；
`docs/anland-interaction.png`：`input tap` 点开 Konsole，窗口与菜单栏渲染正常。


## 19. 交付版缺陷修复：启动慢/报错、stop 慢、kwin_wayland 孤儿（2026-11-09）

老板实测反馈（原话）：

> 平板目前功能还是比较正常的就是有个很严肃的问题，Droidspaces 启动的时候很慢，有报错，关闭的时候也很慢，
> 然后一但使用 anland 过后，我关闭了容器进程里面就有一个 KWIN_WAYLAND 你疯狂持续高占用 CPU，居然没有
> 一起关闭，这是一个严重的 BUG，需要马上修复！

本轮定位到 droidspaces 已升到 **v7.2.0**（上一轮验收的是 7.1.0），新增常驻 `ds-zap` helper（kthread，
ppid=2），会收养容器退出后的孤儿进程 —— 这是问题 3 的直接放大器。**本轮只改脚本与配置层，`
droid_lkm.ko` 未重编、未替换，sha256 仍是 `b710cca3…`。**

### 19.1 问题 3：kwin_wayland 孤儿（最严重，优先修）

**现场证据（`stop` 之后立刻抓）**

```
kwin_wayland  PID 19331  utime+stime 32895 → 33405 ticks / 5 s   ≈ 102% CPU
父链：kwin_wayland(19331) → kwin_wayland_wrapper(19319) → systemd(19137) → ds-zap(15798) → kthreadd(2)
cgroup：/sys/fs/cgroup/droidspaces/UBUNTU26/… 内仍有 172 个进程
systemd --user：8 代（etime 2–21 h），全部挂着没退
`droidspaces show`：已经显示 “No containers running”
```

即：容器“已经关了”，但 kwin_wayland 还在 Anland socket 上空转烧一个核。

**根因**

1. 内核 `CONFIG_PID_NS=n`，`droid_lkm` 只能以 `no_teardown=1` 运行 —— 容器 PID1 退出时，内核**不会**
   回收该 pid 命名空间的其余进程（改 `no_teardown=0` 会走 `find_child_reaper` BUG，不能动）。
2. v7.2.0 的 `ds-zap` 把孤儿收养过来，进程于是**继续活着**，而不是被 init 收尸。
3. `droidspaces stop` 的可执行文件只 kill 容器 init，然后**等** pidns 自然清空 → 等不到就超时，
   残余进程原地留下。

**修法（三层）**

| 层 | 文件 | 做法 |
|---|---|---|
| CLI 快速路径 | `tools/ds_stop.sh` | 直接 `kill -9` cgroup 内**全部**进程（含 init）→ 调一次 `droidspaces stop` 做元数据/网络收尾 → 轮询等 NAT/veth/anland 拆完 → **按父链兜底**（ppid=ds-zap 的孤儿）→ 递归 `rmdir` cgroup（5.10 无 `cgroup.kill`）→ 零残留校验并输出 `RESULT=ZERO_LEAK` |
| App 路径兜底 | `ksu/orphan_watch.sh` + `ksu/service.sh` 第 8 步 | 常驻看门狗，3 s 扫一次 `/sys/fs/cgroup/droidspaces/*`；判定“cgroup 里还有进程、但已经没有 NSpid 末位=1 的 init，且此前见过 init” → `kill -9` + 递归 `rmdir`。这样不论在 App 里点 Stop 还是命令行 stop，都会在数秒内清干净 |
| 防复发 | `tools/ds_start.sh` | start 前先预清理残留 cgroup（顺带消掉 `[CGROUP] left over`） |

> 看门狗只在“曾经真正起来过 init”的容器上动手（靠 `/data/local/tmp/.wd/<name>` marker），
> 避免和刚创建的 cgroup 抢时序；空 cgroup 且目录 mtime >5 s 才删。

### 19.2 问题 2：stop 慢

**原始时间线（修复前，`/data/local/Droidspaces/Logs/UBUNTU26/log`）**

```
Stopping container 'UBUNTU26' (PID …)...
[Anland] terminating ...
[IPT] remove_ds_rules: iptables/ip6tables
[IPT] ip6tables get_table('nat') GET_INFO failed: No such file or directory
        ← 空档 5.16 s
[+] Container 'UBUNTU26' stopped.
```

实测整条 stop **29.4 s**，且留下 172 个孤儿（问题 3）。

**那 15 s 卡在哪**

卡在“停掉 init 之后等 pidns 排空”。因为 `no_teardown=1` 内核永远不会替我们回收，只能等超时。
剩下的固定 ~5 s 来自 `ip6tables ... nat` 表不存在（内核 `CONFIG_IP6_NF_NAT=n`，见 §15），
`get_table` 失败后 droidspaces 内部固定等待 —— **脚本层无法消除**。

**是否必须 graceful**

不必须。本内核下“优雅关闭”实际只是杀 init + 干等，既不会通知 user session，也不会回收进程。
改成快速路径（先杀干净再让 droidspaces 收尾）后语义等价，且不再有 15 s 干等。

**修复后实测（5 轮，`stop+0s` / `stop+30s` 都查）**

| 轮 | stop 耗时 | RESULT | +0 s | +30 s |
|---|---|---|---|---|
| 1 | **3.43 s** | ZERO_LEAK | kwin/plasma/cgroup/nat/veth 全 0 | 全 0 |
| 2 | **2.81 s** | ZERO_LEAK | 全 0 | 全 0 |
| 3 | **3.07 s** | ZERO_LEAK | 全 0 | 全 0 |
| 4 | **2.77 s** | ZERO_LEAK | 全 0 | 全 0 |
| 5 | **3.11 s** | ZERO_LEAK | 全 0 | 全 0 |

拆段（第 1 轮）：`cgroup 枚举 1.61 s` → `KILL 全部 0.11 s` → `droidspaces stop 0.06 s` →
`网络拆完 1.08 s` → `兜底 0.29 s`。

**App 路径（原生 `droidspaces stop`，不走包装器）**

原生 stop **5.20 s** 返回（看门狗在 init 死后 ≤3 s 内清掉 41 个进程，stop 因此提前结束），
`+0 s / +5 s / +30 s` 三次快照：kwin=0、plasmashell=0、cgroup=0、nat=0、veth=0。
看门狗日志：

```
[2026-11-09 23:06:42] LEAK cgroup=UBUNTU26 procs=41 -> kill+rmdir
[2026-11-09 23:06:44]   after: cgroup_exists=0 procs=0
```

### 19.3 问题 1：启动慢 + 有报错

**`[!]` / `[-]` 逐条定性**

| 原始行 | 定性 | 处置 |
|---|---|---|
| `[!] VirGL: server binary not found at /data/data/com.termux/files/usr/bin/virgl_test_server_android - skipping start` | 环境问题（Termux 没装 virglrenderer），可修 | `container.config` 置 `enable_virgl=0`，已消除 |
| `[!] VirGL: socket not found at /.old_root/…/.virgl_test - skipping socket bridge` | 同上，连锁行 | 同上，已消除 |
| `[!] Hardware access disabled`（旧） | 配置问题，可修 | `enable_gpu_mode=1` 后变为 `[+] Setting up GPU-only access...` + `[GPU] Mirrored node: …`，已消除 |
| `[!] [CGROUP] left over …` | 上次 stop 的残留，可修 | `ds_start.sh` 预清理后不再出现 |
| `[-] [IPT] ip6tables get_table('nat') GET_INFO failed: No such file or directory` | **内核编译期硬限制**（`CONFIG_IP6_NF_NAT=n`），不能修 | 保留；代价是原生 stop 内部固定 ~5 s，见 §15 |
| `check` 里 6 项 ✗（devtmpfs / Macvlan / IPv6 NAT / CPU limit / Process limit / Sandboxing） | **内核编译期硬限制**，不能修 | 不动，见 §15 |

修复后连续 5 轮 start 的 `[!]`/`[-]` 计数：**0**。

**启动慢的拆段计时（5 轮，单位 s）**

| 轮 | T1 start 返回 | T2 socket 就绪 | T3 拉起 consumer | T4 fds 送达 producer | T5 plasmashell（桌面可用） |
|---|---|---|---|---|---|
| 1 | 0.23 | 0.30 | 0.47 | 3.05 | **3.91** |
| 2 | 0.29 | 0.37 | 0.82 | 3.79 | **4.74** |
| 3 | 0.24 | 0.33 | 0.80 | 3.76 | **4.31** |
| 4 | 0.27 | 0.35 | 0.82 | 3.77 | **4.70** |
| 5 | 0.28 | 0.36 | 0.83 | 3.72 | **4.64** |

结论：容器创建/挂载/网络/GPU **0.23–0.29 s**；Anland socket 就绪 +0.07–0.08 s；
最慢一段是 **T3→T4 的 2.2–3.0 s**，即 `com.anland.consumer` 冷启动后连 socket 并交付 5 个 fd
（`am force-stop` → `am start` → Activity 启动 → 连接），属 Android App 冷启动成本，脚本层已无优化空间；
T4→T5 只有 0.86–0.95 s。

**修法**

1. `plasma-wayland.service` 去掉 `ExecStartPre=/bin/sleep 20`（这是自伤：每次白等 20 s，期间 kwin 根本没起），
   改 `Restart=always` + `RestartSec=2` + `KillMode=control-group` + `TimeoutStopSec=5`。
2. `container.config`：`enable_virgl=1 → 0`（Termux 无 virglrenderer），`enable_x11` **未动**（仍为 0）。
3. `ds_start.sh`：socket 一就绪就 `am force-stop com.anland.consumer` 再用 `--es socket_path` 拉起，
   等 `fds delivered to producer` 与 `plasmashell`，全程分段计时。
4. 备份：`container.config.preFix2.bak`、`plasma-wayland.service.preFix2.bak`。

### 19.4 前后对照（总）

| 指标 | 修复前 | 修复后 |
|---|---|---|
| start → 桌面可用 | ≥20 s（`sleep 20`），且经常起不来 | **3.91–4.74 s**（5/5 成功） |
| start 的 `[!]`/`[-]` | VirGL ×2、Hardware ×1、CGROUP ×1 | **0** |
| stop（CLI） | **29.4 s**，留 172 个孤儿 | **2.77–3.43 s**，0 残留 |
| stop（App / 原生） | ~30 s，kwin 孤儿持续 100% CPU | **5.20 s**，看门狗 ≤3 s 清空 |
| stop 后 kwin_wayland | 存活，75.7–102% CPU | **不存在**（+0 s / +30 s 均为 0） |
| stop 后 cgroup | 172 进程残留 | **0**，目录已删 |

### 19.5 闭环验收（Anland 必须仍可用）

```
起容器 → 等桌面完全出来 → 长按交互 → stop → 30 s 复查
stop 前：kwin_wayland 15.3% / plasmashell 16.4%
stop：3.26 s，RESULT=ZERO_LEAK
+30 s：显示栈 无 / NAT 无 / veth 无 / cgroup procs 0 / ds-zap 子进程 0
```

截图：`docs/anland-desktop-r21.png`（KDE 壁纸 + 顶部面板时钟 23:11 + 托盘）、
`docs/anland-interaction-r21.png`（长按后 Fcitx「Wayland 诊断」通知 + 底部任务栏 + 时钟 23:12 2026/11/9）。

### 19.6 本轮产物 sha256

```
droid_lkm.ko（未重编，必须不变）  b710cca34249c6cf8b215b61c29ca9aa2e3be6919c9aac3123c1dabecc1603a5
ksu/service.sh                   7920232ae0d201ddd291be6681a7cca5db713c74fc8186ec8f30935eea992e8b
ksu/orphan_watch.sh              24bc3e8fa21f0f19029cc5b3496b0ceb0614d6ebd9dea097bc7cabf709a6d09f
tools/ds_start.sh                1b40674cee52aa76b4d2eadfda2d91be058d2fbba93ed82a91b61c6b97ee5fa8
tools/ds_stop.sh                 e7bae99caf6bba75ba279992e0c560aedaeaf39df38083d2d2f4cab2c3864d8d
prebuilt/droidspaces_shim-1.1.zip c45bf93d68ff6a933614b295be294abf426d4297d147b9e99a67cc7647257bf6
```

### 19.7 仍未解决（如实记录）

1. **`ip6tables nat` 缺失**（`CONFIG_IP6_NF_NAT=n`）：原生 stop 内部固定 ~5 s，脚本层无法消除；
   要消掉只能换带该 CONFIG 的内核，超出本轮“只改脚本/配置”的边界。
2. **`check` 剩余 6 项 ✗**：devtmpfs / Macvlan / IPv6 NAT / CPU limit / Process limit / Sandboxing，
   全部内核编译期硬限制，判定见 §15。
3. **`su` 域漂移**：`su -c` 偶尔落到 `u:r:shell:s0`（uid 仍是 0），此时 `droidspaces` 会
   `can't execute: Permission denied`、`kill` 被拒。两个脚本已加 `id -u` + `attr/current` 守卫并
   `exit 2/3`，宁可报错也不静默“成功”；重开 root 会话即可。
4. **App 的 Stop 按钮路径** 由看门狗兜底（已用原生 `droidspaces stop` 等价验证），
   但没有用真实手指点 App 按钮复测 —— 记录为“等价路径验证通过，未做真机点按”。

### 19.8 回滚

- 配置：`cp container.config.preFix2.bak container.config`；
  `cp /etc/systemd/system/plasma-wayland.service.preFix2.bak /etc/systemd/system/plasma-wayland.service`
- 看门狗：`kill $(pgrep -f orphan_watch.sh)`，并删 `ksu` 模块里的 `orphan_watch.sh`（或整目录 + 重启）。
- 脚本层完全可逆，不涉及 ko / boot / 分区。

### 19.9 重启次数

**本轮 0 次。** 全部验证靠 `stop` + `start` 完成；ko 未动，模块文件用 `cp` 直接落到
`/data/adb/modules/droidspaces_shim/` 并手动 `nohup` 起看门狗（免重启生效）。
累计仍为 **28 次**（§17）。

## License

GPL-2.0（随上游 `Dere3046/_patchHarmony`）。本仓库的修改同样以 GPL-2.0 发布。
