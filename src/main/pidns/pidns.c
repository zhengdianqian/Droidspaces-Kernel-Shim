// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (C) 2026 dere3046
 */

#include <linux/pid.h>
#include <linux/pid_namespace.h>
#include <linux/ns_common.h>
#include <linux/nsproxy.h>
#include <linux/proc_ns.h>
#include <linux/module.h>
#include <linux/sched.h>
#include <linux/sched/signal.h>
#include <linux/sched/task.h>
#include <linux/slab.h>
#include <linux/idr.h>
#include <linux/kthread.h>
#include <linux/jiffies.h>
#include <linux/delay.h>
#include <linux/capability.h>
#include <linux/cred.h>
#include <linux/user_namespace.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <linux/rcupdate.h>
#include <linux/wait.h>
#include <uapi/linux/wait.h>
#include <linux/reboot.h>
#include <linux/signal.h>
#include <linux/sysctl.h>
#include <linux/namei.h>
#include <linux/path.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/string.h>

#include "ds.h"
#ifdef DROID_LKM_NATIVE_PID
#include "native_pid.h"
#include "compat/nsproxy.h"
#endif
#include "ds_shapes.h"
#include "ds_ksym.h"
#include "ds_ipcns.h"
#include "ds_nsops.h"

/* for_each_process_thread embeds &init_task, a trimmed image may not export it */
#define droid_lkm_for_each_process_thread(p, t)				\
	for ((p) = droid_lkm_ks.init_task;				\
	     ((p) = droid_lkm_next_task(p)) != droid_lkm_ks.init_task; )	\
		for ((t) = (p); (t); (t) = NULL)
#include "ds_pidns.h"
#include "ipc_sysctl.h"

bool droid_lkm_task_ipc_exit_defer(struct task_struct *tsk);
void droid_lkm_task_ipc_deferred_run(void);
bool droid_lkm_task_ipc_deferred_pending(void);

static struct kmem_cache *droid_lkm_pidns_cachep;

static const struct proc_ns_operations *droid_lkm_pidns_neutral_ops;

static struct task_struct *droid_lkm_pidns_retire_reaper;

#if defined(DROID_LKM_NATIVE_PID) && !defined(DROID_LKM_PID_BOTH)
#define DROID_LKM_PID_DEFAULT "native"
#else
#define DROID_LKM_PID_DEFAULT "main"
#endif
static char droid_lkm_pid_impl[8] = DROID_LKM_PID_DEFAULT;
module_param_string(pid_impl, droid_lkm_pid_impl, sizeof(droid_lkm_pid_impl), 0444);
MODULE_PARM_DESC(pid_impl, "pid namespace backend: main or native");
static bool droid_lkm_pid_use_native;
static bool droid_lkm_nsproxy_enable;
module_param_named(nsproxy, droid_lkm_nsproxy_enable, bool, 0444);
MODULE_PARM_DESC(nsproxy, "take over nsproxy lifecycle, default 0");
bool droid_lkm_pidns_nsproxy_enabled(void) { return droid_lkm_nsproxy_enable; }

/*
 * pin_kref=1（默认）：create 成功后对假 ns 额外持有一个引用，且永久不 put。
 * 内核侧 put_pid_ns()（5.10 是 ns->kref）最多只能把它减到 1，永远到不了 0，
 * 因此 free_pid_ns -> destroy_pid_namespace -> delayed_free_pidns 这条
 * "跨 cache kmem_cache_free + dec_pid_namespaces(NULL)" 的必死路径不会被执行。
 * 每次停容器泄漏约 136 B（ns 本体）+ idr 节点，属有意为之。
 */
static bool droid_lkm_pin_kref = true;
module_param_named(pin_kref, droid_lkm_pin_kref, bool, 0644);
MODULE_PARM_DESC(pin_kref, "1 = hold one extra ref on fake pid ns forever (default)");

/* no_teardown=1（默认）：exit_cleanup 遇到我们的假 ns 直接返回，什么都不做 */
static bool droid_lkm_no_teardown = true;
module_param_named(no_teardown, droid_lkm_no_teardown, bool, 0644);
MODULE_PARM_DESC(no_teardown, "1 = do nothing on exit of our fake pid ns (default)");

/* zap_guard=1（默认）：do_zap 只杀 active pid ns 确实是该 ns 的任务 */
static bool droid_lkm_zap_guard = true;
module_param_named(zap_guard, droid_lkm_zap_guard, bool, 0644);
MODULE_PARM_DESC(zap_guard, "1 = only SIGKILL tasks whose active pid ns is ns");

/*
 * reaper_fix=1（默认）：本机 GKI 内核 CONFIG_PID_NS=n，zap_pid_ns_processes()
 * 在 include/linux/pid_namespace.h 里被编成 static inline BUG()（kernel/exit.c
 * 的 find_child_reaper() 会无条件调用它）。find_child_reaper() 只有
 * "ns->child_reaper == 正在退出的任务" 且 "线程组里没有别的活线程" 时才会走到
 * 那句 BUG() —— 也就是容器 PID1 退出的那一刻。do_exit 里 exit_task_namespaces()
 * （本模块的钩子，exit_cleanup 从这里进）在 exit_notify() 之前执行，所以这里必须
 * 先把 child_reaper 挪到永不退出的任务，让 find_child_reaper() 走
 * "reaper != father" 的早退分支，绕开那个 BUG()。
 */
static bool droid_lkm_reaper_fix = true;
module_param_named(reaper_fix, droid_lkm_reaper_fix, bool, 0644);
MODULE_PARM_DESC(reaper_fix, "1 = move child_reaper off the dying task before exit_notify");

/*
 * tick_ms：B7 心跳。模块内 kthread 每 tick_ms 打一行 "B7T <seq>" 到 kmsg，
 * 无条件（不看 verbose）。0 = 关，上机时显式传 tick_ms=100。
 * 放内核侧而不是 shell 侧：要测的正是用户态已经卡死/被端掉的情形，
 * shell 侧的 tick 会跟着一起停，内核侧的不会。
 * 复位后 /dev/kmsg 记录自带的 usec 字段（raw 格式第 3 列）就是 uptime，
 * 拿最后一条 B7T 的 uptime 减发 stop 时的 uptime，就是复位延迟。
 */
static unsigned int droid_lkm_tick_ms;
module_param_named(tick_ms, droid_lkm_tick_ms, uint, 0644);
MODULE_PARM_DESC(tick_ms, "B7 heartbeat period in ms, 0 = off");

/*
 * B12 stall bisect：拆除路径在微秒级冻结，BRxx 来不及被 /dev/kmsg 的读者取走。
 * 在指定点用 msleep 停住进程队列，让另一颗 CPU 上的用户态心跳和 tee 采集继续跑：
 *   - 心跳在 kill 之后仍继续 stall_ms → 冻结点在该点之后（这一步确实执行到了）
 *   - 心跳立刻停 → 冻结点在该点之前
 * stall_point: -1 关；0 = exit_ns_wrap 的 BR12 之后；1 = BR13 之后；
 *              2 = exit_cleanup 的 BR01 之后；3 = reaper_swap(BR05) 之后；
 *              4 = disable_pid_allocation(BR09) 之后；5 = no_teardown 返回前；
 *              8 = BR08 之后、disable_pid_allocation 调用之前（B17）。
 * 用 msleep 而不是 mdelay：exit_task_namespaces() 本身 might_sleep()，此处可睡，
 * 睡住本任务不影响别的 CPU 打心跳，测出来的时间点更干净。
 */
static unsigned int droid_lkm_stall_mask;
module_param_named(stall_mask, droid_lkm_stall_mask, uint, 0644);
MODULE_PARM_DESC(stall_mask, "B14 bisect stall bitmask, bit N = stall at point N, 0 = off");

static unsigned int droid_lkm_stall_ms;
module_param_named(stall_ms, droid_lkm_stall_ms, uint, 0644);
MODULE_PARM_DESC(stall_ms, "B14 bisect stall length in ms, 0 = off");

/* B17：跳过 disable_pid_allocation 调用，验证它是否就是复位触发点 */
static bool droid_lkm_skip_disable_alloc;
module_param_named(skip_disable_alloc, droid_lkm_skip_disable_alloc, bool, 0644);
MODULE_PARM_DESC(skip_disable_alloc, "B17: skip disable_pid_allocation call, 1 = skip");

