# CFS 与 vruntime

> 内核如何在多个可运行任务之间分配 CPU 时间，以及为什么"公平"可以用一条除法表达。
> 关联：[01-__schedule-主流程](./01-__schedule-主流程.md)（切换动作）｜[01-task_struct-与内核栈](../00-基础/01-task_struct-与内核栈.md)（任务与栈）

## 0. 先划清范围

**本篇讲的是记账模型，不是当前版本的挑选策略。**

`vruntime` 这套虚拟时间记账法从 2.6.23 起支撑 CFS，至今仍是比例公平的计算基础。但"下一个该跑谁"的策略，在 6.6 之后已由 **EEVDF**（Earliest Eligible Virtual Deadline First）接管，`sched_entity` 里多了 `deadline` 字段，`pick_next_entity()` 不再单纯取红黑树最左节点。

所以读这篇时要把两件事分开：

| 仍然成立 | 已经改变 |
| --- | --- |
| `vruntime` 的计算方式、权重换算、`min_vruntime` 的作用 | 挑选下一个任务的判据（EEVDF 改为"合格时间 + 虚拟截止期"） |
| 红黑树作为按 `vruntime` 排序的容器 | `pick_next_entity()` 的具体逻辑 |
| 新任务与唤醒任务的放置策略 | 时间片与延迟的推导细节 |

详见第 10 节。**不要把这套模型当成当前内核的全部**，这是读调度器最容易踩的坑——网上大量文章停留在 5.x 时代。

## 1. 它解决什么问题

假设有 N 个任务都要跑。理想的多任务 CPU 会让每个任务以 1/N 的速度同时推进，但真实 CPU 一次只能跑一个，切换还有成本。于是问题变成：**怎么让每个任务分到的 CPU 时间，逼近那个理想状态？**

CFS 的答案是记账。为每个任务维护一个"已经消耗了多少 CPU"的累计量，每次选消耗最少的那个来跑。这个量就是 `vruntime`。

关键在于它不是原始时间，是**加权后的虚拟时间**。权重来自 nice 值：优先级高的任务，`vruntime` 增长得慢，于是"跑得更久才追上别人"，自然分到更多 CPU。**不改变策略，只改变记账单位**——这是 CFS 设计上最漂亮的一点。

## 2. 关键数据结构

### struct sched_entity

| 字段 | 作用 |
| --- | --- |
| `vruntime` | 虚拟运行时间，红黑树的排序键，单位 ns |
| `load` | `struct load_weight`，承载权重与预计算的倒数 |
| `run_node` | 挂在 `cfs_rq.tasks_timeline` 上的红黑树节点 |
| `exec_start` | 本次开始运行的时刻，算 `delta_exec` 的起点 |
| `sum_exec_runtime` | 实际消耗的 CPU 时间累计（真时间，非虚拟） |
| `prev_sum_exec_runtime` | 上次出队时的 `sum_exec_runtime`，用于算本次运行量 |
| `on_rq` | 是否在队列里 |
| `cfs_rq` | 所属的 CFS 运行队列 |
| `my_q` | 组调度时指向自己管辖的 `cfs_rq` |

同一个任务在不同调度类里有不同的实体：`task_struct` 里 `se`、`rt`、`dl` 三套并存，各自独立记账。

### struct cfs_rq

| 字段 | 作用 |
| --- | --- |
| `tasks_timeline` | 红黑树根，`rb_root_cached` 缓存了最左节点 |
| `curr` | 当前正在跑的实体 |
| `next` / `last` | buddy 提示，用于唤醒抢占判断 |
| `min_vruntime` | 单调不减的虚拟时钟底线，新任务放置的基准 |
| `load` | 队列内所有实体的权重和，用于算时间片份额 |
| `nr_running` / `h_nr_running` | 队列任务数（后者含组调度） |
| `exec_clock` | 队列级的执行时钟 |

### struct load_weight

```
struct load_weight {
	unsigned long	weight;
	u32		inv_weight;
};
```

`weight` 来自 `sched_prio_to_weight[]` 表，取值有个刻意设计：**相邻 nice 之间约 1.25 倍**。

| nice | weight |
| --- | --- |
| -1 | 1277 |
| 0 | 1024（`NICE_0_LOAD`） |
| 1 | 820 |
| 5 | 335 |
| 10 | 110 |

1024 / 820 ≈ 1.25，820 / 656 ≈ 1.25。这个常数不是随便调的：1.25 倍意味着"高一级优先级的任务，拿到的 CPU 约多 25%"，而 nice 差 10 级时比值约 9.3 倍——数量级合理，不会出现"差一级就天壤之别"。

`inv_weight` 是 `2^32 / weight` 的预计算值。作用很实际：**把除法变成乘法**。这个换算在每次时钟 tick 上都要做，除法代价不可接受。

## 3. vruntime 是怎么算出来的

核心在 `update_curr()`，每次 tick、每次入队出队都会调用：

