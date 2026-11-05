# droidspaces_shim

在开机（late_start）阶段自动 `insmod droid_lkm.ko`，让 Droidspaces 在
`5.10.236-android12-9-00003-gfb24cf99ad97-ab14313284`（Redmi Pad Pro / dizi）上
看到 PID/IPC namespace 与 SysV IPC。

## 语义
- 装了模块 = 开机自动生效。
- 删掉 `/data/adb/modules/droidspaces_shim` + 重启 = 关闭。
- 没有 WebUI、没有开关。

## 文件
- `module.prop` 模块信息
- `service.sh` 加载脚本（带版本 / sha256 / 已加载 三重守卫）
- `droid_lkm.ko` 内核模块（sha256 `4ef26daf…65196`）

## 日志
`/data/adb/droidspaces_shim.log`

每行 `[时间] [service] ...`，常见内容：
- `skip: kernel mismatch (...)` 系统更新过，版本对不上，未加载（正确行为）
- `skip: droid_lkm already loaded` 已经加载过
- `skip: sha256 mismatch (...)` 文件被改过
- `insmod FAILED rc=... : ...` 加载失败，冒号后是内核返回的错误
- `loaded: ... / features: ...` 成功

## 验证是否生效
```
su -c 'grep droid_lkm /proc/modules'
su -c 'head -6 /proc/droid_lkm/features'
```

## 注意
droid_lkm 会 `try_module_get(THIS_MODULE)` 永久自锁，**`rmmod` 一定失败（-EBUSY）**。
所以关闭只能“删目录 + 重启”；当前这一轮里模块仍在内存中，删了目录也不会立刻消失。
