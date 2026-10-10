# usb_dpll_phy 顶层集成验证报告

> 日期：2026-10-10（首版 2026-09-29）　结论：**18/18 PASS**，DUT `usb_dpll_phy` 覆盖率 toggle 92/92 = 100%
> 被测：`src/phy/usb_dpll_phy.v`（纯连线）+ 五个子模块一起编译，TB 只例化顶层。
> 仿真基建：`sim/phy/`（Makefile / TB / 18 个 case / README）。设计报告：`phy_design.md`。

本报告只答一个问题：五个子模块**接起来之后**还对不对。子模块各自的功能判据在它们的
验证报告里（`02_cdr_*` / `clk_mux_*` / `rx_deserial_*` / `tx_serial_*` / `bus_state_*`），
这里不重复，只在覆盖率一章交代两边数字的差值。

---

## 1. 这一层独有的三件事

1. **接线**。`rcv` 归 SIE 产生（PHY 不产）、`usb_rst` 在外面并好再进来、`line_s` 由
   `usb_rx_deserial` 采好转给 `usb_bus_state`、`tx_en` 组合直连 `usb_bus_state` 当 `driving`、
   `bus_suspended` 由 `usb_bus_state` 直送 `usb_tx_serial` 的唤醒旁路（本层内部线，不出端口）。
   任何一根接错、漏接、接反，用例至少挂一条（§4 逐条列了哪条挂哪根）。
2. **跨模块因果链**。一个包从 `rxdp`/`rxdn` 进来到字节流出去，中间过 CDR → clk_mux → deserial
   三级；时钟 MUX 的方向由 `rcv` 定，而 `rcv` 由附着状态与发送状态定。
3. **半双工互斥与换向**。`tx_active` 同时送 deserial，发送期间帧机被按在 idle，
   设备自己发的包不会被自己收下；而 TB 的 `bus_dp` 模型让 `tx_en=1` 时 DUT 的 `rxdp`
   输入读回自己驱的线，等于把「自己发的包」真摆在接收口上——互斥若漏接，`phy_tx_rx_turn`
   会当场把设备自己的包收成一帧（已用变异验证）。换向本身（`rcv` 两次翻转）也是这层的事：
   时钟源在收发之间来回换，换完还得能接住下一个包。

位级信号（`clk12m`/`rx_bit`/`dclk`/`line_s`）不跨出 PHY，TB 只从端口观察，不去戳内部。

## 2. 测试环境

六个源文件一起编（iverilog `-g2012 -Wall`），TB 只例化顶层一个模块。
TB 需要扮三件 PHY 之外的事，三件都必须有，少了整层不转：

| 事情 | TB 里的建模 | 为什么不在 PHY 里 |
|---|---|---|
| 主机/设备共用总线 | `bus_dp = tx_en ? (tx_se0 ? 0 : tx_bit) : rxdp` | 差分驱动器在模拟 PHY |
| `rcv` | `sie_attached` 由 `connect_evt` 置、由 `usb_rst` 清；`rcv = attached & ~(tx_active \| (sie_susp & sie_wkup))` | SIE 产生（`usb_sie_design.md` §1.3） |
| `usb_rst` | `swrst \| usb_bus_rst` | 芯片顶层那个或门 |

`rcv` 复位初值必须是 0（选 `clk12s`）：CDR 还没锁时 `dclk` 是死的，若初值是 1 则 `clk12m`
没有任何沿，整层起不来。`phy_reset_default` 就是查这条，所以每个用例都从冷 SE0 起。

激励模型（`phy_tasks.vh` + `sim/common/usb_pkt_tasks.vh`）按线上字节口径算期望值：
数据字段 LSB first 而 CRC 字段 MSB first，token 的 byte2 低 3 位是 `endp` 不是 CRC。

## 3. 用例与结果

18 条全过。每条用例的「因 → 变 → 果 + 前后文窗口 + 量化判据」写在文件头。

