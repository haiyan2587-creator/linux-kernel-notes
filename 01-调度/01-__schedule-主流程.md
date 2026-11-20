# __schedule() 主流程

> 一次上下文切换到底发生了什么：从 `schedule()` 进入，到寄存器换栈，再到新任务跑起来。

## 1. 它解决什么问题

CPU 核数远少于可运行任务数。内核必须在阻塞点和抢占点决定"下一个谁上"，并把当前任务的现场保存下来、把下一个任务的现场恢复回去。这个动作叫上下文切换，唯一的真正入口是 `__schedule()`。

`schedule()` 只是薄封装：检查抢占是否被禁用，然后调用 `__schedule(SM_NONE)`。

关键约束：

- 调用者**不能已持有** `rq->lock`，锁由 `__schedule()` 自己拿
- `__schedule()` 可以在任意进程上下文中被调用，所以中断状态由内部管理
- 它可能被调用后**不切换**（挑出来的 next 就是 prev），此时直接返回

## 2. 入口与调用链

两条进入路径：

- **主动让出**：任务自己调 `schedule()`，典型场景是等 IO、`wait_event` 睡眠
- **被动抢占**：中断或系统调用返回时发现 `TIF_NEED_RESCHED`，走 `preempt_schedule()` 或返回用户态前调度

```
schedule()
 └─ __schedule(SM_NONE)
      ├─ rq = cpu_rq(cpu)                    取当前 CPU 的运行队列
      ├─ prev = rq->curr                     当前任务
      ├─ update_rq_clock(rq)                 同步 rq 时钟
      ├─ prev_state = prev->__state          记下睡眠原因
      ├─ rq_lock(rq, &rf)                    拿 rq->lock，关中断
      ├─ deactivate_task(rq, prev, ...)      prev 不可运行时出队
      ├─ pick_next_task(rq, prev, &rf)       按调度类优先级挑 next
      │    └─ for_each_class() 依次询问：
      │       stop → dl → rt → fair → idle
      ├─ rq->nr_switches++                   统计
      ├─ context_switch(rq, prev, next, &rf)
      │    ├─ prepare_task_switch()          tracepoint、perf 事件
      │    ├─ switch_to(prev, next, prev)    架构相关：换栈、换寄存器
      │    └─ finish_task_switch()           mm 切换、清理 prev
      └─ 返回
```

**最容易被忽略的一点**：`__schedule()` 返回时，执行流已经属于另一个任务了。同一个函数，进去和出来不是同一个栈。所以函数返回之后打印 `current`，看到的是 next 而不是 prev。

`pick_next_task()` 会先尝试一条快路径（当前任务属于 fair 类且可运行任务数等于 CFS 队列长度时直接问 fair），失败才退回到 `for_each_class()` 逐个询问。

## 3. 关键数据结构

### struct rq —— 每个 CPU 一个

`DEFINE_PER_CPU_SHARED_ALIGNED(struct rq, runqueues)`，用 `cpu_rq(cpu)` 取。一个 CPU 一条队列，这是调度决策的基本单位。

| 字段 | 含义 | 为什么关键 |
| --- | --- | --- |
| `curr` | 当前正在跑的任务 | 切换的起点 |
| `idle` | 本 CPU 的 idle 任务 | 没有可运行任务时的兜底，永远不会空 |
| `nr_running` | 可运行任务总数 | 判断"有没有必要调度"的依据 |
| `clock` / `clock_task` | rq 时钟 | 所有统计与 `vruntime` 的时间基准 |
| `cfs` / `rt` / `dl` | 各调度类的子队列 | 调度类各自维护自己的组织方式 |
| `lock` | rq 自旋锁 | 保护整个 rq，切换全过程持有 |
| `nr_switches` | 累计切换次数 | `/proc` 统计与调试的原始来源 |

### struct task_struct —— 调度相关字段

| 字段 | 含义 |
| --- | --- |
| `__state` | 任务状态：`TASK_RUNNING` / `TASK_INTERRUPTIBLE` / `TASK_UNINTERRUPTIBLE` / `TASK_STOPPED` |
| `policy` | 调度策略：`SCHED_NORMAL` / `BATCH` / `IDLE` / `FIFO` / `RR` / `DEADLINE` |
| `prio` / `static_prio` / `normal_prio` | 三级优先级，`prio` 是实际生效的动态值 |
| `sched_class` | 指向所属调度类的函数表 |
| `se` / `rt` / `dl` | 各调度类的调度实体，同一任务在不同类里有不同的实体 |
| `on_rq` / `on_cpu` | 是否在运行队列中 / 是否正占着一个 CPU |