/* B18：disable_pid_allocation 的两种实现；1 = 按 BTF 真实偏移直写（默认），0 = 调内核函数 */
static unsigned int droid_lkm_disable_alloc_mode = 1;
module_param_named(disable_alloc_mode, droid_lkm_disable_alloc_mode, uint, 0644);
MODULE_PARM_DESC(disable_alloc_mode, "B18: 1 = BTF write pid_allocated (default), 0 = call kernel disable_pid_allocation");

/*
 * B14：把 B12 的单点 stall 改成位图，一次开机就能给每个 BR 点都留出落盘窗口，
 * 复位后 kmsg 里最后出现的那个 BR/STALL 编号就是精确的死点。
 */
void droid_lkm_maybe_stall(int point)
{
	if (point < 0 || point > 31 || !droid_lkm_stall_ms)
		return;
	if (!(droid_lkm_stall_mask & (1u << point)))
		return;

	droid_lkm_info("STALL enter point=%d ms=%u mask=0x%x\n", point,
		       droid_lkm_stall_ms, droid_lkm_stall_mask);
	msleep(droid_lkm_stall_ms);
	droid_lkm_info("STALL exit point=%d\n", point);
}

/*
 * clean_init=1（默认）：create 时把 ucounts / child_reaper 对齐内核
 * create_pid_namespace() 的真实收尾状态。0 = 回到 A 版的纯零值。
 */
static bool droid_lkm_ns_clean_init = true;
module_param_named(clean_init, droid_lkm_ns_clean_init, bool, 0644);
MODULE_PARM_DESC(clean_init, "1 = align ucounts/child_reaper with kernel create path");
static struct kmem_cache *droid_lkm_pid_cache[MAX_PID_NS_LEVEL];
static DEFINE_MUTEX(droid_lkm_pid_caches_mutex);

struct droid_lkm_pidns_entry {
	struct list_head node;
	struct list_head zap_node;
	struct pid_namespace *ns;
	bool zap_queued;
	bool pinned;
};

static LIST_HEAD(droid_lkm_pidns_list);
static DEFINE_SPINLOCK(droid_lkm_pidns_lock);

static struct task_struct *droid_lkm_reaper_task;
static struct task_struct *droid_lkm_tick_task;

static LIST_HEAD(droid_lkm_zap_list);
static DEFINE_SPINLOCK(droid_lkm_zap_lock);
static DECLARE_WAIT_QUEUE_HEAD(droid_lkm_zap_wq);

static struct pid_namespace *to_pid_ns(struct ns_common *ns)
{
	return (struct pid_namespace *)((char *)ns -
		droid_lkm_layout_off(DROID_LKM_F_PID_NS_NS));
}

static struct kmem_cache *droid_lkm_create_pid_cachep(unsigned int level)
{
	struct kmem_cache **pkc;
	struct kmem_cache *kc;
	char name[32];

	if (!level || level > MAX_PID_NS_LEVEL)
		return NULL;

	pkc = &droid_lkm_pid_cache[level - 1];
	kc = READ_ONCE(*pkc);
	if (kc)
		return kc;

	snprintf(name, sizeof(name), "droid_lkm_pid_%u", level + 1);
	mutex_lock(&droid_lkm_pid_caches_mutex);
	if (!*pkc)
		*pkc = kmem_cache_create(name,
					 /*
					  * 严格照抄内核 kernel/pid_namespace.c 的
					  * create_pid_cachep()：对象大小 =
					  * sizeof(struct pid) + level * sizeof(struct upid)。
					  * struct pid 自带 numbers[1]，所以 level=N 一共要
					  * N+1 个 upid。(level+1)*sizeof(upid) 会多分一个 upid，
					  * 不会 OOB 但和内核的 pid_<level+1> 不一致。
					  *
					  * 为什么不用 init_pid_ns.pid_cachep（改善 C.1）：
					  * 那个 cache 是 level-0 的（KMEM_CACHE(pid)），对象只装得下
					  * numbers[0]。我们的假 ns 是 level>=1，alloc_pid() 会写
					  * numbers[level]，用 level-0 的 cache 就是越界写
					  * 16*level 字节的堆 —— 比自建 cache 的"非内核同名"危险得多。
					  * 内核的 pid_cache[] 是 static，模块拿不到；所以这里只能
					  * 自建，但大小/对齐/flag 全部按内核公式对齐。
					  * UAF 风险：pid 的分配与释放都走 ns->pid_cachep（put_pid()
					  * 用 numbers[level].ns->pid_cachep），只要本模块活着就不会
					  * 出现"内核用自己的 cache 释放我们的 pid"；模块卸载前
					  * 必须先杀掉所有容器任务（exit 里已这么做）。
					  */
					 sizeof(struct pid) +
						 level * sizeof(struct upid),
					 0,
					 SLAB_HWCACHE_ALIGN | SLAB_ACCOUNT, NULL);
	mutex_unlock(&droid_lkm_pid_caches_mutex);

	return READ_ONCE(*pkc);
}

/*
 * 改善 C.1 的落地方式：level==0 直接用内核 init_pid_ns 的 pid cache（对象大小
 * 刚好装得下 numbers[0]）；level>=1 用自建 cache。struct pid_namespace 是
 * __randomize_layout，所以读字段必须走 ds_ti 的 BTF 偏移访问器，
 * 不能写 init_pid_ns.pid_cachep。
 */
static struct kmem_cache *droid_lkm_pidns_pick_cachep(unsigned int level)
{
	if (level == 0)
		return droid_lkm_pidns_pid_cachep(&init_pid_ns);
	return droid_lkm_create_pid_cachep(level);
}

static struct droid_lkm_pidns_entry *droid_lkm_pidns_entry_of(struct pid_namespace *ns)
{
	struct droid_lkm_pidns_entry *e;

	if (!ns || ns == &init_pid_ns)
		return NULL;

	list_for_each_entry(e, &droid_lkm_pidns_list, node) {
		if (e->ns == ns)
			return e;
	}
	return NULL;
}

bool droid_lkm_pidns_is_ours(struct pid_namespace *ns)
{
	unsigned long flags;
	bool found;

	if (!ns || ns == &init_pid_ns)
		return false;

	spin_lock_irqsave(&droid_lkm_pidns_lock, flags);
	found = droid_lkm_pidns_entry_of(ns) != NULL;
	spin_unlock_irqrestore(&droid_lkm_pidns_lock, flags);
	return found;
}

