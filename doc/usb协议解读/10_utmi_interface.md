# UTMI / UTMI+ / ULPI 接口解读（学习笔记）

> 本文是**学习文档**，不是设计定稿。目的：把 USB 2.0 时代引入的 **PHY↔Link（SIE）标准接口**讲清楚，
> 并与我们项目「USB 1.1 FS-only、数字收发器直接采 DP/DN」的现状做对照，为将来可能的 USB2.0 高速扩展打底。
>
> 我们的架构决策是 **UTMI 延后**（见 `PROGRESS.md` §3）：本项目暂不需要。但它的**接口思想**（
> 谁做串行编解码、谁做 CDR、字节流怎么握手）与我们的设计直接相关，读它有四个收获：
>
> 1. 看透 **TXValid/TXReady 握手** —— 我们 SIE↔tx_serial 的握手就是它的简化版；
> 2. 看透 **LineState 是什么** —— 它就是 {D+,D-} 单端电平打包，我们的 `rxdp/rxdn` 更底层；
> 3. 看透 **"谁做 NRZI/位填充"的两种切分** —— UTMI 把它切进 PHY，我们切进 SIE；
> 4. 为将来做 HS（480Mbps）扫清概念障碍 —— 那时模拟 PHY 逃不掉，UTMI/ULPI 是必经之路。

---

## 0. 一句话概括

> **UTMI**（USB 2.0 Transceiver Macrocell Interface）是 Intel 在 USB 2.0 时代提出的、**PHY 与 Link/SIE 之间**
> 的标准**并行数字接口**：用一组定义好的信号，把"USB 总线上的差分 NRZI 位流"和"Link 侧的并行字节流"
> 互相转换。UTMI 只支持**设备**；**UTMI+** 加上主机/OTG 能力并分级；**ULPI** 是它的低引脚版本。

---

## 1. 为什么会有 UTMI —— 它解决什么问题

### 1.1 USB 2.0 高速带来的工程难题

USB 1.1 只有 **Full-Speed（12Mbps）/ Low-Speed（1.5Mbps）**，数字逻辑直接在 48MHz 采样 D+/D- 就能做
收发（我们项目就是这么干的）。但 USB 2.0 引入 **High-Speed（480Mbps）**：

- 480Mbps 的 NRZI 差分信号对**模拟收发器**要求很高（压摆率、终端匹配、共模处理），必须用专用模拟 PHY；
- 模拟 PHY 通常和数字 SoC **不在同一颗芯片**（或分属不同工艺），需要把接口引出来；
- 如果每个厂商都自定一套 PHY↔SIE 接口，SoC 就无法搭配不同厂家的 PHY。

### 1.2 UTMI 的答案：标准化一条"数字切口"

UTMI 规定：**模拟部分（收发器 + 高速 CDR + 串并转换）封成一个 PHY 宏单元（Transceiver Macrocell）**，
对外只暴露一组**数字信号**；Link（SIE）通过这组信号读写字节流，完全不碰模拟细节。

```
        ┌──────────────┐   UTMI（并行数字信号）  ┌─────────────────┐
        │  Link / SIE  │ ◄═════════════════════► │  USB Transceiver │◄──► D+ / D-
        │ (字节流/协议) │      DataIn/DataOut,    │  Macrocell (PHY) │     差分线
        └──────────────┘   TXValid/TXReady, ...   └─────────────────┘
              ↑                                        ↑
           我们项目的 SIE                            我们项目的 PHY(CDR+时钟) +
                                                       模拟 PHY(DP/DN 单端)
```

**关键切分**：UTMI 把 **NRZI 编解码、位填充、SYNC/EOP 生成、CDR** 全部装进 PHY；
Link 只管"给我字节 / 收字节"。**我们的项目正好相反**：把 NRZI/解填充/SYNC/字节对齐装进 SIE，
PHY 只留 CDR + 时钟切换。这是同一问题的两种切分（详见 §8 对照）。

---

## 2. 时钟与数据率（先记住这张表）

UTMI 的时钟是 **PHY 提供的**（从 480MHz 参考振荡器分频得到），Link 完全跑在 PHY 给的时钟上。

| 速率 | 数据率 | 8-bit 模式时钟 | 16-bit 模式时钟 | 每时钟传 | 用途 |
|------|--------|----------------|-----------------|----------|------|
| High-Speed | 480 Mbps | 60 MHz | 30 MHz | 1 字节 / 2 字节 | USB 2.0 高速 |
| Full-Speed | 12 Mbps | 48 MHz | 24 MHz | 1 字节 / 2 字节 | USB 1.1 全速 |
| Low-Speed | 1.5 Mbps | 6 MHz | 3 MHz | 1 字节 / 2 字节 | USB 1.1 低速 |

