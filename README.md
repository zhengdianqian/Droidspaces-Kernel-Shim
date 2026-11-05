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

### 5.1 标准方式（管理器 / ksud）

```
su -c '/data/adb/ksud module install droidspaces_shim-1.1.zip'
```

> 本机实测 `ksud` 报 `UAPI version mismatch: kernel=0, ksud=2`，故改用 5.2。

### 5.2 手工安装（等价落盘）

```
adb push droid_lkm.ko service.sh module.prop README.md /data/local/tmp/shim/
su -c 'mkdir -p /data/adb/modules/droidspaces_shim
       cp -f /data/local/tmp/shim/* /data/adb/modules/droidspaces_shim/
       chmod 755 /data/adb/modules/droidspaces_shim/service.sh
       chmod 644 /data/adb/modules/droidspaces_shim/droid_lkm.ko'
# 重启，service.sh 在 late_start 自动 insmod
```

`service.sh` 有四道前置校验：`/proc/modules` 可读、未重复加载、
`uname -r` 逐字节一致、`sha256` 一致；任何一条不过 → 记日志并 `exit 0`（绝不注错版本）。

### 5.3 验证

```
su -c 'grep droid_lkm /proc/modules'
su -c 'cat /data/adb/droidspaces_shim.log'
su -c 'cat /proc/droid_lkm/features'
```

### 5.4 开机自动加载：本机实测结论（重要）

**实测：手工落盘到 `/data/adb/modules/droidspaces_shim/` 后重启，`service.sh` 未被任何进程执行**
（`/data/adb/droidspaces_shim.log` 根本不存在，`/proc/modules` 里也没有 `droid_lkm`）。

根因：本机内核侧 KSU 没有对外暴露 UAPI（`ksud` 报 `UAPI version mismatch: kernel=0, ksud=2`），
`ksud` 在 `late-load` 段也直接失败（`reroot.sh` 日志里是 `[*] ksud late-load ...` → `timeout: exec : No such file or directory`），
因此 **KSU 的模块脚本执行链在本机整体不工作**。这不是本模块的问题，换任何模块都一样。

三种兜底（按优先级）：

1. **提权后立即 insmod（本机实际采用）**：
   每次重启先跑 `rpproot_re/reroot.sh` 拿到 root，随后执行
   ```
   su -c 'insmod /data/adb/modules/droidspaces_shim/droid_lkm.ko route=2 skip_sysvipc=0 gate=1 degrade=1 verbose=1 zap_guard=1 reaper_fix=1 tick_ms=0 no_teardown=1 skip_disable_alloc=0 disable_alloc_mode=1'
   ```
   本仓库 `auto/round.ps1` 就是这条路径的自动化版本（实测复位后 21 s 内完成"上线→提权→可用"）。
2. **`/data/adb/service.d/` 兜底**：已提供 `ksu/service_d_droidspaces_shim.sh`
   （逻辑与 `service.sh` 完全一致，只是写死 `KO` 路径）。若将来 KSU 内核侧恢复正常，这条会随 `service.d` 一起被拉起。
3. **真正要"开机即加载"**：需要内核侧带 KernelSU（UAPI ≥ 2）的 boot 镜像；纯 exploit root 的机型无法做到零人工自动加载。

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
| 19 | `ksud module install` 失败：`UAPI version mismatch kernel=0, ksud=2` | 内核侧 KSU 与 CLI 版本不匹配 | 手工模块目录安装（见 5.2） |
| 20 | `adb push` 写 `/data/adb/modules` 报 Permission denied | adb shell 是普通用户 | push 到 `/data/local/tmp`，再 `su -c cp` |
| 21 | 调用 `disable_pid_allocation` 秒复位、无日志 | CFI（`CONFIG_CFI_CLANG=y`）+ 未导出符号间接调用 | 改 BTF 直写（`disable_alloc_mode=1`） |
| 22 | `unshare --pid` 返回 `Invalid argument` | `CONFIG_PID_NS=n` 的预期行为 | 作为**通过**判据（且不得复位） |
| 23 | 模块落盘到 `/data/adb/modules/` 后重启，`service.sh` 完全没执行（日志文件都不存在） | 本机内核侧 KSU UAPI=0，`ksud` 的 `late-load` 段直接失败，模块脚本执行链整体不工作 | 提权后手动/脚本 `insmod`（见 5.4）；另放 `service.d` 兜底 |
| 24 | `adb shell 'su -c "cmd1; cmd2"'` 里第二条命令掉回 `shell` 域（`/proc/self/attr/current` = `u:r:shell:s0`，且报 `Permission denied`） | adb shell 传参 + 多层引号被外层 shell 提前切分 | 一条 `adb shell` 只放**一条** `su -c` 命令，或把逻辑写成 `.sh` push 到设备执行 |
| 25 | `stop` 后立刻 `start` 报 `another operation is in progress on this container` | droidspaces 的停止是异步收尾，前一次 stop 尚未完成 | 脚本里先 `sleep 15~20`，再用 `droidspaces -n <name> pid` 轮询确认，最多重试 60 s |
| 26 | `ipcmk` 输出是 `Shared memory id: 0`（不是 `id=0`） | 解析正则假设错误，`ipcrm` 拿到空参数 → rc=1 | 从 `ipcs -m` 的第 2 列取真实 id 再 `ipcrm`；实测 id 恒为 0 |

---

## 9. 无人值守运维（复位后自恢复）

`auto/round.ps1`：

1. 轮询 `adb devices`，等 `sys.boot_completed=1`；
2. `su -c id` 失败 → 跑 `rpproot_re/reroot.sh`（无线 ADB token 提权，`--borno` 需 |Δt| ≤ 301 s）；
3. **`Ensure-Module`**：`/proc/modules` 里没有 `droid_lkm` 就自动 `insmod`（本机 KSU 不会开机加载，见 5.4）；
4. 断点写入 `/data/local/tmp/auto_state`；
5. 每轮把 `/data/local/tmp` 的 `kB*.log`、`state`、`ds_start/stop*.log` 拉回 `auto/logs/<轮次>/`。

实测：复位→设备上线（uptime=22.25）→自动提权（`ROOT_RESTORED uid=0(root)`）→模块加载，
全程 **22 s**，无需人工。**不使用一键 root BAT**（其内含分区写入，违反"不刷机 / 不写分区"约束）。

---

## 10. 已知限制

1. **临时 root**：本机 root 由 RPPROOT 经无线 ADB 获取，每次重启需 `reroot.sh` 重跑；KSU 的 `late-load` 段在本机报 `SU=` 为空（不影响 `su -c id` 为 uid=0）。
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
