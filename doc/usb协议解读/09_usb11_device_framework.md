# 第九章 USB 设备框架（Device Framework）精读笔记

> 规范：Universal Serial Bus Specification Revision 1.1, Chapter 9
> 定位：本设计为 FS-only（12Mbps）**设备**控制器，本章直接对应 **EP0 控制端点（Default Control Pipe）** 的实现——设备状态机、标准请求解析、描述符返回、枚举流程。是继第 7 章（电气）、第 8 章（协议）之后，SIE/系统层之上"功能框架"层的核心依据。

---

## §1 章节定位

第 7 章讲"信号怎么在线上传"（电气），第 8 章讲"包怎么组帧/校验/握手"（协议层）。第 9 章讲的是**设备作为一台机器，如何被主机"认识、配置、使用"**：

- 设备有哪些**可见状态**（Attached/Powered/Default/Address/Configured/Suspended），状态如何迁移；
- 主机如何通过**总线枚举**把一台刚插入的设备一步步带到可用状态；
- 设备必须响应的一组**标准请求**（Setup 包格式 + 11 个标准请求）；
- 设备如何用**描述符**向主机自报属性；
- 这些对**设备控制器**而言，就是 **EP0 控制端点状态机 + Setup 解析 + 描述符 ROM** 要实现的东西。

规范把设备分三层（见 §2），本章聚焦"中间层"（端点的路由与通用操作）。对硬件设计者，本章的落点非常具体：**把 §9.1 状态机、§9.4 标准请求、§9.6 描述符翻译成 EP0 的寄存器与状态机**。

---

## §2 设备三层次模型

| 层 | 职责 | 硬件对应 |
|----|------|----------|
| 底层 | 总线接口：收/发包 | PHY（NRZI/CDR/EOP/SE0）+ SIE 组帧 |
| 中间层 | 数据在总线接口与各端点之间路由 | EP0 控制逻辑 + 各端点 FIFO + 端点寄存器 |
| 顶层 | 设备功能（鼠标/ISDN 等） | 应用/功能逻辑（本设计以通用控制器为主） |

> 本章描述的是**中间层**的通用属性与操作——所有 USB 设备都共享的那部分，正是控制器 RTL 要固化的部分。

---

## §3 设备状态机（§9.1）

### §3.1 六个可见状态（Table 9-1）

| 状态 | Attached | Powered | Default | Address | Configured | Suspended | 含义 |
|------|:---:|:---:|:---:|:---:|:---:|:---:|------|
| Attached 态（未接） | No | — | — | — | — | — | 未接入 USB，其余属性无意义 |
| Powered 态（已接未供电） | Yes | No | — | — | — | — | 已接入但 VBUS 未上电 |
| 已接已供电未复位 | Yes | Yes | No | — | — | — | 已上电但尚未被 reset |
| Default 态 | Yes | Yes | Yes | No | — | — | 已 reset，未分配地址，用**默认地址 0** 应答 |
| Address 态 | Yes | Yes | Yes | Yes | No | — | 已分配唯一地址，未配置 |
| Configured 态 | Yes | Yes | Yes | Yes | Yes | No | 已配置，主机可使用其功能 |
| Suspended 态 | Yes | Yes | — | — | — | Yes | ≥3ms 无总线活动（可叠加在 Address/Configured 上） |

**关键点**：
- **Default 态**：设备复位后、未分配地址前，只应答默认地址 0；在收到 reset 前**不得**响应任何总线事务。
- **Configured 态**：从设备视角，"配置"= 向设备配置寄存器写一个**非零值**（即 `SetConfiguration` 生效）。
- **Suspended 态**：是叠加态——有地址/已配置的设备都可以进入挂起；挂起期间保留地址与配置。
- **配置/切换 alternate setting 的副作用**：受影响接口内所有端点的状态与配置值回到默认值，**使用 data toggle 的端点其 toggle 复位为 DATA0**（§9.1.1.5）——这与 §8 的 SETUP 初始化序列位、以及 §9.4.5 ClearFeature(HALT) 复位 toggle 是三条不同的"toggle 归零"路径，设计时要分别处理。

### §3.2 状态迁移（Figure 9-1）