> 8-bit 模式：每个时钟沿搬 1 字节。HS 480Mbps ÷ 8 = 60MHz。这是"每字节一拍"的流水线，和我们的
> `clk12m` 1× 逐字节吞吐的节奏**一致**。

---

## 3. UTMI 信号全集

> 方向均以 **Link（SIE）视角** 为准：**Input = Link 给 PHY 的输入**，**Output = PHY 送给 Link 的输出**。
> ⚠️ **最反直觉的一点**：`DataOut` 是**接收**数据（PHY→Link），`DataIn` 是**发送**数据（Link→PHY）。
> 命名是从 PHY 的视角取的（PHY 输出的数据 = DataOut），别搞反。

### 3.1 数据总线

| 信号 | 方向 | 宽度 | 含义 |
|------|------|------|------|
| `DataIn` | Input（Link→PHY） | 8/16 bit | 发送数据总线（LSb 先出） |
| `DataOut` | Output（PHY→Link） | 8/16 bit | 接收数据总线 |

### 3.2 发送控制（这套握手和我们 SIE↔tx_serial 几乎一样）

| 信号 | 方向 | 含义 |
|------|------|------|
| `TXValid` | Input | 拉高 = DataIn 上有有效发送数据；**PHY 见 TXValid 拉高即自动发 SYNC**；**拉低即自动发 EOP** |
| `TXReady` | Output | PHY 把当前字节已锁进发送寄存器、可以收下一字节。TXValid=1 且 TXReady=0 时，Link **必须保持 DataIn 不变** |

**发送时序（每拍 1 字节）**：

```
clk      __|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__
TXValid  ______________|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|____
TXReady  ______________|‾‾‾|__|‾‾‾|__|‾‾‾|__|________
DataIn   -------------[  B0  ][  B1  ][  B2  ]---------
                       ↑↑↑   ↑↑↑   ↑↑↑      ↑
                       只有 TXValid&TXReady 同时为 1 时 PHY 才取走数据
```

- TXValid 从 0→1：PHY 开始发 **SYNC**（自动，Link 不用管）；
- 传输中：每个 clk 上升沿，TXValid&TXReady 同时为 1 → 取走一字节；
- TXValid 从 1→0：PHY 发 **EOP**（自动）；
- 控制信号（`XcvrSelect/TermSelect/OpMode`）**不得在 TXValid 跳变沿附近改变**（时序要求）。

### 3.3 接收控制

| 信号 | 方向 | 含义 |
|------|------|------|
| `RXValid` | Output | DataOut 上的字节有效（每字节有效一拍） |
| `RXActive` | Output | 检测到包开始（SOP），整个包期间保持 1，包结束拉 0 |
| `RXError` | Output | 接收出错（SOP 错误 / 位填充违规 / 无 squelch 等） |

**接收语义**：`RXActive` 拉高表示"进包了"，之后每个 `RXValid` 一个字节；`RXError` 在本包内报告错误。
（对应我们 deserial 的 `rx_active` / `rx_valid` / `rx_error`，语义一一对应。）

### 3.4 PHY 配置与状态（UTMI 的核心控制面）

| 信号 | 方向 | 宽度 | 含义 |
|------|------|------|------|
| `XcvrSelect` | Input | 1 | 选收发器：0=HS，1=FS（高速收发器或全速收发器） |
| `TermSelect` | Input | 1 | 选终端：0=HS 终端电阻，1=FS 终端电阻（顺带切换 D+ 上拉） |
| `OpMode[1:0]` | Input | 2 | 工作模式（见下表） |
| `LineState[1:0]` | Output | 2 | D+/D- 单端电平状态（Link 用它做复位/挂起/chirp 检测） |

**`OpMode[1:0]` 编码**：

| OpMode | 含义 | 典型用途 |
|--------|------|----------|
| `00` | 正常收发 | 数据收发 |
| `01` | Non-driving（不驱动总线） | 接收模式 / 三态 |
| `10` | 禁用位填充 + NRZI 编码 | **chirp 序列**（HS 握手要裸发 K 态，不做 NRZI） |
| `11` | 保留 | — |

**`LineState[1:0]` = {D+, D-} 单端电平**：