| 用例 | 考什么 | 关键实测 |
|---|---|---|
| `phy_reset_default` | 冷 SE0 下线没插：`clk12m` 起振、四个事件一个不报 | 100µs 内 1200 个 `clk12m` 沿，`dclk` 沿 0 |
| `phy_connect` | SE0→J：一次 `connect_evt`，时钟源换到 `dclk` | 事件在 J 满 2.5µs 后 1 拍内出，脉宽 1 拍 |
| `phy_suspend` | 连接后空闲 J 满 3ms | 2.9996ms 出 `suspend_evt`，再等 3ms 不重复 |
| `phy_resume` | 挂起中主机驱 K ≥2.5µs | 3µs 的 K 出 1 次 `resume_evt` |
| `phy_bus_rst` | 连接后长 SE0 | 出 `usb_bus_rst`；并进 `usb_rst` 后附着清，线回 J 重新报 connect |
| `phy_unplug_susp` | 挂起中拔出再插回 | 拔出出 `usb_bus_rst` 且挂起标志清 0；插回 `connect_evt` 计 2；插回后 3µs K 不报 resume |
| `phy_rx_token` | OUT token 整链复现 | 1 段 `rx_active`、3 字节、无错 |
| `phy_rx_data` | OUT token + DATA0 连发 | 2 段、3 + 11 字节，逐字节对 |
| `phy_rx_hshake` | 单字节握手包 ACK/NAK/STALL | 3 段各 1 字节（PID + EOP），无错、不串包 |
| `phy_rx_maxlen` | 64 字节净荷满长包 | 1 段 67 字节逐字节对，包时 48.9µs |
| `phy_rx_bad` | 截断包（无 EOP） | 字节仍 11 个且正确，`rx_error`=1；下一好包回 0 |
| `phy_rx_abort` | 收包中途 `rx_abort` | 中止段 5 字节 < 11，`rx_error`=0，之后好包照收 |
| `phy_rx_usb_rst` | 收包中途软复位 | 同上；且 `usb_rst` 清附着 → 第二次 connect |
| `phy_tx_line` | 发 4 字节包 | `tx_ready` 4 次、`tx_done` 1 次、EOP 的 SE0 = 8 个 ref 拍 |
| `phy_tx_driving` | 挂起中发包 | 线上保持主机 idle J，`tx_en` 恒 0；0 个 `resume_evt`、0 个 `usb_bus_rst` |
| `phy_tx_rx_turn` | 收 token → 发应答 → 收 DATA0 | `rcv` 各换向 1 次；换向后 11 字节包逐字节对；全程 124 沿 / 10.334µs |
| `phy_susp_wkup` | `bus_suspended`+`sie_wkup` 旁路 | 线驱 K、放开后交高阻，无 `tx_active` 参与 |
| `phy_clk_switch` | 40 趟时钟源来回切 | 每 2µs 窗口 24±1 个 `clk12m` 沿 |

### 3.1 冷启动：`rcv` 初值 0 是这层的启动条件

`phy_reset_default` 把线按在 SE0 上 100µs 不动。TB 在 `ref_clk` 域数到 1200 个 `clk12m`
上升沿（标称 100µs × 12MHz = 1200），`dclk` 沿 0（CDR 没被任何跳变激起）。
因果链：`ref_rstn` 撤除后 `clk12s` = `ref_clk`÷4 起振 → `rcv` 初值 0 选中它 → `clk12m` 有沿
→ SIE 能起振。若 `rcv` 初值给 1，整段静默，用例第一条就挂。

### 3.2 连接与时钟源切换

`phy_connect`：J 保持 2.5µs 出 `connect_evt`（脉宽 1 个 `clk12m` 拍），同一时刻 CDR 被这次
跳变激起，`clk12m` 从 `clk12s` 换到 `dclk`，之后 100µs 仍是 1200 个沿，说明换完还是 12MHz。

`phy_clk_switch` 把这条压到极限：20 趟 × 2 个方向，每趟在 2µs 窗口里数 `clk12m` 上升沿，
要求 23~25 个（标称 24）。多一个沿就是切换处冒了毛刺，少一个就是吃掉半个周期。
40 趟全落在窗口内，且期间不报任何总线事件（`rcv` 与总线事件是两套判据）。