```
Attached --(attach+VBUS)--> Powered --(reset)--> Default
Default --(SetAddress=非零)--> Address --(SetConfiguration=非零)--> Configured
Configured --(SetConfiguration=0)--> Address
Address --(SetAddress=0)--> Default
任意 --(reset)--> Default
任意 Powered+ --(总线空闲>3ms)--> Suspended --(总线活动)--> 原状态
```

**reset 是一票回到 Default 的万能复位**：无论设备在 Address 还是 Configured 态，收到 reset 都回 Default。

### §3.3 总线枚举流程（Bus Enumeration，§9.1.2）

设备插入已供电端口后，主机侧标准流程（对设备设计者，**要理解主机在等什么、设备要承受什么**）：

1. Hub 通过其 status change pipe 通知主机（此时设备处于 Powered 态，端口被 disable）。
2. 主机查询 Hub 确认变化性质。
3. 主机**至少等 100ms**，让插入过程完成、设备电源稳定。
4. 主机对端口发 enable + reset 命令；Hub 维持 reset 信号 **10ms**。
5. reset 释放 → 端口使能 → 设备进入 **Default 态**，最多只能从 VBUS 取 **100mA**，寄存器/状态全复位，只应答默认地址。
6. 主机分配唯一地址（`SetAddress`）→ 设备进 **Address 态**。
7. 主机在分配地址前通过默认地址读**设备描述符**（得知 EP0 最大包长 `bMaxPacketSize0`）。
8. 主机读配置信息（configuration 0..n-1），可能耗时数 ms。
9. 主机依配置选一个配置值（`SetConfiguration`）→ 设备进 **Configured 态**，端点按描述符特性工作，可取的 VBUS 电流=描述符中的 MaxPower。设备从自身视角"就绪可用"。

> 设备被拔出：Hub 通知主机，端口被 disable，主机更新本地拓扑。

**设计映射**：设备 RTL 要能承受"reset（10ms SE0）→ 默认地址应答 → SetAddress → 读描述符 → SetConfiguration"这一整套，且 reset 后 100mA 限流、状态清零。

---

## §4 通用设备操作（§9.2）

### §4.1 动态插拔（§9.2.1）

设备可随时插入/拔出，Hub 负责上报端口状态变化。主机检测到插入后使能端口（同时复位设备）。**复位后的设备特征**：
- 应答默认地址 0；
- 未配置；
- 初始不挂起。

### §4.2 地址分配（§9.2.2）

主机在 reset + 端口使能后分配唯一地址。设备用 `SetAddress` 生效。

### §4.3 配置（§9.2.3）

- 设备可用前必须被配置（主机负责）。
- 一个配置可有多个**接口（interface）**；接口是"呈现单一功能的一组端点"。
- 接口可有**alternate setting**，重定义端点数/特性；有此能力的设备必须支持 `GetInterface`/`SetInterface`。
- 接口号 0..(并发接口数-1)；alternate setting 0..(该接口 setting 数-1)；**初始配置默认 alternate setting = 0**。
- 描述符中的 `Class/SubClass/Protocol` 字段用于自适应驱动识别设备类别。

### §4.4 数据传输（§9.2.4）

端点与主机之间四种传输方式（见第 5 章）。同一端点号在不同 alternate setting 下可用于不同传输类型；但**一旦选定某 setting（含默认），该端点只使用一种传输方式**，直到切换 setting。

### §4.5 电源管理（§9.2.5）

**电源预算（§9.2.5.1）**：
- **未配置前**：从 VBUS 取电 ≤ **1 个 unit load（100mA）**。
- **配置后**：依端口能力最多可到 5 个 unit load（500mA）。
- 挂起设备（无论配置与否）取电上限按第 7 章定义。

**远程唤醒（§9.2.5.2）**：挂起设备可用电气信号请求主机退出挂起（第 7 章 §7.1.7.5 的 resume 信号）。设备在配置描述符中声明是否支持；支持则必须能被标准请求使能/禁止；**设备 reset 后远程唤醒必须被禁止**。

### §4.6 请求处理（§9.2.6）与时序（§9.2.6.1~6.5）