__nocfi noinline struct pid_namespace *droid_lkm_pidns_create(struct pid_namespace *parent)
{
	struct droid_lkm_pidns_entry *e;
	struct pid_namespace *ns;
	unsigned int level;
	int err;

	if (!parent)
		parent = &init_pid_ns;

#ifdef DROID_LKM_NATIVE_PID
	if (droid_lkm_pid_use_native) {
		ns = droid_native_create_pid_namespace(
			droid_lkm_task_cred(current)->user_ns, parent);
		if (IS_ERR(ns))
			return ns;
		e = kzalloc(sizeof(*e), GFP_KERNEL);
		if (!e) {
			droid_native_put_pid_ns(ns);
			return ERR_PTR(-ENOMEM);
		}
		e->ns = ns;
		INIT_LIST_HEAD(&e->node);
		INIT_LIST_HEAD(&e->zap_node);
		spin_lock_irq(&droid_lkm_pidns_lock);
		list_add_tail(&e->node, &droid_lkm_pidns_list);
		spin_unlock_irq(&droid_lkm_pidns_lock);
		return ns;
	}
#endif

	level = droid_lkm_pidns_level(parent) + 1;
	if (level > MAX_PID_NS_LEVEL)
		return ERR_PTR(-ENOSPC);

	ns = kmem_cache_zalloc(droid_lkm_pidns_cachep, GFP_KERNEL);
	if (!ns)
		return ERR_PTR(-ENOMEM);

	idr_init(droid_lkm_pidns_idr(ns));

	droid_lkm_pidns_set_pid_cachep(ns, droid_lkm_pidns_pick_cachep(level));
	if (!droid_lkm_pidns_pid_cachep(ns)) {
		err = -ENOMEM;
		goto out_idr;
	}
	droid_lkm_info("create: ns=%px level=%u cachep=%px %s\n", ns, level,
		       droid_lkm_pidns_pid_cachep(ns),
		       level == 0 ? "kernel" : "own");

	err = droid_lkm_ks.proc_alloc_inum(&droid_lkm_pidns_ns(ns)->inum);
	if (err)
		goto out_idr;

	droid_lkm_ns_set_ops(droid_lkm_pidns_ns(ns), &droid_lkm_pidns_ops,
			     CLONE_NEWPID);
	refcount_set(droid_lkm_pidns_refcount(ns), 1);
	droid_lkm_pidns_set_level(ns, level);
	droid_lkm_pidns_set_parent(ns, parent);
	/*
	 * Ownership follows the creating task's user namespace, so ns_capable()
	 * on this namespace is correct whether or not the userns module is
	 * loaded. No reference is taken: a fake namespace never reaches the
	 * kernel destroy path, and the userns module clears this field before it
	 * releases a user namespace.
	 */
	droid_lkm_pidns_set_user_ns(ns, droid_lkm_task_cred(current)->user_ns);
	droid_lkm_pidns_set_ucounts(ns, NULL);
	droid_lkm_pidns_set_pid_allocated(ns, PIDNS_ADDING);

	/*
	 * clean_init=1：把伪造 ns 的剩余字段对齐内核 create_pid_namespace 的真实
	 * 收尾状态。注意 PIDNS_ADDING（bit31）必须保留：fork.c 在
	 * !(pid_allocated & PIDNS_ADDING) 时直接返回 -ENOMEM，清掉它等于禁止该
	 * ns 里再 fork 任何进程。它由 zap_pid_ns_processes() -> disable_pid_allocation()
	 * 在 ns 死亡时清除，所以活着的时候 bit31 一定是置位的。
	 * ucounts 直接借用父 ns 的指针（不 inc）：只有 delayed_free_pidns() 会
	 * dec_ucount(ns->ucounts)，而 pin_kref 让这条路径永远到不了。
	 */
	if (droid_lkm_ns_clean_init) {
		droid_lkm_pidns_set_ucounts(ns, droid_lkm_pidns_ucounts(parent));
		droid_lkm_pidns_set_child_reaper(ns, droid_lkm_pidns_retire_reaper);
	}

	e = kzalloc(sizeof(*e), GFP_KERNEL);
	if (!e) {
		err = -ENOMEM;
		goto out_inum;
	}
	e->ns = ns;
	INIT_LIST_HEAD(&e->node);
	INIT_LIST_HEAD(&e->zap_node);

	spin_lock_irq(&droid_lkm_pidns_lock);
	list_add_tail(&e->node, &droid_lkm_pidns_list);
	spin_unlock_irq(&droid_lkm_pidns_lock);

	/* pin_kref：额外 +1 且永久不 put，计数永远回不到 0 */
	if (droid_lkm_pin_kref) {
		refcount_inc(droid_lkm_pidns_refcount(ns));
		e->pinned = true;
	}

	droid_lkm_dbg("pidns %px created level=%u parent=%px inum=%u alloc=0x%08x ucounts=%px reaper=%px cachep=%px ops=%px idr_base=%u idr_next=%u\n",
		      ns, level, parent, droid_lkm_pidns_ns(ns)->inum,
		      droid_lkm_pidns_pid_allocated(ns),
		      (void *)droid_lkm_pidns_ucounts(ns),
		      (void *)droid_lkm_pidns_child_reaper(ns),
		      (void *)droid_lkm_pidns_pid_cachep(ns),
		      (void *)droid_lkm_pidns_ns(ns)->ops,
		      droid_lkm_pidns_idr(ns)->idr_base,
		      droid_lkm_pidns_idr(ns)->idr_next);
	return ns;

out_inum:
	droid_lkm_ks.proc_free_inum(droid_lkm_pidns_ns(ns)->inum);
out_idr:
	idr_destroy(droid_lkm_pidns_idr(ns));
	kmem_cache_free(droid_lkm_pidns_cachep, ns);
	return ERR_PTR(err);
}

struct pid_namespace *droid_lkm_pidns_create_for_current(void)
{
	struct pid_namespace *parent = NULL;

	if (droid_lkm_task_nsproxy(current))
		parent = droid_lkm_nsproxy_pid_ns_for_children(
				droid_lkm_task_nsproxy(current));
	if (!droid_lkm_pidns_is_ours(parent))
		parent = &init_pid_ns;

	return droid_lkm_pidns_create(parent);
}

struct pid_namespace *droid_lkm_pidns_get(struct pid_namespace *ns)
{
#ifdef DROID_LKM_NATIVE_PID
	if (droid_lkm_pid_use_native)
		return droid_native_get_pid_ns(ns);
#endif
	if (ns && ns != &init_pid_ns)
		refcount_inc(droid_lkm_pidns_refcount(ns));
	return ns;
}

void droid_lkm_pidns_put(struct pid_namespace *ns)
{
#ifdef DROID_LKM_NATIVE_PID
	struct droid_lkm_pidns_entry *e;
	unsigned long flags;

	if (droid_lkm_pid_use_native) {
		if (!ns || ns == &init_pid_ns)
			return;
		if (refcount_read(droid_lkm_pidns_refcount(ns)) == 1) {
			spin_lock_irqsave(&droid_lkm_pidns_lock, flags);
			list_for_each_entry(e, &droid_lkm_pidns_list, node) {
				if (e->ns == ns) {
					list_del_init(&e->node);
					kfree(e);
					break;
				}
			}
			spin_unlock_irqrestore(&droid_lkm_pidns_lock, flags);
		}
		droid_native_put_pid_ns(ns);
		return;
	}
#endif
	if (!ns || ns == &init_pid_ns)
		return;
	/* pinned ns：put 一律短路，计数保持不动，永不归零 */
	{
		struct droid_lkm_pidns_entry *e;
		unsigned long flags;
		bool pinned = false;

		spin_lock_irqsave(&droid_lkm_pidns_lock, flags);
		e = droid_lkm_pidns_entry_of(ns);
		if (e && e->pinned)
			pinned = true;
		spin_unlock_irqrestore(&droid_lkm_pidns_lock, flags);
		if (pinned) {
			droid_lkm_info("BR40 pidns_put pinned ns=%px refc=%u\n", ns,
				       refcount_read(droid_lkm_pidns_refcount(ns)));
			return;
		}
	}
	if (!refcount_dec_not_one(droid_lkm_pidns_refcount(ns)))
		droid_lkm_dbg("pidns %p refcount one not dropped\n", ns);
}

struct pid_namespace *droid_lkm_pidns_task_for_children(struct task_struct *task)
{
	struct pid_namespace *ns = NULL;

	task_lock(task);
	if (droid_lkm_task_nsproxy(task))
		ns = droid_lkm_nsproxy_pid_ns_for_children(
				droid_lkm_task_nsproxy(task));
	task_unlock(task);

	return ns;
}

bool droid_lkm_pidns_busy(void)
{
	struct droid_lkm_pidns_entry *e;
	unsigned long flags;
	bool busy = false;

	spin_lock_irqsave(&droid_lkm_pidns_lock, flags);
	list_for_each_entry(e, &droid_lkm_pidns_list, node) {
		if (!idr_is_empty(droid_lkm_pidns_idr(e->ns))) {
			busy = true;
			break;
		}
	}
	spin_unlock_irqrestore(&droid_lkm_pidns_lock, flags);

	return busy;
}

bool droid_lkm_any_task_ns_refs(void)
{
	struct task_struct *p, *t;
	bool found = false;

	if (!droid_lkm_layout_trusted())
		return false;

	rcu_read_lock();
	droid_lkm_for_each_process_thread(p, t) {
		struct pid_namespace *pns = NULL;
		struct ipc_namespace *ins = NULL;

		task_lock(t);
		if (droid_lkm_task_nsproxy(t)) {
			pns = droid_lkm_nsproxy_pid_ns_for_children(
					droid_lkm_task_nsproxy(t));
			ins = droid_lkm_nsproxy_ipc_ns(droid_lkm_task_nsproxy(t));
		}
		task_unlock(t);

		if (droid_lkm_pidns_is_ours(pns) ||
		    (droid_lkm_ipcns_is_ours(ins) && !droid_lkm_ipcns_is_host(ins))) {
			found = true;
			goto out;
		}
	}
out:
	rcu_read_unlock();

	return found;
}