只靠 `rcv` 翻不出这个激励：用例用 `sie_susp & sie_wkup` 把 `driving` 拉高再放开，
于是不拆总线也能来回切方向。

### 3.3 四个事件脉冲：次数与宽度一起查

四个事件都查「次数对」和「脉宽 = 1 个 `clk12m` 拍」两件事。脉宽查的是
「一次判据只出一个脉冲」的反面：若脉冲是电平而不是单拍，下游 SIE 会重复计数。

`phy_bus_rst` 里同一根线走了两段：长 SE0 出 `usb_bus_rst`（脉宽 1 拍），
这个脉冲在 TB 里并进 `usb_rst`，清掉附着；线回 J 后再报第二次 `connect_evt`。
一条用例同时验了复位事件、复位对附着的效果、以及重附着。

### 3.4 RX：字节级复现与「段」的口径

TB 把 `rx_active` 的一段高电平叫一段，记下字节数与 `rx_error`，按 `rx_active` 下降沿归档。
连发两包时前一包会被后一包顶掉，所以留了 4 条环形历史，用例按下标回看。

`phy_rx_data` 两段分别 3 与 11 字节（PID + 8 净荷 + 2 CRC16），逐字节与期望值比。
期望值算的是**线上字节**：CRC16 字段按 MSB first 反向摆位后才是接收字节，这一条是这层
最容易搞错的地方。

`phy_rx_bad` 用截断包（发完 CRC16 就回 J，不发 EOP）：字节流照旧 11 个且正确，
`rx_error` 置 1，错误靠标记表达，不靠丢字节。紧接一个好包把 `rx_error` 打回 0。
只查「坏包报错」会放过「`rx_error` 恒 1」的实现，所以第 3 条对照必须有。

### 3.5 中止与 core 复位：两条路径、同一个 `frame_clr`

`rx_abort` 从中止到 `rx_active` 落 ≤2 个 `clk12m` 拍；那一段只有 5 字节（< 11），
说明真被打断而不是收完；`rx_error` 保持 0（强退不是检错）。
之后连发一个好包能整包收齐，字节不会多出上一段的残骸。

`phy_rx_usb_rst` 走另一条入口：`usb_rst` 从**端口**进来，再分到 deserial 与 bus_state 两处。
两根线接反、或漏接到其中一个，这两条用例至少挂一条。复位后 `connected` 落，
线回 J 要重新判 connect，所以 `connect_evt` 计到 2。

这两条用例都把「包尾仍在线上」的现象跑出来了，见 §4.1。

### 3.6 发送：`driving` 取 `tx_en` 的差别查得到

`phy_tx_line`：4 字节包，`tx_ready` 恰好 4 次，`tx_done` 恰好 1 次；
EOP 的 SE0 段最长 8 个 `ref` 拍（166.7ns，两个位时间），
与总线复位的 120 拍差两个数量级，这是 EOP 与复位在 `usb_bus_state` 里分得开的地方。
整包期间 `frame_cnt` 保持 0：`tx_active` 把 deserial 按在 idle，自己的包自己收不下。

`phy_tx_driving` 先挂起再发包。挂起中旁路优先级最高，`tx_en` 全程压 0，
驱动器交高阻，线上一直是主机那头的 idle J（整包逐拍查 `line_state`），包只走完内部流程
（`tx_done` 照出 1 次）。这条用例故意违约：SIE 不该在挂起中拉 `tx_active`，
这里验的是违约也不会出包、更不会污染总线事件：整包期间 `resume_evt` 与 `usb_bus_rst`
都是 0，`suspend_evt` 保持挂起前那 1 次。

这条也是 `driving` 取 `tx_en` 而不是 `tx_active` 的对照：`tx_active` 是 SIE 的发送请求，
它比 `tx_en` 早拉晚落，请求刚拉、驱动器还没开始驱的那几拍计数器不被清零，
残值叠加就可能凑出一次假 resume。用例先把挂起状态摆好，正是为了让这个残值窗口有机会出错。

