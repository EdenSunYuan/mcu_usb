# usb_sie 模块设计报告（第一阶段：RX 事务层）

> 模块：`src/sie/usb_sie.v` + 子模块 `src/sie/usb_sie_pkt_rx.v`
> 范围：**只做接收（RX）**，发包（IN 事务 / TX 串行器）本轮不做
> 新增公共原语：`src/common/usb_crc5_byte.v`、`src/common/usb_crc16_byte.v`（字节并行 CRC）
> 上游依赖：PHY 的 `usb_rx_deserial`（字节流 + 包边界）、`usb_rx_cdr`、`usb_clk_mux`、`usb_bus_state`
> 下游（下一步）：`usb_tx_serial`（TX 执行器）、`usb_sie_cdc`（四相握手 → 端点 FIFO）、APB/寄存器
> 验证报告：[usb_sie_verification.md](usb_sie_verification.md)
> 协议依据：`docs/usb_1_1_spec.pdf` 第 8 章（精读笔记 `doc/usb协议解读/08_usb11_protocol.md`）、
> Intel SIE 白皮书（精读笔记 `doc/intel_sie_whitepaper_notes.md` §6.8/§6.9）

---

## 1. 模块介绍

### 1.1 层次位置

```
┌──────────────────── usb_dpll_phy（PHY）────────────────────┐ ┌──── usb_sie ────┐
 模拟 PHY ─► usb_rx_cdr ─► usb_clk_mux ─► usb_rx_deserial ──┼─►│  usb_sie        │
  (DP/DN)     (位恢复)     (clk12m 切换)   (位→字节+包边界)   │  │  ├ pkt_rx       │──► 应答请求 ──► usb_tx_serial
                                                            │  │  └ txn FSM      │──► 事件/字节 ──► usb_sie_cdc ──► EP FIFO
                                     ◄──── rx_abort ─────────┼──│                 │
                                                            │  └─────────────────┘
                                        ▲ PHY↔SIE 边界 = 字节级 + 线状态
```

`usb_sie`（Serial Interface Engine，串行接口引擎）是协议层。上游 `usb_rx_deserial` 交给它的是已经
对齐的字节流加包边界，不做任何解析，也不判错；下游端点 FIFO 要的是"事务判定 + 应答决策"。本模块
夹在中间，负责把字节变成事务。

### 1.2 本轮范围：只做接收（RX）

| 做（RX 侧） | 不做（留给下一步） |
|---|---|
| **包级接收解析**：字节装配、PID 解码校验、CRC5/CRC16 校验、字段提取（ADDR/ENDP/帧号/数据长度） | **一切发送**：IN 事务（收 IN token → 发 DATA → 等握手）、组包、CRC 生成、SYNC/EOP、`usb_tx_serial` |
| **事务级状态机**：token → 数据包 → 应答的跨包顺序、周转超时 | 应答的**物理发送**（TX 串行器执行；本轮只出"应答请求"） |
| **应答决策**：规范 Table 8-4 真值表（OUT/SETUP）、`ep_stall`/`ep_nak` 采样、data toggle 规则 | 包缓冲 → 端点 FIFO 的 **CDC 桥**（`usb_sie_cdc`，四相握手，已有模块） |
| **端点事件**：`ep_rx_done` / `ep_rx_bad` / `setup_recv` / `sof_recv` + 帧号、**SIE 内 64B 包缓冲**（坏包隔离） | 端点 FIFO、APB 从接口、寄存器文件、顶层集成 |

本轮交付边界即接口冻结点：`usb_sie` 输出 `resp_req` + `resp_pid[7:0]`（ACK / NAK / STALL）作为
应答请求，下一步 TX 执行器接上就能发。本轮不产生任何发送行为，没有 IN 事务，`resp_pid` 不出
DATA0/DATA1。`rcv` 里代表"设备在驱总线"的那一项（`driving`）本轮恒 0，发包与远程唤醒接进来时
只改这一根线的译码，`rcv` 表达式不动（§1.3）。

### 1.3 时钟域

| 域 | 频率 | 本模块内容 |
|---|---|---|
| **`clk12m`**（接收时 = `dclk`，`usb_clk_mux` 切出） | 12 MHz，1 拍 = 1 bit | **全部**：包级解析、事务 FSM、CRC、包缓冲、toggle |
| `pclk`（CPU/端点） | 24 MHz | 仅**准静态**信号跨界：`dev_addr`、`ep_stall`/`ep_nak`/`ep_dir`、`toggle_set`/`toggle_val`（2-FF 同步） |

没有新的异步 CDC 边界。SIE 与端点 FIFO 之间的 CDC 由既有 `usb_sie_cdc`（四相闭环握手）承担，
属下一步；`clk12m` 与 `ref_clk` 是派生同步时钟，EOP/SE0 的交接已由 `usb_rx_deserial` 处理完。

**`rcv` 选路策略**（SIE 产生 `rcv` 并送 `usb_clk_mux`）：

| 时刻 | `rcv` | `clk12m` 来源 |
|---|---|---|
| 复位初始化 | 0 | `clk12s`（本地 12MHz） |
| 检测到插入（`usb_bus_state` 的 `connect_evt`）之后 | 1 | `dclk`（恢复时钟） |
| 自己发送期间（`tx_active`） | 0 | `clk12s` |
| 远程唤醒驱 K 期间（`sie_susp & sie_wkup`） | 0 | `clk12s` |
| 发送/唤醒结束 | 1 | `dclk` |

即 `rcv = attached & ~driving`，`driving = tx_active | (sie_susp & sie_wkup)`。判据是"设备有没有在驱总线"：
包发送与唤醒 K 都是驱，两者都归本地晶振。三个后果：接收路径始终跑恢复时钟（与主机同源）；
发送与唤醒跑本地晶振（比特率由本地 12MHz 定）；`clk12m` 在任何时刻都有沿，因为 `dclk` 是
CDR 状态位的直出、每拍必翻，`rcv=0` 时又切到本地时钟。

挂起段里 `rcv` 不压 0（`sie_susp`=1 但还没请求唤醒）：恢复时钟留着，好让主机 resume 的 K
能被接收路径看见。压 0 的窗口严格等于"设备在驱 K"的那一段。`sie_susp` 是 SIE 自己那份挂起
标志（由 `suspend_evt` 置、`resume_evt`/`usb_rst` 清），只在本模块内用来算 `rcv`，不外送：
`usb_tx_serial` 的唤醒旁路读的是 `usb_bus_state` 判出的 `bus_suspended`。

复位初始化必须是 `rcv=0`，这正是 `usb_clk_mux` 对 `rcv` 的用法要求：CDR 未锁时 `dclk`
输出常 0，若此刻 `rcv=1`，选出来的 `clk12m` 就是常 0，SIE 连复位都没法跑。
`rcv=0` 选到 `clk12s`（`ref_clk` 4 分频，本地晶振），上电即有稳定 12MHz。

本轮 `driving` 恒 0：`tx_active` 与 `sie_susp`/`sie_wkup` 都属发包与唤醒轮，届时只改这一根线的
译码，`rcv` 表达式不动。附着态 `attached` 由 `connect_evt` 置起、`usb_rst` 清（§2.12）。

**挂起与远程唤醒**（SIE 侧职责，本轮不实现）：SIE 产生一根电平 `sie_wkup`（唤醒请求）送
`usb_tx_serial`，K 的驱与撤由它表达；旁路要的挂起态由 `usb_bus_state` 的 `bus_suspended` 直接
给出，不经 SIE 转手（[tx_serial_design.md](tx_serial_design.md) §2.11）。唤醒期间 SIE 不拉 `tx_active`、
不摆新 `tx_data`：唤醒与包路径互斥，这条协调归 SIE，PHY 侧不做门控。K 的 1~15 ms 时长与收尾
也由 SIE 计。前置条件（挂起 ≥5 ms、`rw_en` 已使能且复位清 0）由软件在写 `wkup_req` 前自判，见
[bus_state_design.md](bus_state_design.md) §2.7 与 [tx_serial_design.md](tx_serial_design.md) §2.11。

