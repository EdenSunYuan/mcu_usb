# usb_rx_deserial 模块设计报告

> 模块：`usb_rx_deserial`（RX 反序列化 / 字节恢复）—— **`usb_dpll_phy` 的子模块**（位于 `src/phy/`，PHY 最末端做位→字节恢复）  
> 编写规范：见 [README_design_report.md](../README_design_report.md)  
> 上游：`usb_rx_cdr` + `usb_clk_mux`（同为 PHY 子模块）提供 `clk12m`/`rx_bit` | 下游：字节级边界 → SIE 事务逻辑（clk12m 域）  
> **2026-09-20 归属调整**：本模块由 SIE 改挂 PHY（`src/sie/` → `src/phy/`），**接口、RTL 行为、验证结论一字未改**。  
> 状态：**设计定稿 + RTL 已按本报告落地**（`src/phy/usb_rx_deserial.v`，clk12m 域位流水线；实现期加固：EOP SE0 区门控防"包尾连续 1 + 真 EOP"误判 7 连 1，见 §2.6/§4.6；`rx_error` 释放简化为"帧机回 `USB_IDLE` 即清"，见 §4.11 注）；**11 用例 × base/fixed 双模式回归全过**，见 §4.11  
> 参考：`docs/intel_sie_design_paper.pdf`（《Designing A Robust USB Serial Interface Engine》）；PHY 汇总见 [phy_design.md](phy_design.md)

---

## 1. 模块介绍

`usb_rx_deserial` 是 **`usb_dpll_phy` 的一个子模块**（位→字节恢复，PHY 最末端），接在 `usb_rx_cdr` + `usb_clk_mux` 之后，横跨 **两个时钟域**：

- **`clk12m`（1×，12MHz）**：位→字节流水线（NRZI 解码 / SYNC 检测 / 位解填充 / 字节对齐）。接收时 `clk12m = dclk`（DPLL 恢复时钟经 `usb_clk_mux` 切换而来）。
- **`ref_clk`（4×，48MHz）**：SE0/EOP 定界（需 4× 时间分辨率看单端沿）。

CDR 已经恢复出了 **位时钟 `dclk`** 和 **NRZI 电平 `rx_bit`**，但这两者还是"位级"的：没有字节边界、
没有去位填充、没有 NRZI 解码。`dclk` 经 `usb_clk_mux` 与发送时钟 `clk12s` 无毛刺切换成 `clk12m`
（接收时 = `dclk`）。`usb_rx_deserial` 负责把这串位流变成 **SIE 事务逻辑能直接消费的对齐字节流 +
包边界信号**。

**处理链**（一句话）：采样 NRZI 电平 → NRZI 解码 → SYNC 检测 → 位解填充 → 字节对齐 → EOP 检测。

```
  【usb_dpll_phy（PHY）】                        【usb_sie（SIE）】

   clk12m ──► [位流水线@clk12m 1×]                    ┌──────────────┐
             采样→NRZI解码→SYNC→解填充→字节对齐  ──►  │ rx_data[7:0] │
   rx_bit ──► [定界@ref_clk 4×] SE0/EOP 检测          │ rx_valid     │
             （eop 展宽跨到 clk12m 域）        ──►  │ rx_active    │
   rxdp/rxdn ►                                        │ rx_error     │
                                                     └──────┬───────┘
                                                            ▼
                                                SIE 事务逻辑（PID/CRC/事务）
           ▲  ‹── PHY↔SIE 边界 = 字节级 + 线状态，无异步 CDC ──›
```

**职责边界**：
- **做**：位 → 字节的物理层恢复（NRZI 解码、去填充、字节对齐、SYNC/EOP 定界）；字节维持满 667ns +
  `rx_valid` 每字节一拍脉冲（字节有效标记）+ `rx_active`↓ 包结束信号输出；`tx_active` 自收发门控；响应
  `rx_abort`（SIE 溢出中止）与 `usb_rst`（core 复位同步脉冲）立即回 `USB_IDLE`；线电平采样一份输出给
  `usb_bus_state`（`line_s`）；
- **不做**：CRC 校验、PID 解析、**data toggle（DATA0/DATA1 交替）**、事务/端点管理、**包长上限/
  溢出判断**（均属同层 SIE 事务逻辑）、异步跨时钟域（SIE↔FIFO 的 CDC，属于 `usb_sie_cdc`）。字节交给
  SIE 事务逻辑后由它自己解析（`rx_active`↑ 后第 1 个 `rx_valid` 脉冲的字节即 PID，SIE 自数，本模块
  不标记包首）、**不解释 PID 含义、不维护 DATA0/DATA1 的 toggle 序列**；本模块的 `rx_valid` 是"每字节
  一拍"的**字节有效脉冲**，与 USB 数据包的 DATA toggle 完全无关。

**工作频率**：`clk12m` = 12MHz（1×，位流水线），`ref_clk` = 48MHz（4×，SE0/EOP）；字节率 1.5 MHz
（FS = 12Mbit/s ÷ 8）。恢复时钟 `dclk` 经 `usb_clk_mux` 变成 `clk12m`，**直接作为位流水线时钟**
（每 bit 一拍），不产生派生物理时钟、不用 `bit_ce` 使能。

**字节输出协议（关键）**：`rx_data` 在寄存器里**维持满一字节周期（667ns = 8×clk12m）**——字节率 1.5MHz、
下一字节 8 bit 后才到，维持是天然的，SIE 事务逻辑在 clk12m 域采样时数据始终稳定；并输出 `rx_valid`
**每字节一拍脉冲**作为字节有效标记（UTMI `RXValid` 模型，见 `doc/usb协议解读/10_utmi_interface.md` §3）。
**本模块输出契约 = 纯 clk12m 1× 域信号、直交同域 SIE**：deserial 只负责把字节流交给 SIE，不产生/不消费
任何跨域信号；SIE 拿到字节后再自行处理（如需跨到 pclk/FIFO 由 `usb_sie_cdc` 四相握手完成，那是 SIE
内部的事，**不反向约束本模块输出**）。注意：`rx_valid` **不是 USB 的 DATA0/DATA1 toggle**——它只是
"每收一字节一个脉冲"的有效标记，DATA toggle 序列由 **SIE 事务层**维护，本模块不参与。详见 §4.8。

---

## 2. 模块设计理论和原理及方法

### 2.1 数据恢复链路（CDR → 字节流）

USB 接收方向从物理线到字节流要过四道"解码"，本模块覆盖后三道：

| 层 | 谁做 | 输入 | 输出 |
|----|------|------|------|
| 时钟/电平恢复 | `usb_rx_cdr` | D+/D- 差分线 | `dclk` + `rx_bit`（NRZI 电平） |
| 时钟切换 | `usb_clk_mux` | `dclk`（接收）/`clk12s`（发送） | `clk12m`（接收时 = `dclk`） |
| NRZI 解码 | 本模块 | NRZI 电平序列 | 原始数据 bit（含位填充） |
| 位解填充 | 本模块 | 原始数据 bit | 去填充后数据 bit |
| 字节对齐 + 定界 | 本模块 | 数据 bit | `rx_data[7:0]` + valid/active/error |

### 2.2 NRZI 解码原理

NRZI（Non-Return-to-Zero Inverted）编码规则：**数据 0 = 位起点翻转电平（有跳变），数据 1 = 保持电平（无跳变）**。
解码是对称的逆操作：

```
bit[i] = (nrzi[i] == nrzi[i-1]) ? 1'b1 : 1'b0;
// 电平不变 → 数据 1；电平跳变 → 数据 0
```

**采样点**：在 `clk12m` 上升沿采样 `rx_bit`（= CDR 的 `state[2]`）。接收时 `clk12m = dclk`，该上升沿对应
DPLL 进入"环内高电平两态"的瞬间，正是 bit 的**中点**，采样最稳。上一拍采样值锁存作 `nrzi_prev`，
与当前采样异或判断跳变。此采样原则已被 `case_loopback` 端到端验证（122 数据位 0 差异）证实。

### 2.3 SYNC 检测与相位对齐"吃位"问题

USB 包以 **SYNC = 8 bit `00000001`**（7 个 0 + 1 个 1，LSb 先发）开头，SYNC **不做位填充**。
SYNC 的唯一用途是让接收端对齐位/字节边界，**SIE 从不把 SYNC 当数据**。

**关键难点**：CDR 的时钟相位对齐会"吃掉" SYNC 开头的 1~2 个 0（首包吃 2 个、后续包吃 1 个，
见 CDR 验证报告 §5.2）。因此恢复出的 SYNC 只有 5~6 个 0。检测器**不能要求完整 7 个 0**，而要找
**SYNC 尾巴**：`连续 ≥4 个 0 + 1 个 1`。那个 `1` 是 SYNC 的最后一位，其后紧跟 **PID[0]**。
这个尾 `1` **不进解填充的连续 1 计数**——解填充计数从 PID 起算（理由与证明见 §2.4）。

> **根因（吃位为什么发生）**：空闲期 dclk **自由运转、不跟踪主机**，相位随 ±0.25% 晶振差漂移；
> SYNC 首跳变（J→K）逼 DPLL 重新对齐，**对齐过程要消耗 1~2 个边沿**，就吃掉了 SYNC 开头 1~2 个 0。
> 详见白皮书笔记 §2.6。

**收包帧状态机（位流水线主状态机 `st_stat_cur`，四态 `USB_IDLE` / `USB_SYNC_SEEK` / `USB_DATA` / `USB_ERROR`）**。
关键定义：**`rx_active` = "帧中"有效信号**——`rx_active ≡ (st_stat_cur==USB_DATA) || (st_stat_cur==USB_ERROR)`，
组合解码（`assign rx_active = (st_stat_cur==USB_DATA) || (st_stat_cur==USB_ERROR);`），**不另设帧标志寄存器**。
帧的拉高 = 进 `USB_DATA`、拉低 = 出帧（回 `USB_IDLE`），同一寄存器同起同落，没有"状态机 + 帧标志各存
一份、两套逻辑置位/复位"的重复。**`USB_ERROR` 是"错误保持"态**：物理层检错后**帧先不开**——`rx_active`
保持 1（SIE 仍视为同一包），同时 `rx_error` 置电平，**等总线回到 idle 才关包释放**（§2.6）。四态仍只需
2-bit `st_stat_cur`。

SYNC 搜索只在 `USB_IDLE` / `USB_SYNC_SEEK` 两态运行（`rx_active=0`），避免把数据里的"0…01"误判为 SYNC；
进 `USB_DATA` / `USB_ERROR` 后（`rx_active=1`）搜索停止、位流水线接管。**最高优先级复位**：复位 /
`tx_active=1`（自发送）/ 包终止 → 回 `USB_IDLE`，即 §2.6 释放条件全集（`st_stat_cur` 回 `USB_IDLE` ⇔
`rx_active` 拉低）。错误残余期让 `rx_active` 保持 1（待在 `USB_ERROR`），正是靠"SYNC 搜索门控在
`rx_active=0`"把坏包残余数据挡在 SYNC 检测之外——不会在真 EOP 之前误开新帧。

**`zero_cnt` 门控（同 `ones_cnt` 一个原则，见 §2.4）**：`zero_cnt` 只在 `USB_SYNC_SEEK` 态更新——
首个 `0` 置 1、后续 `0` 累加，命中 / 假触发 / 0 过多回 `USB_IDLE` 时清 0；**`USB_IDLE` / `USB_DATA` /
`USB_ERROR` 期间保持为 0**。原因：`USB_DATA` 里 PID/地址/CRC/数据含大量 `0`，绝不能把它们计入 SYNC 的
0 计数（搜索在 `USB_DATA` 本已停，残留计数只会污染下一包）；`USB_ERROR` 期同样不搜 SYNC（`rx_active=1`），
残留计数同样不产生。两个计数都只在各自窗口内有意义、离窗即复位，杜绝把空闲 J（连续 `1`）或包内数据
误当 SYNC 前导。

