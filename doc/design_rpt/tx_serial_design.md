# TX 串行器 `usb_tx_serial` 设计报告

> 模块：`src/phy/usb_tx_serial.v`（PHY 子模块，发方向最末端）
> 时钟：`clk12m`（发送期 = `clk12s` = `ref_clk÷4`），全模块单时钟 1×
> 范围：只做位级执行器，不碰 CRC / PID / 组包 / 应答 / 流控
> 状态：RTL 已实现并验证（`sim/tx/` 20 用例全过，逐条读数与覆盖率见
> [tx_serial_verification.md](tx_serial_verification.md)）
> 相关：[phy_design.md](phy_design.md) §4.4（PHY 总览）、[usb_sie_design.md](usb_sie_design.md)（上游 SIE）

---

## 1. 模块介绍

`usb_tx_serial` 是数字 PHY 里发方向的最后一个模块，挂在 `usb_clk_mux` 之后、模拟收发器之前。

| 项 | 内容 |
|---|---|
| 上游 | `usb_sie` 事务逻辑（`tx_data` / `tx_last`，握手 `tx_active` / `tx_ready` / `tx_done`） |
| 上游（旁路） | `usb_bus_state` 的 `bus_suspended`（挂起态，电平）+ `usb_sie` 的 `sie_wkup`（唤醒请求，电平），§2.11 |
| 下游 | 模拟 PHY 线驱动（`tx_bit` / `tx_se0` + 驱动使能 `tx_en`） |
| 复位 | 只有 `ref_rstn` 一根异步复位，不接 `usb_rst`（§2.12） |
| 一句话 | 字节流（LSb 先）→ NRZI 位流 + 线电平；SYNC / 位填充 / EOP 由本模块自产 |
| 时钟域 | `clk12m` 1×，一拍 1 bit（83.336 ns） |
| 核心结构 | 移位寄存器 + 位计数器 + 连续 1 计数器 + 线电平寄存器 + 6 态位 FSM（内部无 FIFO、无子模块） |

**放 `clk12m` 1× 的理由**：发送期 `clk12m` 恰为本地 `clk12s`（`ref_clk÷4`，`usb_clk_mux` 无毛刺切来），而 SIE 就在 `clk12m` 上逐字节运行 → **本模块与 SIE 同域**，字节握手只是普通同步寄存器，不需要任何跨域处理。

**边界**：

- **做**：SYNC 生成、字节并入串出（LSb 先）、位填充、NRZI 编码、EOP 生成、发送握手；
  以及挂起期的驱动器接管（交高阻 / 远程唤醒驱 K，§2.11）。
- **不做**：PID / 字段 / CRC 的生成与解释（CRC 字节由 SIE 算好，当普通数据字节送来）、
  发什么包与重传决策、应答与流控；也不判"该不该唤醒"（挂起时长、`rw_en` 特性位归 SIE 与软件，§2.11）。

**隐含契约**（本模块内部依赖，SIE 必须保证）：`tx_active`↑ 时摆上的**第一字节必须是合法 PID**
（低 4 位 code + 高 4 位 `~code`）。模块据此才可以在 SYNC 段跳过填充计数（§2.5）。

---

## 2. 模块设计理论和原理及方法

### 2.1 设计动机：为什么单独切一个位执行器

发一个包里的两件事性质完全不同：

- **位级时序**：位填充要在任意字节中间插位；EOP 是位级时长（SE0 166.7 ns）。这些依赖"当前是第几个 bit"，是位域的事。
- **字节级内容**：下一步发哪个字节、CRC 是多少、是不是最后字节。这是事务层与端点层的事。

所以切一刀：**SIE 管字节流与内容，本模块管位流与时序**。SIE 只回答"下一个字节是什么"，本模块只回答"这一刻线上是什么电平"。

### 2.2 发送数据通路次序

USB 发送的固定次序：**组包 → CRC → 位填充 → NRZI → 线电平**。

| 步骤 | 谁做 | 说明 |
|---|---|---|
| 组包（PID / 字段 / CRC 值） | SIE | 本模块不解释字节内容 |
| CRC 计算 + 取反 + 位序摆放 | SIE | 复用 `usb_crc5` / `usb_crc16`（§4.4） |
| SYNC | 本模块 | 恒 `SYNC_BYTE`(0x80)，SIE 不提供 |
| 位填充 | 本模块 | 6 连 1 后插 0 |
| NRZI 编码 | 本模块 | 模块内直接写，不复用 `usb_nrzi_enc` |
| EOP | 本模块 | SE0×2 + J×1 |

**关键推论**：填充必须排在 SYNC 之后、NRZI 之前。既然 SYNC 排在填充之前，就要回答"SYNC 参不参与连 1 计数"，答：不参与，**计数从 PID 起算**（§2.5 的结构性证明）。

**为什么 NRZI 不复用 `usb_nrzi_enc`**：NRZI 编码器本体只有一个状态位（当前线电平），规则是"数据 0 → 翻转、数据 1 → 保持"。而本模块一帧里 NRZI 要服务的时段并不整齐：

| 时段 | 线电平怎么来 |
|---|---|
| `S_IDLE`（未发）/ 包间 | 复位到 J |
| `S_SYNC` / `S_DATA` / `S_DATA_LAST` | 按数据位走（`data_shift[0]`=0 翻转 / =1 保持） |
| 插填充 0 的那拍（数据段或 `S_EOP1`） | 强制翻转，不看 `data_shift[0]` |
| `S_EOP1`（非填充拍）/ `S_EOP2` | 旁路 NRZI，`tx_se0`=1 直接压 SE0 |
| `S_EOP2` 之后 | 强制回 J（不是按数据位算出来的） |

即"NRZI 只在数据相位按位走，其余整段是旁路与强制"。为这点逻辑单独例化一个模块，反而要在 FSM 与子模块之间多维护一套 `nrzi_en` / `nrzi_rst` 的时序约定，而模块内就地写连寄存器都不用加：翻转基准就是输出寄存器 `tx_bit` 自己的现态。

本工程 RTL 里没有任何模块例化 `usb_nrzi_enc` / `usb_nrzi_dec`，收发两侧的解码都是就地写的；两个原语只被各自的单测与参考模型使用。

### 2.3 核心结构

```
        ┌──── 位 FSM（S_IDLE/S_SYNC/S_DATA/S_DATA_LAST/S_EOP1/S_EOP2）────┐
        │ tx_active↑ → 载 0x80 → 移 8 拍 → 逐字节载/移 → 末字节 → EOP×2 │
        └──────────────────────────┬─────────────────────────────────────┘
                                   │ 每拍推进 1 个数据位
 tx_data[7:0] ─►┌──────────────┐  data_shift_en  ┌──────────────────────┐
 （载入）        │ 移位寄存器     │────────────────►│ 填充：6 连 1 插 0      │
                 │ data_shift[7:0]│                │ bit_stuff=1 的那拍     │
                 └──────────────┘                 │ hold 一拍（不移位）     │
                                                  └──────────┬───────────┘
                                                             │ data_shift[0]
                                                  ┌──────────────────────┐
                                                  │ NRZI 编码（就地写）    │──► tx_bit
                                                  │ data_shift[0] ? 保持   │
                                                  │               : 翻转   │
                                                  │ bit_stuff=1 强制翻转   │
                                                  └──────────────────────┘
                  tx_se0 / tx_en / tx_ready / tx_done 由 FSM 现态译码后寄存直出
                  tx_bit 在非数据相位被译码成 J（EOP 段由 tx_se0 顶替）
```