| LineState | D+ | D- | 含义 |
|-----------|----|----|------|
| `00` | 0 | 0 | **SE0**（复位 / EOP） |
| `01` | 0 | 1 | **K 态**（chirp、EOP 尾） |
| `10` | 1 | 0 | **J 态**（空闲、数据） |
| `11` | 1 | 1 | SE1（非法，不允许出现） |

> 💡 这一行很重要：**LineState 就是 {rxdp, rxdn} 打包**。我们项目直接采 `rxdp`/`rxdn` 单端，
> 自己算 `line_state = {rxdp, rxdn}`（见 deserial RTL 里 `assign line_state = {rxdp, rxdn};`），
> 与 UTMI 的 LineState **一模一样**，只是我们省了"PHY 打包"这一步。

### 3.5 其他控制

| 信号 | 方向 | 含义 |
|------|------|------|
| `clk` | Output（PHY→Link） | PHY 提供的主时钟（60/48/6MHz） |
| `SuspendM` | Input | 低有效：进入挂起（PHY 停掉非必要模拟电路） |
| `Reset`(n) | Input | 复位 PHY（低有效） |
| `VBus_Valid` | Output | VBUS 有效指示（UTMI+ 引入） |

### 3.6 一图流：UTMI 完整信号拓扑

```
                    Link / SIE 视角
  ┌────────────────────────────────────────────────────────────┐
  │                                                            │
  │  DataIn[7:0]  ────►   TXValid ──►  XcvrSelect/TermSelect   │
  │  (发送字节)            TXReady ◄──  OpMode[1:0]             │
  │                                                            │
  │  DataOut[7:0] ◄────   RXValid ◄──  LineState[1:0] ◄─────   │
  │  (接收字节)            RXActive ◄  VBus_Valid ◄──          │
  │                        RXError ◄                           │
  │                                    clk ◄── (PHY 给的时钟)   │
  │                                                            │
  └────────────────────────────────────────────────────────────┘
```

---

## 4. UTMI+：从"设备"扩展到"主机/OTG"

UTMI 只支持 **USB 设备**。USB 2.0 的**主机控制器**和 **OTG** 需要更多能力，于是 Intel 出了 **UTMI+**。
它用**分级**（Level 0~3）的方式递增功能，越往上功能越全、引脚越多。

| 级别 | 能力 | 说明 |
|------|------|------|
| **UTMI+ Level 0** | 仅 HS 设备 | 最简，基本就是 UTMI |
| **UTMI+ Level 1** | 设备 + OTG（HS/FS） | 加 VBUS/会话管理 |
| **UTMI+ Level 2** | 加 LS 支持 | 低速收发器 + 速度切换 |
| **UTMI+ Level 3** | 加 **preamble 包**（LS 前导包） | 完整主机 + OTG，引脚最多（约 12 引脚以上并行） |

> 不同实现/文档对各级精确边界略有出入，以 Intel UTMI+ 原文为准。

### 4.1 UTMI+ 新增信号（相对 UTMI）

| 信号 | 方向 | 含义 |
|------|------|------|
| `IDIG` | Output | OTG ID 检测输入（数字版），用于主机/设备角色判定 |
| `VBus_Valid` | Output | VBUS 电压有效 |
| `SessEnd` / `SessValid` | Output | 会话结束 / 会话有效（OTG 会话管理） |
| `HostDisconnect` | Output | 主机侧：检测到设备断开（下游拉低） |
| `ChirpEn` | Output/Input | 使能 chirp 序列（HS 握手） |
| `DrvVBus` | Input | 驱动 VBUS（主机/OTG 供电控制） |
| `DPPulldown` / `DMPulldown` | Input | D+/D- 下拉控制（主机侧终端） |

> 理解点：UTMI+ 的增量几乎全是**主机/OTG 的"责任"**——VBUS 电源、会话、角色切换、设备断连检测。
> 纯设备端（我们项目）其实只需要 UTMI 那组信号就够了。

---

## 5. ULPI：低引脚版（把引脚变成"寄存器 + 双向总线"）

UTMI/UTMI+ 是**并行 + 大量专用引脚**（几十根）。当 PHY 做成**外置独立芯片**时引脚太贵，
于是有了 **ULPI**（UTMI+ Low Pin Interface）。

### 5.1 三个降引脚手段

1. **静态/慢变信号 → 寄存器位**：`XcvrSelect/TermSelect/OpMode/SuspendM` 这些平时不变的控制，
   不再用引脚，改成 Link 写 PHY 的**寄存器**（Function Control、Interface Control、OTG Control 等）；