| 当前态 | 条件 | 次态 | 动作 / 说明 |
|---|---|---|---|
| `USB_IDLE` | `bit=0` | `USB_SYNC_SEEK` | 首个 0 = 包开始候选，`zero_cnt=1` |
| `USB_IDLE` | `bit=1` | `USB_IDLE` | 空闲 J（连续 1），保持待命 |
| `USB_SYNC_SEEK` | `bit=0` 且 `zero_cnt<7` | `USB_SYNC_SEEK` | 又一个 0，`zero_cnt++` |
| `USB_SYNC_SEEK` | `bit=0` 且 `zero_cnt==7` | `USB_IDLE` | 0 过多（第 8 个 0）非法，回空闲 |
| `USB_SYNC_SEEK` | `bit=1` 且 `zero_cnt≥4` | `USB_DATA` | **SYNC 命中**：`rx_active`↑、`zero_cnt` 清零；解填充 `ones_cnt` 从 PID 起算（窗口 = `rx_active`，此刻仍为 0，见 §2.4）；下一 bit=PID[0] |
| `USB_SYNC_SEEK` | `bit=1` 且 `zero_cnt<4` | `USB_IDLE` | 假触发：零太少的 "0…01" 不是 SYNC |
| `USB_DATA` | `eop`（EOP FSM 拉，SE0→J） | `USB_IDLE` | **正常关包**：`rx_active`↓、清位流水线；`rx_error` 从未置、保持 0（§2.6 释放条件 1） |
| `USB_DATA` | 位填充违规 7 连 1（解填充检出） | `USB_ERROR` | **错误保持**：置 `rx_error`（电平）、**停吐字节**、`ones_cnt` 清 0 重计；`rx_active` **保持 1**（帧不开，等总线回 idle，§2.6） |
| `USB_DATA` | EOP 错（EOP FSM 拉 `eop_err`，SE0 后非 J） | `USB_ERROR` | **错误保持**：同左（SE0 已现 = 帧尾将至，保持到总线静默回 J 即释放） |
| `USB_DATA` | `rx_abort` / `tx_active` / `usb_rst` | `USB_IDLE` | 中止关包：`rx_active`↓、丢包、**不置 `rx_error`** |
| `USB_DATA` | 其他（仍在收） | `USB_DATA` | 不做 SYNC 检测；解填充/字节对齐逐字节打 `rx_valid` |
| `USB_ERROR` | `eop`（EOP FSM 拉，坏帧的 SE0→J 帧尾） | `USB_IDLE` | **释放**：`rx_active`↓、`rx_error` 清（晚一拍，见 §2.6）、清位流水线（§2.6 释放条件 2，用户确认 = 看 `eop`） |
| `USB_ERROR` | 位填充违规 7 连 1 再现（静默 J、无 EOP） | `USB_IDLE` | **释放**：同上（总线静默回 J-idle → 连续 1 数满 7；**无额外计数器**，复用解填充检错当 idle 探针，§2.4/§2.6） |
| `USB_ERROR` | `rx_abort` / `tx_active` / `usb_rst` | `USB_IDLE` | 强制释放：`rx_active`↓、`rx_error` 清 |
| `USB_ERROR` | 其他（仍在等总线回 idle） | `USB_ERROR` | 保持：不吐字节、不检 SYNC、EOP FSM 保持 armed（好让坏帧帧尾的 `eop` 能到） |

> `USB_DATA` / `USB_ERROR` 态内部不再有状态流转：字节恢复（解填充/字节对齐）是**并行数据通路**，不是
> 状态机状态；帧的唯一表征就是这个态本身。`rx_active` 同时回环供 ref_clk 域 EOP FSM 门控（§2.6：帧开
> （`USB_DATA` 或 `USB_ERROR`）期运行）。
> 空闲时 NRZI 解码输出连续 `1`（J 电平无跳变）；第一个 `0` 即 SYNC 首个跳变，天然是"包开始"标志。
> **同一个"数满 7 个 1"（7 连 1），靠当时在哪个态决定动作**：`USB_DATA` 期出现 = 物理错 → 进
> `USB_ERROR` 置错；`USB_ERROR` 期出现 = 总线已静默回 J（idle 证据）→ 释放。硬件只需一份 7 连 1 检测，
> 状态不同动作不同——正是"静默 J 无 EOP 不需额外计数器"（用户指定）的实现形态。

### 2.4 位填充与解填充

USB 位填充：**连续 6 个 1 后强制插 0**，防止长时间无跳变（锁相环会漂）。填充从 **PID 起**（SYNC 不填充），
覆盖 PID/地址/端点/CRC/数据，EOP 不填充。

**计数窗口（门控）**：`ones_cnt` 的窗口 = **`rx_active`（帧中，即 `USB_DATA` / `USB_ERROR`）**，
帧外（`USB_IDLE` / `USB_SYNC_SEEK`）**保持复位为 0**——与 `zero_cnt` 的窗口（只在 `USB_SYNC_SEEK`）
互为镜像：**帧外找 SYNC（数 0），帧内解填充（数 1）**。原因：空闲 J 态 NRZI 解码输出连续 `1`（无跳变），
若帧外也累加，挂总线 ~6 bit 就会把空闲 J 误判成"已 6 连 1"，下一个总线 `0` 会被当成 stuffed 0 丢弃或
触发 7 连 1 违规。
`USB_ERROR` 在窗口内、**继续计数**，是当"总线是否已静默回 J-idle"的**探针**：错误后若发送方停发、总线
静默停在 J，NRZI 解码连续 `1`，数满 7 即 7 连 1 再现 → 释放（§2.6）——**不设额外定时器**。进
`USB_ERROR` 时计数**清 0 重计**：进态的同一个 7 连 1 已被消费，重计才能探测"之后"的静默 J。
（RTL 实现即 `else if (!rx_active) ones_cnt <= 0;`——用已解码的 `rx_active`，不再单独比状态。）

**关键细节：SYNC 尾 `1` 不计入连续 1 计数，计数从 PID 起算**。曾担心"不计数则 PID 以连续 1 开头时
去填充晚一拍、字节边界错位"，**这个担心不成立**：SYNC 之后必定是 PID，而 PID 结构上不可能凑出 6 连 1——
PID 字节 = 低 4 位 code + 高 4 位 `~code`，线上（LSb 先）先发 code 再发 `~code`；同一 nibble 内最多 4 连 1，
**跨 nibble 的连 1 要求 `code[3]`=1 且 `code[0]`=0，与"4 连 1"要求的 `code[0]`=1 矛盾** → 字节内最多 4 连 1。
SYNC 尾 `1` 接上这 4 个 = **5 < 6**，所以 SYNC/PID 段既不会出现 stuffed 0、也不会出现 7 连 1 违规，
**尾 `1` 计不计入对输出位流完全无影响**（两种规则逐位等价，机器证明见
[tx_serial_design.md](tx_serial_design.md) §4.2 与 `tools/gen_tx_timing.py --check`）。
因此 RX 与 TX（`usb_tx_serial`）采用**同一条规则**：**填充计数从 PID 起算**，收发两侧对边界理解一致。

**别误读**：这是"SYNC 不计入"，**不是**"PID 不计入"——PID 可能以 3 连 1 收尾（如 OUT `0xE1` 线上
`10000111`），这个计数**必须**带进下一字节：下一字节开头 3 个 1 就凑满 6 → 发送端插位、接收端丢位
（真实场景：OUT token 发给**地址 7** 的设备）。

**计数规则（窗口内逐 bit）**：**`bit=1` → `ones_cnt+1`；`bit=0` → `ones_cnt` 清 0**。解填充是逆操作：
数到 **6 个 1 后，下一个 bit（发送端必插的 `0`）是 stuffed bit**——丢弃并清计数（不输出、不算数据）：

```
// 窗口 = rx_active (USB_DATA | USB_ERROR); 帧外 (USB_IDLE / USB_SYNC_SEEK) 时 ones_cnt 保持 0
对窗口内每个 bit（PID → 地址/数据/CRC → 错误残余）:
    if (ones_cnt == 6 && bit == 1)   // 7 连 1
        if (st_stat_cur == USB_DATA)    // 物理错（帧中，帧尾未到）
            置 rx_error、进 USB_ERROR、ones_cnt 清 0 重计（§2.6）;
        else                         // st_stat_cur == USB_ERROR：静默 idle 探针
            回 USB_IDLE、清 rx_error（释放，§2.6）;
    else if (ones_cnt == 6)          // 满 6 个 1 后的 stuffed 0
        丢弃（不输出）, ones_cnt = 0;
    else if (bit == 1)
        ones_cnt++;
    else                             // bit == 0
        ones_cnt = 0;
        if (st_stat_cur == USB_DATA) → 输出 bit;   // USB_ERROR 期不吐 bit（停吐）
```

> 注：`USB_SYNC_SEEK` 在窗口外，`ones_cnt` 全程保持 0（SYNC 的 0 与尾 1 都不进解填充计数）；
> 解填充的**"输出 bit"只在 `USB_DATA` 才发生**（SYNC 的 0 不是数据，不交给字节对齐；`USB_ERROR` 期
> 已停吐）。字节对齐的移位使能见 §2.5。

**填充错误检测**：`ones_cnt == 6` 后下一个仍是 `1`（7 连 1）→ 位填充违规。**在 `USB_DATA` 期 = 置
`rx_error` 电平 + 进 `USB_ERROR`**（帧先不开）；**在 `USB_ERROR` 期再现 = 总线静默回 J（idle），释放回
`USB_IDLE`**（同一个检测、按态分支，见 §2.3 状态表 / §2.6 / §4.7）。

### 2.5 字节对齐（LSb first）与 `rx_valid` 脉冲

USB 线上 **LSb 先发**。SYNC 尾 `1` 之后，每 8 个**去填充后**的数据 bit 组成一个字节（最早收到的位是 LSB）。
字节恢复**只在 `USB_DATA` 期进行**——SYNC 的 `0`、空闲 J 的连续 `1`、stuffed 0、`USB_ERROR` 期（检错后）
的残余位都**不是数据，不进移位寄存器**；`USB_IDLE` / `USB_SYNC_SEEK` 期 `shift_reg`、`bit_cnt` 保持清
0，`USB_ERROR` 期因 `enable_shift=0`（见下）自然停移，残余残缺字节不补、随释放清 0。注意 `rx_active`
在 `USB_ERROR` 仍为 1，但字节恢复只看 `st_stat_cur==USB_DATA`——**帧还开 ≠ 还在吐字节**。

**移位使能（门控，不是时时刻刻移）**：`shift_reg` 只在「**`st_stat_cur==USB_DATA`** 且该 bit 是**去填充后的
有效数据 bit**（非 stuffed 0）」时移一拍（每数据 bit 一拍 clk12m，因位流水线每 bit 一拍消费 `rx_bit`）：

```verilog
enable_shift = (st_stat_cur == USB_DATA) && 解填充输出有效;   // 解填充输出 gating 到 USB_DATA，见 §2.4
```

7 位**右移寄存器**存当前字节"已到、尚差最高位 b7"的低 7 位：新数据 bit 进 MSB（`[6]`）、内容整体向 `[0]`
方向移，最早收到的 b0 落 `[0]`（= LSB 位）。移满 7 拍后 `shift_reg[i] = b_i`（i=0~6），第 8 位 b7 尚在
`bit` 输入上：