- 每拍最多推进 1 个数据位；插填充 0 的那一拍**不移位、位计数不前进**（`data_shift_en`=0）。
- `tx_se0` / `tx_en` 不经数据通路，由 FSM 直接给（都是寄存器，§2.10）。
- NRZI 没有独立寄存器：线电平就是 `tx_bit` 本身（0 翻转 / 1 保持，翻转基准即 `tx_bit` 的现态）。

### 2.4 位填充：为什么用"插 0 + hold 一拍"，不用 FIFO

- 规则：**连续 6 个 1 之后必须插一个 0**，从 PID 起算（SYNC 段不跑填充，§2.5）。
- 若用 FIFO 把"插位"和"移位"解耦，包尾必然留 0~2 拍排空余量：等不够会截断尾部（填充位丢了，接收端 CRC 必错）；
  固定多等则多按住线路 0~2 拍，NRZI 下等于多解出 0~2 个 1 位，最坏把接收端的连 1 计数推到 7 而判位填充违例
  （见 [rx_deserial_design.md](rx_deserial_design.md)）。**包尾必须严丝合缝接 EOP，不能靠"多等几拍"。**
- 做法：插 0 的那一拍不移位、字节内位计数不前进（数据通路 hold 一拍）。位流严格连续，模块全知何时到位，包尾没有排空问题。
- 因此 `src/common/usb_bit_stuff.v`（2 深 FIFO 版）在本模块不用；该原语保留在 `common`。

### 2.5 SYNC 与 EOP

- **SYNC** = `SYNC_BYTE`(0x80)：LSb-first 移出恰好是"7 个 0 + 1 个 1"。
- **SYNC 不参与填充计数，计数从 PID 起算**。SYNC 后面必定是 PID，而 PID 结构上不可能凑出 6 连 1：
  PID 字节 = 低 4 位 code + 高 4 位 `~code`，线上（LSb 先）先发 code 再发 `~code`；
  同一个 nibble 内最多 4 连 1，而跨 nibble 的连 1 成立要求 `code[3]`=1 且 `code[0]`=0，
  与"4 连 1"要求的 `code[0]`=1 矛盾 → 任意合法 PID 内最多 4 连 1。
  SYNC 尾 1 接上这 4 个 = **5 < 6**，永远不插位。对全部 16 种 `XX~XX` 形态暴力验证见
  `tools/gen_tx_timing.py --check`（"计入 SYNC"与"不计入 SYNC"两条规则逐位比对位流）。
- **推论**：`S_SYNC` 不必跑填充逻辑，SYNC 恒为 8 拍纯移位。实现上是无条件保证的：
  `bit_ones_cnt` 的次值在 `S_DATA` / `S_DATA_LAST` 之外恒为 0（§2.6），所以进 SYNC 时它一定是 0，一个 6 连 1 都攒不出来。
  这与 RX 侧 `usb_rx_deserial` 的"填充从 PID 起算、SYNC 本身不填充"是同一条规则
  （[intel_sie_whitepaper_notes.md](../intel_sie_whitepaper_notes.md) §4.4），收发两侧对边界理解一致，回环验证才不会有歧义。
- **PID 的尾巴仍要算**：PID 可能以 3 连 1 收尾，这个计数必须带进下一字节。真实例子：
  OUT token（PID `0xE1`，线上 `10000111`）发给地址 7 的设备 → 下一字节线上以 `111` 开头 → 3 + 3 = 6 → 要插一个 0。
  所以"不计 SYNC" ≠ "PID 不计数"。
- **EOP** = SE0 两位时间 + 释放一位时间 + 交高阻。

| 项 | 值 | 由谁实现 |
|---|---|---|
| SE0 时长 | 2 × 83.336 ns = **166.7 ns**（规范 160–175 ns ✓） | `S_EOP1` + `S_EOP2` 各一拍，`tx_se0` 拉高 |
| J 时长 | 1 × 83.336 ns | `tx_en`↓ 撤驱动，上下拉把总线拉回 J（§4.3/§4.8.2） |
| 之后 | 高阻 = 电气空闲 J | `tx_en` 由 `st == S_IDLE` 清 0 |

### 2.6 位状态机

6 态，两段式（次态组合逻辑 + 时序寄存）。
📎 [打开：TX 位状态机跳转图](../fig/tx_serial_state_machine.png)

| 状态 | 编码 | 干什么 | 出口 |
|---|---|---|---|
| `S_IDLE` | 3'd0 | 等 `tx_active`；`tx_en`=0；线保持 J | `tx_active`↑ → `S_SYNC` |
| `S_SYNC` | 3'd1 | 载入 0x80，移 8 拍（不跑填充，恒 8 拍） | 8 拍完 → `S_DATA` / `S_DATA_LAST` |
| `S_DATA` | 3'd2 | 载入 `tx_data`，移 8 拍（过填充） | 8 拍完 → `S_DATA_LAST`（末字节）/ `S_DATA` |
| `S_DATA_LAST` | 3'd3 | 末字节：移 8 拍，发完就转 EOP（不再载入） | 8 拍完且非填充拍 → `S_EOP1` |
| `S_EOP1` | 3'd4 | SE0 第 1 拍；兼尾填充拍 | 无尾填充 → `S_EOP2`；`bit_stuff`=1 → 自环 1 拍 |
| `S_EOP2` | 3'd5 | SE0 第 2 拍 | 下拍 → `S_IDLE`（同时 `tx_done`） |

跳转表（照 `usb_tx_serial.v` 的次态 case 逐行抄）：

| 当前态 | 条件 | 次态 | 说明 |
|---|---|---|---|
| 任意态 | `tx_active`=0 | `S_IDLE` | 中止，优先级最高（次态逻辑最外层 `if`） |
| `S_IDLE` | `tx_active` 上升沿 | `S_SYNC` | 同拍载入 0x80（`tx_active_pos`，§2.7） |
| `S_SYNC` | 未满 8 位 | `S_SYNC` | 纯移位，无 hold（SYNC 不参与填充，§2.5） |
| `S_SYNC` | 8 位完、非末字节 | `S_DATA` | 载 `tx_data`（下一拍给 `tx_ready` 脉冲） |
| `S_SYNC` | 8 位完、末字节 | `S_DATA_LAST` | 同上，只是带上"末字节"身份 |
| `S_DATA` | 未满 8 位，或非末字节 | `S_DATA` | 继续移位 / 载下一字节（中途插 0 的 hold 拍也走这条） |
| `S_DATA` | 8 位完、末字节（非填充拍） | `S_DATA_LAST` | 进末字节态 |
| `S_DATA_LAST` | 未满 8 位，或正插尾填充 0 | `S_DATA_LAST` | 继续移位 / hold 一拍插 0 |
| `S_DATA_LAST` | 8 位完且非填充拍 | `S_EOP1` | 末字节发完，转 EOP |
| `S_EOP1` | 进态时 `bit_stuff`=1 | `S_EOP1` | 尾填充拍：这一拍线上补一个 0 而不是 SE0 |
| `S_EOP1` | 其余 | `S_EOP2` | SE0 第 1 拍 → 第 2 拍 |
| `S_EOP2` | 恒 | `S_IDLE` | 同拍 `tx_done` 脉冲 |

四条把设计说清楚的关键点：