`rcv` 的切换时序没有新问题：`sie_wkup` 在 `clk12m` 沿拉起 → `rcv` 落 → `usb_clk_mux` 无毛刺
切到 `clk12s` → 之后 `usb_tx_serial` 的旁路寄存器在新时钟上取值。两个时钟源都在 `ref_clk` 域
寄存产生、切换已单独验证（`clk_mux_verification.md`），故不需要额外的握手。

### 1.4 核心思想

两级状态机解耦：

- **包级**（`usb_sie_pkt_rx`）无记忆。每个包（`rx_active`↑…↓）独立解析，输出这个包是什么类型、
  字段值多少、CRC 好不好；
- **事务级**（`usb_sie` 内）跨包记忆。记住"我刚收到一个 OUT token，接下来该来数据包"，
  并把包级结论翻译成应答决策。

这样包级可以纯组合加小计数、易于穷举验证；事务级只有 4 个状态，跳转条件全是包级的现成结论。

关键技术选择（推导见 §2）：

1. CRC 必须字节并行。实测 1 字节 = 8 拍 `clk12m`，位串行正好 100% 占用、零余量；
2. 数据包用 2 字节延迟线，一举解决"哪两个字节是 CRC16"和"净荷字节何时推入缓冲"两个问题；
3. SIE 内 64B 包缓冲，CRC 通过才推给端点，坏包当场丢弃，端点 FIFO 不受污染。

---

## 2. 模块设计理论和原理及方法

### 2.1 设计动机：deserial 的职责边界在哪

PHY 的 `usb_rx_deserial`（已定稿）刻意不做任何协议判断：它只恢复字节、标出包边界，连 PID 都不看。
证据是它的验证用例 `case_pkt_all`：坏 PID、坏 CRC5、坏 CRC16 三类包它都透明放行，逐字节照常输出、
`rx_error` 保持 0。

> 契约（`rx_deserial_design.md` §3.2/§4.8，已冻结，不要改）：
> - `rx_active`↑ = 包开始（SYNC 命中），此后第 1 个 `rx_valid` 脉冲的字节 = PID；
> - `rx_data` 满 667ns 字节周期维持，`rx_valid` 每字节恰一拍脉冲；
> - `rx_active`↓ = 包结束，同拍采样 `rx_error`（晚一拍才清）；`rx_error` 只代表**物理层**错误
>   （位填充违规 / EOP 错），不代表 CRC 错；
> - 契约里没有 `rx_start` / `rx_last`，包首包尾全靠 SIE 自己数。

所以 PID 校验、CRC、寻址、toggle、应答全部落在本模块。这不是重复劳动，而是刻意的分层：
物理层只管位和字节对不对，协议层才管这个包该不该应。

### 2.2 两级状态机总结构

```
                 ┌─────────────────── usb_sie_pkt_rx（包级·无记忆）───────────────────┐
rx_data[7:0] ───►│  字节计数 → PID 解码/校验 → 字段提取 → CRC5/CRC16 → 长度/溢出     │
rx_valid    ───►│                                                                    │
rx_active   ───►│  pkt_done / pkt_bad / pkt_cls / pid_ok / tok_* / dat_* / rx_abort   │
rx_error    ───►│  净荷字节（延迟 2 字节后）→ 包缓冲写口                              │
                 └────────────────────────────┬───────────────────────────────────────┘
                                              │ 包结束时的"一包结论"
                 ┌────────────────────────────▼───────────────────────────────────────┐
                 │              usb_sie（事务级·跨包记忆）                             │
                 │  事务 FSM（T_IDLE/T_DATA_WAIT/…）+ 应答决策真值表 + toggle + 超时    │
                 │  + 64B 包缓冲 + 端点事件                                            │
                 └────────────────────────────┬───────────────────────────────────────┘
                                              │
                        resp_req/resp_pid ────┴──── ep_rx_done/ep_rx_bad/setup_recv/sof_recv
                        （→ tx_serial，下一步）      （→ 端点层，下一步经 CDC）
```

事务级不能用"一个包一个状态机"解决。USB 的一个事务跨 2~3 个独立包，token 包、数据包、握手包
各自有 SYNC、EOP、CRC；OUT 事务里 token 包和数据包之间还有间隙。设备必须记住"我刚认了哪个端点、
哪个方向"，才能在数据包结束时决定 ACK 还是 NAK。

### 2.3 token 字段位映射（线上序 → 字节）

USB 所有字段 LSb 先发，但 CRC 字段例外，是 MSB 先发。deserial 输出的字节是线序的，于是 token 的
16 个非 PID 位正好切成 2 字节：

| 字节 | 线序 bit | 含义 |
|---|---|---|
| `byte1` | `[6:0]` | `ADDR[6:0]` |
| `byte1` | `[7]` | `ENDP[0]` |
| `byte2` | `[2:0]` | `ENDP[3:1]` |
| `byte2` | `[7:3]` | `CRC5[4:0]`（**MSB 先**：`byte2[3]`=CRC5[4] … `byte2[7]`=CRC5[0]） |

SOF 包同结构，`byte1` + `byte2[2:0]` 就是 11 bit 帧号（`Frame[7:0]` + `Frame[10:8]`）。

这里有个便利点：因为字节本身就是线序，"每字节从 bit0 到 bit7 依次喂 CRC"自动等价于
"字段按 LSb 先、CRC 按 MSB 先"。CRC 引擎不需要知道哪个字段是 MSB 先发的，统一按字节线序喂即可，
最容易出错的一处位序转换就这样消掉了。

数据包同理：末两字节 = `CRC[15:8]`、`CRC[7:0]`（16 bit CRC 字段 MSB 先发，切成 2 个线序字节）。

### 2.4 PID 解码与校验

PID = 4 bit 类型 + 4 bit 校验（校验 = 类型按位取反）。判定：

```
pid_ok = (pid[7:4] == ~pid[3:0])
```

分组（协议 §3.1 的快速解码技巧，最低两位直接决定组）：

```
pid[1:0] = 01 → Token    (OUT 0xE1 / IN 0x69 / SOF 0xA5 / SETUP 0x2D)
pid[1:0] = 11 → Data     (DATA0 0xC3 / DATA1 0x4B)
pid[1:0] = 10 → Handshake(ACK 0xD2 / NAK 0x5A / STALL 0x1E / NYET 0x96)
pid[1:0] = 00 → Special  (PRE 0x3C)
```

`pid_ok = 0` 则整包忽略（协议 §7.1 Table 8-6 第一行：PID 校验错就忽略整包，不是"部分处理"）。
分组只是粗分类，具体是哪个 PID 仍用完整字节比对（`localparam` 直接取自 `src/inc/usb_const.vh`）。

> FS-only 下 NYET（HS 专用）与 PRE（LS 前导）都按"不认识 → 忽略"处理。

### 2.5 CRC：为什么 RX 必须字节并行

#### 2.5.1 时序推导（决定性约束）

```
FS 位率 12 Mbit/s  →  1 bit = 1 个 clk12m 周期
1 字节 = 8 bit     →  8 个 clk12m 周期/字节（667 ns）

位串行 CRC = 1 bit/周期  →  8 周期/字节 = 100% 占用，零余量
                          + 包尾还要额外 16 拍喂完 CRC16 才出残差
```

