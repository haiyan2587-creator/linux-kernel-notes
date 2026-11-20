# task_struct 与内核栈

> 调度那一节讲 `__schedule()` 换栈，本篇说清"栈"到底是什么、`current` 又从哪来。
> 关联：[01-调度/01-__schedule-主流程](../01-调度/01-__schedule-主流程.md)

## 1. 它解决什么问题

内核要为每个任务保存两类完全不同的状态：

- **描述信息**：谁、什么状态、占哪些资源、父进程是谁
- **执行现场**：调用链、局部变量、返回地址

前者是 `task_struct`，后者是内核栈。分开存放的原因是访问模式不同：`task_struct` 要在调度、遍历、统计里被按指针随机访问；内核栈必须连续、随调用深度增长、且每任务独占。

由此推出一条硬约束：**内核栈不能换出、不能动态增长**。所以内核代码禁止大局部数组和深递归——这不是编码风格偏好，是 16KB 的物理上限。

## 2. 关键数据结构

### task_struct 中与栈直接相关的字段

| 字段 | 作用 |
| --- | --- |
| `stack` | 内核栈起始地址，由 `alloc_thread_stack_node()` 赋值 |
| `thread_info` | 内嵌的线程信息，`flags` 里的 `TIF_NEED_RESCHED` 是调度的触发位 |
| `thread` | 架构相关，x86_64 的 `thread_struct` 存 `sp`、`fsbase`、`gsbase` |
| `mm` / `active_mm` | 用户地址空间；内核线程 `mm` 为 NULL，借用 `active_mm` |
| `pid` / `tgid` | 线程 ID / 线程组 ID，**用户看到的"进程号"是 `tgid`** |

`task_struct` 的大小随配置浮动很大（关掉调试约 1KB 出头，全开可能到几 KB），记数字没有意义，用 `pahole` 看实际值。

### 内核栈的组织

| 项 | 说明 |
| --- | --- |
| 大小 | `THREAD_SIZE`，x86_64 为 16KB（`THREAD_SIZE_ORDER = 2`，4 个 4KB 页） |
| 分配 | `alloc_thread_stack_node()`；`CONFIG_VMAP_STACK` 下走 vmalloc 并带保护页 |
| 溢出检测 | 栈底写 `STACK_END_MAGIC`，由 `task_stack_end_corrupted()` 检查 |
| 金丝雀 | `CONFIG_STACKPROTECTOR`，编译期插入，运行时校验 |
| 中断栈 | x86_64 每 CPU 有独立中断栈，嵌套异常用 IST |

## 3. 两者的关系

```
struct task_struct          ← task_struct_cachep slab 中分配
 ├─ thread_info            ← 内嵌（CONFIG_THREAD_INFO_IN_TASK）
 │    ├─ flags（TIF_NEED_RESCHED / TIF_SIGPENDING …）
 │    └─ cpu
 ├─ stack                  ← 指向内核栈起始地址
 ├─ thread (arch)          ← thread_struct：sp、fsbase、gsbase…
 └─ mm / files / cred …

内核栈  THREAD_SIZE = 16KB（x86_64）
 高地址 ┌──────────────────┐  栈底
        │ pt_regs           │  进入内核时构造
        │ 局部变量 / 调用帧  │  ↓ 向低地址增长
        │ 栈顶 ← %rsp       │
 低地址 └──────────────────┘  VMAP_STACK 下紧邻一个 guard page
```

**注意 `%rsp` 与 `task_struct` 之间没有任何硬关联**——这是 `CONFIG_THREAD_INFO_IN_TASK` 带来的解耦。也正因如此，上一节里 `finish_task_switch()` 才能安全访问 `prev`：换栈只改了 `%rsp`，`task_struct` 的位置没变。

### current 是怎么找到的

`current` 是内核里出现频率最高的宏之一，x86_64 上的实现：

```c
DECLARE_PER_CPU(struct task_struct *, current_task);

static __always_inline struct task_struct *get_current(void)
{
	return this_cpu_read_stable(current_task);
}
#define current get_current()
```

