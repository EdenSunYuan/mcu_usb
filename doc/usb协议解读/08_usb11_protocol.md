# 08 — USB 1.1 第 8 章 协议层（Protocol Layer）精读笔记

> 来源：`docs/usb_1_1_spec.pdf` 第 8 章（原书 p.155–174）。
> 本章是 **SIE 的核心协议**：从位序、字段、包格式，到事务格式、数据翻转同步、错误检测恢复，全部直接决定 SIE 状态机的行为。
> 系列命名：`08_` = 协议第 8 章（与 `01_/02_/03_` 设计文档是两套独立序列）。上一章见 [[07_usb11_electrical]]。

---

## 1. 章节定位与整体结构

自底向上：字段定义 → 包格式 → 事务格式 → 链路层流控 → 事务级故障恢复 → 重试同步 / babble / 总线活动丢失恢复。

| 小节 | 内容 | 对 SIE 的意义 |
|------|------|---------------|
| 8.1–8.2 | 位序、SYNC | 位序 LSb 先发；SYNC 定 PID 起点 |
| 8.3 | 字段格式（PID/ADDR/ENDP/帧号/数据/CRC） | **SIE 解码/编码的全部字段定义** |
| 8.4 | 包格式（Token/SOF/Data/Handshake）+ 握手响应 | **SIE 收发包的状态机骨架** |
| 8.5 | 事务格式（Bulk/Control/Interrupt/ISO） | 端点类型 → 事务行为 |
| 8.6 | 数据翻转同步与重试 | **SIE 拥有 data_toggle 的完整规则** |
| 8.7 | 错误检测与恢复 | 错误类别、总线周转超时、false EOP、babble/LOA |

---

## 2. 位序与 SYNC（8.1 / 8.2）

- **位序**：LSb（最低位）先发，最后发 MSb。以下所有字段图都按"先发在前"画出。
- **SYNC**：NRZI 编码为 `KJKJKJKK`，8 bit。作用 = 最大边沿密度，供接收端对齐本地时钟。**最后两个 bit（KK）是"SYNC 结束、PID 开始"的标记**。
- SYNC 只做同步，不参与 CRC/包内容。

> **对应设计**：`usb_rx_deserial` 的 SYNC 检测 = 找「≥4 个 0 + 1」（NRZI 解码后，`80H` = 7×0+1）。命中后 `rx_active`↑，SIE 数 `rx_valid` 脉冲自判第一字节即 PID（deserial 不标包首，无 `rx_start`）。位序 LSb 先发 → 反序列化 `shift_reg` 右移入（LSb 先入），与第 7 章笔记一致。

---

## 3. 字段格式（8.3）

### 3.1 PID 字段（8.3.1）—— SIE 最重要的字段

- PID 紧跟 SYNC，= **4 bit 包类型 + 4 bit 校验**（校验 = 类型的按位取反 / one's complement）。
- PID 错误判定：校验位不是类型位的取反 → PID 错，**整包忽略**。
- 收到「校验失败」或「未定义值」的 PID → 包损坏，**连同剩余部分全部忽略**。
- 收到"合法但本端点不支持的类型/方向"（如 IN-only 端点收到 OUT）→ **不响应**。

#### PID 编码表（Table 8-1，附完整 8-bit 值）

| 组 | PID 名 | PID[3:0] | **完整字节值** | 说明 |
|----|--------|----------|----------------|------|
| Token | OUT | 0001 | **0xE1** | host→device 数据事务 |
| Token | IN | 1001 | **0x69** | device→host 数据事务 |
| Token | SOF | 0101 | **0xA5** | 帧起始 + 帧号 |
| Token | SETUP | 1101 | **0x2D** | host→控制端点初始化 |
| Data | DATA0 | 0011 | **0xC3** | 偶数据包 |
| Data | DATA1 | 1011 | **0x4B** | 奇数据包 |
| Handshake | ACK | 0010 | **0xD2** | 接收方无错收下数据 |
| Handshake | NAK | 1010 | **0x5A** | 暂不能收/暂不能发 |
| Handshake | STALL | 1110 | **0x1E** | 端点 halt / 控制请求不支持 |
| Special | PRE | 1100 | **0x3C** | host 前导，使能 LS 流量 |