**① 末字节独立成 `S_DATA_LAST`**：本设计**没有 `last_q` 锁存寄存器**。
`tx_last` 在字节边界直接从端口采（SIE 契约见 §2.7），"这一字节是最后一字节"这件事由状态记住。
于是"要不要转 EOP"只在载入那一拍判一次，之后 `S_DATA_LAST` 自环到 8 拍完为止，不必每拍重判 `tx_last`。
`S_DATA` 与 `S_DATA_LAST` 的行为完全一样（都载 `tx_data`、都过填充），差别只在出口条件。

**② `S_EOP1` 兼尾填充拍**：尾填充的时机由 `bit_ones_cnt` 决定，而连 1 可能恰好在末字节收尾：

| 6 连 1 的最后一个 1 是 | 尾填充 0 插在哪 | 怎么走 |
|---|---|---|
| b6（或更早） | 仍在 `S_DATA_LAST` 内 | `bit_cnt_7` 且 `bit_stuff`=1 → 末字节态自环一拍 |
| b7（如末字节 `0xFC`） | 已进 `S_EOP1` | 进态那拍 `bit_ones_cnt`=6 才拉高 `bit_stuff` → `S_EOP1` 自环一拍 |

自环那一拍 `tx_se0`=0、`tx_bit` 按 NRZI 翻转（= 线上一个 0），下一拍才真正拉 SE0。
**两处自环是同一件事的两个落点**，合起来保证"最后一位数据与 EOP 之间不多不少恰好一个 0"。
若不处理，SE0 会紧贴在数据位后面，接收端会把那个填充 0 当成 SE0 的一部分而判帧错。
用例 `tx_tail_stuff` 与 `tx_stuff_pos_scan` 钉这条。

**③ 填充判据收敛成一根组合线 `bit_stuff`**：

```verilog
assign bit_stuff = bit_ones_cnt[2:0] == 3'b110;   // 6 连 1 已攒满 → 本拍要插 0
```

它同时被 5 处引用，语义单一：**是 1 就表示"本拍线上出的是填充 0，不是数据位"**。

| 引用点 | `bit_stuff`=1 时的作用 |
|---|---|
| `data_shift_en` | 置 0 → 不移位（数据通路 hold 一拍） |
| `data_load_en` | 置 0 → 不在填充拍上载入下一字节 |
| `bit_cnt_nxt` | 经 `data_shift_en` 间接 hold（位计数不前进） |
| `tx_bit_nxt` | 强制翻转（NRZI 编码一个 0），不看 `data_shift[0]` |
| `tx_se0_nxt` | 在 `S_EOP1` 里压住 SE0 → 尾填充拍不拉 SE0 |

**④ `bit_ones_cnt` 的更新范围天生保证了"计数从 PID 起算"**：

```verilog
assign bit_ones_cnt_nxt = ~((tx_stat_cur == S_DATA) || (tx_stat_cur == S_DATA_LAST))
                          ? 3'b000                                    // 非数据相位 → 原地清零 (含 SYNC)
                          : (bit_stuff ? 3'b000                       // 刚插过 0 → 重新起数
                                       : (data_shift[0] ? bit_ones_cnt + 1'b1 : 3'b000));
```

非数据相位无条件清零，于是 SYNC 段攒不出连 1（§2.5 的推论自动成立），
EOP / 中止 / 包间也不会有残留计数，不需要任何专门的复位路径。

> **中止（`tx_active` 中途↓）的语义**：`if(~tx_active)` 在 `case` 之外、优先级最高，
> 所以撤请求后模块在下一个 `clk12m` 沿回 `S_IDLE`（`bit_cnt` / `data_shift` / `bit_ones_cnt` 也都在同一拍被清），
> 线回到 J，不留残留半字节。`tx_en` 是寄存器（§2.10），它比状态晚一拍才掉：撤请求后的那一拍
> `tx_bit` 可能仍是滞留的数据位，于是线上多驱动 1 位。USB 不允许包中间停，所以这是错误路径，
> 正常发送不会走到。用例 `tx_abort` / `tx_abort_phases` 验这条。

### 2.7 发送握手时序

1. SIE 拉高 `tx_active`，并把第一个字节（PID）放上 `tx_data`。
   模块靠 `tx_active` 的上升沿（`tx_active_pos`）起包，不是靠电平；电平还用来判断中止，两者分开。
2. 模块发 SYNC（8 拍），这 8 拍就是 SIE 的准备时间。
3. SYNC 移完的那一拍 `data_load_en` 拉高，下一个沿载入 `tx_data` 进移位寄存器；同一次载入还把
   `tx_ready` 拉起（`tx_ready` 是寄存器，所以它出现在载入之后的那一拍）。
4. SIE 见 `tx_ready`，把再下一个字节放上 `tx_data`（当前这个已被取走）。
5. 重复 3~4。`tx_ready` **对每个字节都发（含最后一个）**，含义恒为"已取走"；SIE 自己知道哪个是最后字节，
   并把 `tx_last` 与最后一个字节同拍拉起。
6. 末字节移完 → 转 `S_EOP1` / `S_EOP2` 发 EOP，不再载入。
7. 回 `S_IDLE` 那一拍 `tx_done` 脉冲拉高；`tx_en` 由模块自己的 `st == S_IDLE` 清 0（§2.10），
   所以撤驱动与收尾严丝合缝，线路在 SE0 之后自动回到空闲 J。

**`tx_last` 的时序契约**（端口直接采，不锁存进 `last_q`）：

- **何时被采样**：只在 `S_SYNC` / `S_DATA` 的次态译码里，即"载入某字节的那一拍"。
  末字节载入后 FSM 进 `S_DATA_LAST` 并自环 8 拍到 `S_EOP1`，全程不再引用 `tx_last`；
  `tx_ready_nxt` / `tx_done_nxt` 也不含它。
- **契约**：`tx_last` 是包级标志，只在 `tx_active` 有效期内被采样（`if(~tx_active)` 优先级高于 `case`）。
  SIE 把它与最后一个字节同拍拉起，**看到那一拍的 `tx_ready` 就可以拉低**，保持到包尾同样合法。
  落点窗口很宽：只要不早于"末字节载入那一拍"，晚多久都行（实测边界见验证报告 §4.11）。
- **唯一的硬约束**：不能跨包残留。下一包首字节载入前必须为 0，否则新包的 PID 会在 `S_SYNC`
  出口被判成末字节、截成 PID-only。按"见 `tx_ready` 即落"做，这条天然满足；若保持到包尾，
  则中止路径（§2.6 的 `if(~tx_active)` 分支）不产生 `tx_done`，必须随 `tx_active` 撤清。

**`tx_en` 是寄存器**（不是 `tx_active` 直通）：进入边由 `tx_active_pos` 置 1，退出边由 `st == S_IDLE` 清 0。
于是发送段 `tx_en` 恒为 1、包间恒为 0，且驱动一直保持到 SE0 结束，随后交高阻由偏置拉回 J。
代价与豁免见 §2.10。

### 2.8 供字节预算（跨模块约束）

- 载入是"上一字节移完立刻载入"，所以从 SIE 看到 `tx_ready` 到必须备好下一字节，只有一个字节的移位时间：
  **8 拍（≈667 ns；含填充的字节 9 拍、全 1 载荷 10 拍）**。`sim/tx/tx_handshake` 实测相邻 `tx_ready`
  脉冲间距恒为 8 / 9 / 10 拍，下界 8 拍（§4.5）。
