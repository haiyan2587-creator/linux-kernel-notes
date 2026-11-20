# EEVDF：eligible 与 lag

> 补齐第三篇留下的核心问题：`vlag` 怎么算、`avg_vruntime()` 怎么维护、`update_deadline()` 的完整公式。
> 关联：[02-CFS-与-vruntime](./02-CFS-与-vruntime.md)（记账模型）｜[01-__schedule-主流程](./01-__schedule-主流程.md)（切换动作）

## 0. 这篇要回答什么

第三篇把一个悬念留在这里：EEVDF 为什么要在"挑最早截止期"之前加一道"合格性"检查，`lag` 到底是什么。

本文全部结论标注 `已核对源码（7.4.0）`，代码来自 `kernel/sched/fair.c`。

## 1. 它解决什么问题

CFS 的判据只有一条：取 `vruntime` 最小的实体。这在数学上公平，但有个副作用——**任何 `vruntime` 偏小的实体都能立刻抢占**。一个刚被唤醒的任务，账面数字可能比所有人都小，于是它一醒就把正在跑的任务踢下去；跑一小会儿 `vruntime` 追上，又被别人踢下去。结果是频繁抖动，延迟不可预测。

EEVDF 加了一道约束：**不许透支**。

任务的 `vruntime` 落后于队列平均值，说明它"被欠了服务"（lag 为正）；领先于平均值，说明它"预先消费了未来的 CPU"（lag 为负）。**只有 lag ≥ 0 的实体才允许被挑选**。

判据从一条变成两条：

1. 必须 **eligible**（欠着服务，不许吃老本）
2. 在合格的实体里，取**虚拟截止期最早**的

第一条保证公平，第二条保证延迟可控。CFS 只有第二条的雏形（比 `vruntime`），EEVDF 把"资格"显式化了。

## 2. lag 的定义

源码注释给的原始定义：

```
lag_i = S - s_i = w_i * (V - v_i)
```

- `S` 是按当前虚拟时钟该享有的服务量，`s_i` 是实际得到的
- `V` 是队列的加权平均 `vruntime`，`v_i` 是该实体的 `vruntime`
- `w_i` 是权重

直接跟踪 `lag_i` 要带 `w_i`，太麻烦。所以实际只跟踪**虚拟滞后**：

```
vl_i = V - v_i        <=>   v_i = V - vl_i
```

于是合格判据退化成一次比较：

```
lag_i >= 0   <=>   V >= v_i
```

**`lag ≥ 0` 等价于"我的 vruntime 没跑在队伍平均值前面"。** 这就是 `entity_eligible()` 的全部内容。

`sched_entity.vlag` 存的就是这个 `vl_i`。

## 3. V 怎么维护：增量，不遍历

`V` 是加权平均，直觉上每次都要扫一遍队列。实际不是——源码维护三个量做增量更新：

```
cfs_rq->sum_w_vruntime    // Σ w_i * (v_i - v0)，相对基准 v0 的加权和
cfs_rq->sum_weight        // Σ w_i
cfs_rq->zero_vruntime     // 基准 v0 本身
```

所有实体同时前进 `d` 时：

```
v' = v + d  ==>  sum_w_vruntime' = sum_w_vruntime - d * sum_weight
                 zero_vruntime += d
```

`avg_vruntime()` 只需把当前正在跑的实体（不在队列里但还在消耗 CPU）补进来，再做一次除法取平均。**O(1)**，不需要遍历树。

两个实现细节值得记：

1. **返回值有向左偏置**。源码要求 `avg_vruntime() + 0` 必须使 `entity_eligible()` 为真——即平均值本身必须算"合格"。为此除法要向下取整（源码注释：*"the result of this function must have a left bias"*）。
2. **`avg_vruntime()` 有三个调用点**，各有明确时机：`place_entity()`（入队前）、`update_entity_lag()`（出队前）、`update_deadline()`（时间片到期）。

## 4. 合格判据为什么不直接用除法

`vruntime_eligible()` 里没有除法。它把 `V >= v_i` 两边乘 `W` 变形：

```
Σ (v_j - v0) * w_j  >=  (v_i - v0) * W
```

左边是现成的 `sum_w_vruntime`，右边只需一次乘法。源码注释直说了原因：

> *using `avg_vruntime() > se->vruntime` is inaccurate due to the loss in precision caused by the division*

调度判断每次 tick 都在跑，用整数除法会丢精度，还可能让"刚好相等"的边界来回翻转。**改成乘法比较，既快又不会误判。**

代价是要处理溢出。64 位下 `key * load` 可能超 `s64`，源码给了三条路：

| 配置 | 做法 |
| --- | --- |
| 64 位 + `CONFIG_ARCH_SUPPORTS_INT128` | 用 `__int128` 直接算，最干净 |
| 64 位无 int128 | `check_mul_overflow()`，溢出时用 `key` 的符号判断（大正数→不合格，大负数→合格） |
| 32 位 | 直接乘，位宽够 |

## 5. 截止期怎么算