> 完整字节值 = 校验位（高 4 bit，=类型取反）+ 类型位（低 4 bit）。发送时 bit0 先发。

#### PID 分组技巧（SIE 快速解码）

PID<1:0>（最低两 bit）直接决定分组：

| PID<1:0> | 组 |
|-----------|-----|
| 01 | Token（OUT/IN/SOF/SETUP） |
| 11 | Data（DATA0/DATA1） |
| 10 | Handshake（ACK/NAK/STALL） |
| 00 | Special（PRE） |

> **对应设计**：SIE 里 PID 解码可以两层——先看 PID<1:0> 判组，再完整比对待定 PID 字节值。4 bit 校验 = 类型取反，可用 `pid[7:4] == ~pid[3:0]` 校验。表里的 8-bit 值是 SIE 里 `localparam` 常量的直接来源。

### 3.2 地址字段（8.3.2）

- **ADDR[6:0]**（7 bit，128 个地址）+ **ENDP[3:0]**（4 bit，16 个端点）。
- **地址别名不允许**：ADDR 或 ENDP 任一不匹配 → **忽略该 token**；访问未初始化端点 → 忽略。
- 复位/上电后设备地址**默认 0**（default address），枚举时由 host 编程。
- ENDP 只用于 IN/SETUP/OUT token；**端点 0 = 默认控制管道**（所有设备必须支持）。
- FS 设备最多 16 个端点；LS 最多 3 个管道。

> **对应设计**：SIE 需全解码 ADDR + ENDP 并比对（`usb_addr` 寄存器 + 端点配置），失配即丢弃整 token，不做任何响应。地址 0 上电默认值即枚举期地址。

### 3.3 帧号字段（8.3.3）

- 11 bit，host 每帧递增，到 **0x7FF** 回卷，只在 SOF token 中发送。

### 3.4 数据字段（8.3.4）

- 0–1023 字节，**必须整数字节**，每字节内 LSb 先发。

### 3.5 CRC（8.3.5）

- CRC 保护**所有非 PID 字段**（PID 有自己的校验位，不参与 CRC）。
- **生成/校验顺序**：TX 在**位填充之前**生成 CRC；RX 在**去除填充位之后**校验 CRC。
- 种子 = **全 1**；每 bit：当前余数最高位 XOR 数据位 → 左移 → 低位补 0 → 若 XOR 为 1 则再 XOR 生成多项式。
- 发送端：校验字段最后一位发出前，**CRC 取反**后按 **MSb 先** 发出。
- 接收端：无错时余数 = **残差（residual）**，不等即 CRC 错。
- CRC 覆盖单/双 bit 错误 100%。

#### Token CRC（CRC5）

- 覆盖 IN/SETUP/OUT 的 ADDR+ENDP，或 SOF 的帧号字段。
- 生成多项式 **G(X) = X⁵ + X² + 1**，二进制 **0b00101**（0x05）。
- 无错残差 = **0b01100**（0x0C）。

#### Data CRC（CRC16）

- 覆盖数据字段。
- 生成多项式 **G(X) = X¹⁶ + X¹⁵ + X² + 1**，二进制 **0x8005**。
- 无错残差 = **0b1000000000001101**（0x800D）。

> **对应设计**：SIE 里 TX 路径 = 组包 → 算 CRC → 位填充 → NRZI；RX 路径 = NRZI 解码 → 去填充 → 算 CRC 比对残差。这与 `usb_rx_deserial`（只做 NRZI/去填充/字节对齐，**不做 CRC**）的职责边界一致——CRC 属于 SIE。残差 0x0C/0x800D 是 SIE 自检的魔法数。

---

## 4. 包格式（8.4）

| 包 | 组成 | 字节数 | EOP 要求 |
|----|------|--------|----------|
| **Token** | PID + ADDR(7) + ENDP(4) + CRC5 | 3 字节 | 3 字节后 EOP，否则无效 |
| **SOF** | PID + Frame Number(11) + CRC5 | 3 字节 | 同上 |
| **Data** | PID + DATA(0–1023) + CRC16 | 3–1026 字节 | 数据整数字节 |
| **Handshake** | PID | 1 字节 | 1 字节后 EOP，否则无效 |