```verilog
if (enable_shift) begin
    shift_reg <= {bit, shift_reg[6:1]};
    bit_cnt   <= bit_cnt + 3'd1;   // 字节内位计数 0~7；3-bit 加满 7 自然溢出回绕到 0，无需显式清零
end
```

**满字节 → `byte_rdy` → `rx_valid` 脉冲（UTMI `RXValid` 模型）**：收到第 8 个有效 bit 时（此时
`bit_cnt==7`）字节满。该拍由第 8 位与移位寄存器现态直接拼出整字节 `{bit, shift_reg[6:0]}`——锁进
`rx_data`、同时打 **1 拍宽 clk12m 的 `rx_valid` 脉冲**、`bit_cnt` 由 7 加 1 **自然回绕到 0** 收下一字节。

**寄存器为何只做 7 位**：收字节用"第 8 位到齐即拼"的零延迟法——第 8 位 b7 只出现在 `bit` 输入上、
**不进寄存器**，寄存器只需存已到的 b0~b6 共 7 位；若做成 8 位 `[7:0]`，多出的 `[0]` 只会在第 8 拍后
装进 b0、而字节早已用拼接锁出，是**无扇出的死位**——故收窄到 `[6:0]` 省 1 个触发器。反例：若改成
"先移满 8 拍、下一拍再锁 `shift_reg[7:0]`"（`rx_valid` 晚一拍），才需要第 8 位进寄存器——此处不用该实现。
`rx_data` 在脉冲拍已更新稳定，两次脉冲之间维持不变（字节率 1.5MHz，下一字节 8 bit 后才到）。`bit_cnt`
**不需要显式清零**：完成拍靠回绕前的值 `bit_cnt==7` 判满字节（出 `byte_rdy`/`rx_valid`），3-bit 计数
7+1 溢出即回 0——前提是 `enable_shift` 对每个有效数据位都成立（每字节恰 8 位、stuffed 位已丢弃不计数），
第 8 位那拍一定在移、回绕必发生。

- 每字节恰一个 `rx_valid` 脉冲；`rx_active`↑ 后第 1 个脉冲的字节 = PID（SIE 自数，见 §4.8）；
- **残缺字节（dribble）**：EOP 到来时 `bit_cnt` 不足 8 → **不产生 `byte_rdy` / `rx_valid`**，随回
  `USB_IDLE` 复位丢弃，不污染已打出的上一字节（见 §2.6）；
- stuffed bit 在解填充段已丢弃（§2.4），不计数、不产生脉冲，故 `rx_valid` 脉冲**不按 clk12m 周期等间隔**
  ——SIE 只在脉冲拍采样，无需知道间隔。

### 2.6 EOP / SE0 检测与包尾定界

USB 包尾是 **EOP = SE0（D+ 与 D- 同时为 0）+ J**。标准 EOP 是 **SE0 持续 2 bit 时间 + J 1 bit 时间**。
SE0 是**带外信号**（单端，非差分），直接看 `rxdp`/`rxdn`（`line_state == 2'b00`），与恢复时钟/bit 流
**异步**，因此独立于 bit 流水线、在 `ref_clk`（4× 域）单独跑一个状态机检测（Intel 白皮书 Fig.7）。

**SE0 宽度判据（Fig.7 判决点 = 3 拍 ≈62.5ns）**：USB 1.1 规范要求全速器件**接受 ≥82ns 的 SE0、拒绝
<40ns 的 SE0**（Intel 白皮书转述），40~82ns 之间"可收可拒"。Intel Fig.7 取**中间值 3 拍
（3×20.8ns ≈ 62.5ns）**作判决点——比"规范下限 82ns"略宽容（对偏短的主机 EOP 更友好），仍满足
"必拒 <40ns"（2 拍 = 41.6ns 到不了判决点，作废）：

| 情形 | SE0 时长 | 回到 J | 判定 |
|------|---------|--------|------|
| 标准 EOP | 2 bit（8 ref_clk） | 是 | ✅ EOP |
| 偏短 EOP | 1 bit（4 ref_clk = 83ns ≥ 82ns） | 是 | ✅ EOP |
| 灰色区上沿 | 3 ref_clk（62.5ns，判决点） | 是 | ✅ EOP（Fig.7 接受） |
| 灰色区下沿 | 2 ref_clk（41.6ns） | 是 | ❌ 作废（<3 拍，不判 EOP） |
| 毛刺/噪声 | <2 ref_clk（<40ns） | — | ❌ 非 EOP（规范要求拒绝） |

**必须回到 J**：SE0 之后必须以 **J（idle）** 收尾才拉 `eop`——这是规范对 EOP 的要求（`se0 → j` 沿）。
SE0 之后是 K 或继续 SE0 的异常收尾（**EOP 错**），由 FSM 的 `eop_dead` 态承接：**不拉 `eop`、改拉
`eop_err`**（ref_clk 域），经展宽跨到 clk12m 后把帧态机推入 `USB_ERROR`（置 `rx_error` 电平，§2.3 状态
表）。SE0 已现即"发射方放线"、帧尾将至，但收尾非 J 说明总线**尚未回 idle**——用 `USB_ERROR` 保持
`rx_active=1`，把非 J 残余（NRZI 解码成连续 1）挡在 SYNC 检测之外，等总线静默回 J（7 连 1 探针）或
`usb_rst` 才关包（错误出口见 §2.3 状态表 / §4.6）。

**EOP 检测状态机（Fig.7，5 态，`ref_clk` 域，独立于 bit 流水线）**：**仅在 `rx_active=1` 时运行**
（UTMI 的 `RXActive` 模型：包期间监测、包结束拉低；帧开 = `USB_DATA` 或 `USB_ERROR`，见 §2.3），否则停在
`eop_idle`——坏包在 `USB_ERROR` 保持期间 `rx_active` 仍为 1，EOP FSM **保持 armed**，好让坏帧真正以
SE0→J 结束时能拉到 `eop` 释放；`tx_active=1` 已强制
`rx_active=0`，自发送期天然不检。`rx_active`（clk12m 域）在 ref_clk 域直接采样即可：两者沿对齐
（clk12m 由 dclk/clk12s 派生，边沿都在 ref_clk 上），无亚稳态（同 `rcv` 的 4× 采样，白皮书 §3.5.4）。
每 4× 拍采样一次 `line_state`（全速 J=2'b10 / K=2'b01 / SE0=2'b00），判三个条件：`se0`（==2'b00）、
`j`（==2'b10）、`其他`（非 se0 非 j）。采样寄存器 `line_s` 复位取 `2'b00`（SE0），这是总线上电前的
真实电平。同一个 `line_s` 也输出给同域的 `usb_bus_state` 当输入，那边不再自己采一遍（xiao_yuan
2026-09-28 定），两个模块的复位判据与 EOP 判据因此共用一把尺子。`eop_se0_1/2/3` 是连续 3 拍 SE0
的**计时链**，`eop_dead` 承接"SE0 后非 J"的异常收尾（只待一拍，无条件回 idle）：

```
                 se0                 se0                 se0
[eop_idle] ──────────► [eop_se0_1] ──────────► [eop_se0_2] ──────────► [eop_se0_3]
    ▲                                                                        │
    │                                                                        │ se0（自环）
    └──────────────────── j（拉高 eop）──────────────────────────────────────┘

