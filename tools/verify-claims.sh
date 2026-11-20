#!/usr/bin/env bash
#
# 核对笔记中的技术断言是否与真实源码一致。
#
# 用法：
#   ./tools/verify-claims.sh /path/to/linux
#
# 说明：
#   本脚本只做"关键标识符是否存在于预期位置"的粗粒度检查。
#   输出 NG 有两种可能：
#     1) 笔记写错了
#     2) 你的源码版本与笔记写作时的版本不一致（函数被改名、逻辑被替换）
#   两种情况都需要人去看一眼，脚本只负责把注意力引到正确的位置。
#
#   检查通过（OK）的条目，可以把笔记里对应的「依据已知实现」升级为「已核对源码」。

set -u

K="${1:-}"
if [ -z "$K" ] || [ ! -d "$K/kernel/sched" ]; then
	printf '用法: %s <内核源码根目录>\n' "$0" >&2
	printf '例如: %s ~/linux\n' "$0" >&2
	exit 2
fi

pass=0
fail=0

check() {
	local desc="$1" file="$2" pattern="$3"
	if [ ! -f "$K/$file" ]; then
		printf '  ??  %s\n      文件缺失: %s\n' "$desc" "$file"
		fail=$((fail + 1))
		return
	fi
	if grep -qE -- "$pattern" "$K/$file" 2>/dev/null; then
		printf '  OK  %s\n' "$desc"
		pass=$((pass + 1))
	else
		printf '  NG  %s\n      在 %s 中未匹配到: %s\n' "$desc" "$file" "$pattern"
		fail=$((fail + 1))
	fi
}

printf '源码根目录: %s\n' "$K"
printf '内核版本  : '; make -s -C "$K" kernelversion 2>/dev/null || echo "(无法读取，跳过)"
echo

echo "[00-基础] task_struct 与内核栈"
check "current 由 per-CPU current_task 提供" include/linux/sched.h 'DECLARE_PER_CPU\(struct task_struct \*, *current_task\)'
check "x86 用 this_cpu_read_stable 取 current" arch/x86/include/asm/current.h 'this_cpu_read_stable\(current_task\)'
check "thread_info 内嵌在 task_struct 中" include/linux/sched.h 'struct thread_info *thread_info'
check "THREAD_SIZE_ORDER 定义在 page_64_types.h" arch/x86/include/asm/page_64_types.h 'THREAD_SIZE_ORDER'
check "系统调用手动切栈：cpu_current_top_of_stack" arch/x86/entry/entry_64.S 'cpu_current_top_of_stack'
check "栈溢出魔数检查" kernel/fork.c 'STACK_END_MAGIC'
echo

echo "[01-调度] __schedule 主流程"
check "rq 时钟更新前断言持锁" kernel/sched/core.c 'lockdep_assert_rq_held\(rq\)'
check "__switch_to_asm 以 jmp 进入 __switch_to（非 call）" arch/x86/entry/entry_64.S 'jmp[[:space:]]+__switch_to'
check "finish_task_switch 清 on_cpu" kernel/sched/core.c 'smp_store_release\(&prev->on_cpu'
check "调度类按链表顺序遍历" kernel/sched/sched.h 'for_each_class'
echo

echo "[01-调度] CFS 与 vruntime"
check "权重表存在" kernel/sched/core.c 'sched_prio_to_weight\[40\]'
check "calc_delta_fair 参与 vruntime 累加" kernel/sched/fair.c 'calc_delta_fair'
check "inv_weight 用于免除法换算" kernel/sched/fair.c 'inv_weight'
check "红黑树最左节点缓存" kernel/sched/sched.h 'rb_root_cached'
check "新任务起始欠账 START_DEBIT" kernel/sched/fair.c 'START_DEBIT'
check "睡眠补偿上限 GENTLE_FAIR_SLEEPERS" kernel/sched/fair.c 'GENTLE_FAIR_SLEEPERS'
check "时间片由权重比例推导" kernel/sched/fair.c 'sched_slice'
echo

echo "[版本差异] EEVDF 是否已接管挑选策略"
if grep -qE 'u64[[:space:]]+deadline' "$K/include/linux/sched.h" 2>/dev/null; then
	printf '  OK  sched_entity 已含 deadline 字段 → 当前源码为 EEVDF 时代\n'
	printf '      笔记第 0 节的范围说明适用，第 4 节的红黑树选点逻辑需按 EEVDF 复核\n'
	pass=$((pass + 1))
else
	printf '  --  sched_entity 未见 deadline 字段 → 可能是 EEVDF 之前的版本\n'
	printf '      此时笔记第 0 节的范围说明需相应调整\n'
fi
echo

printf '通过 %d 项，需人工确认 %d 项\n' "$pass" "$fail"
echo
echo "提示：把 OK 的条目在笔记中标注为「已核对源码」，并记下内核版本号。"
echo "      版本号比结论更重要——半年后你能靠它判断这条结论是否还成立。"

exit 0
