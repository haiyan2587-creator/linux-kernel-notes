#!/usr/bin/env bash
#
# 核对笔记中的技术断言是否与真实源码一致。
#
# 用法：
#   ./tools/verify-claims.sh /path/to/linux
#
# 不想下载整个仓库时，用部分克隆：
#   git clone --depth 1 --filter=blob:none --sparse git@github.com:torvalds/linux.git ~/linux
#   git -C ~/linux sparse-checkout set --no-cone /Makefile /kernel/sched/ /kernel/fork.c \
#       /include/linux/sched.h /include/linux/thread_info.h /arch/x86/entry/ /arch/x86/include/asm/
#
# 输出 NG 有两种可能：
#   1) 笔记写错了
#   2) 源码版本与笔记基准版本不同（函数改名或逻辑被替换）
# 两种情况都要人去看一眼，脚本负责把注意力引到正确位置。
#
# 检查通过（OK）的条目，可把笔记中对应的「依据已知实现」升级为「已核对源码」，并注明版本。

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
		printf '  ??  %s\n      文件缺失: %s（可能未包含在稀疏检出中）\n' "$desc" "$file"
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

ver="$(awk -F' = ' '/^VERSION =/{v=$2} /^PATCHLEVEL =/{p=$2} /^SUBLEVEL =/{s=$2} END{if(v!="")print v"."p"."s}' "$K/Makefile" 2>/dev/null)"

printf '源码根目录: %s\n' "$K"
printf '内核版本  : %s\n' "${ver:-（无法读取 Makefile）}"
echo

echo "[00-基础] task_struct 与内核栈"
check "current_task 以 per-CPU 热缓存变量声明" arch/x86/include/asm/current.h 'DECLARE_PER_CPU_CACHE_HOT\(struct task_struct \*, *current_task\)'
check "存在 const 别名 const_current_task" arch/x86/include/asm/current.h 'const_current_task'
check "get_current 走 this_cpu_read_stable" arch/x86/include/asm/current.h 'this_cpu_read_stable\(current_task\)'
check "thread_info 内嵌在 task_struct 中" include/linux/sched.h 'struct thread_info *thread_info'
check "THREAD_SIZE_ORDER 在 page_64_types.h" arch/x86/include/asm/page_64_types.h 'THREAD_SIZE_ORDER'
check "系统调用手动切栈：cpu_current_top_of_stack" arch/x86/entry/entry_64.S 'cpu_current_top_of_stack'
check "栈溢出魔数检查" kernel/fork.c 'STACK_END_MAGIC'
check "每 CPU 独立中断栈" arch/x86/include/asm/processor.h 'irq_stack'
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
check "EEVDF：挑选入口 pick_eevdf" kernel/sched/fair.c 'pick_eevdf'
check "EEVDF：合格性判据 entity_eligible" kernel/sched/fair.c 'entity_eligible'
check "EEVDF：基准 avg_vruntime" kernel/sched/fair.c 'avg_vruntime'
check "EEVDF：截止期推进 update_deadline" kernel/sched/fair.c 'update_deadline'
check "时间片基准 sched_base_slice" kernel/sched/fair.c 'sched_base_slice'
echo

echo "[01-调度] EEVDF：eligible 与 lag"
check "lag 与虚拟滞后的定义注释" kernel/sched/fair.c 'lag_i = S - s_i'
check "合格判据 entity_lag" kernel/sched/fair.c 'entity_lag'
check "滞后守恒入队 PLACE_LAG" kernel/sched/fair.c 'PLACE_LAG'
check "保护窗口 vprot" kernel/sched/fair.c 'vprot'
check "增强树按 min_vruntime 剪枝" kernel/sched/fair.c 'se->min_vruntime'
check "截止期公式 vd = ve + r/w" kernel/sched/fair.c 'vd_i = ve_i \+ r_i / w_i'
check "RUN_TO_PARITY 特性" kernel/sched/fair.c 'RUN_TO_PARITY'
check "PICK_BUDDY 特性" kernel/sched/fair.c 'PICK_BUDDY'
echo

echo "[版本判据] 当前源码属于哪一代"
if grep -qE 'pick_eevdf' "$K/kernel/sched/fair.c" 2>/dev/null; then
	printf '  --  EEVDF 时代：笔记第 0 节的勘误表适用\n'
	if grep -qE 'START_DEBIT' "$K/kernel/sched/fair.c" 2>/dev/null; then
		printf '      但仍检出 START_DEBIT，属过渡期版本，需逐条复核\n'
	else
		printf '      旧特性 START_DEBIT / GENTLE_FAIR_SLEEPERS 已确认不存在\n'
	fi
else
	printf '  --  非 EEVDF 版本：勘误表不适用，旧版描述可能成立\n'
fi
echo

printf '通过 %d 项，需人工确认 %d 项\n' "$pass" "$fail"
echo
echo "提示：把 OK 的条目在笔记中标注为「已核对源码（版本号）」。"
echo "      版本号比结论更重要——半年后你能靠它判断这条结论是否还成立。"

exit 0