回退：eop_se0_1 / eop_se0_2 见"非 se0" → 直接回 eop_idle（SE0 太短，作废）
旁路：eop_se0_3 见"其他(非se0非j)" → eop_dead；eop_dead 无条件回 eop_idle（其中 j 拉 eop、非 j 拉 eop_err）
```

**跳转表**：

| 当前态 | 条件 | 次态 | 动作 / 说明 |
|---|---|---|---|
| `eop_idle` | `se0` | `eop_se0_1` | 检测到 SE0，开始计时 |
| `eop_idle` | 非 `se0` | `eop_idle` | 没 SE0，待命 |
| `eop_se0_1` | `se0` | `eop_se0_2` | 第 2 拍 SE0 |
| `eop_se0_1` | 非 `se0` | `eop_idle` | <2 拍，作废 |
| `eop_se0_2` | `se0` | `eop_se0_3` | 第 3 拍 SE0（≈62.5ns，达判决点） |
| `eop_se0_2` | 非 `se0` | `eop_idle` | <3 拍，作废 |
| `eop_se0_3` | `se0` | `eop_se0_3` | 长 SE0，自环（不重复判） |
| `eop_se0_3` | `j` | `eop_idle` | **拉 `eop`**（正常 EOP） |
| `eop_se0_3` | 其他 | `eop_dead` | SE0 后非 J，走异常旁路 |
| `eop_dead` | `j` | `eop_idle` | **拉 `eop`**（补判 EOP，宽容收尾） |
| `eop_dead` | 非 `j` | `eop_idle` | EOP 错：静默回（不拉 `eop`）但**拉 `eop_err`**（错误事件，ref_clk→clk12m 展宽跨域同 `eop`，见 §2.7）；clk12m 域据此进 `USB_ERROR` 置错（§2.3 状态表 / §4.6） |

📎 [打开波形图：长 SE0 自环不误判 + SE0→J 干净释放（deserial_se0_long.png）](../fig/deserial_se0_long.png)

> 图 2.6a 长 SE0（`deserial_se0_stuck`，2.60–6.30µs）：帧尾进 SE0 后 eop_stat_cur 计到 `eop_se0_3` 并**自环
> 等待**（"长 SE0，自环（不重复判）"一行）；SE0 持续 ~2.6µs 期间 st_stat_cur **全程停在 DATA（=2）不误关包、
> `rx_error` 恒 0 不误报**（SE0 区不解成位 → 无假 7 连 1）；SE0→J 时 EOP FSM 回 `eop_idle` 拉 `eop` →
> st_stat_cur 2→0 干净释放、`rx_active`↓ 正常收尾。SE0 ≥2.5µs 的 disconnect/reset 判定属独立总线状态模块
> （本模块只拿 SE0 做 EOP 定界，见 §4.7 表）。

**帧收尾与错误模型（`rx_error` 电平，关包由 clk12m 帧态机裁决）**：关包/释放**由 clk12m 收包帧态机裁决**
（§2.3 状态表）——EOP FSM 只**报告帧尾事件**（`eop` = SE0→J 正常收尾；`eop_err` = SE0 后非 J 的 EOP
错），**不再直接拉低 `rx_active`**。**正常包**：`USB_DATA` 期收到 `eop` → 回 `USB_IDLE`（`rx_active`↓，
`rx_error` 从未置、为 0）。**坏包**先置 `rx_error` 电平再等关包，分两类：

| 错误 | 检出 | 帧态机 | `rx_error`（电平） | `rx_active` | 关包时机 |
|---|---|---|---|---|---|
| 位填充违规 7 连 1（帧中、帧尾未到） | clk12m 解填充 | DATA → `USB_ERROR` | 置 1（保持） | **保持 1** | 坏帧帧尾 `eop`，或静默回 J（7 连 1 再现） |
| EOP 错（SE0 后非 J 持续） | ref_clk EOP FSM（`eop_err`） | DATA → `USB_ERROR` | 置 1（保持） | **保持 1** | 总线静默回 J（7 连 1 再现） |
| 中止（`rx_abort` / `tx_active` / `usb_rst`） | SIE / 复位 | → `USB_IDLE` | 不置（保持 0） | 拉低 | 立即 |

**`rx_error` 是电平，不是脉冲**：物理检错当拍**置起**（帧态机进 `USB_ERROR`），`USB_ERROR` 期间**保持
为 1**——SIE 在帧仍开（`rx_active=1`）时就能读到"此包已坏"，不必等关包才知道；直到关包（`st_stat_cur` 回
`USB_IDLE`）才**清 0**。内部实现：clk12m 域检错（7 连 1）直接置 `rx_error`；ref_clk 域 EOP 错经
`eop_err`→`eop_err_w` 展宽跨到 clk12m（§2.7 plan B），在 clk12m 域置 `rx_error`。

**`rx_error` 清除时序（保证 SIE 下降沿采样可靠）**：`rx_active` 是组合解码（`st_stat_cur` 回 `USB_IDLE`
当拍即落 0），SIE 要到自己下一拍才采到"下降沿"；若 `rx_error` 与关包**同拍**清 0，SIE 采到下降沿那一拍
`rx_error` 已是 0，会漏报坏包。故 `rx_error` 清 0 **比关包晚一拍**：关包后的第 1 个 `USB_IDLE` 周期仍为
1、第 2 个周期起为 0。实现：记 `st_stat_cur` 前一拍，`st_stat_cur` 由 `USB_DATA`/`USB_ERROR` 回到 `USB_IDLE`
的**下一拍**清 `rx_error`（等价于"关包沿不清、紧接着的清"）。**SIE 契约**：`rx_active` 下降沿 = 包结束，
SIE 以该沿为收包标记、沿后采样 `rx_error`——=1 判"此包坏"（数据作废、按不应答处理），=0 判正常收尾。

**为什么帧中错误"先不开帧、等总线回 idle 才关"（`USB_ERROR` 保持态的由来）**：7 连 1 错在帧中间，错误点
**之后线上还可能有残余位**（发送方仍在驱动的数据或噪声）；若检错当拍就把 `rx_active` 拉低回 `USB_IDLE`，
SYNC 检测器立刻重新挂起（只在 `rx_active=0` 运行），会把错误残余里形似"0…01"的位**误判成新包的 SYNC**、
开出一个幽灵帧。`USB_ERROR` 保持 `rx_active=1`（SYNC 搜索门控在 `rx_active=0`，§2.3），把残余全挡在
当前帧内；等**"总线已回 idle"的证据**才关。idle 证据 = ① 坏帧其实仍以 SE0→J 帧尾正常结束 → EOP FSM 拉
`eop`（**用户确认：ERROR 释放条件 1 就看 `eop` 信号**）；② 无 EOP、总线直接静默停在 J → NRZI 解码连续 1
数满 7 → **位填充违规再现**（deserial **不设额外定时器**，复用解填充的 7 连 1 检测当 idle 探针）；③
`tx_active` / `usb_rst` / `rx_abort` 强制。EOP 错（SE0 后非 J）同理：SE0 已现 = 帧尾将至，但收尾非 J
说明未回 idle，保持到总线静默回 J（7 连 1 探针）或 `usb_rst` 兜底。

**dribble 位（带内→带外过渡的伪位）**：包尾最后一个数据 bit 到 SE0 的过渡处，差分接收器可能
产生一次**伪跳变**，被 DPLL 多恢复出 1 个假 bit（Intel 白皮书称 **dribble**）。它是包尾**多出来的
1 个 bit**——即一个永远补不齐的**残缺字节**（`bit_cnt` 到 EOP 时不足 8，**不产生 `byte_rdy`**），
随 EOP 回 IDLE 直接丢弃，**不污染最后一字节**（最后一字节由 8 个真实 bit 组成，`byte_rdy` 正常打出）。
包尾定界因此**不依赖"数到第几个字节是最后"**，而靠 **EOP 确认后 `rx_active` 下降沿**收尾。
dribble 还可能跟在包尾一个 stuffed bit 之后，同样作为残缺字节丢弃。

- **EOP 检测**：`rx_active` 期间跑 Fig.7 5 态 FSM，`eop_se0_3`（连续 3 拍 SE0 ≈62.5ns）后回到 J → 判定包结束；
- **`rx_active`**：SYNC 命中拉高、包结束（EOP/错误/中止）拉低，框住整包。**下降沿 = 包结束**
  （UTMI `RXActive` 模型，见 `doc/usb协议解读/10_utmi_interface.md` §3/对照表）——**无 `rx_last`**：
  字节在 `byte_rdy` 时逐个正常打出（含最后一字节，各伴一个 `rx_valid` 脉冲），SIE 无需"最后一字节"
  标记——收字节靠 `rx_valid` 每字节一脉冲、包好坏靠 `rx_error` 判、包结束靠 `rx_active`↓。

**SE0 卡死为何不停摆、也不误报（CDR 靠 D+ 检测 + EOP SE0 区门控）**：CDR 的 DPLL 由 `rxdp`（D+ 单端）
驱动（`rxdn` 仅做 SE0 判别、不参与状态跳转）。SE0 对 D+ 而言就是**恒低、无跳变**——与 J/K 一样，DPLL
**自由运转**、`dclk` 照常出沿，位流水线时钟不会停。而 **SE0 区不会被解成假位**：EOP FSM 一进 SE0 态
（`eop_se0_1..3`）就掩蔽 clk12m 域把该区 `rx_bit` 当数据位去 NRZI 解码/数 7 连 1（EOP SE0 区门控，
§4.6）——所以**长 SE0 卡死既不触发假 7 连 1 违规、也不误关包**：st_stat_cur 停在 `USB_DATA`、`rx_error=0`
保持，EOP FSM 在 `eop_se0_3` **自环等 J**（图 2.6a，`case_se0_stuck` 注入 ~2.6µs SE0 实测）；SE0→J 时
拉 `eop` → 干净关包回 `USB_IDLE`。真正的 7 连 1 违规只来自线在 J/K 上发送的真实连 1 数据（非 SE0 区）。
独立总线状态模块的 usb_rst（SE0 ≥2.5µs = disconnect+reset）是**并行兜底**而非本模块职责。含 SE0 ≥2.5µs
的总线复位由 `usb_bus_state` 判出 `usb_bus_rst`，在外面并进 `usb_rst` 送到本模块（释放条件 6）。

**`rx_active` 释放条件（包终止全集）**：正常包在 `USB_DATA` 关、坏包在 `USB_ERROR` 等总线回 idle 才关，
任一满足即回 `USB_IDLE`（`rx_active`↓，SYNC 检测随之重新挂起；坏包释放时 `rx_error` **晚一拍清 0**，
见上）：
1. **正常关包**：`USB_DATA` 期 EOP FSM 拉 `eop`（SE0→J，SE0 ≥62.5ns、Fig.7 判决点 3 拍；含 `eop_dead`
   见 J 的宽容收尾）→ 回 `USB_IDLE`（`rx_error` 保持 0）；
2. **坏帧帧尾**：`USB_ERROR` 期 EOP FSM 拉 `eop`（坏帧其实仍以 SE0→J 帧尾正常结束）→ 释放（用户确认：
   条件 1 就看 EOP FSM 的 `eop` 信号，不额外判）；
3. **静默 idle（无 EOP）**：坏帧无 EOP、总线直接静默回 J → 连续 1 数满 7 → **位填充违规再现** → 释放
   （无额外计数器，§2.4）；SE0 卡死同走此路径（K 恒电平 = 连续 1）；
4. **SIE 溢出中止**：连续跳变乱码**无 EOP** 且一直在吐字节（仍处 `USB_DATA`、未进 `USB_ERROR`）时，
   deserial **不设本地定时器**、照常持续收字节——SIE 事务层按 PID + 端点配置数当前包字节数，**超过该包
   类型/端点最大负载上限**时拉 `rx_abort` → deserial 立即回 `USB_IDLE`（`rx_active`↓、丢包、**不置
   `rx_error`**）。这是**协议感知**的兜底：乱码只要持续跳变，字节就每 8 bit 出一字节、无界增长，迟早超
   上限；进 `USB_ERROR` 后已停吐字节，此兜底不再适用（错误残余靠 7 连 1 探针 / usb_rst 收口）；
5. **自发送门控** `tx_active` → 回 `USB_IDLE`（并清 `rx_error`）；
6. **`usb_rst`**（core 复位同步脉冲，外面并好）→ 回 `USB_IDLE`（并清 `rx_error`）。

> deserial **内部零定时器**：正常关包靠 `eop`；坏包关包靠 `eop`（坏帧帧尾）或 **7 连 1 再现**（静默
> idle 探针）；无 EOP 连续乱码靠 SIE 溢出（`rx_abort`）——全由协议/总线证据包圆，deserial 只剩
> "收字节 + 响应错误与终止信号"，无任何时长计数器。

**两根复位分工**：`ref_rstn` 异步低有效，清全部寄存器（含 `line_s` 采样），是上电复位；`usb_rst`
同步高有效、宽 1 个 `clk12m` 周期，清 clk12m 域协议状态。契约全在模块外定：

- **外面并好再送来**：`usb_rst` = 总线复位（`usb_bus_state` 的 `usb_bus_rst`，SE0 ≥2.5µs）∪ 软复位
  （APB `SWRST`），由 APB/顶层整形成 1 个 `clk12m` 周期的脉冲。模块内**不做同步器、不做展宽**——脉冲
  宽度是契约（§3.2），模块照采。
- **只清协议状态**：帧机回 `USB_IDLE`、位流水线冻结，与 `rx_abort`/`tx_active` 走同一条强退路径
  （`frame_clr`），**不置 `rx_error`**——复位不是检错。

| 为何不留给 SIE 用 `rx_abort` 代劳 | 说明 |
|---|---|
| 复位期间 SIE 自己也在被清 | 总线复位后 SIE 回初始态，没人替 deserial 拉 `rx_abort`；帧机若还开着（`rx_active=1`），刚出复位的 SIE 会看见一个陈旧的开口帧 |
| 时间是 `clk12m` 周期级 | 复位事件在 `ref_clk` 域判出，已经由 `usb_bus_state` 的翻转通知跨到 `clk12m`；本模块只收 `clk12m` 域的同步脉冲 |

**两处不吃 `usb_rst`**（复位范围只到协议状态，不碰"总线的影子"）：

| 位置 | 为什么 |
|---|---|
| `rx_d1`/`rx_d2`（`rx_bit` 打两拍）与 `line_s` 采样寄存器 | 它们是线电平的影子、不承载协议状态。硬塞一个 J 进去，复位撤掉那一拍反而假造一次跳变（`d_bit=0`），在 `USB_IDLE` 里误起一次 SYNC 搜索 |
| ref_clk 域 EOP FSM | 帧机被打回 `USB_IDLE` 后 `in_frame=0`，EOP FSM 下一拍自动回待命，不需要单独复位 |

📎 [打开波形图：usb_rst@DATA 强退与 line_s 不受扰动（deserial_usb_rst_e6.png）](../fig/deserial_usb_rst_e6.png)

> 图 2.6b 软复位场景（`deserial_err_eop` E6，33.72–34.06µs，线静止在 J）：`usb_rst` 高一个 `clk12m`
> 周期（与 clk12m 同宽的 1 拍），`rx_abort`/`tx_active` 全程 0，唯一让 `frame_clr` 拉高的就是它；
> 下一个 `clk12m` 沿 st_stat_cur 2'h2→2'h0、`rx_active` 1→0（`rx_error` 保持 0）；`dut_line_s` 全程
> 2'b10 不变（复位没碰线采样寄存器），`close_cnt` 10→11 = 本帧被关上（只吐了 PID 一个字节）。

📎 [打开波形图：usb_rst@SE0（总线复位场景）无幽灵帧（deserial_usb_rst_e7.png）](../fig/deserial_usb_rst_e7.png)

> 图 2.6c 总线复位场景（`deserial_err_eop` E7，39.08–39.44µs）：帧开着（`in_frame`=1、st=2'h2）时线
> 转 SE0（`dut_line_s`=2'b00），`usb_rst` 一个 `clk12m` 周期 → `frame_clr` → st 2'h2→2'h0、
> `rx_active`/`in_frame` 同拍落 0；ref 域的 `eop_stat_cur` 3'h3→3'h0 是 `~in_frame` 自动回待命，不是
> `usb_rst` 清它。之后线回 J，st 从 2'h1 重新搜 SYNC 收下一个正常包，`rx_error` 恒 0（复位不置错）。

### 2.7 时钟方案：位→字节在 clk12m（1×），EOP/SE0 在 ref_clk（4×）

本模块横跨两个时钟域，各有分工：

- **位→字节流水线（NRZI 解码 / SYNC / 解填充 / 字节对齐）跑在 `clk12m`（1×）域**。接收时
  `clk12m = dclk`（DPLL 恢复时钟经 `usb_clk_mux` 切换而来），所以流水线**每 bit 一拍**直接消费
  `rx_bit`，**不需要**在 ref_clk 域生成 `bit_ce` 使能。恢复时钟 `dclk` 经 clk_mux 后作为**真实时钟**
  驱动本模块位流水线 + SIE。
- **SE0/EOP 定界跑在 `ref_clk`（4×）域**。SE0 是单端带外信号、与恢复时钟/位流异步，且 EOP 判据需要
  4× 时间分辨率（82ns / 40ns 阈值），所以单独用 ref_clk 监测 `rxdp`/`rxdn`，产出帧尾事件 `eop`（SE0→J
  正常收尾）与 `eop_err`（SE0 后非 J 的 EOP 错），**各展宽跨到 clk12m 域**（`eop_err` 到 clk12m 域置
  `rx_error` 电平并进 `USB_ERROR`，§2.6）。

**为什么位流水线要挪到 clk12m**：旧方案把 `dclk` 只当使能（ref_clk 域内 `bit_ce`），SIE 跑在固定本地
时钟上，需要额外跨域握手对齐数据；新方案（Intel 白皮书 §1/§3.6/§8）让位流水线 + SIE 都直接跑在恢复
时钟 `clk12m` 上，**PHY↔SIE 是同步派生时钟交接，无需异步 CDC**（详见 [phy_design.md](phy_design.md) §2.3）。

**`clk12m` 与 `rx_bit` 的相位关系（关键）**：`dclk` 是 CDR `state[1]` 打一拍的**寄存器输出**（延迟
1 ref_clk），而 `rx_bit` 是 `state[2]` 的**组合输出**（无延迟），两者**相差 1 个 ref_clk**——`rx_bit`
领先 `dclk` 一拍。位流水线在 `clk12m`（= `dclk`）上升沿采样 `rx_bit`，此时 `rx_bit` 已稳定（领先 1 拍），
电平仍处于该 bit 的**稳定窗口**内（NRZI 电平保持 4 ref_clk 不变），采样值正确：

```
                 bit 边界            bit 边界