- 只有 host 能发 token。IN = 设备→host 数据；OUT/SETUP = host→设备数据。
- **SOF**：host 每 1.000ms±0.0005ms 发一次，只含帧号。**不触发任何返回包**，投递不可保证。设备收到 SOF PID 即知"帧开始"；不需要帧号的设备（如 hub）可忽略帧号+CRC，只解码 PID。
- **Handshake**：只有支持流控的事务才返回握手；总是在事务握手阶段返回，也可在数据阶段取代数据返回。

### 三种握手（8.4.4）

- **ACK**：数据包无位填充错、无 CRC 错、数据 PID 正确。序列位匹配可收数据时发；或序列位不匹配需重同步时发（见 §6.4）。host 对 IN、设备对 OUT/SETUP 可回 ACK。
- **NAK**：设备暂不能收（OUT）或暂无数据发（IN）。**只有设备能发，host 永不发 NAK**。流控用途。
- **STALL**：设备响应 IN 或 OUT 数据阶段后发。表示端点 halt 或控制请求不支持。**host 永不发 STALL**。

### STALL 两种：功能 stall 与协议 stall（8.4.4 / 8.5.2.4）

STALL 由设备在两种**截然不同**的场合返回，二者在**含义**与**持续时间**上都不同（规范原文 "two distinct occasions"）：

| 维度 | 功能 stall（functional stall） | 协议 stall（protocol stall） |
|------|------|------|
| 触发条件 | 端点 **Halt 特性被置位** | 控制管道收到**不理解/不支持的请求或参数** |
| 含义 | 端点功能出错、无法收发数据 | **不是设备错误**，只表示"请求不懂"，是扩展请求的机制 |
| 适用管道 | bulk / interrupt 端点（控制管道也可但不推荐） | **仅控制管道** |
| 持续时间 | **持续**，直到 host 干预清除 | **下一 SETUP 开始即自动终止** |
| 清除方式 | host 发 ClearFeature(ENDPOINT_HALT) 清 Halt | 无需显式清除，收到下一 SETUP 自动清 |
| STALL 后行为 | 直到 Halt 清除，对该端点任何 IN/OUT 都回 STALL | 直到 SETUP，对该管道任何 IN/OUT 都回 STALL |

**功能 stall 详解**：端点 Halt 特性被置位时发生（Halt 定义见第 9 章）。特例是 **命令 stall（commanded stall）**——host 显式用 `SetFeature(ENDPOINT_HALT)` 置起 Halt（第 9 章）。一旦端点 halt，**必须持续回 STALL**，直到引起 halt 的条件经 host 干预（`ClearFeature`）清除。功能 stall 意味着端点真的失去收发能力，是错误状态。

**协议 stall 详解**：仅控制管道。设备在控制传输的 Data 和/或 Status 阶段回 STALL，表示"无法完成该命令"（§8.5.2.4）。与功能 stall 不同，**协议 stall 不表示设备出错**，只表示"请求或其参数不被理解"，是扩展 USB 请求的机制。协议 stall 一旦发出，**直到收到下一个 SETUP PID**，对该控制端点后续所有访问都回 STALL；收到 SETUP 后条件自动终止。§5.2.4 详述。

**控制管道与功能 stall 的关系**：控制管道**可以**支持功能 stall，但**不推荐**——这是退化情形，因为控制管道功能 stall 意味着设备已失去与 host 通信的能力。若控制管道支持功能 stall，则必须拥有 Halt 特性（host 可置/清）。

### 握手响应规则（8.4.5）

- 若 token 传输到设备时出错 → 设备**不响应**，直到下一个 token 被成功解码。
- **设备响应 IN（Table 8-2）**：

| Token 损坏 | 端点 Halt | 能发数据 | 动作 |
|---|---|---|---|
| 是 | — | — | 不响应 |
| 否 | 置位 | — | STALL |
| 否 | 未置位 | 否 | NAK |
| 否 | 未置位 | 是 | 发数据包 |