- SIE 经 `usb_sie_cdc` 取一字节 ≈750 ns（9 拍），所以在 `tx_ready` 到了才去 FIFO 取字节是不够的。
  SIE 侧必须预取：发送前先把队首几字节抓到小缓冲，发送中持续补。
- 本模块不做反压：`tx_active` 一拉高就必须连续发完（USB 也不允许包中间停）。字节没备好只能整包不发。

### 2.9 可综合性

单时钟 `clk12m`、纯组合 + 时序、无 `#` 延迟、无异步逻辑；移位 / 计数 / FSM / 五个输出全是同步寄存器
（NRZI 编码不占额外寄存器，翻转基准就是 `tx_bit` 自身）；无子模块例化（NRZI 就地写，§2.2）。

### 2.10 输出寄存器化（DFF 直出，现态译码）

**为什么**：`tx_bit` / `tx_se0` / `tx_en` 直连模拟 PHY（`code_rtl.md` 规则 6）。组合译码直通管脚
既没有建立/保持预算，多比特同时翻转还会出假脉冲。

**做法：现态译码 `D = f(现态, 现态各寄存器值)`**，D 只由当拍状态与当拍各寄存器值译码，
不引任何 `*_nxt` 次值线。五个输出一个写法：先写一根组合的 `*_nxt` 线，再由它的专属 `always`
寄存输出，端口上不再有任何组合锥。

| 输出 | D 线（现态译码） | 复位值 | 备注 |
|---|---|---|---|
| `tx_bit` | `tx_bit_nxt`：非数据相位→J；否则按 `data_shift[0]` / `bit_stuff` 做 NRZI | `1'b1` | idle J |
| `tx_se0` | `tx_se0_nxt`：`(S_EOP1 && ~bit_stuff) \|\| S_EOP2` | `1'b0` | 尾填充拍被 `bit_stuff` 压住 |
| `tx_ready` | `tx_ready_nxt`：`(S_SYNC\|\|S_DATA) && bit_cnt_7 && ~bit_stuff` | `1'b0` | 含义"已取走" |
| `tx_done` | `tx_done_nxt`：`S_EOP2` | `1'b0` | 回 `S_IDLE` 的同拍 |
| `tx_en` | 不是纯译码：见下 | `1'b0` | 唯一带边沿条件的输出 |

**代价（`code_rtl.md` 规则 6 要求记账）**：现态译码让每个输出整体后移一拍
（同一条表达式，纯组合译码在第 n 拍出，寄存后在 n+1 拍出）。具体到本模块：

1. **线上波形整体后移一拍，但位流序列不变**。`tx_stat_cur` 进 `S_SYNC` 后再下一拍线电平才翻成 K（SOP）；
   EOP 的 SE0 也同理后移。每一位仍占满一拍、包长不变，接收端看到的仍是合法的 SYNC + 数据 + EOP
   （`tx_pid_only` 的 VCD 逐拍可核，§4.7）。
2. **握手的余量**：`tx_ready` 在载入之后的那一拍给出，SIE 备下一字节的余量 = 8 拍（§2.8），
   已核对够用（TB 里字节恒在 1 拍内换值）。

**`tx_en` 是唯一不能纯译码的输出**：它要跟随 `tx_active`（SIE 的请求），
而"寄存器 D"无法预知输入下一拍掉不掉。写法是带进入/退出条件的寄存器，
外加挂起旁路（§2.11）压在最前：

```verilog
always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn)                  tx_en <= 1'b0;
    else if (bus_suspended)              tx_en <= sie_wkup;   // 挂起旁路: 只有唤醒请求能开驱动器
    else if (tx_active_pos)         tx_en <= 1'b1;       // 起包: 上升沿
    else if (tx_stat_cur == S_IDLE) tx_en <= 1'b0;       // 收尾/中止: 回 IDLE 时清
    else                            tx_en <= tx_en;
end
```

- **进入边晚一拍**：起包那拍 `tx_en` 还是 0，比状态晚一拍才拉高，无影响（那一拍线上还是 J，
  且不存在驱动器抢线问题）。
- **退出边靠模块自己知道的收尾钉住**：`st == S_IDLE` 是模块自身的收尾条件，
  所以 SE0 第二拍一结束 `tx_en` 就落下，线路立刻由偏置拉回 J（空闲 J 是释放后的偏置结果，不是驱动出来的）。
- **代价落在中止路径**：SIE 中途撤 `tx_active` 时，`tx_en` 晚一拍才掉，那一拍 `tx_bit`
  是滞留的数据位（非 J），截断帧在线上多驱动 1 位（`tx_abort` / `tx_abort_phases` 按此语义写）。

### 2.11 挂起与远程唤醒的 K 驱动

USB 挂起后，设备发远程唤醒的方式是在总线上驱 K（FS 下 D+ 高 / D- 低反过来那一态），
持续 1~15 ms，然后交高阻。结束时不驱到 J，由主机侧下拉与设备侧 1.5k 上拉的偏置把线拉回空闲。

做法是旁路，不占状态机：FSM 旁挂两条分支，优先级最高。

```verilog
// tx_bit 链: ... else if (bus_suspended) tx_bit <= ~sie_wkup;
// tx_en  链: ... else if (bus_suspended) tx_en  <=  sie_wkup;
```

挂起态读的是 `usb_bus_state` 判出的 `bus_suspended`（同一层里的一根线），不是 SIE 回送的副本。
旁路的判据本来就是「总线已挂起（PHY 自己判的）+ SIE 请求唤醒」，读源比读副本好三点：
少一次 bus_state → SIE → tx_serial 的往返；主机接管那段 K 时同一拍就解除武装，不会晚几拍
跟主机对着驱；`bus_suspended` 由 `usb_rst` 清，SIE 那份若复位残留会把包路径永久关掉这条隐患
从根上去掉。PHY↔SIE 边界因此少一根信号，SIE 只出 `sie_wkup` 这一根请求。
代价是 `usb_rst` 之后 clk12m 侧要晚 1~2 拍才跟下来（`usb_bus_state` 的同步链只吃 `ref_rstn`，
见 [bus_state_design.md](bus_state_design.md) §2.8），那几拍读到旧值，与 `sie_wkup` 的清除同向，无影响。

| `bus_suspended` | `sie_wkup` | `tx_en` | `tx_bit` | 线（经 PHY 模型） |
|:---:|:---:|:---:|:---:|---|
| 0 | × | 由包路径定 | 由包路径定 | 正常收发 |
| 1 | 0 | 0 | 1 | 高阻，上拉给出空闲 J |
| 1 | 1 | 1 | 0 | K（驱动 + 线电平 0） |

`tx_bit` 取 `~sie_wkup`，是因为 K 就是 `tx_bit`=0、J 就是 `tx_bit`=1（§4.8.2 映射表）。
挂起这一档不需要另立 NRZI 逻辑，一个取反就够。

**为什么不开第 7 个状态**：唤醒 K 不需要 SYNC / 填充 / EOP 任何一条流水，也不参与
`tx_ready` / `tx_done` 握手，而状态机只有 6 态；旁路只改两处 D 链，优先级还自然成立
（`bus_suspended` 分支排在包路径之后，包路径有动作也被它压住）。

代价与 §2.10 是同一笔：旁路也落在寄存链上，`bus_suspended` / `sie_wkup` 到线电平同样晚一拍。

契约（SIE 侧职责）：