ref_clk      ──┬──┬──┬──┬──┬──┬──┬──┬──┬──
rx_bit ────────J──────────────K──────   (state[2] 组合, 无延迟)
dclk/clk12m ______┌──────────┐_______  (state[1] 打一拍, 落后 1 ref_clk)
采样@clk12m↑       ↑          ↑          (每 bit 采样一拍)
```

这个相位关系已被 `case_loopback` 端到端验证（122 数据位 0 差异），实现时**严格复刻、不得挪位**（详见 §4.2）。

**EOP 事件从 ref_clk 跨到 clk12m（plan B 展宽）**：`eop` 与 `eop_err` 都是 ref_clk 域的一拍脉冲（20.8ns），
clk12m（12MHz，83.3ns 周期）可能采不到，所以先各自**展宽到 ≥1 个 clk12m 周期**再跨域
（`eop`→`eop_w`→`eop_sync`、`eop_err`→`eop_err_w`→`eop_err_sync`），保证 clk12m 域不漏检：`eop_sync`
驱动正常关包/坏帧帧尾释放，`eop_err_sync` 置 `rx_error` 电平 + 进 `USB_ERROR`（详见 §4.6 /
`intel_sie_whitepaper_notes.md` §5.5）。

全模块两个时钟（`clk12m` + `ref_clk`），无 `#`/`initial`/`$display`，可综合。

---

## 3. 模块信号列表

### 3.1 端口信号（对外接口）

| 端口 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| **时钟 / 复位** ||||
| `clk12m` | in | 1 | 位流水线主时钟 12MHz（接收时 = `dclk` 经 `usb_clk_mux` 切换，上升沿=采样点）；NRZI 解码/状态机/移位共用 |
| `ref_clk` | in | 1 | 48MHz 参考时钟（SE0/EOP 定界域，需 4× 分辨率看单端沿） |
| `ref_rstn` | in | 1 | 异步复位，低有效（复位回 IDLE J，清所有计数） |
| `usb_rst` | in | 1 | core 复位，同步高有效、宽 1 个 `clk12m` 周期（外面并好总线复位/软复位并整形）：帧机与位流水线当拍回 `USB_IDLE`，不置 `rx_error`（§2.6） |
| **位级输入（来自 PHY）** ||||
| `rx_bit` | in | 1 | NRZI 数据电平（CDR `state[2]` 组合输出，0=K/1=J），领先 `dclk` 1 ref_clk |
| `rxdp` | in | 1 | D+ 单端（SE0/EOP 检测用，ref_clk 域采样） |
| `rxdn` | in | 1 | D- 单端（SE0/EOP 检测用，ref_clk 域采样） |
| **控制输入** ||||
| `tx_active` | in | 1 | 本设备正在发送（SIE 事务逻辑 TX 路径产生，`tx_serial` 仅执行），高时关数据通路防自收发幽灵包 |
| `rx_abort` | in | 1 | SIE 溢出中止（SIE 事务逻辑检测到当前包字节数超该包类型/端点最大负载时拉高），deserial 收到立即回 `USB_IDLE`、丢包（clk12m 域同步） |
| **字节级输出（PHY↔SIE 边界，clk12m 域）** ||||
| `rx_data` | out | 8 | 恢复的接收字节（LSb 对齐，**维持满 667ns 字节周期**） |
| `rx_valid` | out | 1 | 每字节一拍脉冲 = 字节有效标记（UTMI `RXValid` 模型；SIE 同域在该脉冲拍锁存 `rx_data`） |
| `rx_active` | out | 1 | 收包帧中（`st_stat_cur` 组合解码 = `(st_stat_cur==USB_DATA)||(st_stat_cur==USB_ERROR)`：SYNC 命中→`USB_DATA` 拉高，物理错误进 `USB_ERROR` **保持 1**，包结束/释放→回 `USB_IDLE` 拉低；**下降沿 = 包结束**，UTMI `RXActive` 模型，**无 `rx_last`**） |
| `rx_error` | out | 1 | 接收错误（位填充违规 / EOP 错），**电平**：检错置起、`USB_ERROR` 期保持、关包（回 `USB_IDLE`）后**晚一拍清 0**（SIE 于下降沿采样，§2.6） |
| `line_state` | out | 2 | 单端电平 `{rxdp,rxdn}`（透传，供 SIE） |
| `line_s` | out | 2 | 同一对电平的 `ref_clk` 域采样（DFF 直出），供 `usb_bus_state`（§2.6） |

### 3.2 端口信号详细说明（来源 / 语义 / 时序 / 消费方）

| 端口 | 来源 | 语义与有效条件 | 消费方 |
|------|------|----------------|--------|
| `clk12m` | `usb_clk_mux`（PHY） | 每 bit 一拍；上升沿采样 `rx_bit`（后者领先 1 ref_clk，处稳定窗口，见 §2.7） | 本模块全部位流水线逻辑 |
| `ref_clk` | 系统主时钟 | 独立于位流，监测 `rxdp`/`rxdn` 单端沿；EOP 判据 82ns/40ns 阈值需 4× 分辨率 | 本模块 EOP/SE0 状态机 |
| `ref_rstn` | 系统复位 | 异步低有效，任意时刻复位回 `USB_IDLE`（总线电平回 J） | 本模块全部寄存器 |
| `usb_rst` | 顶层（总线复位 ∪ 软复位，并好后整形） | 同步高有效、**恰 1 个 `clk12m` 周期**的脉冲；=1 时本模块当拍回 `USB_IDLE`（帧机 + 位流水线），**不置 `rx_error`**；`line_s` 采样与 ref_clk 域 EOP FSM 不受它影响（§2.6 两根复位分工） | 本模块：回 `USB_IDLE`（§2.6 释放条件 6） |
| `rx_bit` | `usb_rx_cdr`（PHY） | 0=K/1=J；组合输出、无寄存器延迟 | 本模块 NRZI 解码（§2.2/§4.2） |
| `rxdp`/`rxdn` | 模拟 PHY 单端 | 仅用于判 `line_state==2'b00`（SE0）；与位流异步 | 本模块 EOP 检测（§2.6/§4.6） |
| `tx_active` | SIE 事务逻辑 TX 路径 | 发 SYNC 拉高、发完 EOP 拉低；=1 时本模块回 IDLE、不吐字节 | 本模块自收发门控（§4.9） |
| `rx_abort` | SIE 事务逻辑（clk12m 域） | 当前包字节数超该包类型/端点最大负载时拉高；=1 时本模块立即回 `USB_IDLE`（`rx_active`↓、丢包），**不置 `rx_error`**（溢出原因 SIE 自知，`rx_error` 电平只留给物理层错误） | 本模块：回 `USB_IDLE`（§2.6 释放条件 4） |
| `rx_data[7:0]` | 本模块（字节对齐） | 满 667ns 字节周期稳定；LSb 对齐；每字节在 `byte_rdy` 时更新 | SIE 事务逻辑：clk12m 同域采样（§4.8） |
| `rx_valid` | 本模块 | 每收满一字节产生 1 拍脉冲（与 `byte_rdy` 同拍，此时 `rx_data` 已更新稳定）；**仅字节有效标记**（clk12m 域，直交 SIE） | SIE 事务逻辑：clk12m 同域在 `rx_valid` 脉冲拍锁存 `rx_data`；数脉冲定位各字节（`rx_active`↑ 后第 1 个脉冲的字节 = PID）（§4.8） |
| `rx_active` | 本模块（帧态机 `st_stat_cur` 解码） | 组合解码 `(st_stat_cur==USB_DATA)||(st_stat_cur==USB_ERROR)`：SYNC 命中进 `USB_DATA` 拉高、物理错误进 `USB_ERROR` **保持 1**、包结束（EOP/中止）回 `USB_IDLE` 拉低；**下降沿 = 包结束**（无 `rx_last`，SIE 收包完成判定靠它） | SIE 事务逻辑：收包完成判定；本模块内部回环门控 SYNC 检测与 EOP FSM（帧唯一表征 = `st_stat_cur`） |
| `rx_error` | 本模块 | **电平（非脉冲）**：物理层检错（位填充违规 / EOP 错）当拍**置起**（进 `USB_ERROR` 保持），直到关包（回 `USB_IDLE`）**晚一拍清 0**（见 §2.6 清除时序）；不代表 CRC 错 | SIE 事务逻辑：帧开（`rx_active=1`）期间可读"此包已坏"；以 `rx_active` 下降沿为包结束标记、沿后采样 `rx_error`，=1 判坏包按不应答处理（§2.6/§4.7） |
| `line_state[1:0]` | 本模块（`{rxdp,rxdn}` 透传） | 随线电平实时变化，不受 `tx_active` 影响 | SIE（上层复位/挂起检测） |
| `line_s[1:0]` | 本模块（`ref_clk` 域采样寄存器） | 同一个电平打一拍；本模块内部判 SE0/J 用的就是它 | PHY 总线状态检测 `usb_bus_state` 直接吃这一份（§2.6） |

