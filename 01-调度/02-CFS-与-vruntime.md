# CFS 与 vruntime（Linux 7.4.0 校对版）

> 内核如何在多个可运行任务之间分配 CPU 时间，以及为什么"公平"可以用一条除法表达。
> 关联：[01-__schedule-主流程](./01-__schedule-主流程.md)（切换动作）｜[01-task_struct-与内核栈](../00-基础/01-task_struct-与内核栈.md)（任务与栈）

## 0. 范围与版本

**本文以 Linux 7.4.0 为基准**（`Makefile`：`VERSION = 7`、`PATCHLEVEL = 4`），用 `tools/verify-claims.sh` 逐条核对过。

**记账模型和挑选策略是两件事，必须分开看：**

| 项目 | 7.4 现状 |
| --- | --- |
| `vruntime` 的计算与权重换算 | **仍然成立**，CFS 时代的核心没变 |
| 红黑树作为容器 | 仍然用它，但**排序键从 `vruntime` 改成了 `deadline`** |
| 挑选下一个实体的判据 | `pick_eevdf()` 取代旧逻辑，先判 `entity_eligible()` 再取最早 `deadline` |
| 新任务放置 | 重写：`place_entity()` 用 `avg_vruntime()` + `vslice`，`START_DEBIT` 已删除 |
| 时间片推导 | `sched_slice()` / `__sched_period()` 在 7.4 中**不存在**，改为 `sysctl_sched_base_slice`（700µs）基准 |

**这一节不是免责声明，是勘误表。** 网上大量中文资料（包括我最初的版本）描述的是 5.x 行为：红黑树按 `vruntime` 排序、`START_DEBIT` 给新任务记欠账、时间片由 `sched_latency` 和 `min_granularity` 推出。这些在 7.4 里已经不成立。

标注约定沿用三级（定义见 [模板](../99-模板/内核笔记模板.md) 第 6 节）。本文除明确标 `推测待验证` 的条目外，其余均为 `已核对源码（7.4.0）`。

## 1. 它解决什么问题

假设有 N 个任务都要跑。理想的多任务 CPU 会让每个任务以 1/N 的速度同时推进，但真实 CPU 一次只能跑一个，切换还有成本。问题于是变成：**怎么让每个任务分到的 CPU 时间，逼近那个理想状态？**

CFS 的答案是记账。为每个任务维护一个"已经消耗了多少 CPU"的累计量，优先照顾消耗少的。这个量就是 `vruntime`。

关键在于它不是原始时间，是**加权后的虚拟时间**。权重来自 nice 值：优先级高的任务 `vruntime` 增长得慢，于是"跑得更久才追上别人"，自然分到更多 CPU。**不改变策略，只改变记账单位**——这是这套设计最漂亮的一点，也是它能跨越 CFS → EEVDF 两代而基本不变的原因。

## 2. 关键数据结构

### struct sched_entity

7.4 实测字段（`include/linux/sched.h`）：

| 字段 | 作用 |
| --- | --- |
| `vruntime` | 虚拟运行时间，单位 ns |
| `deadline` | **虚拟截止期，红黑树的排序键**（EEVDF 引入） |
| `vlag` | 虚拟滞后量，`entity_eligible()` 的判据基础 |
| `slice` | 本实体被分配的时间片长度（纳秒） |
| `slice_max` / `min_slice` / `max_slice` | 时间片的上下界与动态调整辅助值 |
| `min_vruntime` | 实体级的虚拟时间记录（区别于 `cfs_rq` 的同名字段） |
| `rel_deadline` | 截止期相对标记 |
| `load` | `struct load_weight`，权重与预计算倒数 |
| `run_node` | 挂在 `cfs_rq.tasks_timeline` 上的红黑树节点 |
| `exec_start` | 本次开始运行的时刻，算 `delta_exec` 的起点 |
| `sum_exec_runtime` | 实际消耗 CPU 时间累计（真时间，非虚拟） |
| `on_rq` | 是否在队列里 |