- **host 响应 IN（Table 8-3）**：只能回 ACK。数据损坏→丢弃不响应；不能收→错误不响应；无错能收→ACK。
- **设备响应 OUT（Table 8-4，按优先级）**：

| 数据损坏 | 端点 Halt | 序列位匹配 | 能收 | 响应 |
|---|---|---|---|---|
| 是 | — | — | — | 无 |
| 否 | 置位 | — | — | STALL |
| 否 | 未置位 | 否 | — | ACK（丢弃数据） |
| 否 | 未置位 | 是 | 是 | ACK |
| 否 | 未置位 | 是 | 否 | NAK |

- **设备响应 SETUP（8.4.5.4）**：**必须接受数据，不得回 STALL/NAK**，数据包损坏则丢弃不响应。非控制端点收到 SETUP → 忽略、不响应。

> **对应设计**：Table 8-2 / 8-4 就是 SIE 收到 token 后"响应决策"逻辑的真值表。我们早先定的 `ep_stall`/`ep_nak` 控制信号（token 解码时采样，两者都不激活 = ACK/默认）正好落在这两张表上：stall→STALL，nak→NAK，否则按能否收发数据决定 DATA/ACK/NAK。SETUP 特例（强制接受、只回 ACK 或不响应）需单独处理。

---

## 5. 事务格式（8.5）

四种端点类型：bulk、control、interrupt、isochronous。

### 5.1 Bulk（8.5.1）

- 三阶段：token → data → handshake。流控/halt 时数据阶段被握手取代成两阶段。
- IN：host 发 IN，设备回 DATA0/1 或 NAK/STALL；host 收到好数据回 ACK，出错不回。
- OUT：host 发 OUT+DATA；设备回 ACK（收下）/NAK（暂不能收，host 重发）/STALL（halt，别重试）；CRC 或位填充错→不回。
- 数据翻转：bulk 端点配置事件时初始化 DATA0；短包/IRP 完成**不**直接初始化翻转。

### 5.2 Control（8.5.2）

- 最少两阶段：**Setup + Status**；可选中间 **Data** 阶段。
- **Setup 事务**：SETUP token，**数据始终用 DATA0**；设备必须接受并回 ACK，数据损坏则丢弃不响应。
- **Data 阶段**：同 bulk 规则；所有事务**同方向**（全 IN 或全 OUT）；超过包大小分多事务，余量在最后一事务。
- **Status 阶段**：方向与前一阶段**相反**，**始终用 DATA1**。Data 是 OUT → Status 是 IN；无 Data 阶段 → Setup + IN Status。
- 翻转序列（Fig 8-12）：
  - Control Write：SETUP(DATA0) → OUT(DATA1→DATA0→…) → IN(DATA1)
  - Control Read：SETUP(DATA0) → IN(DATA1→DATA0→…) → OUT(DATA1)
  - No-data：SETUP(DATA0) → IN(DATA1)

#### 5.2.1 Status 报告（Table 8-5）

| 结果 | Control Write（数据阶段回） | Control Read（握手阶段回） |
|---|---|---|
| 成功 | 零长度数据包 | ACK |
| 出错 | STALL | STALL |
| 忙 | NAK | NAK |

- Control Read 的 Status 阶段由 host 发 OUT（零长度）启动，设备回握手表状态。
- Control Write 的 Status 阶段由 host 发 IN 启动，设备回握手或零长度数据包表状态。

#### 5.2.2 变长数据阶段

- 数据结构返回完时，设备回**短于 MaxPacketSize 的包**；恰好整数倍则回**零长度包**结束 Data 阶段。

#### 5.2.3 最后一数据事务的错误处理

- 最后一个 IN 的 ACK 若损坏：host 会发 OUT 启动 Status；设备**把 Status 开始当作"host 已收下数据"的确认**（翻转重试机制在此不适用）。
- Control Write 无此歧义：OUT 的 ACK 损坏，host 不进入 Status，直接重试最后数据。

#### 5.2.4 控制管道的 STALL（协议 stall）