`__state` 与 `on_rq` 必须一起看：状态不是 `TASK_RUNNING` 的任务会被 `deactivate_task()` 移出队列。

### struct sched_class —— 函数表

各调度类通过 `next` 指针串成链表，`for_each_class()` 从 `stop_sched_class` 一路走到 `idle_sched_class`。优先级由链表顺序隐含，不靠数字比较。

## 4. 代码路径

| 文件 | 内容 |
| --- | --- |
| `kernel/sched/core.c` | `schedule()`、`__schedule()`、`pick_next_task()`、`context_switch()` |
| `kernel/sched/sched.h` | `struct rq`、`struct sched_class` |
| `kernel/sched/fair.c` | CFS 实现、`pick_next_task_fair()` |
| `arch/x86/include/asm/switch_to.h` | `switch_to` 宏 |
| `arch/x86/kernel/process_64.c` | `__switch_to()` |

行号会随版本漂移，**以函数名为锚点定位**，不要记行号。

## 5. 验证手段

读代码之外，这几条命令能看到实际行为：

```bash
cat /proc/sched_debug | head -40          # 每个 rq 的状态与队列
cat /proc/<pid>/status | grep ctxt        # nvcsw 自愿切换 / nivcsw 非自愿
perf sched record -- sleep 5              # 录制真实切换
perf sched latency                        # 看谁在等、等了多久
chrt -f 10 <cmd>                          # 用 SCHED_FIFO 跑一个进程
taskset -c 0 <cmd>                        # 绑到单核，剔除迁移干扰
```

`taskset -c 0` 这个习惯值得养成：绑核之后 `load_balance` 不再介入，观察到的现象更干净。

## 6. 五个问题的结论

> 结论基于当前开发线的代码结构。调度器改动频繁，**函数名与标志位相对稳定，细节以手上的源码为准**。
> **标注约定**（三级，不可混用）
>
> - `已核对源码` —— 用 `tools/verify-claims.sh` 在本机源码确认过，并记录了内核版本号
> - `依据已知实现` —— 来自对内核实现的理解，**未在源码中逐条核对**。可能有版本偏差
> - `推测待验证` —— 明确是推断，尚未找到依据
>
> 本页结论目前**全部属于第二级或第三级**，没有一条达到第一级。跑一遍
> `./tools/verify-claims.sh <内核源码目录>`，把输出 OK 的条目升级为 `已核对源码`，
> 并注明内核版本——版本号比结论更重要，它决定这条结论半年后是否还成立。

### 6.1 switch_to() 换栈后，返回地址来自 next 的栈

**依据已知实现。**

`arch/x86/entry/entry_64.S` 里的 `__switch_to_asm` 只做四件事：

1. 把 6 个 callee-saved 寄存器（`rbp`、`rbx`、`r12`–`r15`）push 到**当前任务 prev 的栈**上
2. `movq %rsp, TASK_threadsp(%rdi)` —— 把栈顶指针存进 `prev->thread.sp`
3. `movq TASK_threadsp(%rsi), %rsp` —— 从 `next->thread.sp` 恢复栈顶
4. 从 next 的栈上 pop 出那 6 个寄存器

关键在最后一步：`__switch_to_asm` 结尾是 **`jmp __switch_to`，不是 `call`**。这意味着没有新的返回地址被压栈。所以 `__switch_to` 执行到 `ret` 时，弹出的是 next 栈上那个地址——也就是 next 当初被切出去时留下的、它自己 `call __switch_to_asm` 之后的那条指令。

这就是"同一个函数进去和出来不是同一个栈"的机制来源。至于 `switch_to` 宏里的 `last` 参数：`__switch_to` 的返回值（`%rax`）是 `prev`，宏把它赋给 `last`，调用者借此知道"我刚才从谁手上接过了 CPU"。

### 6.2 finish_task_switch() 为什么能安全访问 prev

**依据已知实现（结论）。** 配对的内存序细节属`推测待验证`。

先拆掉一个概念混淆：`prev` 是 `struct task_struct *`，结构体分配在 slab 里，**不在栈上**。换栈只是换了 `%rsp`，这个指针本身依然有效。所以"栈已经被别人用了"根本不构成危险。

真正要回答的是"结构体会不会被释放"。答案是不会，因为 `finish_task_switch()` 自己就是释放前的最后一道关口：