100% 占用在真实电路里不可实现，任何气泡（`rx_valid` 脉冲拍、EOP 门控、错误分支）都会丢节拍；
包尾那额外 16 拍 = 1.33 µs，也远超设备应答窗口（EOP 后几 bit time 内必须发出握手，否则主机判超时）。

结论：

| 路径 | 方案 | 理由 |
|---|---|---|
| **RX（本模块）** | **字节并行 CRC**（1 字节/拍，8× 余量），新增 `usb_crc5_byte.v` / `usb_crc16_byte.v` | 余量充足；包尾喂 2 个 CRC 字节只需 2 拍（167 ns） |
| **TX（下一步）** | 复用现有位串行 `usb_crc5.v` / `usb_crc16.v` | 发送时位流本来就是 1 bit/拍，喂 CRC **免费** |

现有位串行原语不改（已被验证）；新的字节并行版用同一套 gold 模型（`tools/gen_crc_gold.py`）
交叉验证，两版对同一输入必须给出同一结果。

#### 2.5.2 校验判据：喂满整段（含 CRC 位）查残差

两种等价判据：

- (a) 不喂 CRC 位，算完数据位后直接比 `~余数`（因为发送端发的是 `~crc`，MSB 先）；
- (b) 连 CRC 位一起喂，看最终余数是否等于规范残差。

本设计取 (b)，它把 token 和 data 两条路径统一成"喂完整包、查残差"，而残差是规范魔法数：

| 类型 | 多项式 | 看护范围 | 无错残差 |
|---|---|---|---|
| CRC5 | `x⁵+x²+1`（`0x05`） | token 的 ADDR+ENDP（或 SOF 帧号），11 bit | `0x0C` |
| CRC16 | `x¹⁶+x¹⁵+x²+1`（`0x8005`） | DATA 包的数据字段 | `0x800D` |

token 的 CRC5 特别省事：11 bit 数据 + 5 bit CRC = 16 bit，正好 2 个整字节，所以"喂 byte1、
喂 byte2、查残差 = `0x0C`"即可，不必处理非字节对齐。这是 §2.3 那个位序便利点的直接收益。

#### 2.5.3 数据包：2 字节延迟线（一举两得）

数据包长度事先未知（0~64 字节，靠 EOP 定界），因此无法直接知道"最后 2 字节是 CRC16"。
解决办法是让 CRC 引擎永远吃"延迟 2 字节"的字节流。

```
字节序:    b0     b1     b2    ...   bK  | b(K+1) b(K+2)
           PID    └──── 数据 ────┘      | └── CRC16 ──┘

收到 b(i) 时： 喂 CRC 引擎 = d1（= b(i-2)）; d1←d2; d2←b(i)
包尾时：      d1 = b(K+1)，d2 = b(K+2)  → 补喂这 2 个字节 → 查残差 0x800D
```

延迟线顺手解决了第二个问题。净荷字节（b1…bK）正好就是"延迟 2 字节后仍在流里的字节"，
所以同一个延迟拍既喂 CRC、又写包缓冲。数据字节不会把 CRC 字节带进缓冲，这是坏包隔离的前提。

代价是包尾（`rx_active`↓）后需要 2 拍补喂 CRC 字节才能出残差判定，即应答决策比包尾晚
2 个 `clk12m`（167 ns），远在应答窗口内，可以接受。

### 2.6 包类型、长度约束与溢出保护（`rx_abort`）

| 包类型 | 字节数下限（含 PID） | 字节上限 |
|---|---|---|
| Token（OUT/IN/SETUP） | 3（`MIN_TOKEN`） | 3（`LIM_TOKEN`） |
| SOF | 3 | 3 |
| Handshake | 1（`MIN_HS`） | 1（`LIM_HS`） |
| Data | 3 | 3 + `max_payload` |
| 类别不明 | 0 | 67（`LIM_ERR` = 3 + 64 兜底） |

越上限即拉 `rx_abort`，不足下限（截断包）只标 `pkt_bad`；两者都进 `pkt_bad`。越上限不能只写
"忽略"：忽略不会让字节计数停下，乱码流仍然无界，兜底就失效了。

`max_payload` 按端点取值（EP0 = 8（`MAXP_EP0`），EP1/EP2 = 64）。deserial 侧契约要的是"该包
类型/端点最大负载"，数据包在 token 之后到达，`usb_sie` 此时已知 `ep_sel`，由它查表驱动 `pkt_rx`
的 `max_payload` 端口。EP0 枚举初期为 8、之后放宽到 64 属寄存器的事，本轮取固定表。

`rx_abort` 的作用（`rx_deserial_design.md` §4.7 已定义契约）：异常长包（无 EOP 的持续跳变）
会让 SIE 数出无限字节。SIE 一旦发现字节数超过该包类型上限，立即拉 `rx_abort`，deserial 收到后
立刻回 `USB_IDLE`（`rx_active`↓、丢包），且不置 `rx_error`（溢出是 SIE 自己的判断，
`rx_error` 电平只留给物理层错误）。

> 这是"包尾靠 EOP 定界"这套机制的兜底。EOP 可能因为线缆故障永远不来，字节计数是唯一的护栏。

### 2.7 事务级状态机

#### 2.7.1 状态定义

| 状态 | 编码 | 含义 | 本轮 |
|---|---|---|---|
| `T_IDLE` | 3'd0 | 空闲，等任何包的 `rx_active`↑ | 有弧 |
| `T_DATA_WAIT` | 3'd1 | OUT/SETUP token 已收妥，等数据包（周转计时中） | 有弧 |
| `T_TX` | 3'd2 | IN token 已收妥，正在发数据包 | 编码预留 |
| `T_HS_WAIT` | 3'd3 | 数据包已发完，等主机握手（ACK/NAK/超时） | 编码预留 |

后两个态本轮不实现、也没有任何弧进得来，次态恒为 `T_IDLE`；下一轮 TX 接入时补齐跳转。
先定义只是为了让包级接口一次到位（`pkt_cls` 要能区分 token/data/handshake）。仿真侧已把它们
声明为结构不可达，覆盖率矩阵里这两行两列全 0 属预期（[verification](usb_sie_verification.md) §6.5）。

#### 2.7.2 跳转表（事件 = `pkt_done` 拍上的"一包结论"）

| 当前态 | 事件（包级结论） | 次态 | 动作 / 说明 |
|---|---|---|---|
| `T_IDLE` | TOKEN，`pkt_done` & 非坏 & PID=OUT/SETUP 且地址与端点匹配 | `T_DATA_WAIT` | 记 `ep_sel`/`is_setup`；**启动周转计时** |
| `T_IDLE` | TOKEN，… & PID=IN | `T_IDLE` | 本轮不派发（不发数据），等同忽略 |
| `T_IDLE` | TOKEN，… & PID=SOF | `T_IDLE` | 存 `frame_no`、发 `sof_recv`；**不过地址匹配**（11 bit 是帧号） |
| `T_IDLE` | TOKEN，`pid_ok=0` / CRC5 错 / 地址失配 / 端点越界 | `T_IDLE` | **静默忽略**（协议 §7.1/§3.2：整包/token 忽略） |
| `T_IDLE` | DATA / HANDSHAKE（无 token 前导） | `T_IDLE` | 忽略（不在事务中，属杂散包） |
| `T_IDLE` | INVALID（坏包 / `rx_error`） | `T_IDLE` | 忽略 |
| `T_DATA_WAIT` | DATA，本包完好 | `T_IDLE` | **应答决策**（§2.8）→ 出 `resp_req`/`resp_pid` |
| `T_DATA_WAIT` | DATA，本包坏 | `T_IDLE` | 不应答，丢弃（§2.8 第 1 行） |
| `T_DATA_WAIT` | **新 TOKEN 到达且派发成立**（主机放弃了数据阶段） | `T_DATA_WAIT` | **鲁棒性关键点**：按新 TOKEN 重新武装，`ep_sel`/`is_setup` 覆盖，计时器回 1 |
| `T_DATA_WAIT` | 周转超时（§2.10） | `T_IDLE` | 静默放弃，无应答 |
| `T_DATA_WAIT` | 其它（SOF / IN / 坏 token / HANDSHAKE / INVALID） | `T_IDLE` | 忽略；这些包的 `pkt_done` 一律收尾数据阶段 |