同一个任务在不同调度类里有不同实体：`task_struct` 里 `se`、`rt`、`dl` 三套并存，各自独立记账。

### struct cfs_rq

| 字段 | 作用 |
| --- | --- |
| `tasks_timeline` | 红黑树根，`rb_root_cached` 缓存最左节点 |
| `curr` | 当前正在跑的实体 |
| `next` / `last` | buddy 提示，用于唤醒抢占判断 |
| `min_vruntime` | 队列虚拟时钟底线，`avg_vruntime()` 的基础 |
| `load` | 队列内权重和 |
| `nr_running` / `h_nr_running` | 任务数（后者含组调度） |
| `h_nr_queued` | 已入队任务数，`place_entity()` 用它算排队位置 |

### struct load_weight

```
struct load_weight {
	unsigned long	weight;
	u32		inv_weight;
};
```

`weight` 来自 `sched_prio_to_weight[]`，取值刻意设计成**相邻 nice 约 1.25 倍**（源码注释原文：*"If a task goes up by ~10% and another task goes down by ~10% then the relative distance between them is ~25%"*）。

| nice | weight |
| --- | --- |
| -1 | 1277 |
| 0 | 1024（`NICE_0_LOAD`） |
| 1 | 820 |
| 5 | 335 |
| 10 | 110 |

`inv_weight` 是 `2^32 / weight` 的预计算值，作用很实际：**把除法变成乘法**。这个换算每次 tick 都要做，除法代价不可接受。

## 3. vruntime 是怎么算出来的

核心在 `update_curr()`：

```
delta_exec  = now - se->exec_start
se->exec_start = now
se->sum_exec_runtime += delta_exec
se->vruntime += delta_exec * NICE_0_LOAD / se->load.weight
```

第三行就是全部：

- `weight == NICE_0_LOAD`（nice 0）：`vruntime` 与真实时间 1:1 增长
- `weight == 2 × NICE_0_LOAD`：只涨一半 → 别人跑 2ms 才等于它跑 1ms → 约 2 倍 CPU
- `weight == 0.5 × NICE_0_LOAD`：涨两倍 → 约一半 CPU

**一条除法就编码了整套比例公平策略。** 不需要 if 分支判断优先级，不需要给不同任务设不同时间片——权重全部折进记账单位里。

实现在 `calc_delta_fair()` → `__calc_delta()`，后者用 `inv_weight` 走乘法：

```
fact = delta_exec * NICE_0_LOAD
if (lw->inv_weight)
	fact = mul_u32_u32(fact, lw->inv_weight) >> 32   // 等价于除以 weight
```

## 4. 红黑树与 EEVDF 的选择逻辑

**这里是我原先写错的地方，特此更正。**

7.4 的 `tasks_timeline` 仍然是一棵红黑树，但**排序键不是 `vruntime`，而是 `deadline`**。比较函数比较的是 `a->deadline` 与 `b->deadline`。所以"取最左节点"拿到的是**最早虚拟截止期**的实体，不是 `vruntime` 最小的实体。

选择流程（`pick_eevdf()`）：

1. `entity_eligible(cfs_rq, se)` —— 判断该实体的 `vlag` 是否已"还清欠账"（`vruntime_eligible()` 比较 `se->vruntime` 与队列的 `avg_vruntime()` 基准）
2. 在**合格**的实体中，取 `deadline` 最早的
3. 若 `cfs_rq->next`（唤醒抢占的候选）也合格，优先考虑它

所以 EEVDF 的判据是两步：**先合格（不能透支未来），再比截止期（谁更急）**。旧 CFS 只有一步——比 `vruntime` 谁小。多的这一步解决了 CFS 的一个老问题：纯粹比 `vruntime` 时，刚被唤醒的任务可能因为账面数字小而立刻抢占，导致频繁抖动。

**数据结构的取舍没变**，这部分结论仍然成立：

| 操作 | 链表 | 堆 | 红黑树 |
| --- | --- | --- | --- |
| 按 key 插入 | O(n) | O(log n) | O(log n) |
| 删除任意节点（任务阻塞） | O(1) 已知位置 | **O(n)** | O(log n) |
| 取最左 | O(1) | O(1) | O(log n)，**缓存后 O(1)** |