- `finish_task(prev)` 里执行 `smp_store_release(&prev->on_cpu, 0)`，把 prev 标记为"已离开 CPU"
- 任务的退出路径必须等 `on_cpu` 清零才能继续走完销毁流程
- 该 store 与唤醒路径上的 `smp_load_acquire(&p->on_cpu)` 配对

所以执行期间 prev 的生命周期被 `on_cpu` 这个引用语义钉住。这也解释了它为什么必须在**新任务**的上下文里跑完——它跑完，旧任务才被允许真正消失。

附一个容易漏的细节：进入 `finish_task_switch()` 时 `rq->lock` 是**不持有**的，函数内部自己 `rq_lock()` 重新拿锁，并用 `smp_mb__after_spinlock()` 保证顺序。

### 6.3 pick_next_task() 快路径的跳过条件

**依据已知实现（旧版结构）。** 新版本此路径有简化，需按实际代码复核。

快路径要求两个条件同时成立：

1. `prev->sched_class == &fair_sched_class` —— 当前任务属于 CFS
2. `rq->nr_running == rq->cfs.h_nr_running` —— 可运行任务**全部**在 CFS 队列里，即没有任何 RT / DL 任务可运行

满足则直接调 `pick_next_task_fair()`，跳过整条 `for_each_class()` 链。跳过它的情况：prev 属于 RT/DL/stop/idle 类；存在可运行的 RT 或 DL 任务；`pick_next_task_fair()` 返回 `RETRY_TASK`（需要重来）。

收益很小但位置极热：`for_each_class()` 每轮都要逐类试探，而这一段在每次切换时都会执行。行为等价的前提是"没有更高优先级的类有任务可跑"，这个前提正好由条件 2 保证——所以快路径并不是优化掉了一次检查，而是**用一个更便宜的判据替代了一次完整检查**。

### 6.4 preempt_count 非零时调用 schedule()

**依据已知实现。**

在原子上下文（`preempt_count` 非零，或中断关闭）里调用 `schedule()` 属于**代码缺陷**，不是可用的编程手法。开启 `CONFIG_SCHED_DEBUG` 后会走 `__schedule_bug()`，打印：

```
BUG: scheduling while atomic
```

并把 `preempt_count` 强行设成 `PREEMPT_DISABLED`，遮蔽后续连锁错误，好让系统还能继续跑出更多现场信息。`CONFIG_DEBUG_ATOMIC_SLEEP` 则在更早的位置用 `__might_resched()` 拦截。

一个容易混淆的点：**抢占路径不调 `schedule()`**。它走 `preempt_schedule()`，入口先用 `preemptible()` 判断 `preempt_count() == 0 && !irqs_disabled()`，不满足就直接返回。所以"被抢占"和"主动让出"是两条独立入口，最终都汇到 `__schedule()`。

### 6.5 update_rq_clock() 必须持锁

**依据已知实现。**

函数体第一行就是 `lockdep_assert_rq_held(rq)`，这是设计约束的显式表达。原因有两层：

1. `rq->clock` 不是纯本地数据。远端 CPU 在负载均衡、唤醒迁移路径上会拿到目标 rq 的锁并更新它的时钟，不持锁的读改写会竞态。
2. rq 时钟必须**单调递增**。重复调用靠 `RQCF_ACT_SKIP` / `RQCF_REQ_SKIP` 标志避免重复累加，这套标志和时钟值一样受锁保护。

在 `__schedule()` 里它排在 `rq_lock()` 之后、`deactivate_task()` 之前，目的是让后续出队/入队用到的时间基准已经同步。

## 7. 仍然没解决的

- [ ] `__switch_to_asm` 的寄存器保存顺序必须与 `inactive_task_frame` 结构体布局严格一致，改一处就得改另一处。这条约束在哪些架构上有编译期检查？
- [ ] `finish_task_switch()` 里 `rq->prev_mm` 的交接时机，与 `switch_mm_irqs_off()` 调用顺序之间的依赖关系
- [ ] `RETRY_TASK` 的完整触发链路，以及核心调度（core scheduling）与 `try_to_wake_up` 的交互

## 8. 参考

- `Documentation/scheduler/` 下的说明文件
- LWN 上关于 CFS 与调度器演进的系列文章
- 《Linux 内核设计与实现》第 4 章（概念入门，不够深入）
- 源码 `git log kernel/sched/core.c`，看每次改动解决了什么问题
- `arch/x86/entry/entry_64.S`、`arch/x86/include/asm/switch_to.h`