### 3.7 唤醒旁路：挂起态来自 `bus_suspended`，不是 SIE 送进来的那根

`phy_susp_wkup` 分两段。第一段故意在**没挂起**时把 `sie_wkup` 拉高：线必须还是 idle J、
`tx_en` 必须还是 0。这条查的是旁路的挂起条件取自 `usb_bus_state` 的 `bus_suspended`
（本层内部线），而不是外部送进来的某个标志，换成后者这段就挂。
第二段正常走：`bus_suspended` 与 `sie_wkup` 同时为 1 时线驱 K，`sie_wkup` 落下即交高阻，
全程没有 `tx_active` 参与。

### 3.8 收发往返：换向之后链路还得接得上（`phy_tx_rx_turn`）

首版 14 条用例各自只走一个方向：收的只管收（`phy_rx_*`），发的只管发（`phy_tx_*`），
`phy_clk_switch` 虽然来回翻 `rcv`，翻的时候线上没有包。真实事务是交替的，
而换向处正是跨模块接缝最容易出错的地方：`tx_active` 落下那一刻 `rcv` 从 0 回 1，
`clk12m` 从 `clk12s` 换回 `dclk`，可 CDR 上一段锁的相位还是收 token 时的，
换向期间我们自己在驱线、`rxdp`/`rxdn` 没有新跳变可供重锁。

`phy_tx_rx_turn` 把这条接缝走全：收 OUT token → 发 2 字节应答 → 收 DATA0。
判据四条：`rcv` 在整段里恰落 1 次、起 1 次；发送期间 `frame_cnt` 不动；
换向后的 DATA0 仍 11 字节逐字节对、`rx_error`=0；
从发 DATA0 前到关帧这段里 `clk12m` 沿数与流逝时间相配（实测 124 沿 / 10.334µs，
标称 124.0，误差 <1%）。

第三条是关键：换向若把接收链路带坏（帧机没回 idle、时钟源没换回来），
DATA0 的 SYNC 就会错位，字节流当场对不上。第二条是半双工互斥的量化：
TB 的总线模型让 `tx_en=1` 时 DUT 的 `rxdp` 读回自己驱的线，
把 `tx_active` 从 deserial 上断开，设备就会把自己那 2 字节包收成一帧，
用例报 `own packet not self-received` 挂掉（已做变异验证）。

📎 [图：换向那一拍 —— `tx_active`↑ 与 `rcv`↓ 同拍、`tx_en` 晚 1 拍起、`tx_done`↑ 与 `rcv`↑ 同拍（phy_tx_rx_turn_switch.png）](../fig/phy_tx_rx_turn_switch.png)

📎 [图：换向后的 DATA0 —— `rcv` 已回 1，`rx_active` 一段、11 个 `rx_valid` 脉冲，`rx_data` 逐个落 `C3 A5 5A 0F F0 11 22 33 44 7E A9`（phy_tx_rx_turn_data0.png）](../fig/phy_tx_rx_turn_data0.png)

第二张图上 `rx_data` 在 `rx_valid` 落下之前停在 `F9`（SYNC 段的残值），字节只在
`rx_valid` 的拍上有效 —— 判据比的是那些拍上的值。

### 3.9 两个极端包长：单字节握手包与 64 字节满长包

`phy_rx_hshake` 走结构最短的包：SYNC + PID + EOP，没有数据字段也没有 CRC。
接收帧机在 DATA 态收到第一个字节就遇上 EOP，与 token/data 的收尾路径不是同一段。
连发 ACK/NAK/STALL 三个，三段各 1 字节、值正确、`rx_error`=0，`rx_active` 上升沿 3 次。

`phy_rx_maxlen` 走最长的包：64 字节净荷，整帧 67 字节（PID + 64 + CRC16）。
净荷取 0xFF/0x00/0xAA/0x55 循环，把位填充压到每 7 个 1 补一个 0 的最密处，
填充计数在字节边界上漏算就会一路累积到 CRC 上。判据是 67 个字节逐字节相等。