### 3.3 内部关键信号

| 信号 | 时钟域 | 类型 | 位宽 | 说明 |
|------|--------|------|------|------|
| `nrzi_prev` | clk12m | reg | 1 | 上一拍 NRZI 电平（解码用） |
| `bit` | clk12m | wire | 1 | NRZI 解码出的原始数据 bit（含填充） |
| `st_stat_cur` | clk12m | reg | 2 | 收包帧状态（USB_IDLE/USB_SYNC_SEEK/USB_DATA/USB_ERROR）；`rx_active` 即帧中有效信号 `(st_stat_cur==USB_DATA)||(st_stat_cur==USB_ERROR)`，组合解码（见 §2.3），帧标志不另设寄存器 |
| `zero_cnt` | clk12m | reg | 3 | SYNC 连续 0 计数（仅 `USB_SYNC_SEEK` 更新，`USB_IDLE`/`USB_DATA`/`USB_ERROR` 保持 0；命中/假触发/0 过多回 IDLE 清 0） |
| `ones_cnt` | clk12m | reg | 3 | 解填充连续 1 计数，**窗口 = `rx_active`（`USB_DATA`/`USB_ERROR`）**，帧外（含 `USB_SYNC_SEEK`）保持 0；进 `USB_DATA` 时为 0（从 PID 起算），范围 0~6；进 `USB_ERROR` 清 0 重计当 idle 探针（§2.4/§2.6） |
| `shift_reg` | clk12m | reg | 7 | 字节移位寄存器（LSb 先入；存当前字节已到的低 7 位 b0~b6，第 8 位 b7 只出现在 `bit` 输入、由 `{bit, shift_reg[6:0]}` 拼出整字节，故 7 位即够、省 1 触发器，§2.5；仅 `USB_DATA` + 去填充有效位使能移位，`USB_IDLE`/`USB_SYNC_SEEK`/`USB_ERROR` 停移） |
| `bit_cnt` | clk12m | reg | 3 | 字节内位计数（0~7，仅 `USB_DATA` 对去填充有效位累加；3-bit 加满 7 后 `+1` 自然溢出回绕到 0，`bit_cnt==7` 那拍出 `byte_rdy`） |
| `rx_error` | clk12m | reg | 1 | 接收错误电平（输出同名）：检错置 1（进 `USB_ERROR`）、`USB_ERROR` 期保持、关包回 `USB_IDLE` 后**晚一拍**清 0（§2.6 清除时序） |
| `frame_clr` | clk12m | wire | 1 | 强退本帧 = `tx_active \| rx_abort \| usb_rst`（三条同义：回 `USB_IDLE`、冻结位流水线、都不置 `rx_error`，§2.6） |
| `se0` | ref_clk | wire | 1 | `rxdp==0 && rxdn==0`（SE0 检测） |
| `eop_stat_cur` | ref_clk | reg | 3 | EOP FSM 状态（`eop_idle`/`eop_se0_1/2/3`/`eop_dead`，Fig.7，见 §2.6） |
| `eop_dead` | ref_clk | wire | 1 | 当前在 `eop_dead` 态（SE0 后非 J 的异常收尾，只待一拍） |
| `eop` | ref_clk | reg | 1 | EOP 正常收尾脉冲（`eop_se0_3`/`eop_dead` 见 J 拉，ref_clk 域） |
| `eop_w` | ref_clk | reg | 1 | `eop` 展宽（≥1 clk12m 周期，plan B） |
| `eop_sync` | clk12m | reg | 1 | `eop` 跨到 clk12m 域（正常关包：`USB_DATA` 期→回 IDLE；`USB_ERROR` 期→释放，§2.6） |
| `eop_err` | ref_clk | reg | 1 | EOP 错脉冲（`eop_dead` 见非 J 拉，ref_clk 域） |
| `eop_err_w` | ref_clk | reg | 1 | `eop_err` 展宽（≥1 clk12m 周期，plan B，同 `eop`） |
| `eop_err_sync` | clk12m | reg | 1 | `eop_err` 跨到 clk12m 域（置 `rx_error` + 进 `USB_ERROR`，§2.6） |
| `rx_valid_r` | clk12m | reg | 1 | 字节有效脉冲寄存器（`byte_rdy` 拍产生 1 拍脉冲，驱动 `rx_valid`） |

### 3.4 常量

```verilog
localparam USB_IDLE      = 2'd0;   // 收包帧：空闲（搜索 SYNC 前的 0）
localparam USB_SYNC_SEEK = 2'd1;   // 收包帧：数 0（SYNC 尾巴）
localparam USB_DATA      = 2'd2;   // 收包帧：数据接收（PID 起；rx_active=1 且吐字节）
localparam USB_ERROR     = 2'd3;   // 收包帧：错误保持（rx_active=1 但不吐字节，等总线回 idle 释放，§2.3/§2.6）
localparam SYNC_MIN_ZERO = 4;     // SYNC 尾巴最少 0 个数（容忍 CDR 吃位）
localparam STUFF_MAX_ONE = 6;     // 位填充上限：连续 6 个 1 后插 0
// EOP FSM（Fig.7，ref_clk 域）：eop_se0_3 = 连续 3 拍 SE0（≈62.5ns，40~82ns 判决点）
localparam ST_EOP_IDLE   = 3'd0;  // EOP FSM：空闲（待 SE0）
localparam ST_EOP_SE0_1  = 3'd1;  // EOP FSM：SE0 第 1 拍
localparam ST_EOP_SE0_2  = 3'd2;  // EOP FSM：SE0 第 2 拍
localparam ST_EOP_SE0_3  = 3'd3;  // EOP FSM：SE0 第 3 拍（≈62.5ns，达判决点）
localparam ST_EOP_DEAD   = 3'd4;  // EOP FSM：SE0 后非 J 异常收尾（只待一拍，j 时补判 eop）
```

---

## 4. 关键设计点描述及波形

> RTL 已按本报告落地（`src/phy/usb_rx_deserial.v`，clk12m 域位流水线），各关键点均已仿真验证。
> 下文各节"设计做法"即当前实现；原"待验证现象"除 §4.11 各用例日志判据（逐字节比对 / `rx_error` 电平 /
> 关包次数，可 `make -C sim/deserial run MODE=base|fixed` 复跑佐证）外，**关键点另配波形图**——
> 图由 `sim/deserial` 各 case 的 VCD（`make VCD=1` 生成）经 `tools/render_waveform.py` 离屏截窗渲染，
> 落 `doc/fig/deserial_*.png`，以 📎 超链接给出，图窗范围与所含信号见各图 caption（复跑与改法同验证
> 报告 §2）。图 4.3/4.8 共用 `deserial_sync_byte_out.png` 一张源图、取景一致，互见即同窗。

### 4.1 时钟方案（位流水线 clk12m + EOP ref_clk）

**问题**：SE0/EOP 需要 4× 时间分辨率（82ns/40ns 阈值），必须看 ref_clk 单端沿；但位→字节流水线
若也留在 ref_clk 域用 `bit_ce` 使能，SIE 就跑在固定本地时钟上、要额外跨域握手。

**设计做法**：拆两个域——位流水线（NRZI/SYNC/解填充/字节对齐）直接跑在 `clk12m`（= clk_mux 之后的
`dclk`）1× 域，每 bit 一拍；SE0/EOP 定界跑在 ref_clk 4× 域，产出 `eop` 展宽跨到 clk12m。
**待验证现象**：位流水线各寄存器随 `clk12m` 每 bit 推进一拍，`eop_sync` 在 clk12m 域不漏检。

### 4.2 NRZI 解码与采样对齐（核心时序点）

**问题**：`rx_bit`（CDR `state[2]`，组合输出）与 `dclk`（CDR `state[1]`，寄存器输出）存在
**1 个 ref_clk 的寄存器差**，采样点若错位一位，整串数据全反/全错。

**设计做法**：严格复刻 `case_loopback` 已验证的采样关系——在 `clk12m`（= `dclk`）上升沿采样 `rx_bit`
做 NRZI 解码（`rx_bit` 组合输出领先 `dclk` 寄存器输出 1 拍，相位关系见 §2.7）。
**待验证现象**：端到端还原出的字节流与发送包字节逐字节一致（见 4.10 验证计划）。

### 4.3 SYNC 检测容差（吃位鲁棒性）

**问题**：CDR 相位对齐吃掉 SYNC 开头 1~2 个 0，完整匹配 `00000001` 会漏检。
**设计做法**：只找 SYNC 尾巴 `≥4 个 0 + 1`，且仅在空闲态检测（避免误触发）。**待验证现象**：
首包（吃 2 位）与后续包（吃 1 位）都能正确命中 SYNC、锚定 PID 起点。

> **接受窗口的下界与上界（2026-09-14 补测）**：`SYNC_MIN_ZERO = 4` 是窗口**下界**（0 少于 4 个即 1
> 到达 = 假触发，回 `USB_IDLE`）；窗口**上界**由 `zero_cnt` 数到第 8 个 0 立即回 `USB_IDLE` 给出，
> 即接受窗口 = 判决时本轮计入的连续 0 个数 **∈ [4, 7]**。`case_sync_scan` 把 SYNC 的 7 个 0 换成
> z 个（z=1..11）扫过两侧：**z=1/2/3 → 连跑 1/2/3 拒收；z=4/5/6/7 → 命中且连跑恰为 4/5/6/7；
> z=8 → 第 8 个 0 拒收**。即两个边界都正好落在设计值上（不是"够宽就行"的模糊容忍）。判据用 tb
> 实测的解码 0 连跑而非发射值（CDR 会吃位），且每次注入首个判决断言"实测连跑 == DUT 计数"，
> 详见 `sim/deserial/README.md` §自检机制 4 与验证报告同步项。

📎 [打开波形图：SYNC 容差 + 字节输出（deserial_sync_byte_out.png）](../fig/deserial_sync_byte_out.png)

> 图 4.3 SYNC 容差与字节流出（`deserial_out_normal`，1.55–3.70µs）：rxdp/rxdn 从 idle J 进入 SYNC、
> dclk（clk12m）、rx_bit；st_stat_cur 走 0→1(SYNC_SEEK)→2(DATA)；zero_cnt 在 SYNC 尾巴数到 ≥4 个 0，
> ones_cnt 帧外保持 0、进 `USB_DATA` 时仍为 0（从 PID 起算，见 §2.4）；rx_active↑ 后第 1 个 `rx_valid` 脉冲字节 = e1(OUT PID)、第 2 = 05，
> `rx_data` 在脉冲间维持满字节——CDR 吃位后仍命中 SYNC 尾巴，字节流锚定正确。

### 4.4 位解填充