**通用规则**：除 `SetAddress` 外，设备在 Setup 后返回 ACK 即可开始处理；必须在 Status 阶段成功完成前"完成"处理。长耗时操作由设备类另定义完成指示方式（避免主机轮询）。

**关键时序数字（设计必须满足）**：

| 项目 | 时限 |
|------|------|
| 请求处理上限 | **5 秒**（不普遍适用，见下） |
| Reset/Resume 恢复期 | 主机提供 **10ms** 恢复间隔，设备可忽略期间的数据传输；恢复期结束（reset 结束 / resume EOP 结束起算）后必须能随时接受传输 |
| SetAddress：完成 Status 阶段 | reset/resume 恢复期后 **50ms** 内 |
| SetAddress：恢复间隔 | Status 完成后 **2ms** 内必须能接受发往**新地址**的 Setup，且不得应答旧地址 |
| 标准请求（无 Data 阶段） | 50ms 内完成 Status |
| 标准请求（Data→主机） | 首个数据包 500ms 内；后续每包在前包完成后 500ms 内；最后包后 50ms 内完成 Status |
| 标准请求（Data→设备） | 适用 5 秒上限 |

**设计映射**：SetAddress 的"2ms 内切到新地址"是 EP0 状态机的一个硬约束——地址寄存器要在 Status 完成后才生效（见 §6.6）。

### §4.7 请求错误（§9.2.7）

收到未定义/不适用/参数不兼容的请求 = Request Error。设备在**下一个 Data 阶段事务或 Status 阶段**返回 **STALL**（优先在 Data 阶段返回，减少总线占用）。

> 收到非法请求**不会**置起控制管道的 Halt 特性。若设备因错误条件无法通过 Default Control Pipe 通信，必须 **reset** 才能清除并重启该管道。

---

## §5 设备请求格式（§9.3 Setup 包）

所有设备请求都通过 **Default Control Pipe** 用**控制传输**完成。Setup 包**固定 8 字节**，字段由主机填充（Table 9-2）：

| Offset | 字段 | 大小 | 说明 |
|:---:|------|:---:|------|
| 0 | **bmRequestType** | 1 | 请求特征位图 |
| 1 | **bRequest** | 1 | 具体请求（标准请求见 Table 9-3） |
| 2 | **wValue** | 2 | 随请求变化的参数字 |
| 4 | **wIndex** | 2 | 索引/偏移，常用于指定接口或端点 |
| 6 | **wLength** | 2 | Data 阶段的字节数（0 = 无 Data 阶段） |

### §5.1 bmRequestType（§9.3.1）

| 位 | 字段 | 取值 |
|:---:|------|------|
| D7 | **Direction** | 0 = 主机→设备（OUT）；1 = 设备→主机（IN） |
| D6..5 | **Type** | 0 = Standard；1 = Class；2 = Vendor；3 = Reserved |
| D4..0 | **Recipient** | 0 = Device；1 = Interface；2 = Endpoint；3 = Other；4..31 = Reserved |

- Direction 指定控制传输第二阶段的数据方向；**wLength=0 时 Direction 位被忽略**（无 Data 阶段）。
- Type + bRequest 共同决定请求含义；标准请求只当 Type=0 时定义。
- Recipient 指定请求对象；指向接口/端点时用 wIndex 标识。

### §5.2 wIndex 格式

- **指定端点（Figure 9-2）**：D0..3 = 端点号，D7 = 方向（0=OUT，1=IN），其余保留为 0。控制管道方向位应设 0（设备可接受任一值）。
- **指定接口（Figure 9-3）**：D0..7 = 接口号，D8..15 保留为 0。

### §5.3 wLength（§9.3.5）

- 指定控制传输第二阶段数据长度；=0 则无数据传输阶段。
- **IN 请求**：设备返回数据**不得超过** wLength（可少）。
- **OUT 请求**：wLength 总是主机将发送的确切字节数；主机多发数据时设备行为未定义。

---

## §6 标准设备请求（§9.4）

设备**无论是否已分配地址、是否已配置，都必须响应标准设备请求**。

### §6.1 标准请求总表（Table 9-3）