- 协议 stall ≠ 设备错误，只表示"请求/参数不理解"，是扩展请求的机制。
- 持续到**下一个 SETUP**；期间对该管道任何 IN/OUT 都回 STALL。
- 控制管道一般**不**支持功能 stall（退化情形，丧失通信能力）；Halt 特性应放非控制端点。

### 5.3 Interrupt（8.5.3）

- IN 或 OUT。IN：设备回 DATA0/1、NAK（无新中断）、或 STALL（halt）。host 收到好数据回 ACK，损坏不回。
- 中断数据走**数据翻转协议**（保证"事件已送达 host 才能清"，设备可只发到被确认）。
- 翻转模式：配置事件初始化 DATA0，行为同 bulk。
- 特殊模式（ISO 反馈）：翻转位**不管有无握手、每发一包就翻转**，仅 interrupt IN 支持。

### 5.4 Isochronous（8.5.4）

- **只有 token + data，无握手、无重试**。
- 设备/host **只发 DATA0**，但应能接受 DATA0/DATA1。**不支持翻转序列**。

> **对应设计**：我们 FS-only 设备控制器若只支持控制（枚举必需）+ 可能 bulk/interrupt，SIE 事务状态机按 §5.2/5.1/5.3 搭；ISO 若无需求可不实现。**SETUP 强制接受、Status 方向反转、DATA0/DATA1 翻转**是控制传输必须正确实现的三个坑。

---

## 6. 数据翻转同步与重试（8.6）

- DATA0/DATA1 PID + 独立收发序列位保证握手被双方正确解读。
- **接收方序列位**：只在"能收且收到无错且 PID 匹配"时翻转。
- **发送方序列位**：只在收到有效 ACK 时翻转。
- 收发序列位在事务开始必须同步。ISO 不支持翻转同步。

### 6.1 SETUP 初始化（8.6.1）

- SETUP 把 host 与设备的序列位都初始化。设备接受事务后**必须把序列位置为 1**（收发序列位在 SETUP 事务结束时都 =1）。→ 因此 SETUP 之后第一个 Data 事务用 **DATA1**。

### 6.2 成功事务（8.6.2）

- 发送方：收到 ACK 翻转。
- 接收方：数据 PID 匹配当前序列位且能收 → 收下并翻转。
- NAK → 双方序列位**不变**；两阶段（无数据）事务 → 不变。

### 6.3 数据损坏/不收（8.6.3）

- 收不下或损坏 → NAK/STALL/超时，接收方**不翻转**；发送方没收到 ACK **不翻转**。序列位保持同步，事务重试，成功后双方一起翻转。

### 6.4 ACK 损坏（8.6.4）

- ACK 丢失/损坏 → 收发短暂失同步。发送方下一事务**用原 PID 重发原数据**；接收方 PID 不匹配 → 知道是旧数据，**丢弃、不翻转，回 ACK**；发送方收到 ACK 翻转。下一事务双方重新同步。
- **关键约束**：发送方重发的数据包必须**与原事务逐字节相同**（长度+内容）。若因缓冲区 underrun 发不出相同数据，**必须人为制造位填充违例中止事务**（让接收方判错，保证半包不被当成好包），**不要**用"发一个坏 CRC"来制造错误（坏包+坏 CRC 可能被接收方误判为好包）。

**序列位不匹配（重复包）为什么回 ACK 而不是 NAK**：

这是"ACK 丢失/损坏"重传场景的接收端行为（§8.4.5.3 Table 8-4 第 3 行，优先级在流控之上）。逐步展开：

1. host 发 OUT DATA0（toggle=0）；设备收下、翻转（期待 DATA1）、回 ACK。
2. ACK 在线上丢了 → host 没等到 ACK，不翻转，用 **DATA0 重发**同一包。
3. 设备此时期待 DATA1，收到 DATA0 → **序列位不匹配**。
4. 设备认出"这是我上一包已收过的重复包" → **丢弃数据、不翻转、回 ACK**。
5. host 收到 ACK → 翻转，双方重新同步，继续 DATA1。