**问题**：stuffed 0 不删除会污染字节边界与数据内容。**设计做法**：`ones_cnt` 的窗口 = `rx_active`
（`USB_DATA`/`USB_ERROR`），帧外（`USB_IDLE`/`USB_SYNC_SEEK`）保持 0；窗口内 `bit=1` 自加、`bit=0`
清零，**计数从 PID 起算**（进 `USB_DATA` 时 `ones_cnt=0`，见 §2.4），数到 6 个 1 丢弃下一个 0。
**7 连 1 按态分支**：`USB_DATA` 期 → 位填充违规，置 `rx_error` 电平 + 进 `USB_ERROR`（停吐）；
`USB_ERROR` 期再现 → 总线静默回 J（idle），释放回 `USB_IDLE`（进 `USB_ERROR` 时计数清 0 重计）。
**待验证现象**：含 0x7F（连续 1 触发填充）的数据包去填充后字节内容与发送一致；尤其验证 PID 以
连续 1 开头（OUT=`0x87`、DATA0=`0xC3`）时字节边界不错位。

### 4.5 字节对齐（LSb first）

**问题**：位序颠倒会导致 PID 字节 bit 反。**设计做法**：右移寄存器，首位进 LSB，满 8 拍输出。
**待验证现象**：恢复的 PID 字节等于规范值（如 SETUP=`0x2D`、DATA0=`0xC3`）。

📎 [打开波形图：字节对齐（同源 deserial_sync_byte_out.png）](../fig/deserial_sync_byte_out.png)

> 图 4.5（同图 4.3 取景）：shift_reg 右移逐位进 LSB 组装，`byte_rdy` 满 8 拍打出一字节；前两字节
> = `e1 05`（OUT token），证明位序按 LSb first 还原正确。

### 4.6 EOP 检测与包结束定界（`rx_active`↓ 收尾）

**问题**：包结束边界必须在 SE0 到来时正确判定，且 SE0 与位流不同步；还要容忍主机 SE0 偏短。
**设计做法**：`rxdp`/`rxdn` 直接监测 SE0（与 bit 流独立），用 **Fig.7 5 态 FSM**（`eop_se0_1/2/3`
计时链，判决点 3 拍 ≈62.5ns）产生**帧尾事件**：`eop_se0_3`/`eop_dead` 见 `j` 拉 `eop`（正常/宽容
收尾）、`eop_dead` 见非 J 拉 `eop_err`（EOP 错，见 §2.6）。**关包由 clk12m 帧态机裁决**，EOP FSM 不
直接拉 `rx_active`：`eop` 在 `USB_DATA` 期 → 正常关包回 IDLE、在 `USB_ERROR` 期 → 释放；`eop_err` →
置 `rx_error` 电平 + 进 `USB_ERROR`。**字节流与 EOP 收尾解耦**（UTMI 模型）：每个字节在 `byte_rdy` 时
正常打出（含最后一字节，各伴一个 `rx_valid` 脉冲、内容由 8 个真实 bit 组成，dribble 残缺字节随回 IDLE
丢弃）；关包后 `rx_active` 拉低——**下降沿 = 包结束**，SIE 据此收包，**无 `rx_last`**。
**跨域**：帧尾事件在 ref_clk 域检出，`eop`/`eop_err` 各经 `*_w` 展宽（≥1 clk12m 周期）跨到 clk12m 域
（plan B，见 §2.7），驱动帧态机关包/进 ERROR。
**错误保持（防死锁 + 防幽灵帧）**：帧中 7 连 1 检错当拍**不**关包，先进 `USB_ERROR` 保持
（`rx_active=1`、置 `rx_error` 电平、停吐字节）——错误残余若立刻放开 SYNC 检测会被误判成新包 SYNC。
`USB_ERROR` 的释放 = EOP FSM 拉 `eop`（坏帧仍以 SE0→J 结束）、或 7 连 1 再现（无 EOP 静默回 J，idle
探针）、或 `tx_active`/`usb_rst`/`rx_abort` 强制。`eop_dead` 见非 J 的 EOP 错同理进 `USB_ERROR`，
SE0 已现 = 帧尾将至、保持到总线静默回 J 才释放。三条口都回 `USB_IDLE`，`rx_active` 永不卡死、SYNC
检测器不会停摆（对应白皮书 Fig.7 的 `eop_dead` 双出口 + 帧态机 ERROR 保持，见
`intel_sie_whitepaper_notes.md` §5.6）。
**待验证现象**：每包 `rx_active` 下降沿恰好一次（= 包结束，SIE 收包）；分别注入 2-bit SE0 与 1-bit SE0
两种 EOP，都能正确判定包结束；注入 SE0 后接 K（非 J），FSM 走 `eop_dead` 拉 `eop_err`，帧态机进
`USB_ERROR`，随后总线回 J 静默 → 7 连 1 再现释放：`rx_active`↓，SIE 沿后采样 `rx_error=1` 判坏包
（好坏由关包时 `rx_error` 电平有无区分）。

📎 [打开波形图：干净 EOP 关包（deserial_eop_close.png）](../fig/deserial_eop_close.png)

> 图 4.6a 干净 EOP 定界关包（`deserial_out_normal`，4.00–4.62µs）：ref_clk（4×，EOP 域）、rxdp/rxdn
> 帧尾 SE0→J；eop_stat_cur 计数 SE0 ≥3 拍确认（本例值 1→2→3→回 0，非 J 未走错）、eop_sync 跨到 clk12m 域；
> st_stat_cur 2→0 关包，`rx_active` 下降沿 = 包结束；末字节（58）仍伴 `rx_valid` 脉冲，`rx_error` 全程 0
> = 正常包。

📎 [打开波形图：bad-EOP（SE0→K）探针自愈（deserial_err_selfheal.png）](../fig/deserial_err_selfheal.png)

> 图 4.6b EOP 错自愈（`deserial_err_eop` E1，2.85–4.10µs）：帧尾 SE0 后回 K（非 J）→ eop_stat_cur 走
> 到 `eop_dead` 判定（非 J 出口）拉 `eop_err` → st_stat_cur 2→3(USB_ERROR)、`rx_error` 电平=1（`rx_active`
> 保持 1、停吐字节）；总线静默回 J → 7 连 1 idle 探针 → st_stat_cur 3→0 释放、`rx_error` 晚一拍清 0。
> SIE 在 `rx_active`↓ 沿采样 `rx_error=1` 判坏包（关包 err=1）；其后干净 OUT 仍能正确命中（无幽灵帧，
> 见验证报告 E1）。对应 §2.6「EOP 错」/`eop_dead` 双出口。

### 4.7 错误检测汇总

| 错误 | 检测点 | 动作 |
|------|--------|------|
| 位填充违规（7 连 1，覆盖 J/K/SE0 卡死） | 解填充 | `USB_DATA` 期：置 `rx_error` 电平 + **进 `USB_ERROR` 保持**（`rx_active` 保持 1、停吐）；释放 = 坏帧帧尾 `eop` / 7 连 1 再现（静默 idle 探针） |
| SYNC 非法（0 过多） | SYNC 检测 | 回空闲（不算包，未进 `USB_DATA`，无需清 `rx_active`） |
| EOP 错（SE0 后非 J） | SE0→非J 沿（`eop_err`） | 置 `rx_error` 电平 + **进 `USB_ERROR` 保持**；总线静默回 J → 7 连 1 再现释放（§2.6 必须回到 J） |
| SE0 超长（总线复位） | — | 属 `usb_bus_state`（SE0 ≥2.5µs = 总线复位事件，出 `usb_bus_rst`）；本模块 SE0 计数仅服务 EOP 定界（~160ns 量级），不判复位；卡死期由位填充违规先进 `USB_ERROR` 再释放（7 连 1 兜底，~0.6µs 量级） |
| **无 EOP（连续跳变乱码）** | **SIE 事务层**字节计数超该包类型/端点最大负载 → 拉 `rx_abort` | 仅 `USB_DATA` 期适用（还在吐字节）：deserial 收到回 IDLE、丢包（`rx_active`↓、**不置 `rx_error`**）；进 `USB_ERROR` 后已停吐字节，此兜底不适用，靠 7 连 1 探针 / usb_rst 收口；deserial 内部无定时器 |

> 注：帧中错误统一"先进 `USB_ERROR` 保持、等总线回 idle 才关"的根因是防残余位误判 SYNC（幽灵帧）；
> 极端的"违规后发送方继续合法乱流、无 EOP 且无 7 连 1"属协议外（违规发送方本身已不合法），
> 由 usb_rst（最终 SE0）或上层超时兜底，deserial 不为它设定时器。

📎 [打开波形图：真 7 连 1 检错 + 释放（deserial_stuff_viol_err.png）](../fig/deserial_stuff_viol_err.png)

> 图 4.7 帧中真 7 连 1（`deserial_stuff_viol`，2.95–3.95µs）：rx_bit 在 K 电平连发 7 个 1（线非 SE0，
> EOP 门控不生效），ones_cnt 逐位爬升后越限 → st_stat_cur 2→3(USB_ERROR)：`rx_error` 电平=1、`rx_active`
> 保持 1、停吐（e1 fc 两字节后再无 `rx_valid`）；坏帧 EOP 收尾 → st_stat_cur 3→0 释放、`rx_error` 晚一拍
> 清 0；关包沿采 err=1 判坏包（`case_stuff_viol` 判据，见验证报告）。

### 4.8 字节输出（clk12m 域直交 SIE）：`rx_data` 维持 + `rx_valid` 每字节脉冲（UTMI `RXValid`）

**问题**：解填充使位边界不规则，SIE 事务逻辑**无法自己数出字节边界**，必须有 deserial 提供的
"字节有效"信号才能定位每个字节、划出 PID/CRC 区。

**设计做法**：deserial 的全部字节级输出都是 **clk12m 1× 域同步信号，直交同域 SIE 事务逻辑**，
**不涉及任何跨域设计**。把 `rx_data` 在寄存器里**维持满一字节周期（667ns = 8 × clk12m）**——字节率
1.5MHz、下一字节 8 bit 后才到，维持是天然发生的，SIE 同域采样时数据始终稳定；并输出 `rx_valid`
**每字节一拍脉冲**（在 `byte_rdy` 拍随 `rx_data` 更新同步产生，UTMI `RXValid` 模型）。SIE 事务逻辑
在 clk12m 域于 `rx_valid` 脉冲拍**直接锁存** `rx_data`（同域，无握手、无边沿检测开销），并数脉冲
定位各字节——`rx_active`↑ 后第 1 个 `rx_valid` 脉冲的字节即 **PID**（SIE 自数，deserial 不另做包首
标记）。**`rx_error` 是电平（非脉冲）**：检错置起、`USB_ERROR` 期保持、关包后晚一拍清 0（§2.6）；
**`rx_active`** 是**帧信号**（UTMI `RXActive` 模型）：SYNC 命中拉高、物理错误进 `USB_ERROR` **保持 1**、
包结束拉低，整个包期间保持 1，**不随字节周期翻动**，SIE 靠它的**下降沿**收尾——坏包在关包沿
`rx_error` 仍为 1（晚一拍才清，§2.6），正常包为 0（见 §2.6/§4.6，**无 `rx_last`**）。

**注意（两个易混点）**：
- **本模块输出不带 CDC 语义**：字节交给 SIE 即完成职责。SIE 要不要把字节跨到 pclk/FIFO、怎么跨
  （`usb_sie_cdc` 四相握手，见 [03_usb_sie_cdc_design.md](../03_usb_sie_cdc_design.md)），是 SIE
  拿到字节后的内部处理，**不反向约束本模块的输出时序**；早先"rx_toggle 维持 667ns 供 CDC 跨域"的
  旧方案**已作废**；