| bmRequestType | bRequest | wValue | wIndex | wLength | Data |
|------|------|------|------|------|------|
| 00000000B/01B/10B | **CLEAR_FEATURE** | Feature Selector | Zero/Interface/Endpoint | Zero | None |
| 10000000B | **GET_CONFIGURATION** | Zero | Zero | One | Configuration Value |
| 10000000B | **GET_DESCRIPTOR** | Type + Index | Zero 或 Language ID | Descriptor Length | Descriptor |
| 10000001B | **GET_INTERFACE** | Zero | Interface | One | Alternate Interface |
| 10000000B/01B/10B | **GET_STATUS** | Zero | Zero/Interface/Endpoint | Two | Device/Interface/Endpoint Status |
| 00000000B | **SET_ADDRESS** | Device Address | Zero | Zero | None |
| 00000000B | **SET_CONFIGURATION** | Configuration Value | Zero | Zero | None |
| 00000000B | **SET_DESCRIPTOR** | Type + Index | Zero 或 Language ID | Descriptor Length | Descriptor |
| 00000000B/01B/10B | **SET_FEATURE** | Feature Selector | Zero/Interface/Endpoint | Zero | None |
| 00000001B | **SET_INTERFACE** | Alternate Setting | Interface | Zero | None |
| 10000010B | **SYNCH_FRAME** | Zero | Endpoint | Two | Frame Number |

### §6.2 标准请求码（Table 9-4）

| bRequest | 值 | | bRequest | 值 |
|------|:---:|---|---|:---:|
| GET_STATUS | 0 | | SET_DESCRIPTOR | 7 |
| CLEAR_FEATURE | 1 | | GET_CONFIGURATION | 8 |
| (保留) | 2 | | SET_CONFIGURATION | 9 |
| SET_FEATURE | 3 | | GET_INTERFACE | 10 |
| (保留) | 4 | | SET_INTERFACE | 11 |
| SET_ADDRESS | 5 | | SYNCH_FRAME | 12 |
| GET_DESCRIPTOR | 6 | | | |

### §6.3 描述符类型（Table 9-5）

| 描述符类型 | 值 |
|------|:---:|
| DEVICE | 1 |
| CONFIGURATION | 2 |
| STRING | 3 |
| INTERFACE | 4 |
| ENDPOINT | 5 |

### §6.4 标准特性选择子（Table 9-6）

| Feature Selector | Recipient | 值 |
|------|------|:---:|
| DEVICE_REMOTE_WAKEUP | Device | 1 |
| ENDPOINT_HALT | Endpoint | 0 |

**非法请求的统一响应**：设备在 Data/Status 阶段返回 STALL；若在 Setup 阶段就检测到错误，**优先在较早的 Data 或 Status 阶段**返回 STALL。非法请求**不置 Halt**。

### §6.5 各请求要点（§9.4.1~9.4.11）

| 请求 | 核心行为 |
|------|------|
| **ClearFeature** | 清除/禁止特性。`ENDPOINT_HALT` 清除后端点不再 STALL，且 **data toggle 复位为 DATA0**（§9.4.5） |
| **GetConfiguration** | 返回当前配置值；未配置返回 0。Address 态返回 0 |
| **GetDescriptor** | wValue 高字节=类型、低字节=索引；wIndex 对字符串描述符=Language ID。描述符长于 wLength 只返回前段；短于 wLength 用**短包**（short packet / NULL data packet）结束传输。配置描述符请求返回"配置+所有接口+端点"整段。设备必须有 device descriptor 和至少一个 configuration descriptor |
| **GetInterface** | 返回指定接口当前 alternate setting |
| **GetStatus** | 按 recipient 返回状态（见下方 3 个图） |
| **SetAddress** | 设设备地址（见 §6.6 特殊时序） |
| **SetConfiguration** | wValue 低字节=配置值；0=回 Address 态；匹配某配置描述符值=选中该配置进 Configured 态 |
| **SetDescriptor** | 更新/新增描述符（可选支持） |
| **SetFeature** | 设置/使能特性。`DEVICE_REMOTE_WAKEUP`=使能远程唤醒；`ENDPOINT_HALT`=置 halt |
| **SetInterface** | 选择 alternate setting |
| **SynchFrame** | 仅等时传输用，报告/重启同步帧号 |