要点：
- **为什么不是 NAK**：NAK 表达"我忙、收不了、待会儿重试"——若此处回 NAK，host 会以为"设备没收到"，一直重发同一 DATA0，永远走不下去。ACK 才表达"协议上这单已成功、序列已对齐"；重复包靠"丢弃"去重。
- **优先级在流控之上**：Table 8-4 里"序列位不匹配"这一行的"能否接收"列是 **N/A**——即使设备 FIFO 满收不下，只要序列位不匹配，也照样回 ACK + 丢弃（数据本来就要丢，谈不上收不收得下）。NAK 只在"序列位匹配、但流控忙"时出现。
- **"丢弃"是去重，不是判错**：这包数据本身完好无损（CRC/位填充都对），只是"序列已前进、这是旧包"。与 §6.3 那种"数据损坏 → 不响应/NAK"是两码事，别在 SIE 状态机里混成一路。

### 6.5 低速事务（8.6.5）

- 所有发给 LS 设备的下行包需 **PRE 前导**（SYNC + PRE PID，全速发）。host 发完 PRE PID 后等 ≥4 全速 bit time 供 hub 使能 LS 端口。
- LS 限制：数据负载 ≤8 字节；只支持 interrupt/control；LS 设备不收 SOF。
- （我们 FS-only，此节仅记录，不实现。）

> **对应设计**：§6 完整定义了 SIE 的 data_toggle 状态机——早先架构决策"**SIE 拥有 data_toggle**，输出 `data_toggle` 读值，CPU 给 `toggle_set`+`toggle_val` 初始化"正好对应：TX 收 ACK 翻转、RX 收匹配 PID 翻转、SETUP 置 1。§6.4 的"重发必须逐字节相同，否则制造位填充违例中止"是 SIE TX 重试逻辑的硬约束。

---

## 7. 错误检测与恢复（8.7）

### 7.1 包错误类别（8.7.1，Table 8-6）

三种检测机制：**位填充违例**（§7.1.9）、**PID 校验位**（§8.3.1）、**CRC**（§8.3.5）。

| 字段 | 错误 | 动作 |
|------|------|------|
| PID | PID 校验、位填充 | 忽略整包 |
| 地址 | 位填充、地址 CRC | 忽略 token |
| 帧号 | 位填充、帧号 CRC | 忽略帧号字段 |
| 数据 | 位填充、数据 CRC | 丢弃数据 |

- 除 SOF 外，任何包损坏 → 接收方忽略、丢弃数据/字段。

### 7.2 总线周转时间（8.7.2）

- 无人发送"出错指示"，**"无 ACK"即出错指示**。所以 host/设备都要计时：从 EOP 的 SE0→J 沿起，到 Idle→K SOP 沿止。
- 设备超时：EOP 后 **不早于 16 bit time、不晚于 18 bit time**。host 若用超时表示错误，须等 ≥18 bit time 再发下一 token（确保下游设备都已超时）。
- 设备在 token↔data、data↔handshake 之间用；host 在 data↔handshake、token↔data 之间用。

**设备为什么需要这个定时器（容易误读为"只有 host 需要"）**：规范原文写死 **"Both devices and the host require turn-around timers"**。设备在两个间隙用它：

| 场景 | 设备在什么之间计时 | 在等什么 |
|------|------|------|
| OUT/SETUP | token ↔ data | 收到 token 后，等 host 发 DATA 包 |
| IN | data ↔ handshake | 发完 DATA 后，等 host 回 ACK |

核心原因：总线**没有显式错误信号**，"没收到 ACK"就是唯一错误指示。设备发完 IN 数据后，若 host 的 ACK 丢了/损坏，设备**不能无限等下去**，必须靠超时判断"我这次传输失败了"，然后序列位保持不翻转、进入"等 host 重发 token"。

具体例子（IN 传输，接 §6.4 的 ACK 损坏）：① host 发 IN token → ② 设备发 DATA0 → ③ host 的 ACK 在线上丢了 → ④ 设备等 16–18 bit time 没等到 ACK → 超时、判失败、序列位不动 → ⑤ host 也超时、重发 IN token → 设备重发 DATA0。**没有这个定时器，第 ④ 步设备会永远卡在等 ACK**，整条管道死掉。