`this_cpu_read_stable` 编译成一条读 `%gs` 段偏移的 `mov`。`%gs` 的基址在用户态与内核态不同，靠 `swapgs` 切换：

- 从用户态进内核：`swapgs` 把基址换成 per-CPU 区
- 返回用户态：再 `swapgs` 换回

结论：`current` **不需要查表、不需要遍历，一条指令**。这是内核里"随手拿当前任务"这个习惯成立的性能前提。

历史做法正好相反：`thread_info` 曾放在栈上，靠 `current_thread_info()` 用 `%rsp & ~(THREAD_SIZE - 1)` 掩码算出，再从 `thread_info` 反推 `task_struct`。既要求栈按 `THREAD_SIZE` 对齐，又让栈溢出可以直接篡改 `thread_info`。

## 4. 从用户态进内核时栈怎么切

这是整个机制里最容易断的一环。用户态和内核态用不同的栈，切换依赖两条路径：

| 入口 | 机制 |
| --- | --- |
| 系统调用（`SYSCALL` 指令） | 硬件**不切栈**。`entry_SYSCALL_64` 里手动 `movq PER_CPU_VAR(cpu_current_top_of_stack), %rsp` |
| 中断 / 异常 | 硬件通过 TSS 的 `sp0` 字段取内核栈顶，发生特权级变化时自动切换 |

两条路径最终都落到同一个位置：**当前任务内核栈的顶端**，然后在那里构造 `pt_regs`。

这里有个细节值得记：系统调用要软件手动切栈，是因为 `SYSCALL` 指令设计上只为性能，不做特权级栈切换；而中断走 IDT，硬件会按 TSS 自动切。同一个"进入内核"，两条路径的栈来源不同。

## 5. 代码路径

| 文件 | 内容 |
| --- | --- |
| `include/linux/sched.h` | `struct task_struct` 定义、`current` 声明 |
| `include/linux/thread_info.h` | `struct thread_info`、`TIF_*` 标志 |
| `kernel/fork.c` | `alloc_thread_stack_node()`、`dup_task_struct()`、`set_task_stack_end_magic()` |
| `arch/x86/include/asm/current.h` | x86 的 `get_current()` 实现 |
| `arch/x86/entry/entry_64.S` | `entry_SYSCALL_64`，手动切栈的位置 |
| `arch/x86/include/asm/processor.h` | `thread_struct`、`THREAD_SIZE` 相关定义 |
| `kernel/irq_64.c`（或 `arch/x86/kernel/irq_64.c`） | 每 CPU 中断栈 |

行号会漂移，**以函数名和宏名为锚点**。

## 6. 验证手段

```bash
pahole -C task_struct vmlinux | tail -3        # 结构体大小与总偏移
pahole -C thread_info vmlinux                  # 确认已内嵌
cat /proc/<pid>/stack                          # 某个阻塞任务的内核栈回溯
echo t > /proc/sysrq-trigger                   # 打印所有阻塞任务的栈
./scripts/checkstack.pl x86_64 < System.map    # 找栈帧过大的函数
```

`CONFIG_DEBUG_STACK_USAGE` 打开后，任务退出时会打印它用过的最深栈深度——这是判断"16KB 到底够不够"的唯一实测手段，比看代码猜可靠。

用 crash 工具看运行中的系统：

```
crash> task <pid>      # 打印 task_struct 关键字段
crash> bt <pid>        # 栈回溯，同时能看到栈的起止地址
```

## 7. 结论

置信度沿用三级标注：`已核对源码` / `依据已知实现` / `推测待验证`（定义见 [01-__schedule-主流程](../01-调度/01-__schedule-主流程.md) 第 6 节）。**本页没有一条达到第一级**，可用 `./tools/verify-claims.sh <源码目录>` 核对后升级。

### 7.1 current 是一条指令