`T_DATA_WAIT` 要能被新 TOKEN 打断，是因为主机在 token 后可能因为帧末、错误恢复等原因不发
数据包，直接开始下一个事务。如果状态机死等数据包，就会把下一个事务的 token 误当成"数据包"。
规则统一为"任何包都先按包级结论分类，再按上表分派"，打断情形天然被覆盖：派发成立就重新武装
（自环），不成立就由 `pkt_done` 收尾回空闲。

分派顺序是先按 PID 分类，再对 OUT/SETUP 做地址匹配。SOF 的 11 bit 是帧号而不是地址，
若先过地址过滤（帧号 ≠ `dev_addr`）就永远收不到 SOF；表里第 1、3 行的差别就在这。

### 2.8 应答决策（规范真值表落地）

设备响应 OUT（协议 Table 8-4，按优先级从上到下）：

| 优先级 | 条件 | 响应 | 数据去向 |
|---|---|---|---|
| 1 | 数据包损坏（`pkt_bad`：物理错 / PID 错 / CRC16 错 / 长度越界） | **不应答** | 丢弃 |
| 2 | OUT 打到配成 IN 的端点（`ep_dir` 方向不符） | **不应答** | 丢弃 |
| 3 | 端点 `ep_stall=1`（halt） | **STALL** | 丢弃 |
| 4 | 序列位不匹配（toggle 不符） | **ACK** | **丢弃**（去重，不翻转、不收） |
| 5 | 序列位匹配 且 `ep_nak=1`（FIFO 满/忙） | **NAK** | 丢弃（主机重试） |
| 6 | 序列位匹配 且 包缓冲可用 | **ACK** | **收下** → 推包缓冲 → 端点 FIFO，翻转 toggle |

第 1 行的"不应答"是硬性的：协议规定损坏包一律不响应，让主机超时重试。第 2 行是全双工端点的
方向保护：OUT 打到配成 IN 的端点上没有被接收的通道，按忽略处理。

第 4 行是 ACK 丢失重传场景（协议 §6.4），这包数据本身完好，只是"序列已前进"，属于去重而非判错。
它与第 5 行的优先级关系要注意：即使 FIFO 满（`ep_nak=1`），只要序列不匹配也要回 ACK 加丢弃，
因为数据本来就要丢，谈不上"收不收得下"。这一条最容易写反。

「能收」还有第二个条件：本包开始时包缓冲必须可用（`buf_ready=0`）。这个判断在包首（`rx_active`↑）
采样并全程保持，中途 CDC 排空也不改判——前半段净荷字节已经被写口门控丢掉了，中途改判会让缓冲
里出现半个包。

设备响应 SETUP（协议 §8.4.5.4，特殊）：

| 条件 | 响应 |
|---|---|
| 包损坏 | **不应答**（丢弃） |
| 数据 PID ≠ DATA0 | **不应答**（SETUP 事务恒用 DATA0，序列异常） |
| 非控制端点（EP1/EP2）收到 SETUP | **忽略，不应答** |
| 正常 | **无条件 ACK**（**不得** STALL、**不得** NAK），并：`toggle[EP0] ← 1`、发 `setup_recv` |

设备响应 IN（协议 Table 8-2）：本轮完全不做（发包先不做）。真值表先记录在案，下一轮 TX 实现，
即 token 损坏不响应 / halt 回 STALL / 无数据回 NAK / 有数据发 DATA(toggle)。

### 2.9 data toggle 规则

归属：SIE 拥有 toggle，因为只有 SIE 看得到主机的 ACK/NAK（白皮书 §6.8）。每端点 1 bit，
EP0/EP1/EP2 共 3 bit。

| 事件 | toggle 动作 | 依据 |
|---|---|---|
| SETUP 事务正常收妥 | **置 1**（收发序列位都初始化） | 协议 §6.1：SETUP 后第一个数据事务用 DATA1 |
| OUT 收下（CRC 好 + 序列匹配 + 能收） | **翻转** | §6.2：接收方"能收且无错且 PID 匹配"才翻 |
| OUT 序列不匹配（重复包） | **不翻转** | §6.4 |
| NAK / STALL / 坏包 | **不翻转** | §6.3：NAK 双方序列位不变 |
| 发送方收到 ACK | 翻转 | 下一步（TX） |

比较规则是 `期望 DATA0 ⇔ toggle==0`。收到 DATA0 时若 `toggle==1`，即序列不匹配，走 §2.8 第 3 行。

CPU 可通过 `toggle_set[2:0]` + `toggle_val[2:0]`（准静态，2-FF 同步）写初值。所谓准静态，指它
只在配置事件（SET_ADDRESS / 配置端点）时改变，不在事务进行中翻转。

### 2.10 周转超时（turn-around timer）

协议 §7.2 明确规定 Both devices and the host require turn-around timers。设备在 token 与 data
之间必须计时，因为 USB 总线上没有显式错误信号，"没等到"就是唯一的错误指示。

| 参数 | 值 | 说明 |
|---|---|---|
| 规范起算点 | token 包 EOP 的 SE0→J 沿 | 协议 §7.2（8.7.2）：不早于 16、不晚于 18 bit time |
| 计数起点 | `T_IDLE → T_DATA_WAIT` 那一拍 | = token 的 `pkt_done`，**比 EOP 晚 2 拍**（§2.5.3 补喂 CRC） |
| 计时终点 | 下一个包的 SOP（`rx_active`↑），或超时 | |
| 超时阈值 | **15 个 `clk12m`**（`TURNAROUND_MAX`） | 判超时拍 + 回空闲拍 = 2 + 16 = EOP 后 18 bit time，规范上限 |

阈值必须把"补喂 CRC 的 2 拍"算进去。若照搬规范值 18 并从 `pkt_done` 起算，实际放弃点会落到
EOP 后 20 bit time，超出上限。从 `pkt_done` 起算 15、判超时那一拍已算"到顶"，次拍才回空闲，
两者相加是 16，合计 18 bit time。

计数器只在 `T_DATA_WAIT` **且总线空闲**（`rx_active=0`）时累加：数据包本身几十上百拍，一压不住
计数早就到顶、包还没收完就被判超时。计时器量的是"token 与数据之间的空档"，不是包长。
任何包的包首（`rx_active`↑）都会把计数清零，所以超时判定里也排除包首那一拍。

`clk12m` 计数即可，1 bit = 1 拍，无需额外精度；空闲期 `usb_clk_mux` 选 `clk12s`（本地晶振），
计数是准的。超时后回 `T_IDLE`、静默放弃，不发任何应答（主机没发数据包，设备无从应答）。

计数到顶那一拍 `turn_done` 成立、次态已回 `T_IDLE`，所以计数器的饱和臂在同一拍就被重装成 1。
换言之计数器停在 15 只有一拍，饱和臂本身走不到（[verification](usb_sie_verification.md) §6.5）。

> 帧末 babble / activity loss 由 hub 负责检测恢复（协议 §7.4），设备端只需保证自己不卡死。

### 2.11 包缓冲与端点接口（坏包隔离）