堆的致命伤在第二行：任务阻塞要按任意位置删除，堆做不到。链表插入 O(n)。红黑树三项都合格，取最小的劣势又被 `rb_leftmost` 缓存抹平。

## 5. 新任务与唤醒任务放在哪

7.4 的 `place_entity()` 签名是 `(struct cfs_rq *cfs_rq, struct sched_entity *se, int flags)`——注意第三个参数从旧版的 `initial` 布尔值改成了 `flags`（`ENQUEUE_*` 标志）。

实际代码片段：

```
u64 vslice, vruntime = avg_vruntime(cfs_rq);
unsigned int nr_queued = cfs_rq->h_nr_queued;
s64 lag = 0;

if (!se->custom_slice)
	se->slice = sysctl_sched_base_slice;
vslice = calc_delta_fair(se->slice, se);
```

三个变化值得记住：

1. **基准从 `min_vruntime` 换成 `avg_vruntime()`**。旧版用队列最小值，新版用平均值——平均值更能反映"队伍中位位置"，新任务不会因为队里有个落后的实体就被放得太靠前。
2. **欠账量由 `vslice` 计算**：`calc_delta_fair(se->slice, se)` 把时间片换算成虚拟时间单位。概念上是旧版 `sched_vslice()` 的等价物，但不再依赖 `__sched_period()`。
3. **`START_DEBIT` 特性已删除**，新任务的记账不再靠开关控制，机制固化进 `place_entity()` 本身。

旧版的两条修正（`START_DEBIT` 记欠账、`GENTLE_FAIR_SLEEPERS` 限制睡眠补偿）在 7.4 的 `fair.c` 里**都搜不到**。它们要解决的问题——新任务独占 CPU、睡眠进程醒来霸占 CPU——现在由 `vlag` 与 `entity_eligible()` 统一处理：透支的实体不合格，自然排不上。

**这个演进的思路值得记住**：旧版用两个特殊开关打补丁，新版把"不许透支"变成第一等判据。补丁变成原则，特例就消失了。

## 6. 时间片：从"推导"变成"配置"

旧模型（5.x）不设固定时间片，只定义目标延迟，再由权重比例推出每个任务分多少。7.4 里这套机制不存在了：`sched_slice()`、`sched_vslice()`、`__sched_period()` 都搜不到。

现在是一个直接的基准值：

```
unsigned int sysctl_sched_base_slice = 700000ULL;   // 700µs
```

配合实体自带的 `slice`、`min_slice`、`max_slice`、`slice_max`，由 `update_deadline()` 在时间片到期时推进该实体的 `deadline`。

含义上的变化：

- 旧模型：时间片 = 周期 × 权重占比，任务越多每个越短（周期被拉长以保吞吐）
- 新模型：**每个实体先拿一个基准 slice，再按权重与 `vlag` 调整**，截止期由 slice 与 `vruntime` 共同决定

`se->slice` 的完整缩放规则（`slice_max`、`min_slice`/`max_slice` 怎么参与调整）我没有逐行读完，属 `推测待验证`。可确认的是基准值 700µs 与这些字段的存在。

## 7. 代码路径

| 文件 | 内容 |
| --- | --- |
| `kernel/sched/fair.c` | `update_curr()`、`__calc_delta()`、`place_entity()`、`pick_eevdf()`、`entity_eligible()`、`update_deadline()`、`avg_vruntime()` |
| `include/linux/sched.h` | `struct sched_entity`（含 `deadline` / `vlag` / `slice`）、`struct load_weight` |
| `kernel/sched/sched.h` | `struct cfs_rq` |
| `kernel/sched/core.c` | `sched_prio_to_weight[]`、`NICE_0_LOAD` |
| `kernel/sched/debug.c` | `/proc/sched_debug` 输出逻辑 |
| `tools/verify-claims.sh` | 本文断言的自动核对脚本 |