void droid_lkm_reset_task_ns_refs(void)
{
	struct task_struct *p, *t;

	if (!droid_lkm_layout_trusted())
		return;

	rcu_read_lock();
	droid_lkm_for_each_process_thread(p, t) {
		struct pid_namespace *pns = NULL;
		struct ipc_namespace *ins = NULL;

		task_lock(t);
		if (droid_lkm_task_nsproxy(t)) {
			pns = droid_lkm_nsproxy_pid_ns_for_children(
					droid_lkm_task_nsproxy(t));
			ins = droid_lkm_nsproxy_ipc_ns(droid_lkm_task_nsproxy(t));
		}
		task_unlock(t);

		if (!droid_lkm_pidns_is_ours(pns) && !droid_lkm_ipcns_is_ours(ins))
			continue;

		task_lock(t);
		if (droid_lkm_task_nsproxy(t)) {
			struct nsproxy *nsp = droid_lkm_task_nsproxy(t);

			if (droid_lkm_pidns_is_ours(
				    droid_lkm_nsproxy_pid_ns_for_children(nsp))) {
				droid_lkm_pidns_put(
					droid_lkm_nsproxy_pid_ns_for_children(nsp));
				droid_lkm_nsproxy_set_pid_ns_for_children(
					nsp, &init_pid_ns);
			}
			if (droid_lkm_ipcns_is_ours(droid_lkm_nsproxy_ipc_ns(nsp)))
				droid_lkm_nsproxy_set_ipc_ns(nsp, NULL);
		}
		task_unlock(t);
	}
	rcu_read_unlock();
}

static bool droid_lkm_keepalive_held;

void droid_lkm_keepalive_pin(void)
{
	if (droid_lkm_keepalive_held)
		return;

	if (try_module_get(THIS_MODULE)) {
		droid_lkm_keepalive_held = true;
		droid_lkm_dbg("keepalive: pinned, rmmod will -EBUSY\n");
	}
}

void droid_lkm_keepalive_sync(void)
{
	bool busy = droid_lkm_pidns_busy() || droid_lkm_ipcns_busy();

	if (busy) {
		droid_lkm_keepalive_pin();
		return;
	}

	if (droid_lkm_keepalive_held) {
		droid_lkm_keepalive_held = false;
		droid_lkm_dbg("keepalive: released\n");
		module_put(THIS_MODULE);
	}
}

void droid_lkm_keepalive_release(void)
{
	if (droid_lkm_keepalive_held) {
		droid_lkm_keepalive_held = false;
		module_put(THIS_MODULE);
	}
}

static struct ns_common *droid_lkm_pidns_get_active(struct task_struct *task)
{
	struct pid_namespace *ns;

	rcu_read_lock();
	ns = droid_lkm_pidns_get(task_active_pid_ns(task));
	rcu_read_unlock();

	return ns ? droid_lkm_pidns_ns(ns) : NULL;
}

static struct ns_common *droid_lkm_pidns_get_for_children(struct task_struct *task)
{
	struct pid_namespace *ns = NULL;

	task_lock(task);
	if (droid_lkm_task_nsproxy(task))
		ns = droid_lkm_pidns_get(droid_lkm_nsproxy_pid_ns_for_children(
					 droid_lkm_task_nsproxy(task)));
	task_unlock(task);

	/*
	 * upstream refuses to hand out a namespace whose reaper is gone
	 * (pidns_for_children_get), so a dead namespace reads as ENOENT
	 */
	if (ns && !droid_lkm_pidns_child_reaper(ns)) {
		droid_lkm_pidns_put(ns);
		ns = NULL;
	}

	return ns ? droid_lkm_pidns_ns(ns) : NULL;
}

static void droid_lkm_pidns_put_common(struct ns_common *ns)
{
	droid_lkm_pidns_put(to_pid_ns(ns));
}

static int droid_lkm_pidns_install(struct nsset *nsset, struct ns_common *ns)
{
	struct nsproxy *nsproxy = nsset->nsproxy;
	struct pid_namespace *active = task_active_pid_ns(current);
	struct pid_namespace *ancestor, *new = to_pid_ns(ns);

	droid_lkm_dbg("setns(pid): %s[%d] active=%p -> ns=%p level=%u\n",
	       droid_lkm_task_comm(current), droid_lkm_task_pid(current),
	       active, new, droid_lkm_pidns_level(new));

	if (!ns_capable(droid_lkm_pidns_user_ns(new), CAP_SYS_ADMIN) ||
	    !ns_capable(nsset->cred->user_ns, CAP_SYS_ADMIN))
		return -EPERM;

	if (droid_lkm_pidns_level(new) < droid_lkm_pidns_level(active))
		return -EINVAL;

	ancestor = new;
	while (droid_lkm_pidns_level(ancestor) >
	       droid_lkm_pidns_level(active))
		ancestor = droid_lkm_pidns_parent(ancestor);
	if (ancestor != active)
		return -EINVAL;

	/*
	 * nsproxy pointers borrow. get_pid_ns()/put_pid_ns() are no-ops in a
	 * CONFIG_PID_NS=n kernel, so a ref taken here would never be returned:
	 * every setns would add one and the ns could only be neutralized at
	 * unload. the real reference is the one the nsfs inode holds through
	 * droid_lkm_pidns_get_active()/put_common(), and live use is tracked
	 * through the ns idr plus droid_lkm_any_task_ns_refs().
	 */
	droid_lkm_nsproxy_set_pid_ns_for_children(nsproxy, new);
	return 0;
}

static struct ns_common *droid_lkm_pidns_get_parent(struct ns_common *ns)
{
	struct pid_namespace *active = task_active_pid_ns(current);
	struct pid_namespace *pid_ns, *p;

	pid_ns = p = droid_lkm_pidns_parent(to_pid_ns(ns));
	for (;;) {
		if (!p)
			return ERR_PTR(-EPERM);
		if (p == active)
			break;
		p = droid_lkm_pidns_parent(p);
	}

	pid_ns = droid_lkm_pidns_get(pid_ns);
	return pid_ns ? droid_lkm_pidns_ns(pid_ns) : ERR_PTR(-ENOMEM);
}

static struct user_namespace *droid_lkm_pidns_owner(struct ns_common *ns)
{
	return droid_lkm_pidns_user_ns(to_pid_ns(ns));
}

const struct proc_ns_operations droid_lkm_pidns_ops = {
	.name = "pid",
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 18, 0)
	.type = CLONE_NEWPID,
#endif
	.get = droid_lkm_pidns_get_active,
	.put = droid_lkm_pidns_put_common,
	.install = droid_lkm_pidns_install,
	.owner = droid_lkm_pidns_owner,
	.get_parent = droid_lkm_pidns_get_parent,
};

const struct proc_ns_operations droid_lkm_pidns_for_children_ops = {
	.name = "pid_for_children",
	.real_ns_name = "pid",
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 18, 0)
	.type = CLONE_NEWPID,
#endif
	.get = droid_lkm_pidns_get_for_children,
	.put = droid_lkm_pidns_put_common,
	.install = droid_lkm_pidns_install,
	.owner = droid_lkm_pidns_owner,
	.get_parent = droid_lkm_pidns_get_parent,
};

int droid_lkm_pidns_reboot(struct pid_namespace *ns, int cmd)
{
	switch (cmd) {
	case LINUX_REBOOT_CMD_RESTART2:
	case LINUX_REBOOT_CMD_RESTART:
		droid_lkm_pidns_set_reboot(ns, SIGHUP);
		break;
	case LINUX_REBOOT_CMD_POWER_OFF:
	case LINUX_REBOOT_CMD_HALT:
		droid_lkm_pidns_set_reboot(ns, SIGINT);
		break;
	default:
		return -EINVAL;
	}

	if (droid_lkm_pidns_child_reaper(ns)) {
		struct task_struct *reaper = droid_lkm_pidns_child_reaper(ns);

		send_sig(SIGKILL, reaper, 1);
		droid_lkm_info("pidns %p reboot=%d, reaper %d killed\n", ns,
			droid_lkm_pidns_reboot_value(ns), droid_lkm_task_pid(reaper));
	}
	return 0;
}