时间值为何这么定：设备超时 = EOP 后不早于 16、不晚于 18 bit time；host 须等 **≥18 bit time** 再发下一 token，是为了**确保所有下游设备都已先超时**，避免 host 抢在设备放弃前发新 token 造成总线冲突。

### 7.3 假 EOP（False EOP，8.7.3）

- 假 EOP 会把当前包截断成 CRC 失败（最后 16 bit 恰好是正确 CRC 概率极低），由此识别。
- 设备见损坏数据包 → 不响应、等下个 token；设备发的数据包被假 EOP 损坏 → host 忽略不回握手，设备超时。
- host 收到损坏数据包 → 假定可能假 EOP，**等 16 bit time** 看是否有后续上行流量；无跳变且总线回到 Idle 才发下一 token。等 16 bit time 保证：(1) 设备已发完包（>6 bit 位填充间隔）；(2) 发送设备周转超时已过。时长与速度相关（FS 16 个 FS bit time）。

### 7.4 Babble 与活动丢失（8.7.4）

- **LOA**：SOP 后无总线活动（一直 J/K）、帧末无 EOP。
- **Babble**：SOP 后总线活动越过帧末。
- 两者都可能导致死锁或挤掉下一帧开头。**由 hub 负责检测恢复**（§11.8.1）：帧末未完成的传输，最近 hub 关掉该端口。

> **对应设计**：§7.2 的设备周转超时（16–18 bit time）是 SIE 的一个定时器；§7.3 假 EOP 由 CRC 失败兜底（SIE 只管 CRC，无需专门逻辑）；§7.4 babble/LOA 是 hub 职责，**设备端只需保证自己帧末前结束发送**（TX 侧要有时长/字节上限保护）。

---

## 8. 与 SIE 设计的对应关系（小结）

| 协议要求 | SIE 落地点 | 状态 |
|----------|-----------|------|
| PID 解码 + 校验（类型取反） | SIE PID 比较器（0xE1/0x69/0xA5/0x2D/0xC3/0x4B/0xD2/0x5A/0x1E） | ⬜ 待设计 |
| ADDR+ENDP 全解码失配忽略 | 地址/端点比较器 | ⬜ 待设计 |
| CRC5/CRC16（0x05/0x8005，残差 0x0C/0x800D） | SIE CRC 生成/校验（TX 填充前、RX 去填充后） | ⬜ 待设计 |
| Token 3 字节 / Handshake 1 字节 EOP | SIE 字节计数 + EOP 判定 | ⬜ 待设计 |
| 握手响应真值表（Table 8-2/8-4） | SIE 响应决策（ep_stall/ep_nak → STALL/NAK/ACK/DATA） | 已定架构 |
| SETUP 强制接受 + DATA0 + 序列位置 1 | SIE 控制传输状态机 | ⬜ 待设计 |
| Control Status 方向反转 + DATA1 | SIE 控制传输状态机 | ⬜ 待设计 |
| 数据翻转（TX 收 ACK / RX 收匹配 PID） | SIE data_toggle 状态机 | 已定架构 |
| 重发必须逐字节相同 / 违例中止 | SIE TX 重试逻辑 | ⬜ 待设计 |
| 设备周转超时 16–18 bit time | SIE 周转定时器 | ⬜ 待设计 |

---

## 附：关键常量速查（SIE 实现用）

```verilog
// PID 字节值 (bit0 先发, 高4位=校验=~低4位)
localparam PID_OUT   = 8'hE1;
localparam PID_IN    = 8'h69;
localparam PID_SOF   = 8'hA5;
localparam PID_SETUP = 8'h2D;
localparam PID_DATA0 = 8'hC3;
localparam PID_DATA1 = 8'h4B;
localparam PID_ACK   = 8'hD2;
localparam PID_NAK   = 8'h5A;
localparam PID_STALL = 8'h1E;
localparam PID_PRE   = 8'h3C;

// CRC
localparam CRC5_POLY  = 5'h05, CRC5_RESID  = 5'h0C;
localparam CRC16_POLY = 16'h8005, CRC16_RESID = 16'h800D;
```