| 项 | 约定 |
|---|---|
| 时钟域与形状 | `clk12m`、电平均有效，无需脉冲化；SIE 在整段挂起/唤醒期间保持住即可 |
| 唤醒期不发包 | `bus_suspended`=1 期间 SIE 不得拉 `tx_active`、不得摆新 `tx_data`。唤醒与包路径互斥，协调归 SIE |
| K 的时长 | 1~15 ms 由 SIE 计。本模块只执行"`sie_wkup`=1 就驱 K"，不做时长判定 |
| 收尾 | SIE 拉低 `sie_wkup`；本模块下一拍落 `tx_en` 交高阻 |
| `rcv` 压 0 | 唤醒期 `rcv` 必须压 0：K 属于发送期间，`clk12m` 得由本地 `clk12s` 给 |
| `sie_wkup` 单独有效 | 不挂起时它单独为 1 不开驱动器（表第 1 行），防接线错误 |
| 唤醒前置条件 | 挂起 ≥5 ms、`rw_en` 已使能、且该位必须被总线复位清掉，三条由软件自判 |
| 复位后必须为 0 | `sie_wkup` 残留为 1 会开驱动器（`bus_suspended` 由 `usb_rst` 清，不靠 SIE） |

`rcv` 的策略表见 [usb_sie_design.md](usb_sie_design.md) §1.3；唤醒前置条件硬件不门控，
理由见 [bus_state_design.md](bus_state_design.md) §2.7 末。

"唤醒期不发包"这条是契约而不是本模块的保证。`bus_suspended` 分支在 D 链上优先级最高，
所以违约时线上也出不来包（用例 20 段 4 记录了这个行为），那是旁路结构的副产品，不作为设计要求。

### 2.12 复位口径：本模块不接 `usb_rst`

模块只有 `ref_rstn` 一根复位（异步、低有效），作用是把上电后的寄存器带到确定值
（`tx_bit`=J、其余 0）。core 复位（软件复位 `SWRST`、总线复位）没有接到本模块，因为模块里
没有需要它来清的寄存器：没有任何跨包存活的配置位或状态，每个寄存器都有自己的归位路径。

| 寄存器 | 归位路径 |
|---|---|
| `tx_stat_cur` | `if(~tx_active)` 回 `S_IDLE`；正常收尾由 `S_EOP2` 回 `S_IDLE` |
| `data_shift` / `bit_cnt` / `bit_ones_cnt` | 撤请求时 `data_shift` 清 0、`bit_cnt` 随 `S_IDLE` 清 0、`bit_ones_cnt` 在非数据相位无条件清 0 |
| `tx_bit` | 非数据相位译回 J（§2.10） |
| `tx_en` | `st == S_IDLE` 清 0（§2.10） |
| `tx_active_dly` | 跟随 `tx_active`，滞后一拍 |

所以一次 core 复位对本模块的效果等同于 SIE 撤销 `tx_active`（§2.6 的中止路径）：
下一拍回 `S_IDLE`、线回 J、无残留半字节。总线复位落在包中间本来就是非法路径，模块不需要为它做什么。

另一层原因是时钟域：接收期 `clk12m` 由 CDR 恢复出来的 `dclk` 驱动，`usb_clk_mux` 会在
`dclk` 与 `clk12s` 之间切，CDR 未锁时它还会停在低电平。往一个会被切换、可能停摆的时钟域送异步复位，
等于额外背一条恢复/移除时序约束；既然没有非清不可的寄存器，就不接。

反过来有两条 SIE 侧契约：复位后 `bus_suspended` / `sie_wkup` 必须为 0（§2.11），
且 `tx_active` 也应为 0（SIE 自己的复位职责）。

---

## 3. 模块信号列表

### 3.1 端口信号（对外接口）

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `clk12m` | in | 1 | 发送期 = `clk12s`（`ref_clk÷4`），一拍 1 bit |
| `ref_rstn` | in | 1 | 异步复位，低有效；本模块唯一复位输入（§2.12） |
| `tx_active` | in | 1 | SIE 发送请求：上升沿起包；见 `tx_done` 后 ↓；中途 ↓ = 中止 |
| `tx_data` | in | 8 | 待发字节，LSb 先发；`tx_active`↑ 时的首字节必须是合法 PID（§1） |
| `tx_last` | in | 1 | 包级标志：与末字节同拍拉起，见该字节的 `tx_ready` 即可拉低（§2.7） |
| `bus_suspended` | in | 1 | 挂起态（电平，`clk12m` 域）：来自 `usb_bus_state` 的同名输出，1 = 已挂起，包路径让位给唤醒旁路（§2.11） |
| `sie_wkup` | in | 1 | 远程唤醒请求（电平，`clk12m` 域）：挂起中为 1 时线上驱 K（§2.11） |
| `tx_ready` | out | 1 | 1 拍脉冲 = 已取走（载入）一个字节；`output reg`，D = 现态译码（§2.10） |
| `tx_done` | out | 1 | 1 拍脉冲 = EOP 已发完；`output reg`，D = 现态译码（§2.10） |
| `tx_bit` | out | 1 | 线电平：1=J / 0=K；`output reg`，D = 现态译码（§2.10） |
| `tx_se0` | out | 1 | 1 = SE0（仅 EOP 两拍）；`output reg`，D = 现态译码（§2.10） |
| `tx_en` | out | 1 | 驱动使能；`output reg`：上升沿置位、回 `S_IDLE` 清零（§2.10） |

### 3.2 内部关键信号

**寄存器**（10 个，外加 1 个组合的次态变量）：

| 信号 | 位宽 | 说明 |
|---|---|---|
| `tx_stat_cur` / `tx_stat_nxt` | 3 | 位 FSM 现态（寄存器）/ 次态（组合，`always @(*)`） |
| `data_shift` | 8 | 并入串出移位寄存器（bit0 先出） |
| `bit_cnt` | 3 | 当前字节已移出位数（到 7 后 hold，只在 `S_IDLE` 清零） |
| `bit_ones_cnt` | 3 | 连续 1 计数（0~6，只在 `S_DATA` / `S_DATA_LAST` 更新，其余相位恒清 0） |
| `tx_active_dly` | 1 | `tx_active` 打一拍，与 `tx_active` 一起做上升沿检测 |
| `tx_bit` `tx_se0` `tx_en` `tx_ready` `tx_done` | 1 | 五个输出寄存器（§2.10） |

**组合线**（其余）：

| 信号 | 说明 |
|---|---|
| `tx_active_pos` | `tx_active & ~tx_active_dly`，起包上升沿（也是 `tx_en` 的置位条件） |
| `bit_stuff` | 唯一的填充判据：`bit_ones_cnt == 3'b110`（§2.6 第 ③ 条，被 5 处引用） |
| `data_load_en` | 本拍载入字节：`(S_SYNC\|\|S_DATA) && bit_cnt_7 && ~bit_stuff` |
| `data_shift_en` | 本拍移位：`(S_SYNC\|\|S_DATA\|\|S_DATA_LAST) && ~bit_stuff`（填充拍 hold） |
| `bit_cnt_7` | `bit_cnt == 3'b111`，本字节最后一位那拍 |
| `data_shift_nxt` / `bit_cnt_nxt` / `bit_ones_cnt_nxt` | 三个数据通路寄存器的 D |
| `tx_bit_nxt` / `tx_se0_nxt` / `tx_ready_nxt` / `tx_done_nxt` | 四个输出寄存器的 D（§2.10 表格） |