决策：SIE 内 64B 包缓冲。收包期间字节写入 SIE 自己的缓冲，CRC 校验通过后
才推给端点 FIFO；坏包当场丢弃、写指针回卷，端点 FIFO 完全不受污染。

```
收包期：  pkt_rx 净荷字节（已延迟 2 字节）──写──► pkt_buf[64][7:0]  (wr_ptr)
包尾判定：CRC 好 + 决定"收下" ──► 置 buf_ready=1，进入排出状态
排出期：  buf_rd_en 逐字节读 ──► usb_sie_cdc（四相握手）──► 端点 FIFO(pclk)
坏包/丢弃：wr_ptr 直接回卷到 0，buf_ready 保持 0（FIFO 侧零感知）
```

这 64B 值得花，理由有三条。一是 CRC 只有在包尾才知道好坏，若边收边推，坏包已经把垃圾字节推进
FIFO，要靠跨时钟域的"丢弃 N 字节/写指针回卷"来补救，既复杂又与 CPU 并发读有竞争。二是与线缆
解耦，收包的瞬时速率不被 CDC 排出速率牵制（来不及排出时按 §2.8 第 4 行回 NAK 流控），比边收边推
少一层跨域补救逻辑。三是接口干净，端点层只看到"整包有效/无效"，不需要理解 USB 的 CRC 语义。

遗留风险要记一笔：现四相握手 CDC 实测单字节握手周期约 750 ns（`usb_sie_cdc` 13 相位扫描，
理论 P_max），而 FS 收字节率是 667 ns/字节，CDC 跟不上实时字节率，靠缓冲平均。这与
`PROGRESS.md` §5 待定事项（pclk 是否提频到 ≥36 MHz / 是否改两相 Toggle）是同一个问题，
本模块不解决。接口按"能背压"设计：`buf_ready` 排出期间收到新数据包，走 §2.8 第 4 行回 NAK，
协议上是合法流控，不会出错，只是吞吐下降。真要做满吞吐需先解决 §5 待定事项。

### 2.12 跨时钟域（本模块只涉及"准静态"同步）

没有新的异步 CDC。本轮所有逻辑在 `clk12m` 单域内（接收时 `clk12m` = `dclk`）。

唯一跨界的是 pclk 来的准静态配置：`dev_addr`、`ep_stall`、`ep_nak`、`ep_dir`、`toggle_set/val`。

- 这些信号只在配置事件时变化（CPU 写寄存器），事务进行中恒定；
- 用 2-FF 同步器同步进 `clk12m`（每根 3 位信号是两级各 3 bit，取本级与上级），不要求逐拍正确；
- 采样时刻：`ep_stall`/`ep_nak` 在应答决策那一刻采样。白皮书 §6.8 建议的是解析完 token 后采样，
  但 OUT 的决策发生在数据包尾，两处都满足"此时已稳定"，本设计取决策点采样，少存一份快照。

两根同域输入：`connect_evt` 来自 `usb_bus_state`（`clk12m` 单拍脉冲，置 `attached`），
`usb_rst` 是 core 复位（软复位 ∪ 总线复位，同样宽 1 个 `clk12m` 周期），清事务状态机、toggle、
包缓冲与 `attached`；`ref_rstn` 只做异步置位。

去向端点层的事件（`ep_rx_done`/`ep_rx_bad`/`setup_recv`/`sof_recv`）本轮只在本域产生。跨域方案
已定（白皮书 §6.8）：按性质分流，随字节走的挂四相握手侧带，独立的用脉冲 CDC；这是下一步
`usb_sie_cdc` 对接的范围。

### 2.13 可综合性与正确性说明

- 全部逻辑单时钟 `clk12m`，纯组合加寄存器，无 `#` 延迟、无锁存器（if/else 全补全，规范强制）；
- 状态机一律两段式（时序段只搬 `*_stat_cur`，组合段算 `*_stat_nxt`），与 `usb_rx_deserial` 一致；
- 无除法、乘法、查表外的大块组合，字节并行 CRC 展开为 8 级 XOR 链，组合深度小，12 MHz 下宽裕；
- 包缓冲是寄存器阵列（64×8 = 512 FF），可在综合时按目标工艺映射为小 SRAM；
- 唯一的"经验值"是残差 `0x0C`/`0x800D` 与超时拍数。前者由 gold 模型交叉验证，后者有规范区间背书。

---

## 3. 模块信号列表

### 3.1 `usb_sie.v` 端口（对外接口）

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| **时钟 / 复位 / 附着** ||||
| `clk12m` | in | 1 | 1× 位时钟（接收时 = `dclk` 经 `usb_clk_mux`），本模块**全部**逻辑的时钟 |
| `ref_rstn` | in | 1 | 异步复位，低有效（**与 `usb_rx_deserial` 同一根复位网络**；异步置位，不依赖 `clk12m` 是否在振） |
| `usb_rst` | in | 1 | core 复位（软复位 ∪ 总线复位），同步脉冲，宽 1 个 `clk12m` 周期；清事务状态机 / toggle / 包缓冲 / 附着 |
| `connect_evt` | in | 1 | 附着事件，来自 `usb_bus_state` 的 `clk12m` 单拍脉冲 → 置 `attached` |
| `rcv` | out | 1 | **去 `usb_clk_mux`**：`attached & ~driving`，选 `dclk` / `clk12s`（§1.3） |
| **RX 输入（来自 PHY `usb_rx_deserial`，契约冻结）** ||||
| `rx_data` | in | 8 | 恢复的接收字节（LSb 对齐，满 667 ns 维持） |
| `rx_valid` | in | 1 | 每字节一拍脉冲 |
| `rx_active` | in | 1 | 帧中；**下降沿 = 包结束**（无 `rx_last`） |
| `rx_error` | in | 1 | 物理层错误**电平**（位填充违规 / EOP 错），包结束沿后晚一拍清 |
| `rx_abort` | out | 1 | **回 deserial**：字节数超包类型上限 → 立即中止当前包（不置 `rx_error`） |
| **应答接口（`usb_tx_serial`，下一步接入）** ||||
| `resp_req` | out | 1 | 应答请求（1 拍脉冲），与 `resp_pid` 同拍有效 |
| `resp_pid` | out | 8 | 应答 PID：`ACK`/`NAK`/`STALL`（`usb_const.vh` 常量；`DATA0`/`DATA1` 属 TX 轮） |
| **包缓冲排出接口（接 `usb_sie_cdc`，下一步）** ||||
| `buf_rd_data` | out | 8 | 包缓冲读数据（整包已校验通过） |
| `buf_rd_en` | in | 1 | 逐字节读使能（由 CDC 桥的四相握手驱动） |
| `buf_cnt` | out | 7 | 包缓冲内净荷字节数（0~64），`buf_ready=1` 期间有效 |
| `buf_ready` | out | 1 | 缓冲内有一个**校验通过、待排出**的完整包 |
| **端点事件（去端点层，下一步经 CDC）** ||||
| `ep_rx_done` | out | 1 | OUT/SETUP 数据包完好**且已决定收下**（1 拍脉冲） |
| `ep_rx_bad` | out | 1 | 收到的数据包坏（物理错/PID/CRC/长度），诊断用（1 拍脉冲） |
| `setup_recv` | out | 1 | SETUP 事务收妥（1 拍脉冲，端点据此清协议 stall） |
| **SOF** ||||
| `sof_recv` | out | 1 | 收到 SOF token（1 拍脉冲） |
| `frame_no` | out | 11 | 最近一次 SOF 的帧号（11 bit，写 `REG_FRAME` 用） |
| **CPU 准静态配置（`pclk` 域 → 2-FF 同步进 `clk12m`）** ||||
| `dev_addr` | in | 7 | 设备地址（复位后默认 0，枚举时 CPU 写） |
| `ep_stall` | in | 3 | 端点 halt 标志 `{EP2,EP1,EP0}`（1 = 回 STALL） |
| `ep_nak` | in | 3 | 端点忙标志 `{EP2,EP1,EP0}`（1 = 回 NAK） |
| `ep_dir` | in | 2 | `{EP2,EP1}` 方向（1 = IN，0 = OUT）；EP0 恒双向 |
| `toggle_set` | in | 3 | CPU 写 toggle 初值使能 `{EP2,EP1,EP0}` |
| `toggle_val` | in | 3 | CPU 写的 toggle 初值 `{EP2,EP1,EP0}` |