```
delta_exec  = now - se->exec_start
se->exec_start = now
se->sum_exec_runtime += delta_exec
se->vruntime += delta_exec * NICE_0_LOAD / se->load.weight
```

第三行就是全部：

- `weight == NICE_0_LOAD`（nice 0）：`vruntime` 与真实时间 1:1 增长
- `weight == 2 × NICE_0_LOAD`（约 nice -5）：`vruntime` 只涨一半 → 别人跑 2ms 才等于它跑 1ms → 它拿到约 2 倍 CPU
- `weight == 0.5 × NICE_0_LOAD`：`vruntime` 涨两倍 → 只拿到约一半 CPU

**一条除法就编码了整套比例公平策略。** 不需要 if 分支判断优先级，不需要给不同任务设不同时间片——权重全部折进记账单位里了。

实现上这一步是 `calc_delta_fair()` → `__calc_delta()`，后者用 `inv_weight` 走乘法：

```
fact = delta_exec * NICE_0_LOAD
if (lw->inv_weight)
	fact = mul_u32_u32(fact, lw->inv_weight) >> 32   // 等价于除以 weight
```

## 4. 红黑树怎么被使用

`cfs_rq.tasks_timeline` 是一棵按 `vruntime` 排序的红黑树。选下一个任务 = 取最左节点 = `vruntime` 最小者。

**为什么是红黑树，不是堆或链表**——三种操作必须同时便宜：

| 操作 | 链表 | 堆 | 红黑树 |
| --- | --- | --- | --- |
| 按 `vruntime` 插入 | O(n) | O(log n) | O(log n) |
| 删除任意节点（任务 sleep） | O(1) 已知位置 | **O(n)** | O(log n) |
| 取最小 | O(1) | O(1) | O(log n)，**缓存后 O(1)** |

堆的致命伤在第二行：任务阻塞时要按任意位置删除，堆做不到。链表插入是 O(n)。红黑树是唯一三项都合格的结构，而第三行的劣势被 `rb_root_cached` 的 `rb_leftmost` 缓存抹掉了。

> 一个细节：`rb_root_cached` 维护最左节点指针，插入删除时同步更新。所以"取最小"实际是一次指针读取，不是树遍历。

## 5. 新任务与唤醒任务放在哪

这是 `vruntime` 模型里最需要动脑的地方。

### min_vruntime 的作用

`min_vruntime` 是队列的虚拟时钟底线，**只增不减**。它解决一个朴素问题：树里所有任务的 `vruntime` 都在涨，需要一个基准来判断"什么算旧账、什么算新账"。

### 新任务不能从 0 开始

如果新 fork 的任务 `vruntime = 0`，而队列里其他人已经攒到几十毫秒，这个新任务会**独占 CPU 直到追上所有人**——单次能跑几百毫秒，交互体验直接崩掉。

`place_entity(initial=1)` 的处理是给它记一笔起始欠账：

```
vruntime = min_vruntime + sched_vslice(cfs_rq, se)
```

`sched_vslice()` 把"一个时间片"换算成 `vruntime` 单位。效果是新任务排在队伍末尾附近，而不是插到最前面。这个特性叫 `START_DEBIT`。

### 唤醒任务不能拿全额补偿

任务睡眠期间 `vruntime` 不涨（它没消耗 CPU）。醒来时它的 `vruntime` 可能远低于所有人，于是立刻抢占——这对交互式进程是好事，但如果全额补偿，一个睡了一小时的进程醒来能霸占 CPU 很久。

`GENTLE_FAIR_SLEEPERS` 特性的做法是把补偿限制在一个调度周期内：

```
vruntime = max(se->vruntime, min_vruntime - sysctl_sched_latency)
```

**这两处修正体现同一个原则：纯粹按 `vruntime` 最小来选，公平性成立但响应性会崩。** 公平和响应是一对矛盾，CFS 用这两处"欠账"和"限账"在中间找平衡点。

## 6. 时间片不是配出来的，是算出来的

CFS 没有固定时间片，它只定义**目标延迟**，具体分给每个任务多少由权重比例推出：

```
period = __sched_period(nr_running)
  nr_running <= sched_nr_latency  →  period = sysctl_sched_latency
  nr_running >  sched_nr_latency  →  period = nr_running * sysctl_sched_min_granularity

slice = period * se->load.weight / cfs_rq->load.weight
```

两个常量的作用：

- `sysctl_sched_latency` —— 目标延迟，即"所有可运行任务都轮一遍"的期望时间
- `sysctl_sched_min_granularity` —— 最小粒度，防止任务过多时切换开销吃掉全部 CPU

`sched_nr_latency = sched_latency / min_granularity`（默认 8）。任务数超过这个值，周期不再固定，而是随任务数线性增长——**牺牲延迟保证吞吐**。

这两个常量的默认值随内核版本和 CPU 数量变化（有 `1 + ilog2(nr_cpus)` 的缩放），别记数字，看 `sysctl_sched_*` 的当前值。

## 7. 代码路径