> 末字节身份由 `S_DATA_LAST` 记住、填充由 `bit_stuff` 一根线统一表达、EOP 由 `S_EOP1` / `S_EOP2`
> 两个状态表达、NRZI 电平就是 `tx_bit` 自身，所以没有 `last_q` / `stuff_pend` / `eop_cnt` / `nrzi_lv`
> 这类寄存器。挂起旁路接在已有的 `tx_bit_nxt` / `tx_en` 链尾，寄存器数量不受影响。

### 3.3 常量

```verilog
localparam [2:0] S_IDLE = 3'd0, S_SYNC = 3'd1, S_DATA = 3'd2,
                 S_DATA_LAST = 3'd3, S_EOP1 = 3'd4, S_EOP2 = 3'd5;
// 填充判据是字面量 3'b110 (bit_ones_cnt==6) 写在 bit_stuff 一处, 未另立常量
```

---

## 4. 关键设计点描述及波形

> 本节各条引用的图都是从 `sim/tx/*.vcd` 实采样导出的真实波形（来源 VCD 与出图命令见 §4.7）。

### 4.1 包尾严丝合缝：hold 一拍 vs FIFO

**问题**：填充器若带缓冲，包尾就有排空余量，等不够会截断、多等会多按住线路（§2.4）。
**做法**：插 0 那拍 hold 数据通路；走到包尾时，`S_DATA_LAST` / `S_EOP1` 各自自环一拍把那个 0 插掉（§2.6 ②），
位流由构造保证连续。
**波形**：📎 [打开：末字节 6 连 1 收尾](../fig/tx_serial_tail_stuff.png) —— 末字节 `0xFC`（线上 b2~b7 全 1 = 恰好 6 连 1，
且第 6 个 1 正是 b7）：末字节态 `3'h3` 里 `bit_ones_cnt` 累到 `3'b110`，下一拍状态已进 `S_EOP1`（`3'h4`）而
`bit_stuff`=1 → `S_EOP1` 自环一拍：这一拍 `tx_se0`=0、`data_shift` 停在 `8'h0`、`tx_bit` 翻转 =
线上最后一位就是那个填充 0；再下一拍才进 `S_EOP2`（`3'h5`）拉 SE0，中间不多不少一拍。

### 4.2 填充从 PID 起算（SYNC 不计入）

**问题**：SYNC 的尾 1 要不要计入连 1 计数？结构上不可能凑到 6。
**做法**：`bit_ones_cnt` 在 `S_DATA` / `S_DATA_LAST` 之外无条件清 0（§2.6 ④），所以 SYNC 段自然攒不起来；
计数从 PID 起算，SYNC 恒 8 拍纯移位。
**证明**：PID = code(4) + `~code`(4)，线上先 code 后 `~code`，跨 nibble 的连 1 需 `code[3]`=1 且 `code[0]`=0，
与 4 连 1 所需的 `code[0]`=1 矛盾 → 字节内最多 4 连 1；SYNC 尾 1 接上它 = 5 < 6。
**机器证明**：`python3 tools/gen_tx_timing.py --check`（16 种 `XX~XX` × 8 种后续字节，
"计入/不计入 SYNC"两条规则输出的线上位流逐位相同）。
**别误读**：这是"SYNC 不计入"，不是"PID 不计入"——PID 可能以 3 连 1 收尾（如 `0xE1` 尾 `111`），
下一字节开头 3 个 1 就要插位（§2.5 的 OUT→地址 7 例子）。
**波形**：📎 [打开：位填充](../fig/tx_serial_stuffing.png) —— 数据字节 `0xFF`：`bit_ones_cnt` 累到 `3'b110` 那一拍
`bit_stuff` 拉高 → `data_shift_en`=0（`data_shift` 停在 `8'h7` 不动）、`tx_bit` 被强制翻转出那个 0；
`bit_cnt` 同时不前进（`3'b110` 持续两拍）；下一拍 `bit_ones_cnt` 归零、移位恢复（`data_shift` 变 `8'h3`）。

### 4.3 EOP 时长与高阻时机

**做法**：SE0 严格 2 拍（166.7 ns，落在 160–175 ns 内），随后交高阻；`tx_done` 在回 `S_IDLE` 的同拍给出，
`tx_en` 由 `st == S_IDLE` 在 SE0 第二拍结束的那个沿上清 0（§2.10），线路随即由偏置拉回 J。
释放后的空闲 J 就是 EOP 的第 3 个"J 位时间"（PHY 模型据此建模，§4.8.2）。
**波形**：📎 [打开：EOP 与交高阻](../fig/tx_serial_eop.png) —— `tx_se0` 高电平 2260489→2427161 ps，
宽 **166672 ps = 2 × 83336 ps = 2 个 `clk12m` 周期**；状态 `3'h3`→`3'h4`→`3'h5`→`3'h0`，
末态那一拍 `tx_done` 拉高，`tx_en`↓ 交高阻。

### 4.4 CRC 字节位序契约（SIE 侧职责）

**问题**：线上 CRC 字段是 MSB 先发（`usb_crc16.v` 头注释、`usb_sie_design.md` §2.3 的
`byte2[7:3]=CRC5[4:0]` 都印证）；而本模块每字节 bit0 先发。模块不碰 CRC，位序只能由 SIE 提前摆好。

**做法**：SIE 把 CRC16 取反后按位反转成两个字节再送：

| 字节 | 装载值 | 线上顺序 |
|---|---|---|
| 第 1 个 | `tx_data[k] = ~crc16[15-k]`（k=0..7） | `~crc16[15]` → `~crc16[8]` |
| 第 2 个 | `tx_data[k] = ~crc16[7-k]`（k=0..7） | `~crc16[7]` → `~crc16[0]` |

**风险**：写错不报错，只会 CRC 全错、静默丢包，因此在 SIE 报告里同步记一条。

### 4.5 握手与供字节预算

**问题**：载入与 `tx_ready` 只差一拍，SIE 只有一个字节的时间备下一个（§2.8）。
**做法**：本模块不反压、不等字节；预算问题留给 SIE 用预取解决。
**波形**：📎 [打开：字节边界握手](../fig/tx_serial_handshake.png) —— `tx_data` 在每次 `tx_ready` 之后一拍换值
（`0xE1`→`0x07`→`0x10`，最后一字节 `tx_last`=1）；`tx_ready` 两次脉冲之间恒为 `bit_cnt` 走完一整圈，
实测 8 拍（含填充 hold 的字节 9 拍、全 1 载荷 10 拍，下界 8 拍）。
`sim/tx/tx_handshake` 的判据就是这个下界（≥8 拍），实测三组包全部满足。

### 4.6 驱动使能与 SOP

**做法**：`tx_en` 是寄存器，由 `tx_active` 上升沿置位、`st == S_IDLE` 清零（§2.10），
所以它在整包期间恒为 1、包间恒为 0，SE0 结束那一拍同步撤驱动。
线电平在空闲段保持 J（`tx_bit` 复位值 1），收发器把第一个 SYNC 位（0）翻转成 K，线上 SOP 即"空闲 J → K"。
**波形**：📎 [打开：SOP 与线电平](../fig/tx_serial_nrzi_sop.png) —— 空闲段 `tx_stat_cur`=`3'h0`、`tx_bit`=1(J)；
进 `S_SYNC`（`3'h1`）时 `data_shift` 载入 `8'h80`，再下一拍 `tx_bit` 翻成 K，即 SOP；
其后 SYNC 的 7 个 0 依次翻转、第 8 位 1 保持，`data_shift` 逐拍右移（`8'h80`→`8'h40`→…→`8'h1`）。
`rxdp` / `rxdn` 同步翻转（PHY 模型零延迟）。
线电平比 `tx_stat_cur` 晚整一拍（现态译码的固定代价，§2.10）：图上 `tx_stat_cur` 在 843777 ps 进 `S_SYNC`，
`tx_bit` 到 927113 ps 才翻成 K。每一位仍占满一拍，包长不变。