端点事件用 `ep_` 前缀（`ep_rx_done`/`ep_rx_bad`），与包级 `pkt_rx` 的 `pkt_done`/`pkt_bad`（§3.2）
区分开。两者语义不同：前者是"数据包已收下/坏包"，后者是"本包解析结论有效"。

### 3.2 `usb_sie_pkt_rx.v` 端口（包级解析，`clk12m` 域）

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `clk12m` / `ref_rstn` | in | 1 | 同 §3.1 |
| `rx_data` / `rx_valid` / `rx_active` / `rx_error` | in | 8/1/1/1 | 直连 deserial |
| `max_payload` | in | 7 | 本包允许的最大净荷字节数，由 `usb_sie` 按 `ep_sel` 查表驱动（默认 64；EP0 枚举初期 8） |
| `rx_abort` | out | 1 | 字节数超上限 → 中止（§2.6） |
| `pl_byte` | out | 8 | **净荷字节**（延迟 2 字节后，见 §2.5.3） |
| `pl_byte_vld` | out | 1 | 净荷字节有效（与数据包净荷区对齐，不含 PID 与 CRC16） |
| `pkt_done` | out | 1 | 一包结论有效脉冲：`rx_active`↓ + 2 拍补喂 CRC 后（§2.5.3） |
| `pkt_bad` | out | 1 | **本包**坏（`rx_error` / `pid_ok=0` / CRC 残差不对 / 长度越界） |
| `pkt_cls` | out | 2 | 包类别：`INVALID`/`TOKEN`/`DATA`/`HANDSHAKE` |
| `pid` | out | 8 | 收到的 PID 字节 |
| `pid_ok` | out | 1 | PID 校验位正确（`pid[7:4] == ~pid[3:0]`） |
| `tok_addr` | out | 7 | token 的 ADDR（`byte1[6:0]`） |
| `tok_endp` | out | 4 | token 的 ENDP（`{byte2[2:0], byte1[7]}`） |
| `tok_frame` | out | 11 | SOF 帧号（`{byte2[2:0], byte1}`） |
| `tok_crc_ok` | out | 1 | token 的 CRC5 残差 = `0x0C` |
| `dat_pid_is1` | out | 1 | 数据包 PID = DATA1（0 = DATA0） |
| `dat_crc_ok` | out | 1 | 数据包 CRC16 残差 = `0x800D` |
| `dat_len` | out | 7 | 数据包净荷长度（= `byte_cnt` − 3） |

`pid_ok`、`tok_crc_ok`、`dat_crc_ok` 三个输出在 `usb_sie` 里不接（都已并进 `pkt_bad`），
留作调试观测点。包级解析器不吃 `usb_rst`（端口上就没有）：它只跟着 `rx_active` 走，
包内状态在包首清零，不需要 core 复位介入。

### 3.3 内部关键信号

| 信号 | 所在 | 类型 | 位宽 | 说明 |
|---|---|---|---|---|
| `byte_cnt` | `pkt_rx` | reg | 8 | 本包已收字节数（`rx_active`↑ 清零，`rx_valid` 累加）；`byte_cnt==0` 即 PID |
| `d1` / `d2` | `pkt_rx` | reg | 8 | **2 字节延迟线**（§2.5.3）：`d2` 最新，`d1` 早一拍；既喂 CRC16 又出净荷 |
| `crc5_b` / `crc16_b` | `pkt_rx` | reg | 5/16 | 字节并行 CRC 当前余数（残差比较用） |
| `frame_seen` | `pkt_rx` | reg | 1 | 本包已见 `rx_active`↑；用于在包尾那 2 拍区分"刚结束"与"总线空闲" |
| `tail_cnt` | `pkt_rx` | reg | 2 | 包尾补喂计数，数到 2（`TAIL_DONE`）出 `pkt_done` |
| `rx_err_lat` | `pkt_rx` | reg | 1 | 锁存的 `rx_error` 电平（关包沿采样） |
| `t_state_cur` / `t_state_nxt` | `usb_sie` | reg/wire | 3 | 事务状态机（2 段式，规则 8） |
| `ep_sel` | `usb_sie` | reg | 4 | 当前事务的端点点号（派发成立时锁存） |
| `is_setup` | `usb_sie` | reg | 1 | 当前事务是 SETUP（决定无条件 ACK 与 toggle 置 1） |
| `toggle` | `usb_sie` | reg | 3 | 每端点 data toggle `{EP2,EP1,EP0}` |
| `turn_cnt` | `usb_sie` | reg | 5 | 周转超时计数（`T_DATA_WAIT` 且总线空闲时累加，到 15 判超时，§2.10） |
| `pkt_buf` | `usb_sie` | reg | 64×8 | **包缓冲**（寄存器阵列，收包期写入、校验通过后排出） |
| `wr_ptr` / `rd_ptr` | `usb_sie` | reg | 7 | 包缓冲读写指针（只取低 6 位寻址；包首与 `usb_rst` 都回 0） |
| `pkt_wr_ok` | `usb_sie` | reg | 1 | 包首采样"缓冲可用"（`~buf_ready`），全程不变（§2.8） |
| `attached` | `usb_sie` | reg | 1 | 已附着（`connect_evt` 置起、`usb_rst` 清） |
| `driving` | `usb_sie` | wire | 1 | 设备在驱总线；本轮恒 0（§1.3） |
| `buf_ready` / `buf_cnt` | `usb_sie` | reg | 1/7 | 缓冲内有一个"校验通过、待排出"的完整包 / 其中的净荷字节数 |
| `resp_req` / `resp_pid` | `usb_sie` | reg | 1/8 | 应答决策结果（编码见 §2.8 真值表），同拍有效 |
| `dev_addr_s` 等六组同步链 | `usb_sie` | reg | — | pclk 准静态量的 2-FF 同步链，`*_s` 是链本体、`*_q` 是同步后的值（§2.12） |
| `rx_active_dly` | `usb_sie`/`pkt_rx` | reg | 1 | `rx_active` 打一拍，用于做包首上升沿 |

### 3.4 常量与参数