**GetStatus 返回的 16-bit 状态**：

- **Device（Figure 9-4）**：D0=**Self Powered**（0=bus-powered，1=self-powered，不可被 SetFeature/ClearFeature 改变）；D1=**Remote Wakeup**（0=禁止，1=使能；默认禁止；reset 后归零）；其余保留为 0。
- **Interface（Figure 9-5）**：全部保留为 0。
- **Endpoint（Figure 9-6）**：D0=**Halt**（0=未 halt，1=已 halt）；其余保留为 0。Halt 特性对 interrupt/bulk 端点**必须**实现。

**Halt 特性要点**（§9.4.5，EP0 设计关键）：
- Halt 对 interrupt/bulk 端点必须实现；对 Default Control Pipe **不要求也不推荐**，但设备可置它来反映功能错误。
- 置 Halt 后，标准请求到该管道会 STALL（除 `GetStatus`/`SetFeature`/`ClearFeature` 三个例外）。
- `ClearFeature(ENDPOINT_HALT)` **无条件**把 data toggle 复位为 DATA0。
- Halt 在 `SetConfiguration`/`SetInterface` 后**复位为 0**（即使配置值/接口与当前相同）。

### §6.6 SetAddress 的特殊时序（§9.4.6）

**这是所有请求中唯一"Status 阶段完成后才生效"的请求**：

- 三个阶段：Setup →（可选）Data → Status；**Setup 之后的阶段沿用 Setup 的地址**。
- 设备在 **Status 阶段成功完成后才改地址**（其余请求是"Status 前完成操作"）。
- 地址 >127、或 wIndex/wLength 非零 → 行为未定义。
- 设 0 的行为未定义。
- 状态迁移：Default 态收非零 → Address 态；收 0 → 留在 Default 态（非错误）。Address 态收 0 → Default 态；收非零 → 留 Address 态但用新地址。

**设计映射（硬约束）**：EP0 地址寄存器必须**锁存在 Status 阶段完成沿**，不是 Setup 收到时；配合 §4.6 的"2ms 内切新地址、不得应答旧地址"。

---

## §7 描述符（§9.5 / §9.6）

### §7.1 通用结构（§9.5）

- 每个描述符开头是**长度字节 + 类型字节**。
- 字符串引用字段为 0 表示无字符串描述符（字符串可选，引用字段**必填**）。
- 返回的长度字段小于规范定义 → 无效，主机应拒绝；大于 → 多出的字节被主机忽略，但**下一个描述符按返回长度定位**（而非期望长度）。
- 类/厂商特定描述符可：① 与标准描述符交织（有标准长度+类型头）随配置信息返回；② 独立格式用 `GetDescriptor` 指定类型+索引取回。

### §7.2 设备描述符（Table 9-7，18 字节）

| Offset | 字段 | 大小 | 说明 |
|:---:|------|:---:|------|
| 0 | bLength | 1 | =18 |
| 1 | bDescriptorType | 1 | =1 (DEVICE) |
| 2 | bcdUSB | 2 | BCD 版本号（**USB 1.1 = 0x0110**；2.10 → 0x210） |
| 4 | bDeviceClass | 1 | 类码（0=按接口独立；1..0xFE=聚合类；0xFF=厂商特定） |
| 5 | bDeviceSubClass | 1 | 子类码（bDeviceClass=0 时须为 0） |
| 6 | bDeviceProtocol | 1 | 协议码（0xFF=厂商特定） |
| 7 | bMaxPacketSize0 | 1 | **EP0 最大包长，仅 8/16/32/64 合法** |
| 8 | idVendor | 2 | 厂商 ID |
| 10 | idProduct | 2 | 产品 ID |
| 12 | bcdDevice | 2 | 设备版本号（BCD） |
| 14 | iManufacturer | 1 | 厂商字符串索引 |
| 15 | iProduct | 1 | 产品字符串索引 |
| 16 | iSerialNumber | 1 | 序列号字符串索引 |
| 17 | bNumConfigurations | 1 | 配置数量 |

**关键点**：`bMaxPacketSize0` 直接决定 EP0 的 FIFO/包长上限；FS 设备常用 8/16/32/64。设备仅有一个 device descriptor。