**挂起/唤醒期这条边由另一条链接管**（§2.11）：`bus_suspended`=1 时 `tx_en` 不再跟 `tx_active` 走，而跟 `sie_wkup` 走。
**波形**：📎 [打开：挂起交高阻与远程唤醒 K](../fig/tx_serial_susp_wkup.png) —— 从左往右：
`bus_suspended`↑ 后 `tx_en`=0、线经上拉回 J；`sie_wkup`↑ 下一拍 `tx_en`=1 且 `tx_bit`=0，
线上 `rxdp=0` / `rxdn=1` 即 K，连续 120 拍（逐拍查过）；`sie_wkup`↓ 再晚一拍回高阻。
最右段 `tx_active` 在挂起中拉高 12 拍、`tx_en` 始终为 0、线上无残留。
那一段是契约外的刻意违约（SIE 本不该在唤醒期发包，§2.11），图里留着是为了看清
旁路分支在 D 链上的优先级，不是设计要求。

### 4.7 关键波形

以下 7 张图都是 `tools/render_waveform.py` 从 `sim/tx` 的真实 VCD 离屏截出的，
出图来源与命令一并列出，便于复现。信号路径用 `tb_tx_serial.u_tx.*` 实例路径
（`u_tx` 里有 `tx_stat_cur` / `bit_stuff` 等内部信号；
注意 VCD 里 `u_tx` 与 `u_rx` 各有一个 `bit_cnt`，必须写全路径，短名会解析歧义）。

| 图 | 来源 VCD / 用例 | 内容 |
|---|---|---|
| 📎 [单字节包](../fig/tx_serial_pid_only.png) | `tx_pid_only.vcd` / `tx_pid_only` | PID-only：SYNC + 8 位 + EOP，全握手信号 |
| 📎 [字节边界握手](../fig/tx_serial_handshake.png) | `tx_handshake.vcd` / `tx_handshake` | 四个握手信号与供字节预算 |
| 📎 [位填充](../fig/tx_serial_stuffing.png) | `tx_stuff_dense.vcd` / `tx_stuff_dense` | `0xFF` 触发填充，插 0 处 hold 一拍 |
| 📎 [末字节 6 连 1 收尾](../fig/tx_serial_tail_stuff.png) | `tx_tail_stuff.vcd` / `tx_tail_stuff` | `0xFC` 收尾：`S_EOP1` 自环一拍插尾填充 0 |
| 📎 [EOP 与交高阻](../fig/tx_serial_eop.png) | `tx_eop_timing.vcd` / `tx_eop_timing` | SE0 2 拍 → 释放（= J 一位时间）+ 交高阻 |
| 📎 [SOP 与线电平](../fig/tx_serial_nrzi_sop.png) | `tx_pid_only.vcd` / `tx_pid_only` | 空闲 J → SOP K，线电平比状态晚一拍 |
| 📎 [挂起与远程唤醒 K](../fig/tx_serial_susp_wkup.png) | `tx_susp_wkup.vcd` / `tx_susp_wkup` | 挂起交高阻 → 驱 K 120 拍 → 回 J；末段是契约外违约 |

```bash
cd sim/tx && rm -f tx.vvp && make VCD=1 run    # ★ 先删 .vvp 强制带 VCD 重编
python3 tools/render_waveform.py sim/tx/tx_eop_timing.vcd doc/fig/tx_serial_eop.png \
  --signals "tb_tx_serial.u_tx.tx_stat_cur,tb_tx_serial.u_tx.tx_bit,tb_tx_serial.u_tx.tx_se0,tb_tx_serial.u_tx.tx_en,tb_tx_serial.u_tx.tx_done,tb_tx_serial.rxdp,tb_tx_serial.rxdn" \
  --start 2000000 --end 2700000 --radix "tb_tx_serial.u_tx.tx_stat_cur=hex"

# §2.11 挂起/唤醒图（因= bus_suspended/sie_wkup，变= tx_en/tx_bit，果= rxdp/rxdn）
python3 tools/render_waveform.py sim/tx/tx_susp_wkup.vcd doc/fig/tx_serial_susp_wkup.png \
  --signals "tb_tx_serial.bus_suspended,tb_tx_serial.sie_wkup,tb_tx_serial.tx_active,tb_tx_serial.tx_en,tb_tx_serial.tx_bit,tb_tx_serial.rxdp,tb_tx_serial.rxdn" \
  --start 3600000 --end 21000000 --width 1800 --height 780
```

> ★ `VCD=1` 是编译期宏（`-DVCD_SAVE`）。`make VCD=1 run` 在 `tx.vvp` 已是最新时不会重编，
> 于是不会写 VCD、只会静默沿用上次的旧文件。出图前必须先 `rm -f tx.vvp`（或 `make clean`）。

`tools/gen_tx_timing.py` 是参考模型与位级自检工具（`--check` 逐位比对、`--dump` 出逐拍 trace），
不作为出图来源。

### 4.8 验证

用例表、逐条实测读数、缺陷记录与覆盖率见 [tx_serial_verification.md](tx_serial_verification.md)。

#### 4.8.1 测试环境

| 项目 | 说明 |
|---|---|
| RTL（DUT） | `src/phy/usb_tx_serial.v`（1× `clk12m` 域，纯位级执行器） |
| 回环接收链 | TB 内 PHY 模型（§4.8.2）→ `usb_rx_cdr` → `usb_rx_deserial`（两个都已单独验证） |
| Testbench | `sim/tx/tb_tx_serial.v`：激励 + PHY 模型 + 逐位 oracle + 规则 6 结构守卫 + 自检 + `+case=` 分发 |
| PHY 模型 | `sim/common/phy_model.v`（可被 tx / sie / 顶层各 sim 复用） |
| Case 文件 | `sim/tx/case_*.v`，20 个，逐 case 独立 log `sim_<case>.log` |
| 激励方式 | TB 直接驱动 `tx_active` / `tx_data` / `tx_last`，按字节喂（扮演 SIE），不需要 USB 包 builder |
| 时钟 | `ref_clk` 48MHz（CDR + 派生 `clk12s`）；`clk12s` = `ref_clk÷4` 即 TX 的 `clk12m`；无需 `usb_clk_mux` |
| 自检 | PASS/FAIL = Verilog 内 `errors` 计数；make 按 `TEST PASSED` 判定 |

对比 RX 侧：TX 的输入是数字字节流而非物理波形，所以不需要 `usb_pkt_tasks.vh` 那套 NRZI/填充编码器；
反过来，TX 的输出得先经 PHY 模型还原成差分电平，才能交给已经验过的接收链去读回来。

#### 4.8.2 TB 内的 PHY 模型（`tx_bit` / `tx_se0` / `tx_en` → `rxdp` / `rxdn`）

发送方向最末端是模拟收发器驱动 DP/DN；仿真里没有模拟电路，所以在 TB 里用一个理想 PHY 模型把三个数字
输出还原成差分电平，接给接收链。映射规则（FS 设备：J = D+ 高 / D- 低）：