```verilog
// ---- usb_sie_pkt_rx ----
// 净荷上限走端口 max_payload（§3.2）而非 parameter：各端点上限不同（EP0 = 8 / EP1・EP2 = 64）
localparam [7:0]  LIM_TOKEN  = 8'd3;      // token / SOF 字节上限（PID + 2）
localparam [7:0]  LIM_HS     = 8'd1;      // handshake 上限（只有 PID）
localparam [7:0]  LIM_ERR    = 8'd67;     // 类别不明时的兜底上界 = 3 + 64
localparam [7:0]  MIN_TOKEN  = 8'd3;      // token / 数据包字节数下限
localparam [7:0]  MIN_HS     = 8'd1;      // handshake 下限
localparam [4:0]  CRC5_RESID = 5'h0C;     // token CRC5 无错残差
localparam [15:0] CRC16_RESID= 16'h800D;  // data CRC16 无错残差
localparam [1:0]  TAIL_DONE  = 2'd2;      // 包尾补喂到第 2 拍出 pkt_done
localparam [7:0]  PL_FIRST   = 8'd3;      // 净荷区起始字节下标（0 = PID）
// 包类别
localparam [1:0] CLS_INVALID = 2'd0, CLS_TOKEN = 2'd1, CLS_DATA = 2'd2, CLS_HANDSHAKE = 2'd3;

// ---- usb_sie ----
localparam [2:0] T_IDLE      = 3'd0;  // 空闲，等 token
localparam [2:0] T_DATA_WAIT = 3'd1;  // OUT/SETUP token 收妥，等数据包
localparam [2:0] T_TX        = 3'd2;  // （下一步）IN token 收妥，发数据
localparam [2:0] T_HS_WAIT   = 3'd3;  // （下一步）等主机握手
localparam [1:0] DEC_NONE = 2'd0, DEC_ACK = 2'd1, DEC_NAK = 2'd2, DEC_STALL = 2'd3;
localparam [3:0] EP0 = 4'd0, EP1 = 4'd1, EP2 = 4'd2, EP_MAX = 4'd2;  // 端点点号与实现范围
localparam [4:0] TURNAROUND_MAX = 5'd15;  // 判超时拍 + 回空闲拍 = 2+16 = EOP 后 18 bit time（§2.10）
localparam [6:0] MAXP_EP0 = 7'd8, MAXP_EP1 = 7'd64, MAXP_EP2 = 7'd64;  // 净荷上限表
localparam [7:0] RESP_NONE = 8'h00;   // 无应答时 resp_pid 的占位
// 应答 PID 直接用 usb_const.vh: PID_ACK / PID_NAK / PID_STALL（DATA0/DATA1 属 TX 轮）
```

---

## 4. 关键设计点描述及波形

本节各点给出实现后的实测现象。图一律用超链接，出自 `doc/fig/`，复跑方法与完整判据见
[usb_sie_verification.md](usb_sie_verification.md)。

### 4.1 两级状态机解耦（包级无记忆 / 事务级跨包）

问题：USB 一个事务跨 2~3 个独立包（token / data / handshake 各有 SYNC、EOP、CRC）。
若用"一个状态机管到底"，包内位序、字段语义、跨包记忆全糅在一起，无法穷举验证。

设计做法：包级只有"当前包"的概念（`rx_active`↑ 清零、`rx_active`↓ 出结论），输出
`pkt_cls`/`pid_ok`/`tok_*`/`dat_*`/`pkt_bad` 一组一包结论；事务级只吃这组结论，再记住
`ep_sel`/`is_setup`，按 §2.7.2 跳转表走。包级可以按"喂任意字节序列看结论"穷举测试，
事务级只需覆盖 4×4 的"状态 × 包类别"组合。

📎 [图：事务态只在 `pkt_done` 拍变（sie_two_level_fsm.png）](../fig/sie_two_level_fsm.png)

`pkt_cls` 先为 1（token），`pkt_done` 同拍 `t_state_cur` 由 `3'h0` 变 `3'h1`；随后数据包
`pkt_cls=2`，`pkt_done` 又一拍回 `3'h0`，同拍出 `dec`/`resp_req`。事务级在 `pkt_done` 之外
不采样任何包级信号。

### 4.2 字节线序 → CRC 位序的统一（省掉整层位序转换）

问题：USB 字段 LSb 先发，但 CRC 字段 MSB 先发。若按"字段语义"重组位序，token 里
`ADDR`/`ENDP`/`CRC5` 三段要分别处理，是极易出错的地方。

设计做法（§2.3）：deserial 给的字节本身就是线序，所以"每字节 bit0→bit7 依次喂 CRC"
自动等价于"数据段 LSb 先、CRC 段 MSB 先"，无需任何特判。token 的 11 bit 数据 + 5 bit CRC
正好 2 个整字节，直接"喂 byte1、喂 byte2、查残差"。

📎 [图：残差走到 `0x0C`（sie_token_crc.png）](../fig/sie_token_crc.png)

`rx_data` 依次是 `0x69`/`0x85`/`0x49`，`byte_cnt` 走到 3，`crc5_b` 由 `0x1F` 经 `0x15` 落到
`0x0C`，同拍 `tok_crc_ok=1`、`pkt_done=1`。把 `byte2` 任一 bit 翻掉的变体残差离开 `0x0C`、
`pkt_bad=1`。

### 4.3 字节并行 CRC（时序决定性论证）

问题：位串行 CRC 在 FS 下占满 100% 占空（8 周期/字节），零余量；且包尾补 16 拍超应答窗口。

设计做法（§2.5.1）：新增 `usb_crc5_byte.v` / `usb_crc16_byte.v`，8 级 XOR 展开为组合链，
一次吃掉一个字节；`crc_clr` 回种子全 1，`crc_en` 每字节一拍。12 MHz 下组合深度宽裕。

残差判据在包级用例里逐条量化：好 token 残差恒 `0x0C`、好数据包恒 `0x800D`，单 bit 翻转即离开；
`usb_crc16_byte` 四项覆盖率全 100%，`usb_crc5_byte` 的 expr 未覆盖点全是 13 输入组合锥里
填不满的组合（[verification](usb_sie_verification.md) §6.4）。

### 4.4 2 字节延迟线（一份延迟、两个职责）

问题：数据包长度靠 EOP 定界、事先未知，"哪两个字节是 CRC16"无从预知；同时净荷字节不能把
CRC 字节带进包缓冲。

设计做法（§2.5.3）：CRC16 引擎永远吃"延迟 2 字节"的流（收 `b(i)` 时喂 `d1 = b(i-2)`），
包尾再补喂留在 `d1`/`d2` 的两个字节；同一个延迟拍输出 `pl_byte`/`pl_byte_vld` 写包缓冲。
一份延迟逻辑同时解决 CRC 定界与净荷提取。

📎 [图：`pl_byte` 比 `rx_data` 晚 2 拍且不含 CRC（sie_crc_delay_line.png）](../fig/sie_crc_delay_line.png)

`byte_cnt` 走到 7..11，`rx_data` 末两字节是 CRC16，写口取的 `pl_byte` 是净荷；`wr_ptr` 4→8，
`pkt_done` 同拍 `buf_cnt=8`、`dat_crc_ok=1`。零长度包 `dat_len=0` 且不产生 `pl_byte_vld`、
64B 满包排出 64 字节逐字节对得上，也在同一用例里。

### 4.5 应答决策的优先级（"序列不匹配"高于"忙"）

问题：Table 8-4 各行有严格优先级，最容易写反的是"序列不匹配"与"忙"的先后。序列位不匹配时
（重复包去重），即使 FIFO 满也必须回 ACK，不能回 NAK，否则主机会一直重发同一 DATA0，
管道死锁（协议 §6.4 有完整推导）。

设计做法（§2.8）：决策写成有序三目链（坏包 → SETUP 分支 → 方向不符 → halt → 序列不匹配 →
忙 → 收下），不是并行 case。坏包永远是最高优先级，不响应，连 STALL 都不发。

📎 [图：序列不匹配压过忙（sie_resp_priority.png）](../fig/sie_resp_priority.png)

这一拍 `ep_nak_q=2`（EP1 报忙）、`dat_pid_is1=1` 而 `toggle_sel=0`，故 `toggle_match=0`；
`busy_sel=1` 同时成立，`dec` 仍是 1（ACK），`resp_pid=8'hD2`、`resp_req` 出一拍。同用例的
"CRC 错 + halt + 忙三者同挂"那一组 `pkt_bad=1`、`resp_req` 不拉。

### 4.6 SETUP 特例（强制接受 + toggle 置 1）