**依据已知实现。** `get_current()` 展开成读 `%gs` 段偏移的 `mov`，前提是 `swapgs` 已正确执行。用户态和内核态各自的 gs 基址由 `MSR_GS_BASE` 与 `MSR_KERNEL_GS_BASE` 两个 MSR 保存，`swapgs` 交换两者。若某条路径漏了 `swapgs`，`current` 会读到用户态的垃圾值——这类 bug 的表现是随机崩溃，而不是立即报错。

### 7.2 thread_info 搬进 task_struct 解决了什么

**依据已知实现（结论）。** 历史演进顺序属`推测待验证`。

两个收益是确定的：

1. **安全**：栈溢出不再能篡改 `thread_info.flags`。以前溢出到栈底就能伪造 `TIF_NEED_RESCHED` 或 `TIF_SIGPENDING`，等于把调度和信号的控制权交给了一个缓冲区越界。
2. **解耦**：`current` 不再依赖栈地址，栈可以放到 vmalloc 区（`CONFIG_VMAP_STACK`），从而获得保护页。

### 7.3 16KB 为什么"够"，以及为什么禁大栈

**部分`推测待验证`。**

确定的部分：`THREAD_SIZE` 是编译期常量，栈在任务创建时一次性分配，**运行期无法扩展**。所以任何"栈上开个大数组"的写法都是把溢出风险写进代码。

不确定的部分：最坏调用链到底有多深，没有权威上界。中断上下文比进程上下文更紧张，因为中断可能叠加在已经很深的进程栈上——这也正是需要独立中断栈的原因（见 7.5）。真正可靠的判断方式只有实测：开 `CONFIG_DEBUG_STACK_USAGE` 跑真实负载，看最大深度。

### 7.4 栈溢出怎么被发现

**依据已知实现。** 两种机制，可靠性差别很大：

| 机制 | 原理 | 局限 |
| --- | --- | --- |
| guard page（`CONFIG_VMAP_STACK`） | 栈后紧跟一页不可访问内存，越界立刻触发缺页异常 | 只能发现"跨过整页"的溢出，页内小越界漏掉 |
| `STACK_END_MAGIC` | 栈底写魔数，退出时校验是否被改写 | **事后**发现，损坏已经发生 |

所以 guard page 是把"静默踩内存"变成"明确 Oops"，属于可用性问题；魔数校验是最后一道兜底，不能指望它防住什么。

### 7.5 中断为什么需要独立栈

**依据已知实现。**

如果中断处理复用被中断任务的栈，那么"内核栈已经很深时来一个中断"就会直接溢出——而这条路径恰恰最难复现、后果最严重。x86_64 的做法是每 CPU 一条独立中断栈，再加上 IST（Interrupt Stack Table）为 NMI、double fault、MCE 这类**不能被普通栈状态影响**的异常提供专属栈。

IST 的意义在于：即使当前栈指针已经完全错乱（比如 double fault 的场景），硬件仍能从一个固定位置加载可用栈，把错误信息打出来。没有这个机制，栈损坏后连"为什么崩"都记录不下来。

## 8. 仍然没解决的

- [ ] `cea_exception_stacks` 与普通 `estacks` 的分配差异，以及 `IST_INDEX` 的完整分配表
- [ ] `CONFIG_VMAP_STACK` 下 guard page 触发缺页时，异常处理怎么区分"正常栈增长"与"栈溢出"
- [ ] 内核线程（`kthread`）的栈使用与用户进程有无实质差别，`active_mm` 的借用时机
- [ ] 开了 `CONFIG_DEBUG_STACK_USAGE` 之后，历史最大深度记录存在哪个字段、何时清零

## 9. 参考

- `Documentation/x86/entry_64.rst`（入口路径与栈切换）
- `Documentation/x86/kernel-stacks.rst`（各类栈的说明）
- `include/linux/sched.h`、`include/linux/thread_info.h`
- `kernel/fork.c` 中 `alloc_thread_stack_node()` 一节
- LWN 关于 `CONFIG_VMAP_STACK` 引入过程的文章