static __nocfi noinline void droid_lkm_pidns_do_zap(struct pid_namespace *ns)
{
	struct pid *pid;
	struct task_struct *task;
	int nr = 2;
	int rounds;
	long rc;
	unsigned long next;
	int it = 0;

	droid_lkm_info("BR20 do_zap begin ns=%px alloc=0x%08x\n", ns,
		       droid_lkm_pidns_pid_allocated(ns));

	droid_lkm_ks.disable_pid_allocation(ns);
	droid_lkm_info("BR21 do_zap after disable alloc=0x%08x\n",
		       droid_lkm_pidns_pid_allocated(ns));

	rcu_read_lock();
	/*
	 * a stock image may not export tasklist_lock. without it the walk stays
	 * rcu protected but loses the task list serialization, which is what the
	 * zapper can afford: it only sends SIGKILL to what it finds
	 */
	if (droid_lkm_ks_tasklist_lock)
		read_lock(droid_lkm_ks_tasklist_lock);
	idr_for_each_entry_continue(droid_lkm_pidns_idr(ns), pid, nr) {
		task = pid_task(pid, PIDTYPE_PID);
		if (task && droid_lkm_zap_guard &&
		    task_active_pid_ns(task) != ns)
			task = NULL;
		if (task && !__fatal_signal_pending(task))
			droid_lkm_ks.group_send_sig_info(SIGKILL, SEND_SIG_PRIV, task,
						  PIDTYPE_MAX);
	}
	if (droid_lkm_ks_tasklist_lock)
		read_unlock(droid_lkm_ks_tasklist_lock);
	rcu_read_unlock();

	droid_lkm_info("BR22 do_zap after sig walk alloc=0x%08x\n",
		       droid_lkm_pidns_pid_allocated(ns));

	do {
		droid_lkm_info("BR23 do_zap wait4 call it=%d\n", it++);
		rc = droid_lkm_ks.kernel_wait4(-1, NULL, __WALL, NULL);
		droid_lkm_info("BR24 do_zap wait4 ret rc=%ld\n", rc);
	} while (rc != -ECHILD);

	next = jiffies + msecs_to_jiffies(200);
	for (rounds = 0; rounds < 500; rounds++) {
		if (droid_lkm_pidns_pid_allocated(ns) == 0)
			break;
		msleep(10);
		if (time_after_eq(jiffies, next)) {
			next = jiffies + msecs_to_jiffies(200);
			droid_lkm_info("BR25 do_zap wait alloc=0x%08x round=%d\n",
				       droid_lkm_pidns_pid_allocated(ns), rounds);
		}
	}

	droid_lkm_info("BR26 do_zap done alloc=0x%08x rounds=%d\n",
		       droid_lkm_pidns_pid_allocated(ns), rounds);
}

static void droid_lkm_pidns_monitor(void);

static int droid_lkm_zap_fn(void *unused)
{
	struct droid_lkm_pidns_entry *e;

	{
		struct sighand_struct *sighand = droid_lkm_task_sighand(current);

		spin_lock_irq(&sighand->siglock);
		sighand->action[SIGCHLD - 1].sa.sa_handler = SIG_IGN;
		spin_unlock_irq(&sighand->siglock);
	}

	while (!kthread_should_stop()) {
		wait_event_interruptible_timeout(droid_lkm_zap_wq,
						 !list_empty(&droid_lkm_zap_list) ||
						 droid_lkm_task_ipc_deferred_pending() ||
						 kthread_should_stop(),
						 HZ / 4);

		droid_lkm_pidns_monitor();

		for (;;) {
			unsigned long flags;

			spin_lock_irqsave(&droid_lkm_zap_lock, flags);
			if (list_empty(&droid_lkm_zap_list)) {
				spin_unlock_irqrestore(&droid_lkm_zap_lock, flags);
				break;
			}
			e = list_first_entry(&droid_lkm_zap_list,
					     struct droid_lkm_pidns_entry, zap_node);
			list_del_init(&e->zap_node);
			spin_unlock_irqrestore(&droid_lkm_zap_lock, flags);

			droid_lkm_info("BR50 zap dispatch ns=%px\n", e->ns);
			droid_lkm_pidns_do_zap(e->ns);
			droid_lkm_info("BR51 zap dispatch done ns=%px\n", e->ns);
		}

		droid_lkm_task_ipc_deferred_run();

		droid_lkm_keepalive_sync();
	}

	return 0;
}

void droid_lkm_reaper_wake(void)
{
	wake_up_interruptible(&droid_lkm_zap_wq);
}

void droid_lkm_pidns_queue_zap(struct pid_namespace *ns)
{
	struct droid_lkm_pidns_entry *e;
	unsigned long flags;

	droid_lkm_info("BR30 queue_zap ns=%px\n", ns);

	spin_lock_irqsave(&droid_lkm_pidns_lock, flags);
	e = droid_lkm_pidns_entry_of(ns);
	spin_unlock_irqrestore(&droid_lkm_pidns_lock, flags);
	if (!e) {
		droid_lkm_info("BR31 queue_zap not_ours ns=%px\n", ns);
		return;
	}

	spin_lock_irqsave(&droid_lkm_zap_lock, flags);
	if (!e->zap_queued) {
		e->zap_queued = true;
		list_add_tail(&e->zap_node, &droid_lkm_zap_list);
		droid_lkm_info("BR32 queue_zap queued ns=%px\n", ns);
	} else {
		droid_lkm_info("BR33 queue_zap already_queued ns=%px\n", ns);
	}
	spin_unlock_irqrestore(&droid_lkm_zap_lock, flags);

	wake_up_interruptible(&droid_lkm_zap_wq);
}

/*
 * 拆除路径的每一步都留一条无条件面包屑 BRxx（编号全局唯一、不重复）。
 * 复位后 kmsg 里最后出现的那个编号就是死掉的那一步，不需要再"崩一次看看"。
 */