| 文件 | 内容 |
| --- | --- |
| `kernel/sched/fair.c` | 全部核心逻辑：`update_curr()`、`__calc_delta()`、`place_entity()`、`enqueue_entity()`、`pick_next_entity()`、`sched_slice()` |
| `include/linux/sched.h` | `struct sched_entity`、`struct load_weight` |
| `kernel/sched/sched.h` | `struct cfs_rq` |
| `kernel/sched/core.c` | `sched_prio_to_weight[]` 权重表、`NICE_0_LOAD` |
| `kernel/sched/debug.c` | `/proc/sched_debug` 的输出逻辑 |
| `kernel/sched/features.h` | `START_DEBIT`、`GENTLE_FAIR_SLEEPERS` 等特性开关 |

## 8. 验证手段

`/proc/sched_debug` 是最直接的观察窗口，能看到每个 `cfs_rq` 的 `min_vruntime` 和每个实体的 `vruntime`：

```bash
cat /proc/sched_debug | sed -n '/cpu#0/,/^$/p'
```

单任务视角看 `/proc/<pid>/sched`：

```bash
cat /proc/<pid>/sched | grep -E "se.sum_exec_runtime|se.vruntime|nr_switches"
```

**一个值得亲手做的实验**——验证权重比是否真的转化为 CPU 份额：

```bash
# 两个 CPU 密集型任务，一个默认 nice，一个 nice 10
nice -n 0  sh -c 'while :; do :; done' &
nice -n 10 sh -c 'while :; do :; done' &
top          # 观察两者 CPU% 之比，应接近 1024 : 110 ≈ 9.3 : 1
kill %1 %2
```

如果实测偏离 9.3:1 很多，说明观测期间有其它负载干扰，或者看的不是 `%CPU` 的瞬时值——用 `pidstat 1` 看多秒平均更准。

## 9. 结论

置信度沿用三级标注：`已核对源码` / `依据已知实现` / `推测待验证`（定义见 [01-__schedule-主流程](./01-__schedule-主流程.md) 第 6 节）。**本页没有一条达到第一级**，可用 `./tools/verify-claims.sh <源码目录>` 核对后升级。

### 9.1 一条除法编码了全部比例公平策略

**依据已知实现。** `vruntime += delta_exec * NICE_0_LOAD / weight`。优先级完全折进记账单位，不需要分支判断。带来的直接好处是策略可组合：想让某个任务多拿 CPU，调权重即可，不用改选择逻辑。

### 9.2 红黑树是被"任意删除"逼出来的选择

**依据已知实现（结论）。** 任务阻塞需要按任意位置删除，堆做不到 O(log n)；链表插入 O(n)。红黑树三项都合格，取最小的开销又被 `rb_leftmost` 缓存抹平。

### 9.3 新任务必须记欠账

**依据已知实现。** `place_entity(initial=1)` 里 `vruntime = min_vruntime + sched_vslice()`。没有这一步，新进程会独占 CPU 追平历史，交互性崩溃。

### 9.4 睡眠补偿必须设上限

**依据已知实现（机制）。** 默认值行为属`推测待验证`。`GENTLE_FAIR_SLEEPERS` 把补偿限制在 `sysctl_sched_latency` 内。这个开关的存在本身就说明：**纯粹的最小 `vruntime` 优先，公平成立但响应不成立。**

### 9.5 时间片是派生量

**依据已知实现（公式）。** 常量默认值`推测待验证`。CFS 只定义目标延迟，时间片由权重比例算出。任务数超过 `sched_nr_latency` 后周期线性拉长，用延迟换吞吐。

### 9.6 权重表 1.25 倍的用意

**依据已知实现（数值）。** `sched_prio_to_weight[]` 相邻项比值约 1.25。目的是让 nice 差一级对应约 25% 的份额差，差 10 级约 9.3 倍——单调但不失控。

## 10. 仍然没解决的

- [ ] **EEVDF 的 eligible / deadline 判据**：`sched_entity.deadline` 怎么算，`lag` 与 `vruntime` 如何共同决定"合格"，这是当前版本的核心
- [ ] `sysctl_sched_latency` 的 `1 + ilog2(nr_cpus)` 缩放在什么场景下会失效（CPU 热插拔？cgroup 限核？）
- [ ] 组调度（`CONFIG_FAIR_GROUP_SCHED`）下，`cfs_rq.load` 的层级聚合如何影响单任务实际份额
- [ ] CFS 带宽控制（`cpu.max`）与 `vruntime` 记账的交互：被 throttle 的期间，`vruntime` 是否继续增长

最后一条特别值得查。容器里跑 CPU 限流时观察到的行为异常，很多能追到这个问题上。

## 11. 参考

- `Documentation/scheduler/sched-design-CFS.rst`
- `kernel/sched/fair.c` 顶部注释，写了设计意图
- LWN 关于 EEVDF 引入的系列文章（2023 年前后），理解"为什么替换 CFS 的挑选逻辑"
- `Documentation/scheduler/sched-stats.rst`