### §7.3 配置描述符（Table 9-8，9 字节）

| Offset | 字段 | 大小 | 说明 |
|:---:|------|:---:|------|
| 0 | bLength | 1 | =9 |
| 1 | bDescriptorType | 1 | =2 (CONFIGURATION) |
| 2 | wTotalLength | 2 | 本配置返回的**全部**描述符总长（含配置+接口+端点+类/厂商） |
| 4 | bNumInterfaces | 1 | 接口数 |
| 5 | bConfigurationValue | 1 | 供 SetConfiguration 选中的值 |
| 6 | iConfiguration | 1 | 配置字符串索引 |
| 7 | bmAttributes | 1 | D7=1（保留必须置 1）；D6=自供电；D5=远程唤醒；D4..0=0 |
| 8 | MaxPower | 1 | 最大取电，**2mA 单位**（50=100mA） |

### §7.4 接口描述符（Table 9-9，9 字节）

| Offset | 字段 | 大小 | 说明 |
|:---:|------|:---:|------|
| 0 | bLength | 1 | =9 |
| 1 | bDescriptorType | 1 | =4 (INTERFACE) |
| 2 | bInterfaceNumber | 1 | 接口号（从 0 起） |
| 3 | bAlternateSetting | 1 | alternate setting 选择值 |
| 4 | bNumEndpoints | 1 | 本接口端点数（**不含 EP0**；0=只用 Default Control Pipe） |
| 5 | bInterfaceClass | 1 | 类码（0=保留待标准化；0xFF=厂商特定） |
| 6 | bInterfaceSubClass | 1 | 子类码 |
| 7 | bInterfaceProtocol | 1 | 协议码 |
| 8 | iInterface | 1 | 接口字符串索引 |

> 接口描述符总是随配置描述符返回，**不能**用 GetDescriptor/SetDescriptor 直接访问。

### §7.5 端点描述符（Table 9-10，7 字节）

| Offset | 字段 | 大小 | 说明 |
|:---:|------|:---:|------|
| 0 | bLength | 1 | =7 |
| 1 | bDescriptorType | 1 | =5 (ENDPOINT) |
| 2 | bEndpointAddress | 1 | D3..0=端点号；D7=方向（0=OUT，1=IN；控制端点忽略） |
| 3 | bmAttributes | 1 | D1..0=传输类型：00=Control，01=ISO，10=Bulk，11=Interrupt |
| 4 | wMaxPacketSize | 2 | 最大包长 |
| 6 | bInterval | 1 | 轮询间隔（ms）。ISO 必须=1；Interrupt=1..255；bulk/control 忽略 |

> 端点描述符总是随配置信息返回，**不能**直接访问；**永远没有 EP0 的端点描述符**。

### §7.6 字符串描述符（§9.6.5）

- 可选。字符串索引 0 返回设备支持的 **LANGID 数组**（Table 9-11）；无字符串描述符的设备不得返回 LANGID 数组。
- UNICODE 字符串描述符（Table 9-12）：bLength + 类型 + bString（UNICODE 编码，**非 NULL 结尾**）。
- 字符串长度 = bLength − 2。

---

## §8 设备类定义（§9.7）

标准化一个设备类需定义三部分：描述符（标准描述符的类特定约束 + 扩展描述符）、接口与端点用法、类特定请求。所有设备都必须支持本章的请求与描述符；类在此之上扩展。

---

## §9 与设计对应关系（EP0 控制端点实现映射）

本章内容直接落到 EP0 状态机与寄存器设计：