2. **数据总线双向**：同一根 8 位总线既传 USB 包数据、也传寄存器读写的命令+数据；
3. **PHY 当总线主人**：因为总线双向，PHY 用 `DIR` 控制方向（防接收时被打断）。

### 5.2 ULPI 信号（共 12 根：8 数据 + 3 控制 + 1 时钟）

| 信号 | 方向 | 含义 |
|------|------|------|
| `clk` | PHY→Link（或外部） | 60MHz（8-bit 单沿必选；4-bit 双沿可选） |
| `DATA[7:0]` | **双向** | 空闲时传命令（`TX_CMD`/`REG_WR`/`REG_RD`），忙时传 USB 数据 |
| `DIR` | PHY→Link | PHY 控制总线方向；高 = PHY 在驱动总线（不能被打断） |
| `NXT` | PHY→Link | 节流：接收时 ≈ RXValid，发送时 ≈ TXReady |
| `STP` | Link→PHY | 拉高 = 结束本次包传输 / 寄存器写 / 中止接收 |

**`NXT` 的双重身份**（理解 ULPI 的钥匙）：
- **接收**时，`NXT` 对应 `RXValid`（Link 每拍采样 Data）；
- **发送**时，`NXT` 对应 `TXReady`（Link 每拍看它决定是否推下一字节）；
- `DIR` 拉高同时 `NXT` 拉高，表示检测到包开始（对应 `RXActive`）。

### 5.3 寄存器访问（在总线上做"地址 + 数据"）

Link 通过同样的 8 位总线发 **REG_WR / REG_RD 命令 + 地址 + 数据** 来配置 PHY。
ULPI 寄存器分四类：**ID（厂商/产品号）、Mode（功能/接口控制）、Interrupt（中断）、Extra（保留/厂商）**。

### 5.4 与 UTMI 的关系

ULPI **不是**另一套标准，而是 UTMI+ 的低引脚**物理实现**：芯片内部仍是 UTMI+ 语义，
只是在接口上挂了一个 **UTMI↔ULPI 桥**（Link 侧把 UTMI 信号翻译成 ULPI 命令流）。
SMSC USB3300 就是"一个 ULPI PHY 实现全部 UTMI+ Level 3"的典型。

---

## 6. UTMI / UTMI+ / ULPI 速查对照

| 维度 | UTMI | UTMI+ | ULPI |
|------|------|-------|------|
| 本质 | PHY↔Link 标准并行接口 | UTMI + 主机/OTG 扩展 | UTMI+ 的低引脚物理实现 |
| 支持 | 仅设备 | 设备/主机/OTG（分级） | 同 UTMI+（面向 Level 3） |
| 引脚 | ~20+ 并行 | 随级别增加 | 12（8-bit）/ 8（4-bit） |
| 控制面 | 专用引脚 | 专用引脚 | 寄存器位（走总线） |
| 数据 | 单向并行总线 | 单向并行总线 | **双向**总线 |
| 总线主人 | Link（单向，无冲突） | Link | **PHY**（用 DIR 控制方向） |
| 典型场景 | 片内集成 PHY 的 SoC | 片内 + 需要主机/OTG | **外置 PHY 芯片** |

---

## 7. ⭐ 对照我们的设计（学习要落地的地方）

我们项目是 **USB 1.1 FS-only**、**数字收发器直接采 DP/DN 单端**、**自有 DPLL CDR**、**没有 PHY-Link 标准接口**。
把我们的信号逐一对到 UTMI 上，最能看出两者怎么切分：

| 我们（现状） | UTMI 对应 | 差异说明 |
|--------------|-----------|----------|
| `rxdp` / `rxdn`（模拟 PHY 单端） | `LineState[1:0]` | 同一件事。我们直接采线自己算 `{rxdp,rxdn}`；UTMI 的 PHY 打包成 LineState 交给 Link |
| `dclk` + `rx_bit`（自有 DPLL CDR 恢复） | `clk` + `DataOut` | 我们的 CDR 在**数字域**自己做（`usb_rx_cdr.v`）；UTMI 的 PHY 用**模拟** CDR 恢复位时钟 |
| NRZI 解码 / 位解填充 / SYNC / 字节对齐（`src/phy/usb_rx_deserial.v`） | PHY 内部串行编解码 | **已收敛**：2026-09-20 我们把串行编解码由 SIE 改挂 PHY，与 UTMI 切分一致——PHY 出字节，Link/SIE 只见字节 |
| `tx_data` / `tx_valid` / `tx_ready`（SIE→tx_serial） | `DataIn` / `TXValid` / `TXReady` | **握手语义几乎一致**：valid 拉高→发 SYNC，valid 拉低→发 EOP，ready 节流 |
| `rx_active` / `rx_valid` / `rx_error`（deserial 输出） | `RXActive` / `RXValid` / `RXError` | 一一对应。我们的 `rx_valid`=每字节一拍脉冲≈`RXValid` |
| `rcv` 时钟方向 + `usb_clk_mux`（clk12m 无毛刺切换） | `XcvrSelect` / `TermSelect` / `OpMode` | 我们用 `rcv` 在 dclk/clk12s 间切；UTMI 用 XcvrSelect 在 HS/FS 收发器间切、TermSelect 切终端电阻 |
| `tx_active`（SIE 事务逻辑门控 EOP/RX） | （无直接对应） | UTMI 的 PHY 看 TXValid 自动知道在发送、自动门控接收；我们用手动 `tx_active` 门控 |
| `line_state` 计时做挂起/复位检测（待设计） | `LineState` + `SuspendM` | 我们靠 `line_state` 计时；UTMI 有专门的 `SuspendM` 引脚控制挂起 |