`update_deadline()` 的公式只有一行，注释写得很明确：

```
EEVDF:  vd_i = ve_i + r_i / w_i
```

对应代码：

```c
if (vruntime_cmp(se->vruntime, "<", se->deadline))
	return false;

if (!se->custom_slice)
	se->slice = sysctl_sched_base_slice;

/* EEVDF: vd_i = ve_i + r_i / w_i */
se->deadline = se->vruntime + calc_delta_fair(se->slice, se);
avg_vruntime(cfs_rq);

return true;    /* 时间片用完，该重调度了 */
```

读法：

- `ve_i` 是实体的 `vruntime`，`r_i` 是请求的时间片（`se->slice`，默认 `sysctl_sched_base_slice` = 700µs），`w_i` 是权重
- `calc_delta_fair(slice, se)` 把真实时间片换算成虚拟时间——**和第三篇那条除法是同一个函数**
- 第一行的短路判断是关键：如果 `vruntime` 还没走到 `deadline`，直接返回 `false`，什么都不算。**这就是"时间片还没用完"的判定**
- 返回 `true` 表示请求已耗尽，调用方据此触发重调度

所以 `deadline` 不是时间戳，是**在虚拟时间轴上，"这个任务该被换下去"的位置**。

## 6. pick_eevdf 怎么在树上找

> **先分清两层**：`pick_eevdf(cfs_rq, protect)` 只做挑选；实际调用它的是 `pick_next_entity(rq, protect)`（`fair.c` 约 6694 行），后者挑出实体后还要处置 `sched_delayed`——若被选中的实体处于延迟出队状态，会执行 `__dequeue_task(rq, task_of(se), DEQUEUE_SLEEP | DEQUEUE_DELAYED)`，并且此后**不能再引用 `se`**（注释指向 `__block_task()`）。所以"挑出来"和"挑完怎么处置"是两步。

### 增强红黑树

第三篇说过树按 `deadline` 排序。这里补上被省略的一半：**这棵树同时是一棵以 `vruntime` 为键的堆**，靠每个节点维护：

```
se->min_vruntime = min(se->vruntime, se->left->min_vruntime, se->right->min_vruntime)
```

用途是**剪枝**。因为"合格"关于 `vruntime` 单调（`vruntime` 越小越容易合格），所以只要左子树的 `min_vruntime` 都不合格，整个左子树就可以跳过：

```c
if (left && vruntime_eligible(cfs_rq, __node_2_se(left)->min_vruntime)) {
	node = left;      /* 左子树里一定有合格实体，且 deadline 更早 */
	continue;
}
```

**一棵树同时服务两个键**：按 `deadline` 有序保证"最早截止期"，按 `min_vruntime` 的堆性保证"能快速跳过不合格的子树"。这是 O(log n) 而不是 O(n) 的原因。

### 挑选流程

按源码顺序：

1. **只有一个实体** → 直接返回，省掉所有检查
2. **buddy 优先**：`PICK_BUDDY` 开启且 `cfs_rq->next` 合格 → 返回它。注释写明*"Picking the ->next buddy will affect latency but not fairness"*——唤醒抢占优先，但不影响公平
3. **当前实体仍合格且有保护窗口** → 继续跑它
4. **最左节点合格** → 就是它（`deadline` 最早且合格）
5. **否则堆搜索**：沿树下降，左子树有合格实体就向左，否则检查当前节点，都不行向右
6. **收尾**：若没找到，或 `curr` 的截止期比找到的更早，用 `curr`

### 保护窗口 vprot

第 3 步的"保护"值得单独说。`se->vprot` 是一个受保护的 `vruntime` 上限：

```c
static inline bool protect_slice(struct sched_entity *se)
{
	return vruntime_cmp(se->vruntime, "<", se->vprot);
}
```

只要 `vruntime` 没到 `vprot`，正在跑的实体就不会被换下去。作用相当于"最小执行量"——防止一个任务刚上 CPU 就被更早截止期的实体踢走，导致切换开销吃掉全部收益。

`set_protect_slice()` 里还涉及两个特性开关：`RUN_TO_PARITY`（跑到与队伍持平为止，用队列中最短 slice 作保护期）和 `PREEMPT_SHORT`（更短 slice 的实体可提前抢占）。

## 7. place_entity 为什么这么复杂

这是本篇最难的一段，也是旧版文章最容易讲错的地方。

朴素想法：新任务入队，给它记一笔欠账，别让它插到队首。但真实的难点在于——**加入一个实体本身就会改变 `V`**。

源码注释给了完整推导。设加入前加权平均为 `V`，总权重 `W`，新实体虚拟滞后 `vl_i`、权重 `w_i`：

```
V' = (V*(W + w_i) - w_i*vl_i) / (W + w_i)
   = V - w_i*vl_i / (W + w_i)

vl'_i = V' - v_i = vl_i - w_i*vl_i / (W + w_i)     <  vl_i
```