| 规范要求 | 设计落点 | 状态 |
|---------|---------|:---:|
| §9.1 设备状态机（Default/Address/Configured/Suspended） | EP0 顶层状态寄存器 `dev_state` + reset/SetAddress/SetConfiguration 迁移 | 待设计 |
| §9.1.1.6 Suspended：>3ms 无活动 | 与 §7 suspend 检测复用（注意与 J≥2.5µs connect、SE0≥2.5µs disconnect 区分） | 待设计 |
| §9.1.2 枚举：reset 后先默认地址、再 SetAddress | 复位后地址寄存器清零 → 默认地址 0 | 待设计 |
| §9.3 Setup 8 字节解析 | Setup 包解析器，锁存 bmRequestType/bRequest/wValue/wIndex/wLength | 待设计 |
| §9.4.6 SetAddress：Status 完成后才切地址 | 地址寄存器**锁存于 Status 完成沿**（非 Setup） | 待设计 |
| §9.4.5 GetStatus 三 recipient 状态 | 状态位组装（Self Powered / Remote Wakeup / Halt） | 待设计 |
| §9.4.5 ClearFeature(HALT) → toggle=DATA0 | 复用 §8 data_toggle 初始化路径 | 待设计 |
| §9.6 描述符返回 | 描述符 ROM（device + configuration 链 + interface + endpoint + string） | 待设计 |
| §9.4.3 短包结束传输 | SIE 短包检测（< wMaxPacketSize 或 NULL） | §8 已覆盖 |
| §9.4.5 Halt（interrupt/bulk 必须实现） | `ep_stall` 端点控制位（§8 已定义） | §8 已覆盖 |

**两个必须记住的设计决定/注意点**：
1. **插拔/复位检测按用户指定方案**（J≥2.5µs=connect，SE0≥2.5µs=disconnect+reset），见 `doc/07_usb11_electrical.md` §12、§15，与本章 §9.1.2 主机侧枚举流程区分——设备侧自行做线状态检测。
2. **SetAddress 生效时机**：这是 EP0 最容易出 bug 的点——地址必须等 Status 阶段完成才生效，且 2ms 内切新地址。

---

## 附：Verilog 常量（EP0 标准请求码/描述符类型/特性选择子）

```verilog
// ---- 标准请求码（Table 9-4, bRequest）----
localparam REQ_GET_STATUS        = 8'h00;
localparam REQ_CLEAR_FEATURE     = 8'h01;
localparam REQ_SET_FEATURE       = 8'h03;
localparam REQ_SET_ADDRESS       = 8'h05;
localparam REQ_GET_DESCRIPTOR    = 8'h06;
localparam REQ_SET_DESCRIPTOR    = 8'h07;
localparam REQ_GET_CONFIGURATION = 8'h08;
localparam REQ_SET_CONFIGURATION = 8'h09;
localparam REQ_GET_INTERFACE     = 8'h0A;
localparam REQ_SET_INTERFACE     = 8'h0B;
localparam REQ_SYNCH_FRAME       = 8'h0C;

// ---- 描述符类型（Table 9-5）----
localparam DESC_DEVICE        = 8'h01;
localparam DESC_CONFIGURATION = 8'h02;
localparam DESC_STRING        = 8'h03;
localparam DESC_INTERFACE     = 8'h04;
localparam DESC_ENDPOINT      = 8'h05;

// ---- 特性选择子（Table 9-6, wValue）----
localparam FEAT_ENDPOINT_HALT      = 16'h0000;  // Recipient = Endpoint
localparam FEAT_DEVICE_REMOTE_WAKEUP = 16'h0001; // Recipient = Device

// ---- bmRequestType 位域（Table 9-2）----
//   D7    : Direction (0=H2D/OUT, 1=D2H/IN)
//   D6..5 : Type (0=Standard, 1=Class, 2=Vendor, 3=Reserved)
//   D4..0 : Recipient (0=Device, 1=Interface, 2=Endpoint, 3=Other)
localparam RT_DIR_IN       = 7;   // bmRequestType[7]
localparam RT_TYPE_STD     = 2'b00;
localparam RT_TYPE_CLS     = 2'b01;
localparam RT_TYPE_VND     = 2'b10;
localparam RT_RECIP_DEV    = 5'd0;
localparam RT_RECIP_IFACE  = 5'd1;
localparam RT_RECIP_EP     = 5'd2;

// ---- GetStatus 返回状态位（Figure 9-4/9-6）----
// Device  : D0=Self Powered, D1=Remote Wakeup
// Endpoint: D0=Halt
localparam ST_DEV_SELF_POWERED  = 16'h0001;
localparam ST_DEV_REMOTE_WAKEUP = 16'h0002;
localparam ST_EP_HALT           = 16'h0001;
```
