#!/usr/bin/env python3
# B17 patch: stall point 8 between BR08 and disable_pid_allocation,
#            skip_disable_alloc param, print resolved fn address.
import sys

P = "/home/ubuntu/ph/src/main/pidns/pidns.c"
s = open(P, encoding="utf-8").read()
orig = s

# 1) param after stall_ms MODULE_PARM_DESC
anchor = 'MODULE_PARM_DESC(stall_ms, "B14 bisect stall length in ms, 0 = off");\n'
if anchor not in s:
    print("FAIL: stall_ms anchor not found"); sys.exit(2)
ins = anchor + '''
/* B17：跳过 disable_pid_allocation 调用，验证它是否就是复位触发点 */
static bool droid_lkm_skip_disable_alloc;
module_param_named(skip_disable_alloc, droid_lkm_skip_disable_alloc, bool, 0644);
MODULE_PARM_DESC(skip_disable_alloc, "B17: skip disable_pid_allocation call, 1 = skip");
'''
if "skip_disable_alloc" not in s:
    s = s.replace(anchor, ins, 1)

# 2) BR08 block
old = '''	if (self_reaper) {
		droid_lkm_info("BR08 disable_alloc before alloc=0x%08x\\n",
			       droid_lkm_pidns_pid_allocated(ns));
		droid_lkm_ks.disable_pid_allocation(ns);
		droid_lkm_info("BR09 disable_alloc after alloc=0x%08x\\n",
			       droid_lkm_pidns_pid_allocated(ns));
	}
'''
new = '''	if (self_reaper) {
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
if old not in s:
    print("FAIL: BR08 block anchor not found"); sys.exit(3)
s = s.replace(old, new, 1)

# 3) stall comment: add point 8
c_old = " *              4 = disable_pid_allocation(BR09) 之后；5 = no_teardown 返回前。\n"
c_new = (" *              4 = disable_pid_allocation(BR09) 之后；5 = no_teardown 返回前；\n"
         " *              8 = BR08 之后、disable_pid_allocation 调用之前（B17）。\n")
if c_old in s:
    s = s.replace(c_old, c_new, 1)

if s == orig:
    print("NOCHANGE"); sys.exit(4)
open(P, "w", encoding="utf-8").write(s)
print("OK patched")