旧的 `kernel/sched/features.h` 里已无 `START_DEBIT`、`GENTLE_FAIR_SLEEPERS`，别再按老文章的指引去找。

## 8. 验证手段

`/proc/sched_debug` 能看到每个 `cfs_rq` 的基准与每个实体的 `vruntime`：

```bash
cat /proc/sched_debug | sed -n '/cpu#0/,/^$/p'
```

单任务视角：

```bash
cat /proc/<pid>/sched | grep -E "se.sum_exec_runtime|se.vruntime|nr_switches"
```

**一个值得亲手做的实验**——验证权重比是否真的转化为 CPU 份额：

```bash
nice -n 0  sh -c 'while :; do :; done' &
nice -n 10 sh -c 'while :; do :; done' &
pidstat 1 5     # 两者 CPU% 之比应接近 1024 : 110 ≈ 9.3 : 1
kill %1 %2
```

用 `pidstat 1` 看多秒平均，别用 `top` 的瞬时值——单次采样偏差很大。

## 9. 结论

标注：`已核对源码（7.4.0）` / `推测待验证`。

### 9.1 一条除法编码了全部比例公平策略

**已核对源码（7.4.0）。** `vruntime += delta_exec * NICE_0_LOAD / weight`，`calc_delta_fair()` 与 `inv_weight` 均在源码中确认。策略可组合：调权重即可改变份额，不用动选择逻辑。

### 9.2 红黑树是被"任意删除"逼出来的选择

**已核对源码（7.4.0）。** `rb_root_cached` 与 `tasks_timeline` 确认存在。任务阻塞需按任意位置删除，堆做不到 O(log n)，链表插入 O(n)。

### 9.3 红黑树的排序键已从 vruntime 换成 deadline

**已核对源码（7.4.0）。** 比较函数取 `a->deadline` 与 `b->deadline`。**旧文章说"取 vruntime 最小的实体"在 7.4 上是错的**，取的是最早截止期。

### 9.4 新任务放置改用 avg_vruntime，START_DEBIT 已删除

**已核对源码（7.4.0）。** `place_entity()` 签名带 `flags`，内部用 `avg_vruntime(cfs_rq)` 与 `vslice = calc_delta_fair(se->slice, se)`。`START_DEBIT`、`GENTLE_FAIR_SLEEPERS` 在 `fair.c` 中均不存在。

### 9.5 时间片改为 base_slice 基准

**已核对源码（7.4.0）**（基准值 700µs 确认）。`sched_slice()` / `__sched_period()` 已移除。具体的 slice 动态调整规则属 `推测待验证`。

### 9.6 权重表 1.25 倍的用意

**已核对源码（7.4.0）。** `sched_prio_to_weight[40]` 存在，且源码注释自己写了"相对距离约 25%"。nice 差一级约 25% 份额差，差 10 级约 9.3 倍。

## 10. 仍然没解决的

- [ ] `update_deadline()` 推进 `deadline` 的完整公式，`slice_max` / `min_slice` / `max_slice` 的调整规则
- [ ] `vlag` 的更新时机与 `avg_vruntime()` 的维护成本（这棵辅助树的开销是否在热路径上）
- [ ] 组调度（`CONFIG_FAIR_GROUP_SCHED`）下，`cfs_rq.load` 的层级聚合如何影响单任务实际份额
- [ ] CFS 带宽控制（`cpu.max`）与 `vruntime` 记账的交互：被 throttle 期间 `vruntime` 是否继续增长

最后一条特别值得查。容器里跑 CPU 限流时观察到的行为异常，很多能追到这里。

## 11. 参考

- `kernel/sched/fair.c` 顶部注释与 `place_entity()` 前后的大段注释，写了 EEVDF 的设计意图
- LWN 关于 EEVDF 引入的系列文章（2023 年前后）
- `Documentation/scheduler/sched-design-CFS.rst`（注意：部分内容未跟上 EEVDF）
- 复核方式：`./tools/verify-claims.sh <源码目录>`