| `tx_en` | `tx_se0` | `tx_bit` | `rxdp` | `rxdn` | 线状态 |
|:---:|:---:|:---:|:---:|:---:|---|
| 0 | × | × | 1 | 0 | 高阻 → 建模为空闲 J（见下） |
| 1 | 1 | × | 0 | 0 | SE0（EOP 两拍；此时忽略 `tx_bit`） |
| 1 | 0 | 1 | 1 | 0 | J |
| 1 | 0 | 0 | 0 | 1 | K |

**高阻为什么建模成 J**：`tx_en`=0 时驱动确实撤了，但总线上并不悬空。主机端 D+/D- 各有 15 kΩ 下拉，
设备端（FS）D+ 有 1.5 kΩ 上拉，分压结果就是 D+ 高、D- 低 = 空闲 J。所以"交高阻"在电气上等价于
"回空闲 J"，模型直接给 `dp=1` / `dn=0`，接收链看到的就是合法的 idle。

**模型是理想的**：组合输出，不含传播延迟、抖动与上下沿斜率。这些属于模拟域与 CDR 容差的范畴
（CDR 已单独验证），本模块的验证不重复覆盖；模型只负责"数字 → 差分"这一件事，保持可判定。

**回环接线**（`sim/tx` 里的连接关系）：

```verilog
usb_tx_serial u_tx ( .clk12m(clk12s), .tx_active(tx_active), .tx_data(tx_data), .tx_last(tx_last),
                     .tx_bit(tx_bit), .tx_se0(tx_se0), .tx_en(tx_en), ... );   // ★ 端口名 clk12m

phy_model u_phy ( .tx_bit(tx_bit), .tx_se0(tx_se0), .tx_en(tx_en),
                  .rxdp(rxdp), .rxdn(rxdn) );           // §4.8.2 映射表

usb_rx_cdr u_cdr ( .ref_clk(ref_clk), .ref_rstn(ref_rstn),
                   .rxdp(rxdp), .rxdn(rxdn),
                   .dclk(dclk), .rx_bit(rx_bit) );      // 恢复 12MHz + NRZI 电平

usb_rx_deserial u_rx ( .clk12m(dclk), .ref_clk(ref_clk), .ref_rstn(ref_rstn),
                       .rx_bit(rx_bit), .rxdp(rxdp), .rxdn(rxdn),
                       .tx_active(1'b0), .rx_abort(1'b0),   // ★ 见下
                       .rx_data(rx_data), .rx_valid(rx_valid),
                       .rx_active(rx_active), .rx_error(rx_error), .line_state() );
```

> ★ `tx_active` / `rx_abort` 必须接 0：`usb_rx_deserial` 的 `tx_active` 是自收发门控（为 1 时强制回
> `USB_IDLE`）。回环里 TX 正在发送，若把 TX 的 `tx_active` 直连过去，deserial 会被一直摁在 IDLE、什么都收不到。
> 真实系统 USB 是半双工（同一时刻只有一个方向驱动总线），所以回环里接收侧恒为"非发送"。

#### 4.8.3 判据：回环为主，逐位 oracle 定位，结构守卫补"怎么变"

| 路径 | 做法 | 角色 |
|---|---|---|
| A 端到端回环 | TX → PHY 模型 → `usb_rx_cdr` → `usb_rx_deserial`，比对收到的字节流与发出的字节流 | 主判据。用的是真的已验 RTL，端到端自证 |
| B 逐位 oracle | TB 内自写位流生成器（按 §2.2 / §2.5 独立实现）逐位比对发出的位流 | 定位。回环只能报"哪一帧错"，B 能指到"哪一位错" |
| C 规则 6 结构守卫 | 四个输出各挂一条 `always @(sig)`：变沿必须落在 `clk12s` 上升沿上 | 补"怎么变"。A/B 只管"发的是什么"，这条管"是不是 DFF 直出" |
| D 跨语言旁证 | `python3 tools/gen_tx_timing.py --dump` 的逐拍 trace vs TB 打印的逐拍信号 | 独立实现（同 RX 报告 §5 的 Python 复算思路） |

**回环的比对口径**（沿用 RX 侧约定）：`rx_active`↑ 后第 1 个 `rx_valid` 脉冲字节 = PID；沿
`rx_valid` 逐字节与 TB 发出的字节队列比对；每包 `rx_active`↓ 恰一次、且该沿采到 `rx_error`=0。
发出的字节 = 收到的字节（含 PID / 地址 / 端点 / 数据 / CRC 字节；CRC 字节由 TB 按 §4.4 摆好位序后喂入，
模块应原样发出，故回环不涉 CRC 计算）。

几条路径互相制约：回环 A 若与 DUT 犯同一个理解错误（如都把某位算错），B/D 会拆穿。
这是 RX 侧 `byte_exact` 配 Python 复算的同一套做法。

#### 4.8.4 覆盖矩阵（设计条目 → 用例）

用例内容见 [tx_serial_verification.md](tx_serial_verification.md) §3。

| 设计条目 | 用例 |
|---|---|
| §2.2 通路次序（填充在 NRZI 之前；NRZI 就地写） | `tx_stuff_dense` `tx_pid_carry` `tx_byte_sweep` `tx_stuff_pos_scan` |
| §2.4 位填充（插 0 + hold 一拍） | `tx_stuff_dense` `tx_tail_stuff` `tx_carry_sweep` `tx_stuff_pos_scan` |
| §2.5 SYNC 不填充、计数从 PID 起算 | `tx_sync_pid_nostuff` `tx_pid_carry` `tx_all_pid` `tx_carry_sweep` |
| §2.6 位 FSM 六态、出口条件与中止 | `tx_len_scan` `tx_eop_timing` `tx_back2back` `tx_abort_phases` |
| §2.6 ② 尾填充两处落点 | `tx_tail_stuff` `tx_stuff_pos_scan` |
| §2.7 握手（`tx_ready` / `tx_last` 契约 / `tx_en` 边沿） | `tx_pkt_all` `tx_handshake` |
| §2.8 供字节预算（≥8 拍） | `tx_handshake` |
| §2.10 输出现态译码（DFF 直出 + 后移一拍） | 全部用例的规则 6 结构守卫 |
| §4.1 包尾严丝合缝（无 FIFO 余量） | `tx_len_scan` `tx_tail_stuff` `tx_stuff_pos_scan` |
| §4.3 EOP 时长与高阻时机 | `tx_eop_timing` `tx_back2back` |
| §4.4 CRC 字节位序（SIE 侧职责） | `tx_pkt_all` `tx_long_loopback`（喂已反序的 CRC 字节，验模块不重排） |
| §4.6 驱动使能与 SOP | `tx_back2back` `tx_abort` `tx_abort_phases` |
| §2.11 挂起交高阻 / 唤醒驱 K / 旁路优先级 | `tx_susp_wkup` |
| §2.11 `sie_wkup` 只在挂起态生效（防接错线） | `tx_susp_wkup`（收尾段：未挂起时单拉 `sie_wkup` 驱动器仍关） |
| 跨字节连 1 累计（填充最难的边界） | `tx_pid_carry` `tx_carry_sweep` |
| 包间空闲与 CDR 重锁（真实总线调度） | `tx_idle_between` |
| 形状空间随机回归 | `tx_random_stress` |
| §1 隐含契约（首字节必须是合法 PID） | `tx_sync_pid_nostuff`（反向：喂非法首字节不保证位流正确，只断言不挂死） |