**新实体的滞后在加入瞬间就变小了。** 如果不补偿，一个睡觉很久、攒了正滞后的任务，一入队滞后就被"稀释"掉，等于白睡——公平性被破坏。

所以入队前要先把滞后**放大**，使得入队后正好等于原来的值。把上式反解：

```
vl_i = (W + w_i) * vl'_i / W
```

这就是 `place_entity()` 里 `PLACE_LAG` 分支在做的事。注释把这称作 *"placement strategy #1 / #2"*。

三个要点：

1. 滞后不是"重新算"，而是**从出队时保存的 `vlag` 恢复**（`update_entity_lag()` 在出队前记下）
2. `avg_vruntime()` 被调用两次是有意的：一次算基准，一次在状态改变后刷新
3. 若 `PLACE_LAG` 关闭，则退化为"直接放到 `avg_vruntime()` 附近"

对照组：旧版 CFS 用 `START_DEBIT` 给新任务记固定欠账、用 `GENTLE_FAIR_SLEEPERS` 限制睡眠补偿上限。那是两个**特例补丁**；EEVDF 用"滞后守恒"变成一条**通用原则**。补丁消失，是因为问题被重新表述了。

## 8. 验证手段

```bash
cat /proc/sched_debug | sed -n '/cpu#0/,/^$/p'    # 看 rq 与各实体的 vruntime
cat /proc/<pid>/sched | grep -E "se.vruntime|se.sum_exec_runtime"
```

想观察"不许透支"的实际效果，可以对比不同 nice 值下的抢占频率：

```bash
# 一个长任务 + 一个反复睡眠唤醒的短任务，观察后者是否收敛到应有份额
chrt -b 0 ./long_task &          # SCHED_BATCH
for i in $(seq 200); do sleep 0.01; done &
pidstat 1 10
```

反复睡醒的任务如果每次都抢占成功、把长任务反复踢下去，说明 lag 补偿机制在起作用；观察 `pidstat` 里的 `cswch/s`（自愿切换）和 `nvcsw` 变化最直观。

## 9. 结论

标注：`已核对源码（7.4.0）` / `推测待验证`。

### 9.1 合格的判据是 lag ≥ 0，等价于 V ≥ v_i

**已核对源码（7.4.0）。** 源码注释：*"Entity is eligible once it received less service than it ought to have, eg. lag >= 0"*，`entity_eligible()` 直接调 `vruntime_eligible(cfs_rq, se->vruntime)`。

### 9.2 合格判断用乘法不用除法

**已核对源码（7.4.0）。** 注释明确指出除法精度损失会导致误判，实现改为 `avg >= (__int128)key * load`，并有三套溢出处理分支。

### 9.3 V 是增量维护的，每次 O(1)

**已核对源码（7.4.0）。** 维护 `sum_w_vruntime` / `sum_weight` / `zero_vruntime` 三个量，全体前移时只做一次乘减。`avg_vruntime()` 不需要遍历树。

### 9.4 截止期 = vruntime + slice 折算成虚拟时间

**已核对源码（7.4.0）。** `se->deadline = se->vruntime + calc_delta_fair(se->slice, se)`，公式注释为 `vd_i = ve_i + r_i / w_i`。`update_deadline()` 返回 `true` 即表示请求耗尽、需要重调度。

### 9.5 树是"按 deadline 排序 + 按 min_vruntime 剪枝"的双重结构

**已核对源码（7.4.0）。** 注释明确：*"The tree keeps the entries sorted on deadline, but also functions as a heap based on the vruntime by keeping se->min_vruntime = min(...)"*。这是 O(log n) 的来源。

### 9.6 入队要补偿"加入动作本身对 V 的扰动"

**已核对源码（7.4.0）（推导部分）。** 注释给出完整代数推导与反解式 `vl_i = (W + w_i)*vl'_i / W`。`PLACE_LAG` 分支实现该逻辑。**补偿代码的完整分支（含负滞后、`sched_delayed` 等情形）我只读到前 80 行，未逐行确认**，属`推测待验证`。

## 10. 仍然没解决的

- [ ] `entity_lag()` 里除 `w_i` 之外的钳制逻辑（lag 上下界从哪来）
- [ ] `sched_delayed` 机制：延迟出队（`DELAY_ZERO`）与 lag 截断的交互
- [ ] `avg_vruntime_weight()` 在组调度下的权重聚合，与单任务场景的差别
- [ ] `cfs_rq_min_slice()` 与 `RUN_TO_PARITY` 的完整语义：它如何影响实际吞吐与延迟
- [ ] `PREEMPT_SHORT` 打开后的抢占频率变化，是否有实测数据

## 11. 参考

- `kernel/sched/fair.c` 第 730–800 行（`avg_vruntime` 与设计注释）、870–960 行（lag 与合格判据）、1060–1215 行（保护窗口与 `pick_eevdf`）、1232 行起（`update_deadline`）、6335 行起（`place_entity`）
- LWN 关于 EEVDF 的原始提案与合并讨论
- 复核方式：`./tools/verify-claims.sh <源码目录>`