### 7.1 一句话总结两种切分

> **UTMI 的哲学**：把一切"跟波形打交道"的活（模拟收发、CDR、NRZI、位填充、SYNC/EOP）**全部下沉到 PHY**，
> Link 只和**字节流**打交道。
>
> **我们的哲学**（因 FS-only + 自有 DPLL）：PHY 只留 CDR + 时钟切换（反正 FS 12Mbps 数字采样足够稳），
> 把串行编解码**上收到 SIE**。
>
> 两者是同一问题的**两种边界**。边界画在哪里，取决于"数字能处理到多快"。FS 可以数字硬扛，
> HS（480Mbps）必须模拟 PHY + 标准接口 —— 这就是 UTMI 存在的原因。

### 7.2 如果将来要做 HS，我们要补什么

1. **模拟 PHY**（差分驱动/接收、HS 终端、squelch、模拟 CDR）——数字没法替代，这是硬门槛；
2. **HS 握手**（chirp K/J 序列、HS 复位检测）→ 对应 UTMI 的 `OpMode[1:0]=10` 裸发 K 态 + `TermSelect/XcvrSelect` 切换；
3. **HS squelch 检测**（低速噪声抑制）→ UTMI 的 `RXError` 一部分；
4. 选型：**外置 PHY 用 ULPI**（少引脚），**片内集成用 UTMI/UTMI+**（并行、控制灵活）；
5. 我们现有的 `usb_rx_deserial` / `tx_serial` 的串行编解码会被 PHY 替代，SIE 事务层可复用大半。

---

## 8. 学习路径建议

1. **先吃透 §7 的对照表** —— 用自己项目的信号去理解 UTMI，比背信号名快得多；
2. 拿一个真实 **ULPI PHY 数据手册**（如 SMSC USB3300）对照着读 §5，看寄存器怎么配出 FS/HS；
3. 想深入时序再读 **UTMI spec v1.05** 的 Timing 章节（setup/hold 对 RTL 集成是硬约束）；
4. 我们项目当前**不需要**实现它 —— 把它当作"FS 数字方案的天花板参照"来理解即可。

---

## 9. 参考资源

> 📁 **本地已存档**（在 `docs/`，清单见 `docs/utmi_docs_index.md`）：
> `utmi_spec_1.05.pdf`（官方 67 页）、`ULPI规范V1.1_中文版.pdf`（翻译版 91 页）。

- **Intel, *USB 2.0 Transceiver Macrocell Interface (UTMI) Specification*, v1.05** —— UTMI 原始规范 ✅ 本地
  <https://www.intel.com/content/dam/www/public/us/en/documents/technical-specifications/usb2-transceiver-macrocell-interface-specification.pdf>
- **Intel, *UTMI+ Specification*, v1.0** —— UTMI+（主机/OTG 扩展 + Level 0~3）⚠️ 需手动下载（见 `docs/utmi_docs_index.md`）
- **USB-IF / *ULPI Specification* v1.1** —— ULPI 低引脚接口 ✅ 中文版本地，英文原版需手动下载
- **SMSC USB3300/3250 数据手册** —— 一个"ULPI PHY 实现全部 UTMI+ Level 3"的实物对照 ⚠️ 需手动下载
- 本仓库相关：`doc/intel_sie_whitepaper_notes.md`（Intel SIE 白皮书笔记，含"对应我们的设计"注解）、
  `doc/usb协议解读/07_usb11_electrical.md`（USB 1.1 电气层，D+/D- 单端概念打底）