void droid_lkm_pidns_exit_cleanup(struct task_struct *task)
{
	struct pid_namespace *ns = task_active_pid_ns(task);
	struct task_struct *reap;
	bool self_reaper;

	droid_lkm_info("BR01 exit_cleanup pid=%d comm=%s ns=%px\n",
		       droid_lkm_task_pid(task), droid_lkm_task_comm(task), ns);

	if (droid_lkm_task_ipc_exit_defer(task))
		droid_lkm_reaper_wake();

	if (!droid_lkm_pidns_is_ours(ns)) {
		droid_lkm_info("BR02 exit_cleanup not_ours ns=%px\n", ns);
		return;
	}

	reap = droid_lkm_pidns_child_reaper(ns);
	self_reaper = (reap == task);
	droid_lkm_info("BR03 exit_cleanup ours ns=%px alloc=0x%08x reaper=%d self=%d\n",
		       ns, droid_lkm_pidns_pid_allocated(ns),
		       reap ? droid_lkm_task_pid(reap) : -1, (int)self_reaper);
	droid_lkm_maybe_stall(2);

	/*
	 * 关键一步：CONFIG_PID_NS=n 下 zap_pid_ns_processes() 是 static inline
	 * BUG()，而 find_child_reaper() 只在 child_reaper == 退出中的任务 且
	 * 没有别的活线程时调用它。exit_task_namespaces() 在 exit_notify() 之前，
	 * 所以这里先把 child_reaper 挪到永不退出的任务上（这一步与 no_teardown 无关）。
	 */
	if (self_reaper && droid_lkm_reaper_fix) {
		struct task_struct *nr = droid_lkm_reaper_task ?
			droid_lkm_reaper_task : droid_lkm_pidns_retire_reaper;

		droid_lkm_info("BR04 reaper_swap old=%d new=%d\n",
			       droid_lkm_task_pid(task),
			       nr ? droid_lkm_task_pid(nr) : -1);
		if (nr) {
			struct task_struct *now;

			droid_lkm_pidns_set_child_reaper(ns, nr);
			now = droid_lkm_pidns_child_reaper(ns);
			droid_lkm_info("BR05 reaper_swap done cur=%d\n",
				       now ? droid_lkm_task_pid(now) : -1);
		}
	}
	droid_lkm_maybe_stall(3);

	/*
	 * 只要是 reaper 退出，就清 PIDNS_ADDING：否则最后一个 pid 被 free_pid()
	 * 减到 0x80000000 时会命中 "case PIDNS_ADDING" 里的 WARN_ON(child_reaper)。
	 * 这只禁止往这个将死的 ns 里再 fork，和 no_teardown 不冲突。
	 */
	if (self_reaper) {
		unsigned int al = droid_lkm_pidns_pid_allocated(ns);

		droid_lkm_info("BR08 disable_alloc before alloc=0x%08x fn=%px skip=%d mode=%u\n",
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
		droid_lkm_info("BR09 disable_alloc after alloc=0x%08x\n",
			       droid_lkm_pidns_pid_allocated(ns));
	}
	droid_lkm_maybe_stall(4);

	/*
	 * no_teardown=1（默认）：不改内核那边剩下的语义、不 queue_zap。
	 */
	if (droid_lkm_no_teardown) {
		droid_lkm_info("BR06 no_teardown return alloc=0x%08x\n",
			       droid_lkm_pidns_pid_allocated(ns));
		droid_lkm_maybe_stall(5);
		return;
	}

	if (!self_reaper) {
		droid_lkm_info("BR07 not_self_reaper return\n");
		return;
	}

	if (droid_lkm_reaper_task)
		droid_lkm_pidns_set_child_reaper(ns, droid_lkm_reaper_task);

	if (droid_lkm_pidns_reboot_value(ns))
		droid_lkm_task_signal(task)->group_exit_code =
			droid_lkm_pidns_reboot_value(ns);

	droid_lkm_info("BR10 queue_zap before alloc=0x%08x\n",
		       droid_lkm_pidns_pid_allocated(ns));
	droid_lkm_pidns_queue_zap(ns);
	droid_lkm_info("BR11 queue_zap after\n");
}

/*
 * 2 秒一次把伪造 ns 的关键状态打到 kmsg：stop 若复位，ring buffer 里能看到
 * alloc 的最后轨迹，不用靠崩一次去猜。
 */
static void droid_lkm_pidns_monitor(void)
{
	static unsigned long next;
	struct droid_lkm_pidns_entry *e;
	struct pid_namespace *arr[8];
	unsigned int alloc[8];
	struct task_struct *reap[8];
	unsigned long flags;
	int n = 0, i;

	if (time_before(jiffies, next))
		return;
	next = jiffies + 2 * HZ;

	spin_lock_irqsave(&droid_lkm_pidns_lock, flags);
	list_for_each_entry(e, &droid_lkm_pidns_list, node) {
		if (n >= 8)
			break;
		arr[n] = e->ns;
		alloc[n] = droid_lkm_pidns_pid_allocated(e->ns);
		reap[n] = droid_lkm_pidns_child_reaper(e->ns);
		n++;
	}
	spin_unlock_irqrestore(&droid_lkm_pidns_lock, flags);

	for (i = 0; i < n; i++)
		droid_lkm_info("mon: ns=%px alloc=0x%08x count=%u adding=%u reaper=%d\n",
			       arr[i], alloc[i], alloc[i] & ~(1u << 31),
			       !!(alloc[i] & (1u << 31)),
			       reap[i] ? droid_lkm_task_pid(reap[i]) : -1);
}

/*
 * B7 心跳：无条件 printk，每 tick_ms 一行。复位后最后一条 "B7T <seq>" 的
 * kmsg 时间戳就是内核真正断气的时刻；和发 stop 前记的 /proc/uptime 相减，
 * 就能把 "发 stop -> 复位" 的延迟量成具体秒数。
 */
static int droid_lkm_tick_fn(void *unused)
{
	unsigned long long seq = 0;

	while (!kthread_should_stop()) {
		droid_lkm_info("B7T %llu\n", seq++);
		if (!droid_lkm_tick_ms)
			break;
		msleep(droid_lkm_tick_ms);
	}
	return 0;
}

#ifdef CONFIG_PROC_FS
/*
 * nsdump：一次开机把每个伪造 pid ns 的内部状态全打出来，避免靠崩溃去试。
 * 只读，不改任何字段。
 */
struct droid_lkm_ns_snap {
	struct pid_namespace *ns;
	struct pid_namespace *parent;
	struct kmem_cache *cachep;
	struct task_struct *reaper;
	struct ucounts *ucounts;
	const struct proc_ns_operations *ops;
	void *idr_head;
	unsigned int level;
	unsigned int inum;
	unsigned int alloc;
	unsigned int refc;
	unsigned int idr_base;
	unsigned int idr_next;
	unsigned int entries;
	int reaper_pid;
	bool pinned;
	bool zap_queued;
	int first[4];
};

struct droid_lkm_task_snap {
	int pid;
	long state;
	bool reaper;
	char comm[16];
};

#define DROID_LKM_NSDUMP_MAX	16
#define DROID_LKM_TSDUMP_MAX	64

static int droid_lkm_pidns_dump_show(struct seq_file *m, void *unused)
{
	struct droid_lkm_ns_snap snaps[DROID_LKM_NSDUMP_MAX];
	struct droid_lkm_task_snap tsnaps[DROID_LKM_TSDUMP_MAX];
	struct droid_lkm_pidns_entry *e;
	struct task_struct *p, *t;
	unsigned long flags;
	int nsnap = 0, ntask = 0, i;

	spin_lock_irqsave(&droid_lkm_pidns_lock, flags);
	list_for_each_entry(e, &droid_lkm_pidns_list, node) {
		struct droid_lkm_ns_snap *s;
		struct idr *idr;
		struct pid *pid;
		unsigned int cnt = 0;
		int nr, k;

		if (nsnap >= DROID_LKM_NSDUMP_MAX)
			break;
		s = &snaps[nsnap];
		*s = (struct droid_lkm_ns_snap){ 0 };
		for (k = 0; k < 4; k++)
			s->first[k] = -1;

		s->ns = e->ns;
		s->parent = droid_lkm_pidns_parent(e->ns);
		s->level = droid_lkm_pidns_level(e->ns);
		s->inum = droid_lkm_pidns_ns(e->ns)->inum;
		s->ops = droid_lkm_pidns_ns(e->ns)->ops;
		s->alloc = droid_lkm_pidns_pid_allocated(e->ns);
		s->ucounts = droid_lkm_pidns_ucounts(e->ns);
		s->reaper = droid_lkm_pidns_child_reaper(e->ns);
		s->reaper_pid = s->reaper ? droid_lkm_task_pid(s->reaper) : -1;
		s->cachep = droid_lkm_pidns_pid_cachep(e->ns);
		s->refc = refcount_read(droid_lkm_pidns_refcount(e->ns));
		s->pinned = e->pinned;
		s->zap_queued = e->zap_queued;

		idr = droid_lkm_pidns_idr(e->ns);
		s->idr_base = idr->idr_base;
		s->idr_next = idr->idr_next;
		s->idr_head = (void *)READ_ONCE(idr->idr_rt.xa_head);

		rcu_read_lock();
		idr_for_each_entry(idr, pid, nr) {
			if (cnt < 4)
				s->first[cnt] = nr;
			cnt++;
		}
		rcu_read_unlock();
		s->entries = cnt;
		nsnap++;
	}
	spin_unlock_irqrestore(&droid_lkm_pidns_lock, flags);

	rcu_read_lock();
	if (droid_lkm_layout_trusted())
		droid_lkm_for_each_process_thread(p, t) {
			struct pid_namespace *ans;

			if (ntask >= DROID_LKM_TSDUMP_MAX)
				break;
			ans = task_active_pid_ns(t);
			if (!droid_lkm_pidns_is_ours(ans))
				continue;
			tsnaps[ntask].pid = droid_lkm_task_pid(t);
			tsnaps[ntask].state = READ_ONCE(t->state);
			tsnaps[ntask].reaper = droid_lkm_pidns_child_reaper(ans) == t;
			memcpy(tsnaps[ntask].comm, droid_lkm_task_comm(t), 16);
			ntask++;
		}
	rcu_read_unlock();

	seq_printf(m, "layout_trusted=%d fake_ns=%d live_tasks=%d\n",
		   droid_lkm_layout_trusted(), nsnap, ntask);
	for (i = 0; i < nsnap; i++) {
		struct droid_lkm_ns_snap *s = &snaps[i];

		seq_printf(m, "\n[ns %d] ns=%px level=%u parent=%px inum=%u\n",
			   i, s->ns, s->level, s->parent, s->inum);
		seq_printf(m, "  ops=%px ours_ops=%px for_children_ops=%px\n",
			   (void *)s->ops, (void *)&droid_lkm_pidns_ops,
			   (void *)&droid_lkm_pidns_for_children_ops);
		seq_printf(m, "  pid_allocated=0x%08x count=%u adding_bit=%u\n",
			   s->alloc, s->alloc & ~(1u << 31),
			   !!(s->alloc & (1u << 31)));
		seq_printf(m, "  ucounts=%px child_reaper=%px reaper_pid=%d cachep=%px refcount=%u\n",
			   (void *)s->ucounts, (void *)s->reaper, s->reaper_pid,
			   (void *)s->cachep, s->refc);
		seq_printf(m, "  idr base=%u next=%u head=%px entries=%u first=%d,%d,%d,%d\n",
			   s->idr_base, s->idr_next, s->idr_head, s->entries,
			   s->first[0], s->first[1], s->first[2], s->first[3]);
		seq_printf(m, "  pinned=%d zap_queued=%d\n",
			   s->pinned, s->zap_queued);
	}
	for (i = 0; i < ntask; i++)
		seq_printf(m, "  task pid=%d comm=%s state=%ld reaper=%d\n",
			   tsnaps[i].pid, tsnaps[i].comm, tsnaps[i].state,
			   tsnaps[i].reaper);
	return 0;
}

static int droid_lkm_pidns_dump_open(struct inode *inode, struct file *file)
{
	return single_open(file, droid_lkm_pidns_dump_show, NULL);
}

static const struct proc_ops droid_lkm_pidns_dump_pops = {
	.proc_open = droid_lkm_pidns_dump_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
};

int droid_lkm_pidns_dump_init(struct proc_dir_entry *dir)
{
	if (!dir)
		return -EINVAL;
	if (!proc_create("nsdump", 0444, dir, &droid_lkm_pidns_dump_pops))
		return -ENOMEM;
	return 0;
}

void droid_lkm_pidns_dump_exit(struct proc_dir_entry *dir)
{
	if (dir)
		remove_proc_entry("nsdump", dir);
}
#else
int droid_lkm_pidns_dump_init(struct proc_dir_entry *dir)
{
	return 0;
}

void droid_lkm_pidns_dump_exit(struct proc_dir_entry *dir)
{
}
#endif

#ifdef DROID_LKM_NATIVE_PID
static int droid_lkm_pidns_init_native(void)
{
	int ret;

	ret = droid_native_pidns_init();
	if (ret)
		return ret;
	droid_lkm_pidns_neutral_ops = droid_lkm_ns_ops_alias("pid", CLONE_NEWPID);
	if (!droid_lkm_pidns_neutral_ops) {
		droid_native_pidns_exit();
		return -ENOMEM;
	}
	droid_lkm_pidns_retire_reaper = (struct task_struct *)droid_lkm_sym("init_task");
	droid_lkm_reaper_task = kthread_run(droid_lkm_zap_fn, NULL, "ds-zap");
	if (IS_ERR(droid_lkm_reaper_task)) {
		ret = PTR_ERR(droid_lkm_reaper_task);
		droid_lkm_reaper_task = NULL;
		droid_native_pidns_exit();
		return ret;
	}
	if (droid_lkm_nsproxy_enable) {
		ret = droid_native_nsproxy_init();
		if (ret) {
			kthread_stop(droid_lkm_reaper_task);
			droid_lkm_reaper_task = NULL;
			droid_native_pidns_exit();
			return ret;
		}
	}
	droid_lkm_info("pidns native ready (reaper=%d)\n",
		droid_lkm_task_pid(droid_lkm_reaper_task));
	return 0;
}
#endif

static int droid_lkm_pidns_init_main(void)
{
	droid_lkm_pidns_cachep = kmem_cache_create("droid_lkm_pid_namespace",
					    droid_lkm_pidns_size(),
					    __alignof__(struct pid_namespace),
					    SLAB_HWCACHE_ALIGN | SLAB_ACCOUNT, NULL);
	if (!droid_lkm_pidns_cachep) {
		droid_lkm_err("cannot create droid_lkm_pid_namespace cache\n");
		return -ENOMEM;
	}

	droid_lkm_pidns_neutral_ops = droid_lkm_ns_ops_alias("pid", CLONE_NEWPID);
	if (!droid_lkm_pidns_neutral_ops) {
		droid_lkm_err("cannot build neutral pid ns ops\n");
		kmem_cache_destroy(droid_lkm_pidns_cachep);
		droid_lkm_pidns_cachep = NULL;
		return -ENOMEM;
	}

	droid_lkm_pidns_retire_reaper = (struct task_struct *)droid_lkm_sym("init_task");
	if (!droid_lkm_pidns_retire_reaper)
		droid_lkm_warn("init_task not found, leaked pidns keep a null reaper\n");

	droid_lkm_reaper_task = kthread_run(droid_lkm_zap_fn, NULL, "ds-zap");
	if (IS_ERR(droid_lkm_reaper_task)) {
		int ret = PTR_ERR(droid_lkm_reaper_task);

		droid_lkm_reaper_task = NULL;
		kmem_cache_destroy(droid_lkm_pidns_cachep);
		droid_lkm_pidns_cachep = NULL;
		droid_lkm_err("cannot start ds-zap thread: %d\n", ret);
		return ret;
	}

	droid_lkm_info("pidns ready (reaper=%d)\n",
			 droid_lkm_task_pid(droid_lkm_reaper_task));

	if (droid_lkm_tick_ms) {
		droid_lkm_tick_task = kthread_run(droid_lkm_tick_fn, NULL, "ds-b7tick");
		if (IS_ERR(droid_lkm_tick_task)) {
			droid_lkm_tick_task = NULL;
			droid_lkm_warn("cannot start b7 tick thread\n");
		} else {
			droid_lkm_info("b7 tick %u ms (thread=%d)\n", droid_lkm_tick_ms,
				       droid_lkm_task_pid(droid_lkm_tick_task));
		}
	}
	return 0;
}

int droid_lkm_pidns_init(void)
{
	if (!strcmp(droid_lkm_pid_impl, "native"))
		droid_lkm_pid_use_native = true;
	else if (!strcmp(droid_lkm_pid_impl, "main"))
		droid_lkm_pid_use_native = false;
	else {
		droid_lkm_err("pid_impl must be main or native\n");
		return -EINVAL;
	}

	if (droid_lkm_nsproxy_enable && !droid_lkm_pid_use_native) {
		droid_lkm_err("nsproxy=1 requires pid_impl=native\n");
		return -EOPNOTSUPP;
	}

#ifndef DROID_LKM_NATIVE_PID
	if (droid_lkm_pid_use_native) {
		droid_lkm_err("pid_impl=native is not built\n");
		return -EOPNOTSUPP;
	}
#else
#ifndef DROID_LKM_PID_BOTH
	if (!droid_lkm_pid_use_native) {
		droid_lkm_err("pid_impl=main is not built\n");
		return -EOPNOTSUPP;
	}
#endif
#endif

#ifdef DROID_LKM_NATIVE_PID
	if (droid_lkm_pid_use_native)
		return droid_lkm_pidns_init_native();
#endif
	return droid_lkm_pidns_init_main();
}

/*
 * the reaper kthread dies below, but a leaked namespace keeps allocating and
 * freeing pids after that, so every fake namespace gets a reaper that outlives
 * the module first
 */
static void droid_lkm_pidns_retire_reapers(void)
{
	struct droid_lkm_pidns_entry *e;
	unsigned long flags;

	if (!droid_lkm_pidns_retire_reaper)
		return;

	spin_lock_irqsave(&droid_lkm_pidns_lock, flags);
	list_for_each_entry(e, &droid_lkm_pidns_list, node)
		droid_lkm_pidns_set_child_reaper(e->ns,
						droid_lkm_pidns_retire_reaper);
	spin_unlock_irqrestore(&droid_lkm_pidns_lock, flags);
}

__nocfi noinline void droid_lkm_pidns_exit(void)
{
	struct droid_lkm_pidns_entry *e;
	unsigned long flags;
	int leaked = 0;
	bool caches_clean = true;
	int i;

#ifdef DROID_LKM_NATIVE_PID
	if (!droid_lkm_pid_use_native && !droid_lkm_pidns_cachep)
		return;
#else
	if (!droid_lkm_pidns_cachep)
		return;
#endif

#ifdef DROID_LKM_NATIVE_PID
	if (droid_lkm_pidns_nsproxy_enabled())
		droid_native_nsproxy_exit();
#endif

	droid_lkm_pidns_retire_reapers();

	if (droid_lkm_tick_task) {
		kthread_stop(droid_lkm_tick_task);
		droid_lkm_tick_task = NULL;
	}

	if (droid_lkm_reaper_task) {
		kthread_stop(droid_lkm_reaper_task);
		droid_lkm_reaper_task = NULL;
	}

	spin_lock_irqsave(&droid_lkm_zap_lock, flags);
	INIT_LIST_HEAD(&droid_lkm_zap_list);
	spin_unlock_irqrestore(&droid_lkm_zap_lock, flags);

	droid_lkm_reset_task_ns_refs();
	rcu_barrier();

	for (;;) {
		spin_lock_irqsave(&droid_lkm_pidns_lock, flags);
		if (list_empty(&droid_lkm_pidns_list)) {
			spin_unlock_irqrestore(&droid_lkm_pidns_lock, flags);
			break;
		}
		e = list_first_entry(&droid_lkm_pidns_list, struct droid_lkm_pidns_entry, node);
		list_del_init(&e->node);
		spin_unlock_irqrestore(&droid_lkm_pidns_lock, flags);

		if (droid_lkm_ns_stashed(droid_lkm_pidns_ns(e->ns)) ||
		    refcount_read(droid_lkm_pidns_refcount(e->ns)) > 1 ||
		    !idr_is_empty(droid_lkm_pidns_idr(e->ns))) {

			droid_lkm_warn("pidns %p neutralized+leaked (stashed=%p count=%d)\n",
				e->ns, droid_lkm_ns_stash_ptr(
					droid_lkm_pidns_ns(e->ns)),
				refcount_read(droid_lkm_pidns_refcount(e->ns)));
			droid_lkm_pidns_set_child_reaper(
				e->ns, droid_lkm_pidns_retire_reaper);
			droid_lkm_ns_neutralize(droid_lkm_pidns_ns(e->ns),
						droid_lkm_pidns_neutral_ops);
			leaked++;
			caches_clean = false;
			continue;
		}

#ifdef DROID_LKM_NATIVE_PID
		if (droid_lkm_pid_use_native) {
			droid_native_put_pid_ns(e->ns);
			kfree(e);
			continue;
		}
#endif
		idr_destroy(droid_lkm_pidns_idr(e->ns));
		if (droid_lkm_pidns_ns(e->ns)->inum)
			droid_lkm_ks.proc_free_inum(
				droid_lkm_pidns_ns(e->ns)->inum);
		kmem_cache_free(droid_lkm_pidns_cachep, e->ns);
		kfree(e);
	}

	if (leaked) {
		droid_lkm_warn("%d pidns leaked on unload, pid caches kept\n", leaked);
		return;
	}

#ifdef DROID_LKM_NATIVE_PID
	if (droid_lkm_pid_use_native) {
		droid_native_pidns_exit();
		return;
	}
#endif
	for (i = 0; i < MAX_PID_NS_LEVEL; i++) {
		if (droid_lkm_pid_cache[i]) {
			kmem_cache_destroy(droid_lkm_pid_cache[i]);
			droid_lkm_pid_cache[i] = NULL;
		}
	}

	if (droid_lkm_pidns_cachep && caches_clean) {
		kmem_cache_destroy(droid_lkm_pidns_cachep);
		droid_lkm_pidns_cachep = NULL;
	}
}

/*
 * /proc/sys/kernel/ns_last_pid. the kernel registers it under
 * CONFIG_CHECKPOINT_RESTORE only, so a stock GKI kernel leaves a container no
 * way to choose the next pid. the table is global like upstream's, and the
 * handler resolves the namespace of the caller on every access.
 *
 * upstream reads the cursor through idr_get_cursor()/idr_set_cursor(), which are
 * static inline in include/linux/idr.h on every branch we build for, so there is
 * no symbol to resolve and the field is touched directly as those do.
 */

static int droid_lkm_pidns_sysctl_zero;
static int droid_lkm_pidns_pid_max = PID_MAX_LIMIT;

static int droid_lkm_pidns_ns_last_pid(DROID_LKM_CTL_TABLE *table, int write,
				       void *buffer, size_t *lenp, loff_t *ppos)
{
	struct pid_namespace *ns = task_active_pid_ns(current);
	struct ctl_table tmp = *table;
	int ret, next;

	if (!ns)
		return -ENOENT;

	/* the owner of the namespace authorizes the write, as upstream does */
	if (write && (!droid_lkm_pidns_user_ns(ns) ||
		      !ns_capable(droid_lkm_pidns_user_ns(ns),
				  CAP_CHECKPOINT_RESTORE)))
		return -EPERM;

	/*
	 * the cursor is volatile in a live namespace and writers are expected to
	 * serialize among themselves, so no lock is taken here
	 */
	next = READ_ONCE(droid_lkm_pidns_idr(ns)->idr_next) - 1;

	tmp.data = &next;
	ret = proc_dointvec_minmax(&tmp, write, buffer, lenp, ppos);
	if (!ret && write)
		WRITE_ONCE(droid_lkm_pidns_idr(ns)->idr_next, next + 1);

	return ret;
}

static struct ctl_table droid_lkm_pidns_sysctls[] = {
	{
		.procname	= "ns_last_pid",
		.maxlen		= sizeof(int),
		.mode		= 0666,	/* the handler checks the capability */
		.proc_handler	= droid_lkm_pidns_ns_last_pid,
		.extra1		= &droid_lkm_pidns_sysctl_zero,
		.extra2		= &droid_lkm_pidns_pid_max,
	},
	{ }	/* 5.10 finds the end of a table through a null procname */
};

static struct ctl_table_set droid_lkm_pidns_sysctl_set;
static struct ctl_table_header *droid_lkm_pidns_sysctl_header;
static struct ctl_table *droid_lkm_pidns_sysctl_tbl;

static struct ctl_table_set *droid_lkm_pidns_sysctl_lookup(struct ctl_table_root *root)
{
	return &droid_lkm_pidns_sysctl_set;
}

static int droid_lkm_pidns_sysctl_is_seen(struct ctl_table_set *set)
{
	return set == &droid_lkm_pidns_sysctl_set;
}

static struct ctl_table_root droid_lkm_pidns_sysctl_root = {
	.lookup		= droid_lkm_pidns_sysctl_lookup,
};

void droid_lkm_pidns_sysctl_init(void)
{
	struct path path;
	struct ctl_table *tbl;
	int *pid_max;

	if (!droid_lkm_sysctl_ready()) {
		droid_lkm_warn("no ns_last_pid: sysctl helpers unavailable\n");
		return;
	}

	/*
	 * a kernel built with CONFIG_CHECKPOINT_RESTORE already registered the
	 * file, and its handler resolves the same active namespace
	 */
	if (!kern_path("/proc/sys/kernel/ns_last_pid", 0, &path)) {
		path_put(&path);
		droid_lkm_dbg("ns_last_pid already provided by the kernel\n");
		return;
	}

	tbl = kmemdup(droid_lkm_pidns_sysctls, sizeof(droid_lkm_pidns_sysctls),
		      GFP_KERNEL);
	if (!tbl) {
		droid_lkm_warn("no ns_last_pid: out of memory\n");
		return;
	}

	/*
	 * the live pid_max is the upper bound upstream uses, and the static one
	 * only has to be permissive enough for a kernel without the symbol
	 */
	pid_max = (int *)droid_lkm_sym("pid_max");
	if (pid_max)
		tbl[0].extra2 = pid_max;

	droid_lkm_sysctl_setup_set(&droid_lkm_pidns_sysctl_set,
				   &droid_lkm_pidns_sysctl_root,
				   droid_lkm_pidns_sysctl_is_seen);
	droid_lkm_pidns_sysctl_header = droid_lkm_sysctl_register_table(
		&droid_lkm_pidns_sysctl_set, "kernel", tbl,
		ARRAY_SIZE(droid_lkm_pidns_sysctls) - 1);
	if (!droid_lkm_pidns_sysctl_header) {
		droid_lkm_sysctl_retire_set(&droid_lkm_pidns_sysctl_set);
		kfree(tbl);
		droid_lkm_warn("ns_last_pid registration failed\n");
		return;
	}
	droid_lkm_pidns_sysctl_tbl = tbl;

	droid_lkm_info("ns_last_pid registered\n");
}

void droid_lkm_pidns_sysctl_exit(void)
{
	if (!droid_lkm_pidns_sysctl_header)
		return;

	unregister_sysctl_table(droid_lkm_pidns_sysctl_header);
	droid_lkm_pidns_sysctl_header = NULL;
	droid_lkm_sysctl_retire_set(&droid_lkm_pidns_sysctl_set);
	kfree(droid_lkm_pidns_sysctl_tbl);
	droid_lkm_pidns_sysctl_tbl = NULL;
}