满长包需要 TB 侧的配合：`usb_pkt_tasks.vh` 的 `data_packet_task` 净荷形参只有 8 个，
CRC 参考模型 `crc16_tx` 同样按 8 字节定签名。故 `phy_tasks.vh` 增了 `crc16_pay`
（逐字节喂 `crc16_feed_byte`，不限长度）、`exp_data_n`、`send_data_pay` 三个，
帧留档深度从 16 字节提到 128（`FB_DEPTH`）。
`crc16_pay` 与既有 `crc16_tx` 在 8 字节以内必须一致，用例开头先比一次，
免得「67 字节都对」只证明了两边一起错。

### 3.10 挂起中拔出：`usb_rst` 真的接到了 `usb_bus_state` 上

`phy_bus_rst` 从「已连接且活跃」的 J 上复位，`phy_unplug_susp` 多插一段挂起。
拔出时线被下拉成 SE0，协议上与主机复位不可区分，走的是同一条判据；
不同的地方在挂起标志的归宿：`usb_rst` 进来要同时清掉 `connected` 与 `suspended`。

判据四条：长 SE0 出 `usb_bus_rst` 之后 `bus_suspended` 必须落 0；
未插入期间不重复报复位（判据要求 `connected=1`）；插回后出第二次 `connect_evt`；
插回后再驱 3µs K **不报** `resume_evt`。最后一条是本用例的主判据，
它把「挂起标志真被清掉了」和「只是碰巧没到门限」分开：标志若留着，
挂起态下 3µs K 正好是一次合法 resume。

把 `usb_bus_state` 的 `usb_rst` 端口接死，插回后 `connect_evt` 只计到 1、
`rcv` 回不来，用例当场挂（已做变异验证）。

📎 [图：拔出 —— 线落 SE0，`usb_bus_rst` 出脉冲那一拍 `bus_suspended`、`rcv`、`sie_attached` 一起落 0（phy_unplug_rst_clears_susp.png）](../fig/phy_unplug_rst_clears_susp.png)