- `rx_valid` **≠ data toggle（DATA0/DATA1 交替）**。本模块只做"每字节一拍脉冲"的物理动作，
  **不解析 PID、不维护 DATA0/DATA1 的 toggle 序列**——那是 SIE 事务层的职责：事务逻辑识别到
  DATA0/DATA1 的 PID 后，按"接收/发送序列 + 成功握手"规则自行更新 toggle。`rx_valid` 与协议层
  toggle 无任何关系。
- `rx_error` **是电平、非脉冲**：物理层检错（位填充违规 / EOP 错）当拍**置起**、进 `USB_ERROR` 保持、
  关包（回 `USB_IDLE`）后**晚一拍清 0**（§2.6 清除时序）——SIE 在帧开期间即可读到"此包已坏"，关包沿后
  采样仍为 1 判坏包。它**不代表 CRC 错**——CRC 由 SIE 事务层对收到的字节自行校验，不在本模块判；
  `rx_abort` 溢出路径**不置** `rx_error`（也关包拉低 `rx_active`，但属"正常被中止"，§4.7）。

**待验证现象**：`rx_valid` 每字节恰一脉冲（频率 = 字节率 = 1.5MHz，宽 1 拍 clk12m）；`rx_data` 在两次
脉冲之间保持稳定。

📎 [打开波形图：字节输出脉冲（同源 deserial_sync_byte_out.png）](../fig/deserial_sync_byte_out.png)

> 图 4.8（同图 4.3 取景）：`rx_valid` 每字节恰一脉冲（e1 / 05 两拍、宽 1 拍 clk12m），`rx_data` 在脉冲
> 间维持满字节不变（1.5MHz 字节率，下一字节 8 bit 后才到）——UTMI `RXValid` 模型，SIE 同域在脉冲拍
> 直接锁存。

### 4.9 `tx_active` 自收发门控

**问题**：USB 半双工 + 共享 D+/D- 线，设备发送时自己的接收器也"听到"自己发的信号（CDR 照常跟踪
边沿），deserial 会误判 SYNC 命中、把自发的字节当主机数据推给 SIE（**幽灵包**）。

**设计做法**：加 `tx_active` 输入（由 SIE 事务逻辑在 TX 路径产生，从发 SYNC 拉高、到发完 EOP 拉低；
`usb_tx_serial` 只是执行者）。`tx_active=1` 时强制 deserial 回 `USB_IDLE`：清 `zero_cnt/ones_cnt/bit_cnt/shift_reg`，
不做 SYNC 检测、不吐任何字节（不产生 `rx_valid` 脉冲）。`line_state` 照常输出（复位/挂起/SE0 检测不受影响）。

**为什么安全**：USB 半双工——设备发送期间主机一定没在发，关掉 RX 不漏任何主机数据。

**待验证现象**：设备发 ACK/NAK/DATA 期间 deserial 不产生任何字节；发送结束后恢复接收主机下一包。

### 4.10 验证计划（实现后）

复用 CDR 验证已有的 **端到端回环 + `exp_tx_q` 记录机制**，把比较粒度从"位"升级到"字节"：

| 验证点 | 方法 | 判据 |
|--------|------|------|
| 字节对齐 | 发送 SETUP/DATA0/ACK 包 | `rx_data` 逐字节 = 发送 PID/ADDR/ENDP/CRC/数据 |
| 位解填充 | DATA0 载荷含 0x7F + PID 连续 1 开头 | 去填充后字节 = 原始字节，边界不错位 |
| SYNC 容差 | 首包 + 多包 | 每个包均命中 SYNC，`rx_active`↑ 后第 1 个 `rx_valid` 脉冲的字节 = PID |
| SYNC 窗口**边界** | SYNC 的 0 个数 z=1..11 扫描（0 少 / 窗口内 / 0 多） | 判决 ⟺ 实测解码 0 连跑 ∈ [4,7]：z≤3 拒收且不开包、z=4..7 命中、z≥8 拒收；越界注入后仍能正常收包（无卡死/幽灵帧） |
| 字节脉冲 | 任意包 | `rx_valid` 每字节恰一脉冲（包内脉冲数 = 去填充后字节数） |
| EOP 宽度（放宽） | 2-bit SE0 + J 与 1-bit SE0 + J | 两种都判 EOP，每包 `rx_active` 下降沿恰一次（包结束收尾） |
| SE0 毛刺拒绝 | <0.5 bit（<2 ref_clk）SE0 毛刺 | 不判 EOP，`rx_active` 不误拉低 |
| EOP J 收尾 | SE0 后接 K（非 J） | 不拉 `eop`（规范要求 se0→j 沿）、拉 `eop_err` → 进 `USB_ERROR`（见下"EOP 错"） |
| dribble 位 | 包尾插入 1 个伪 bit 再 SE0 | 残缺字节不产生 `byte_rdy`，随回 `USB_IDLE` 丢弃；最后一字节内容正确 |
| 自收发门控 | 设备发 ACK/NAK 期间 | deserial 不吐字节，无幽灵包 |
| 帧中错误（7 连 1 保持+释放） | 数据中注入 7 连 1 | 进 `USB_ERROR`：`rx_error` 电平=1、`rx_active` **保持 1**、停吐字节；坏帧仍以 SE0→J 收尾 → `eop` 释放（`rx_active`↓、`rx_error` 晚一拍清 0），SIE 沿后采样判坏包 |
| 静默 idle（无 EOP）释放 | 7 连 1 后总线直接静默回 J、无 EOP | 不卡死：连续 1 数满 7 → 7 连 1 再现 → 释放回 `USB_IDLE`（无定时器）；随后能命中下一正常包 SYNC（无幽灵帧） |
| EOP 错（SE0 无 J 收尾） | SE0 后持续 K | `eop_err` → 进 `USB_ERROR`，总线静默回 J → 释放，`rx_error` 电平在 `USB_ERROR` 期保持、关包晚一拍清 |
| 无 EOP 乱码（SIE 溢出兜底） | 注入持续跳变、无 SE0 的乱码（仍处 `USB_DATA`、在吐字节），字节数超 SIE 上限 | SIE 拉 `rx_abort`，deserial 回 IDLE、丢包、`rx_error` 保持 0；随后能命中下一个正常包的 SYNC |
| core 复位 `usb_rst` | 帧开着（`USB_DATA` / 长 SE0 / `USB_ERROR`）时给 1 个 `clk12m` 周期的 `usb_rst` | 当拍回 `USB_IDLE`、`rx_active`↓、**不置 `rx_error`**；`line_s` 采样与 ref 域 EOP FSM 不被它碰；总线回 J 后无幽灵帧 |

### 4.11 实现后回归：11 用例 × base/fixed 双模式全过

> 本节为简表；方法、逐用例实测摘录、交叉旁证与结论见独立验证报告
> [rx_deserial_verification.md](rx_deserial_verification.md)（2026-09-07 已按「因→变→果 + 前窗/后窗 +
> 量化判据」三段式改写；波形图与本报告 §4.3/4.6/4.7/4.8 同源，复用各 case VCD）。

RTL 落地后建 `sim/deserial` 11 用例。`MODE=base`（定稿模块裸编）与 `MODE=fixed`
（定稿模块 + `-DTAIL_EXP_CLEAN -DCONFORM_EXP_CLEAN` 严格断言）**均 11/11 PASS**；编译零 error / 零
warning（含 `VCD=1` 波形配置，`-Wall`）；合并日志无 FAIL/timeout/assert 残留。每用例落下一日志
`sim_<case>.log`，可 `make -C sim/deserial MODE=base run` 复跑。

| 用例 | 内容 | 覆盖 §4.10 验证点 | 关键判据结果 |
|---|---|---|---|
| `case_out_normal` | OUT token `e1 05 58`，nbyte=3 | 字节对齐 / 字节脉冲 | 逐字节 = `e1 05 58`，err=0 |
| `case_tail_scan` | EOP 尾假连续 1 扫描 R=3..6 + 真 EOP | EOP 宽度（放宽）/ EOP 假 7 连 1 修复 | `fixed`（`TAIL_EXP_CLEAN`）断言 R=3..6 全 err=0 PASS |
| `case_stuff_viol` | 数据中**真** 7 连 1（违例） | 帧中错误（7 连 1 保持+释放） | err=1、`rx_active` 保持、停吐；坏帧 EOP 后干净释放 |
| `case_se0_stuck` | SE0 卡死 ~3.5µs（测量用） | 长 SE0 / 毛刺 | 不误关包、err=0，SE0→J 干净释放 |
| `case_conformant_scan` | 合规包扫描 256×1B + 400×8B | 字节对齐 / 解填充 / 多包 SYNC | `fixed` 严格断言（`CONFORM_EXP_CLEAN`）全清 0，无幽灵关包 |
| `case_byte_exact` | 逐字节 oracle（`chk_byte`/`chk_frame`） | 全链路字节保真 | 每帧 got==exp |
| `case_tail7` | 尾 7 连 1 边界 A–D 扫描 | EOP J 收尾 | 边界符合（真 EOP 收尾不误判） |
| `case_pkt_all` | **全部 USB1.1 FS 包类型**逐字节：IN / SETUP / SOF(0x3FF) / ACK / NAK / STALL / PRE / NYET / 坏 PID / 坏 CRC5 / 坏 CRC16 | 字节对齐（全类型）/ 坏包透明 | 全 got==exp、err=0；坏 PID/CRC **只恢复字节不检错**（属 SIE 层职责，deserial 必须透明） |
| `case_err_eop` | 异常释放 E1–E8：坏 EOP(SE0→K) / 截断无 EOP / `rx_abort`@DATA / `rx_abort`@ERROR / `tx_active`@DATA / `usb_rst`@DATA(J) / `usb_rst`@SE0 / `usb_rst`@ERROR | EOP 错 / 静默 idle / 溢出中止 / 自收发门控 / core 复位 | 各回 `USB_IDLE` 且 `rx_error` 复位时机正确（`usb_rst` 三条不置错）；随后均能收下一正常包（无幽灵帧）；E6 另验 `usb_rst` 期间 `line_s` 采样不被扰动 |
| `case_sync_scan` | SYNC 接受窗口扫描：SYNC 的 7 个 0 换成 z 个（z=1..11），0 少 / 窗口内 / 0 多三段 | SYNC 容差（窗口**边界**） | z=1/2/3 拒收、z=4..7 命中且连跑恰为 4/5/6/7、z=8 第 8 个 0 拒收；首发判决 run==cnt；越界带无幽灵帧；命中后 token 仍解对 |
| `case_eop_glitch` | 帧内亚判决点 SE0 毛刺：1/2 拍、`SE0×3+K×1+J` | EOP 判决点下界 / 毛刺拒绝 | 1/2 拍不关包且无 `eop`；3 拍+K 的宽容收尾 err=0 |

**`rx_error` 释放实现注**：§2.6 计划以 `was_frame`/`frame_just_closed` 记"上一拍在帧内"的关包沿来清；
实现时按用户意见**简化 = 直接判 `st_stat_cur==USB_IDLE`**（帧机回 idle 即清，无额外标志寄存器）。外部时序不变——
`rx_error` 仍保持到关包后第 1 个 `USB_IDLE` 周期末（相对 `rx_active`↓ 恰"晚一拍"），SIE 沿关包沿采样仍读到 1，
§2.6 采样契约保持。`case_err_eop` E4 专项验证：`rx_abort` 于 `USB_ERROR` 期拉出 → 回 IDLE 当拍即清。

---

*上游源码：`src/phy/usb_rx_cdr.v`（已验证）+ `src/phy/usb_clk_mux.v`（待实现）；本模块源码：`src/phy/usb_rx_deserial.v`（**已按本报告重写为 clk12m 域并仿真通过**，见 §4.11）。*
