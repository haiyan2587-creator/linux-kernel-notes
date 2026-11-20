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

## 6. 待验证的问题

读代码时逐条确认，确认一条就把复选框勾上：

- [ ] `switch_to()` 换栈之后，返回地址是从 next 的栈上取的，需要对着 `arch/x86` 的汇编确认这个细节
- [ ] `finish_task_switch()` 里为什么还能安全访问 `prev`——此时 prev 的栈已经不属于当前执行流
- [ ] `pick_next_task()` 的快路径在什么条件下会被跳过，跳过后行为是否等价
- [ ] `preempt_count` 非零时调用 `schedule()` 会发生什么，`might_sleep` 是否覆盖这种情况
- [ ] `update_rq_clock()` 为什么必须在拿锁之后调用，早调会怎样

## 7. 参考

- `Documentation/scheduler/` 下的说明文件
- LWN 上关于 CFS 与调度器演进的系列文章
- 《Linux 内核设计与实现》第 4 章（概念入门，不够深入）
- 源码 `git log kernel/sched/core.c`，看每次改动解决了什么问题