📎 [图：插回 —— J 上出第二次 `connect_evt`，附着与 `rcv` 回来；随后线转 K（`line_state` = 2'b01）而 `resume_evt` 不动（phy_unplug_replug_no_resume.png）](../fig/phy_unplug_replug_no_resume.png)

## 4. 交给 SIE 的两个接口事实

### 4.1 中止之后，包尾会在线上重开一段空的 `rx_active`

`frame_clr` 只是把帧机打回 `USB_IDLE`，主机并不知道、包尾照发。帧机在 idle 上看到数据 0
就重新进 SYNC 搜索，包尾的数据里凑够 ≥4 个 0 加一个 1 就重新进 `USB_DATA`，
于是多出一段**0 字节、无错误**的 `rx_active`。

对 PHY 不算错（不吐字节、不置错，下一个好包照收），但 SIE 必须忽略它：
**收到没有 SYNC/PID 支撑的 `rx_active` 段不能当成新包**。SIE 本来就靠 PID 判包，
不额外加逻辑也满足这条。

实测：中止与软复位两条用例各出现 1 段这样的空段（`phy_rx_abort` 的 3 段 = 5 + 0 + 11 字节）。

### 4.2 `rx_error` 不含 CRC

这层的 `rx_error` 只认物理错：位填充违规、EOP 异常收尾（SE0 之后不是 J）。
CRC5/CRC16 校验是 SIE 的事（`src/common/usb_crc5_byte.v` / `usb_crc16_byte.v`）。
所以坏 CRC 的包在这一层必须「字节照收、`rx_error` 不置位」，本层用例不查它。

## 5. 编译卫生

```bash
verilator --lint-only -Wall -Wno-fatal -Isrc/inc src/phy/usb_dpll_phy.v \
    src/phy/usb_rx_cdr.v src/phy/usb_clk_mux.v src/phy/usb_rx_deserial.v \
    src/phy/usb_tx_serial.v src/phy/usb_bus_state.v
iverilog -g2012 -Wall -I../../src/inc -I../common -o phy.vvp tb_phy.v <六个源文件>
```

iverilog 侧零 error、零 warning；Verilator lint 只剩 `usb_rx_cdr` 里既有的两处
`UNUSEDSIGNAL`（该模块自己的报告已记）。TB 里的 `$display` 标签一律 ASCII：
字符串经宽向量形参传递时按位截断，中文 UTF-8 续字节会被砍掉。

## 6. 覆盖率（Verilator 5.052，18 用例合并）

### 6.1 结论

报数口径是 DUT 模块 `usb_dpll_phy`，由 `--report hier` 的 Design Unit Coverage Summary 取该行：

| 维度 | DUT | 判定 |
|---|---|---|
| 翻转 toggle | 92/92 = 100% | ✅ |
| 行 line | 无点 | 顶层没有过程语句 |
| 分支 branch | 无点 | 顶层没有 `if`/`case` |
| 表达式 expr | 无点 | 顶层没有表达式 |

`usb_dpll_phy` 只有端口和五条例化，工具只给它记了端口与内部四根线
（`bus_suspended` / `dclk` / `rx_bit` / `line_s[1:0]`）的翻转点。92 个点全翻过，
说明五个子模块都被例化到了、没有悬空端口、每一根内部线都真的通了信号。

真正有逻辑的是五个子模块，各自的权威数字在它们自己的报告里（§6.4）。

### 6.2 复跑方法

```bash
make cov MOD=phy                # 建 → 跑全 18 用例 → 合并 → 打印 summary
make covclean MOD=phy           # 删 cov/

# DUT 口径：
verilator_coverage --report hier cov/merged.dat      # 取 Design Unit 段的 usb_dpll_phy 行
verilator_coverage --filter-type toggle --write /tmp/o.dat cov/merged.dat   # 单维度复核
```

`make cov` 先用 iverilog 的同一套功能判据卡一遍，任用例非 `TEST PASSED` 即中止。

### 6.3 工具与口径

1. 必须跨用例合并：单用例只走自己那条路径（`phy_reset_default` 里一个事件都不报、
   `phy_tx_line` 里 `frame_cnt` 恒 0）。表里的百分比是 18 用例合并后的口径。
2. `--report hier` 的每一行**含子实例**：`tb_phy.u_dut` 那一行把五个子模块的都算进去了，
   逐模块看数得读 Design Unit Coverage Summary。
3. 本层没有状态机，`fsm_state`/`fsm_arc` 恒 0/0，`fsmcov` 是留空目标；
   子模块的 FSM 在各自 `sim/` 下验。
4. `--annotate` 的输出比源文件多一行表头，行号要减 1 再对源文件。

### 6.4 子模块经顶层这一遍的数字

五个子模块合起来（`tb_phy.u_dut` 行）：line 128/138、toggle 614/638、branch 193/196、expr 301/311。

| 单元 | line | toggle | branch | expr |
|---|---|---|---|---|
| `usb_clk_mux` | 7/8 | 28/28 | 16/16 | 20/20 |
| `usb_rx_cdr` | 17/18 | 40/40 | 24/24 | 24/24 |
| `usb_rx_deserial` | 69/76 | 162/174 | 57/60 | 111/119 |
| `usb_tx_serial` | 25/26 | 126/126 | 54/54 | 72/72 |
| `usb_bus_state` | 10/10 | 166/178 | 42/42 | 74/76 |

`usb_tx_serial` 这一行与它自己报告里的数字完全一致。其余四行的差值全部是**激励范围**
差出来的，不是 RTL 缺陷，逐条定性：

| 单元 | 未覆盖项 | 定性 |
|---|---|---|
| `usb_clk_mux` | 1 条行（`case` 的 `default`） | 结构不可达，编码规范要求的兜底。同它自己的报告 |
| `usb_rx_cdr` | 1 条行（`case` 的 `default`） | 同上 |
| `usb_tx_serial` | 1 条行（`case` 的 `default`） | 同上 |
| `usb_rx_deserial` | EOP 异常尾支路（`ST_EOP_DEAD` / `USB_ERROR` / `eop_err` 的翻转与表达式）、`zero_cnt==7` 那条、2 条 `case default` | 整合 TB 只发合规包与截断包，没构造「SE0 之后不是 J」的收尾。该形态由 `sim/deserial` 的 `case_err_eop` E1/E2 覆盖，`zero_cnt==7` 由 `case_sync_scan` 覆盖（该报告 line 75/76、branch/expr/toggle 全满） |
| `usb_bus_state` | `rst_s[1]`/`rsm_s[1]`/两个翻转位的 `1→0` 及两条两拍链的表达式 | 整合用例里每类事件一条用例只翻转一次，同步链第二级只见到 `0→1`。两次翻转的形态由 `sim/busstate` 的 `case_bs_two_resets` 覆盖（该报告四项全 100%） |

这五条都指向同一件事：整合 TB 的职责是查接线与跨模块因果，不是把每个子模块的
边角激励再走一遍。子模块的权威数字以各自验证报告为准。

### 6.5 覆盖率查出的缺陷：`tx_data` 三个位从未翻转（TB 侧，已修）

首轮 DUT 的 toggle 是 87/92，5 个未覆盖点全在顶层的 `tx_data` 端口上：
`tx_data[2]`、`tx_data[3]` 两位从未变过，`tx_data[4]` 只翻了一个方向。
原因是发送用例当时只发 `E1/03/00/00` 这四个字节，这几位恰好恒定。
这暴露的是 **TB 激励缺口**（顶层只是把 `tx_data` 透传给 `tx_serial`，本身没有逻辑），
改法是让发送用例的字节取值成对地翻：`phy_tx_line` 发 `FC/03/00/FE`，`phy_tx_driving` 发 `FC`。
DUT 随即到 92/92。

顺带把发射路径的两条边角支路也带上了：末字节以 6 连 1 收尾的两种形态
（第 6 个连 1 落在 b7 → `S_EOP1` 自环；落在 b6 → `S_DATA_LAST` 自环）
和单字节包（`S_SYNC` 直接进 `S_DATA_LAST`）。这三条 `sim/tx` 各有专例
（`tx_tail_stuff`、`tx_stuff_dense`、`tx_stuff_pos_scan`），本层是顺手覆盖，不是补验。

## 7. 结论

1. 五个子模块接起来后功能自洽：18/18 PASS，跨模块因果链（CDR → clk_mux → deserial、
   tx_serial → 线驱动、bus_state 事件）在整层上逐条走通；
2. 接线正确：`rcv` 由 SIE 侧给（TB 建模）、`usb_rst` 在层外并好、`line_s` 由 deserial 转给
   bus_state、`tx_en` 直连 `driving`、`bus_suspended` 由 bus_state 直送 tx_serial，每根都有专门用例查；
3. 四个事件脉冲互斥、宽 1 个 `clk12m` 拍，冷启动状态与复位后即刻可用都验过；
4. 半双工互斥成立：发送期间 `frame_cnt` 恒 0，收发**往返**（收 → 发 → 收）换向后
   下一个包仍整包收齐、时钟不毛刺；EOP 的 SE0 两个位时间，与总线复位分得开；
5. 包长两端都过：单字节握手包与 64 字节净荷满长包（67 字节帧）逐字节正确；
6. DUT 覆盖率 toggle 92/92 = 100%，无未覆盖项；
7. 两条接口事实交下游：没有 SYNC/PID 支撑的 `rx_active` 段要忽略；`rx_error` 不含 CRC。

两条关键接线（`tx_active` 到 deserial、`usb_rst` 到 bus_state）另做了变异验证：
各自断开后，`phy_tx_rx_turn` 与 `phy_unplug_susp` 当场挂掉，说明用例真能判到那两根线。

---

*本模块的仿真基建：`sim/phy/`（Makefile / TB / 18 个 case / README）。*