问题：SETUP 是唯一"不得 NAK、不得 STALL"的事务；且它同时承担"初始化收发序列位"的职责
（协议 §6.1）。非控制端点收到 SETUP 还必须忽略。

设计做法（§2.8/§2.9）：SETUP 走独立分支，不查 `ep_stall`/`ep_nak`/toggle。包好、PID 是 DATA0
且打在 EP0 上就无条件 ACK 加 `setup_recv` 脉冲，并把 `toggle[EP0]` 置 1；包坏、PID ≠ DATA0、
`ep_sel != EP0` 三情形都不应答。

📎 [图：halt 挂着仍回 ACK（sie_setup_special.png）](../fig/sie_setup_special.png)

`ep_stall_q=1`、`is_setup=1`、`ep_sel=0`，`pkt_done` 后 `dec=1`、`resp_pid=8'hD2`、`resp_req=1`，
同拍 `setup_recv=1`、`acc_setup=1`。

📎 [图：`toggle[EP0]` 由 0 置 1（sie_setup_toggle.png）](../fig/sie_setup_toggle.png)

`is_setup=1` 与 `ep_sel=0` 成立 → `acc_setup=1`、`tog_set=1`，`toggle` 由 0 变 1，`setup_recv`
一拍。非 EP0 与 PID ≠ DATA0 两情形在用例里各走一遍，都是 `resp_req` 不拉。

### 4.7 `T_DATA_WAIT` 可被新 TOKEN 打断（鲁棒性）

问题：主机在 token 后未必总发数据包（帧末、错误恢复、总线复位）。若状态机死等数据包，
会把下一事务的 token 误当数据包处理。

设计做法（§2.7.2）：分派规则统一为"先按包级结论分类，再按跳转表分派"。`T_DATA_WAIT` 收到
派发成立的 token 时自环并重新武装（覆盖 `ep_sel`/`is_setup`、计时器回 1），没有"等数据包"的
特例代码。

📎 [图：新 token 使计数回 1（sie_data_wait_break.png）](../fig/sie_data_wait_break.png)

`t_state_cur=3'h1` 里 `turn_cnt` 已爬到 6，新 token 的 `pkt_done` 与 `tok_dispatch` 同拍到达，
计数立刻回 1，`tok_endp` 0→2、`ep_sel` 1→2，`resp_req` 全程不动。

📎 [图：重新武装后新端点的数据包照收（sie_data_wait_ack.png）](../fig/sie_data_wait_ack.png)

同一数据阶段的后续：`ep_sel=2`、`pkt_done` 后 `dec=1`、`resp_pid=8'hD2`，`toggle` 翻的是 EP2
那位，`buf_cnt=4`。打断后的事务是完整的。

### 4.8 包缓冲：坏包对端点 FIFO 零污染

问题：CRC 只有在包尾才知道，而字节在收包期就到达，边收边推会让坏包污染 FIFO。

设计做法（§2.11）：收包期只写 SIE 内 `pkt_buf`；包尾校验通过且决策为"收下"才置
`buf_ready`，由 CDC 桥逐字节排出。坏包则 `wr_ptr` 回卷到 0、`buf_ready` 保持 0，
端点侧看不到任何字节。

📎 [图：`pkt_bad` 拍上不应答也不落地（sie_bad_pkt_isolate.png）](../fig/sie_bad_pkt_isolate.png)

`pkt_done` 拍上 `dat_crc_ok=0`、`pkt_bad=1`，于是 `dec=0`、`resp_req=0`、`buf_ready` 全程 0、
`buf_cnt` 全程 0；`wr_ptr` 停在 4，净荷进过内部缓冲但从未发布。紧随其后的好包照常 ACK 与排出。

### 4.9 `rx_abort` 溢出护栏

问题：包尾靠 EOP 定界。线缆故障导致 EOP 永不到来时，字节计数会无限增长。

设计做法（§2.6）：包级解析器自带字节计数与包类型长度上限（token 3 / handshake 1 /
data `3+max_payload` / 类别不明 67），越上限立即拉 `rx_abort`（回 deserial）。

📎 [图：溢出即中止，`rx_error` 保持 0（sie_rx_abort.png）](../fig/sie_rx_abort.png)

`byte_cnt=11` 与 `byte_limit=11` 相等，下一个字节到达时 `overflow=1`，`rx_abort` 抬起并保持到
`rx_active` 落，`rx_error` 全程 0，`pkt_bad=1`、`resp_req` 不拉。跟着的好包能收，说明中止标志
随 `rx_active` 落干净了。

### 4.10 周转超时（EOP 后 18 bit time）

问题：总线无显式错误信号，"没等到数据包"必须靠计时判断，否则状态机永久卡在 `T_DATA_WAIT`。

设计做法（§2.10）：`T_DATA_WAIT` 且总线空闲时 `turn_cnt` 以 `clk12m` 累加，到 15 判超时、
次拍回 `T_IDLE`、静默放弃（计数起点已在 EOP 后 2 拍，2+16 = 18 bit time）。任何包的
`rx_active`↑ 都清零计数器。

📎 [图：`turn_cnt` 计到 15 后回 `T_IDLE`（sie_turnaround.png）](../fig/sie_turnaround.png)

孤立 token 之后线上一片安静，`turn_cnt` 从 1 一格格爬到 15，到顶那一拍 `turn_done` 抬起、
`t_state_cur` 由 `3'h1` 回 `3'h0`，`resp_req` 全程为 0。

### 4.11 toggle 只在收下时翻转

📎 [图：DATA1 匹配、ACK、翻回 0（sie_toggle_seq.png）](../fig/sie_toggle_seq.png)

`dat_pid_is1=1`、`ep_sel=1`、`toggle_sel=1`、`toggle_match=1`，`dec=1`、`acc_evt=1`、
`resp_req=1`、`resp_pid=8'hD2`，`toggle` 由 2 变 0。序列不匹配（重复包）回 ACK 但不翻转、
NAK/STALL/坏包三类也不翻转，各在用例里有读数。

### 4.12 附着与 core 复位

📎 [图：`usb_rst` 清附着、`rcv` 落 0，重附着后回 1（sie_ctl_rst.png）](../fig/sie_ctl_rst.png)

`usb_rst` 一拍进来：`attached` 落 0、`rcv` 随之落 0，同拍 `t_state_cur` 由 `3'h1` 回 `3'h0`、
`toggle` 由 2 清 0、`buf_ready` 落 0、`buf_cnt` 由 8 清 0、`turn_cnt` 回 1。之后 `connect_evt`
一拍，`attached` 与 `rcv` 先后回 1，复位后能立刻重新收包。

### 4.13 三项时序量同时压到下限

📎 [图：8 拍/字节、尾 gap 0 下结论照出（sie_tail_tight.png）](../fig/sie_tail_tight.png)

`byte_period=8`（每字节恰好 8 拍）、`pkt_tail_gap=0`（末字节后立刻落 `rx_active`）、
`pkt_idle_gap=2`。图上 `byte_cnt` 走到 7 之后 `rx_active` 落，`tail_cnt` 走 0→1→2 补完两个 CRC
字节，`pkt_done` 一拍，`dec=1`、`acc_evt=1`、`resp_req=1`、`resp_pid=8'hD2`，`toggle` 由 0 变 2、
`buf_cnt` 跳到 4。

---

*上游源码（全在 `src/phy/`）：`usb_rx_deserial.v`、`usb_rx_cdr.v`、`usb_clk_mux.v`、`usb_bus_state.v`。
本模块源码：`src/sie/usb_sie.v`、`src/sie/usb_sie_pkt_rx.v`。
新增原语：`src/common/usb_crc5_byte.v`、`src/common/usb_crc16_byte.v`。*
