#!/usr/bin/env python3
# B18: replace kernel disable_pid_allocation() call with a BTF-offset write.
import sys

P = "/home/ubuntu/ph/src/main/pidns/pidns.c"
s = open(P, encoding="utf-8").read()
orig = s

anchor = 'MODULE_PARM_DESC(skip_disable_alloc, "B17: skip disable_pid_allocation call, 1 = skip");\n'
if anchor not in s:
    print("FAIL: skip anchor"); sys.exit(2)
add = '''
/* B18：disable_pid_allocation 的两种实现；1 = 按 BTF 真实偏移直写（默认），0 = 调内核函数 */
static unsigned int droid_lkm_disable_alloc_mode = 1;
module_param_named(disable_alloc_mode, droid_lkm_disable_alloc_mode, uint, 0644);
MODULE_PARM_DESC(disable_alloc_mode, "B18: 1 = BTF write pid_allocated (default), 0 = call kernel disable_pid_allocation");
'''
if "disable_alloc_mode" not in s:
    s = s.replace(anchor, anchor + add, 1)

old = '''	if (self_reaper) {
		droid_lkm_info("BR08 disable_alloc before alloc=0x%08x fn=%px skip=%d\\n",
			       droid_lkm_pidns_pid_allocated(ns),
			       (void *)droid_lkm_ks.disable_pid_allocation,
			       (int)droid_lkm_skip_disable_alloc);
		droid_lkm_maybe_stall(8);
		if (!droid_lkm_skip_disable_alloc)
			droid_lkm_ks.disable_pid_allocation(ns);
		droid_lkm_info("BR09 disable_alloc after alloc=0x%08x\\n",
			       droid_lkm_pidns_pid_allocated(ns));
	}
'''
new = '''	if (self_reaper) {
		unsigned int al = droid_lkm_pidns_pid_allocated(ns);

		droid_lkm_info("BR08 disable_alloc before alloc=0x%08x fn=%px skip=%d mode=%u\\n",
			       al, (void *)droid_lkm_ks.disable_pid_allocation,
			       (int)droid_lkm_skip_disable_alloc,
			       droid_lkm_disable_alloc_mode);
		droid_lkm_maybe_stall(8);
		if (droid_lkm_skip_disable_alloc) {
			/* B17 验证用：什么都不做 */
		} else if (droid_lkm_disable_alloc_mode == 0) {
			droid_lkm_ks.disable_pid_allocation(ns);
		} else {
			/*
			 * B18：不调用内核函数，按 BTF 得到的真实偏移直写
			 * pid_allocated，语义等价于 disable_pid_allocation(ns)
			 * 的 ns->pid_allocated &= ~PIDNS_ADDING。
			 */
			droid_lkm_pidns_set_pid_allocated(ns,
				al & ~((unsigned int)PIDNS_ADDING));
		}
		droid_lkm_info("BR09 disable_alloc after alloc=0x%08x\\n",
			       droid_lkm_pidns_pid_allocated(ns));
	}
'''
if old not in s:
    print("FAIL: BR08 block"); sys.exit(3)
s = s.replace(old, new, 1)

if s == orig:
    print("NOCHANGE"); sys.exit(4)
open(P, "w", encoding="utf-8").write(s)
print("OK b18 patched")
