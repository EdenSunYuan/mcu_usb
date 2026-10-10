# CDR 模块验证报告

> 模块：`usb_rx_cdr`（Intel SIE DPLL 时钟数据恢复）  
> 日期：2026-09-07（新增 `cdr_case_pkt_all`；自检升级为「因果链 + 前后文窗口」确认；
> 短 bit 频率自适应拆成 J/K 两个 case：`cdr_case_short_bit_j`（data=1/J→6→1）与
> `cdr_case_short_bit_k`（data=0/K→2→5，镜像），均带因果链自检）  
> 工具：iverilog + vvp（`-g2012`），自检全部在 Verilog 内完成  
> 源码：`src/phy/usb_rx_cdr.v` | 测试：`sim/cdr/tb_cdr.v` + 10 个 `case_*.v`

---

## 1. 概述

`usb_rx_cdr` 是 USB 1.1 数字收发器（PHY）中的时钟数据恢复单元，用 48MHz
`ref_clk` 对 D+/D- 差分线做 4× 过采样，恢复出 12MHz 位时钟 `dclk` 和 NRZI
电平数据 `rx_bit`。其核心是 Intel SIE 的 16 态 DPLL 状态机：

- **锁存路径**：C(12) → D(13) → 5（进入右环即锁存）
- **右环（J 电平）**：5 → 7 → 6 → 4
- **左环（K 电平）**：1 → 3 → 2 → 0
- **长 bit 绕行**：F(15)、B(11) 各多耗一拍

验证目标：证明 CDR 在标称、长/短 bit、SE0、随机、多包、以及**端到端数据往返**
等场景下都能正确恢复时钟与数据。

## 2. 测试环境

| 项目 | 说明 |
|------|------|
| RTL | `src/phy/usb_rx_cdr.v`（16 态 DPLL 状态机） |
| Testbench | `sim/cdr/tb_cdr.v`：实例化 DUT + 自检逻辑 + `+case=` 分发 |
| Case 文件 | `sim/cdr/case_*.v`（10 个），通过 `+case=<name>` 独立运行 |
| 激励任务 | `sim/common/usb_pkt_tasks.vh`：`bit_task → byte_task → pid_task → packet_task` |
| 参考模型 | `sim/common/crc5_ref.vh`、`crc16_ref.vh`（CRC5/CRC16 黄金向量） |
| 时钟 | 48MHz `#(1000/48/2)`；USB bit 时间 = 4 ref_clk ≈ 83.33ns |
| NRZI/位填充 | `bit_task` 内置 NRZI 编码 + 位填充（连续 6 个 1 后插 0） |
| 周期覆盖 | `bit_task(d, cyc)` 支持 3（短）/4（标称）/5（长） |

仿真方式（`sim/cdr/` 下）：

```bash
make -C sim/cdr run            # 全 10 个 case 逐个运行并汇总
make -C sim/cdr run VCD=1      # 每个 case 保存独立 VCD 波形
make -C sim/cdr debugwave      # 交互菜单: 弹 10 个 case 名供选 → 自动 VCD=1 → 直接开 wave_debugger
make -C sim/cdr debugwave CASE=cdr_case_short_bit_k   # 直接指定 case (可脚本化)
make debugwave                 # 仓库根入口: 模块 → case 两级菜单 (规范见 sim/common/README.md)
```

## 3. 自检机制

pass/fail 判定基于硬件级别的自动检测（非人工看波形）：

| # | 检测点 | 实现 | 判据 |
|---|--------|------|------|
| 1 | 锁存 | `stat_cur==5 && stat_nxt==7` 首次成立 → `locked=1` | `locked` |
| 2 | F 绕行 | `prev_state==3 && stat_cur==15` | `f_detected` |
| 3 | B 绕行 | `prev_state==7 && stat_cur==11` | `b_detected` |
| 4 | 恢复时钟 | `posedge dclk` 相邻沿间 ref_clk 计数 | 周期 ∈ 3~5 ref_clk |
| 5 | rx_bit 跟踪 | `locked` 后在 ref_clk 沿比 `rx_bit` vs `rxdp` | 信息性统计（DPLL 有 1~2 拍流水延迟，不强制） |
| 6 | 端到端回环 | 用 `dclk`+`rx_bit` 还原数据位 vs 发送位 | 逐 bit 一致（见 §5） |
| 7 | 因果链·锁存 | `causal_arm`/`causal_lock_check` 逐 `ref_clk` 采样 `dut.stat_cur`+`dclk` 时间线 | idle 前窗 + C→D→5 时序符合（见 §3.1） |

> rx_bit 跟踪（#5）是信息性的：DPLL 内部有流水延迟，每个 case 正常有 ~40~90
> 次沿边沿不匹配，但**连续**不匹配长度（`max run`）才是数据恢复质量的判据。

### 3.1 确认方法论：因果链 + 前后文窗口（用户 2026-09-07 定）

早先的自检偏"只看最终标志、观察太局部"。现按新规范——**通用规范见
`sim/common/README.md` 的「仿真结果确认规范」**——把关键结论都改成
**因 → 变 → 果 + 量化判据 + 前后文窗口**：

- **前窗**：idle J 下 `state` 恒 C(12)、`dclk` 恒 0——无数据流时恢复时钟不运行，
  证明锁存不是从脏起点发生；
- **因①**：线上首个 K（SYNC 首 0，`rxdp` 由 J 变 K，`b` 采样到 0）→ DPLL 离开 C
  直接进入 D(13)（`C→D`，与跳转表逐条对应）；
- **因②**：线上回 J（`b` 采样到 1）→ D→5（进右环即锁存），两次边沿间隔 = 锁存延迟；
- **果 + 后窗**：锁定后数 16 `ref_clk` 内 `dclk` 上升沿 ≥2——12MHz 恢复时钟真在
  运行，而非单个标志被置位。

量化判据：首个非 C 态必须 = D；锁存延迟 ∈ [1,8] ref_clk（标称 1 bit = 4）；
idle 前窗 ≥3 拍。`case_nominal` / `case_pkt_all` 首包实测输出（回归日志节选）：

```
因果链·前窗: idle J 下 state=C 持续 10 ref_clk, dclk 恒 0 (无数据不吐时钟) ✓
因果链·因①: 线上首 K (SYNC 首 0) → C(12)→D(13) @ref_clk#19 ✓
因果链·因②: 线上回 J → D(13)→5 锁定 @ref_clk#23, 锁存延迟 4 ref_clk
  (判据: 延迟 4 ref_clk ∈ [1,8], 对应 SYNC 0→0 两次边沿间隔 ~4 ref_clk) ✓
因果链·果: 锁定后 16 ref_clk 内 dclk 上升沿 4 个 → 12MHz 恢复时钟运行 ✓
```

锁存延迟实测恰为 **4 ref_clk = 1 bit**——与"SYNC 相邻 0 位（电平交替）之间隔 1 bit、
DPLL 收满两次边沿即锁"的机制逐拍吻合。这是用驱动信号（SYNC 电平边沿）→ 中间状态
（C→D→5 时间线）→ 最终结果（`dclk` 起振）完整还原的锁存证明，不再只有一个
`locked=1`。

## 4. 测试用例与结果

10 个 case 全部通过：

| Case | `+case=` | 测试目的 | 关键判据 | 结果 |
|------|----------|---------|---------|------|
| 标称 | `cdr_case_nominal` | 标称 4-cycle OUT Token 基本锁存 | `locked=1` + 因果链锁存窗口（§3.1） | ✅ |
| 长 bit F | `cdr_case_long_bit_f` | J 电平长 bit（5cyc）→ F 绕行 | `f_detected=1` | ✅ |
| 长 bit B | `cdr_case_long_bit_b` | K 电平长 bit（5cyc）→ B 绕行 | `b_detected=1` | ✅ |
| 短 bit J | `cdr_case_short_bit_j` | data=1/J bit（3cyc）频率自适应（真机制验证） | 因果链：`6→1`×1 + `2→5`×0 + 3-ref_clk×1 + 不过冲（§4.1） | ✅ |
| 短 bit K | `cdr_case_short_bit_k` | data=0/K bit（3cyc）频率自适应（J 的镜像） | 因果链：`2→5`×1 + `6→1`×0 + 3-ref_clk×1 + 不过冲（§4.1） | ✅ |
| SE0 | `cdr_case_se0` | 注入 SE0 后能重新锁存 | 第二次 `locked=1` | ✅ |
| 随机 | `cdr_case_random` | 64 bit 随机数据 + 随机宽度(3/4/5cyc) | `locked` 全程保持 | ✅ |
| 多包 | `cdr_case_multi_pkt` | 3 包事务（SETUP+DATA0+ACK） | 时钟/数据持续恢复 | ✅ |
| 回环 | `cdr_case_loopback` | 端到端逐 bit 对比 | 122 数据位 0 差异 | ✅ |
| 全包型回环 | `cdr_case_pkt_all` | 全部 9 类合法正常包端到端逐 bit | 9/9 包 0 差异 | ✅ |

关键实测输出摘录：

```
[长 bit F]  F detour (3→F→6) detected ✓
[长 bit B]  B detour (7→B→2) detected ✓
[短 bit J]  6→1 跳过×1 | 2→5 跳过×0 | 3-ref_clk 周期×1 | 过短(<3)=0 | dclk 44 沿, 不失锁 ✓
[短 bit K]  6→1 跳过×0 | 2→5 跳过×1 | 3-ref_clk 周期×1 | 过短(<3)=0 | dclk 44 沿, 不失锁 ✓
[SE0]       CDR re-locked after SE0 ✓
[随机]      CDR locked ✓  /  CDR still locked ✓
[多包]      dclk: 126 rising edges (expect ~124), 0 bad periods
            rx_bit tracking: 200 mismatches, max run 2 ref_clk (≤ 6 ✓)
[回环]      ✓ 24 + 90 + 8 = 122 data bits recovered identical
```

### 4.1 短 bit 频率自适应（case_short_bit_j / case_short_bit_k，双向因果链自检）

短 bit 的"频率自适应"有 **J（data=1）与 K（data=0）两种极性、两条独立跳过路径**，
故镜像长 bit 的 f/b 拆成两个 case。早先单一 `case_short_bit` 只查"短 bit 后不失锁"——
短 bit 机制从未被显式验证（长 bit 有 `f_detected`/`b_detected`，短 bit 却没有对应
断言）。本次按 §3 方法论升级为**因果链 + 量化判据**，把"驱动 → 内部跳变 → 恢复时钟"
完整还原，两 case 共享判据、互证镜像：

**case_short_bit_j — data=1/J bit（CRC5[2]，bit 29）压到 3cyc → 右环 6→1**

- **因**：J 电平 bit 压到 3cyc → 其后的 **K** 翻转沿比标称早 1 ref_clk；
- **变**：DPLL 右环第 3 态 `6` 判到提前 K 沿（b=0）→ **`6→1` 跳过切环**（跳 4/5，
  state 6 转移 `(b==1)?4:1`）；
- **果**：该位恢复时钟周期被压到 **3 ref_clk**（其余仍 4），全程不失锁。

**case_short_bit_k — data=0/K bit（CRC5[3]，bit 30）压到 3cyc → 左环 2→5**

- **因**：data=0 bit 起始翻转进 K 电平；K 段压到 3cyc → 段末回 **J** 的翻转沿比标称
  早 1 ref_clk；
- **变**：DPLL 左环第 3 态 `2` 判到提前 J 沿（b=1）→ **`2→5` 跳过切环**（跳 0/1，
  state 2 转移 `(b==0)?0:5`）；
- **果**：同 J 方向——该位恢复时钟周期 = **3 ref_clk**，全程不失锁。

量化判据全部硬断言（两 case 各自）：本向跳过恰 1（J:6→1=1 / K:2→5=1）、**对向跳过=0**
（J/K 两方向互不串扰）、3-ref_clk 周期恰 1 个、`<3` 过短 0 次、`dclk` 沿 ≥20。
回归实测（见 §4 摘录）＋ VCD 离屏核对：

```
J: 6→1×1 | 2→5×0 | 3-ref_clk×1 | 44 沿 0 过短    状态轨迹 5→7→6→1→3→2→0
K: 6→1×0 | 2→5×1 | 3-ref_clk×1 | 44 沿 0 过短    状态轨迹 1→3→2→5→7→6→4
   两 case 短周期均 62502 ps = 3 ref_clk (VCD 实测, 其余 83336 ps = 4 ref_clk)
```

两条跳过路径对应的状态轨迹波形见图 §4.3（`cdr_short_bit_j.png` / `cdr_short_bit_k.png`，
均在 VCD 上核对过：`6→1` / `2→5` 各恰一次、其余位周期 4 ref_clk 正常）。

### 4.2 多包事务（case_multi_pkt）

发送一次 SETUP 控制传输的 3 个包（SETUP token + DATA0(8B, 含 0x7F 触发位填充) +
ACK），验证 CDR 在包与包之间的 EOP + idle J 间隔后仍持续正确恢复：

- 恢复时钟 `dclk` 共 126 个上升沿（预期 ≈124，2 个 stuffed bit 补齐），**0 个坏周期**；
- `rx_bit` 对 `rxdp` 的最大连续滞后仅 **2 ref_clk**（远小于 1 bit = 4 ref_clk），说明数据电平从未丢失。

### 4.3 波形图（wave_debugger 导出，超链接打开）

以下波形用本项目的 `tools/wave_debugger.py` 波形调试器显示，并经
`tools/render_waveform.py` 离屏渲染导出（详见 tools/README_render_waveform.md）。
PNG 已存于 `doc/fig/`，点击链接即可打开查看（部分阅读器无法内嵌渲染图片）。
信号名中 `dut.stat_cur` 为 4-bit DPLL 状态；图上该总线以**十六进制**标值
（`4'hC`=C=12、`4'hD`=D=13、`4'h5`=5=锁定…，hex 即状态编码，由渲染工具
`--radix "tb_cdr.dut.stat_cur=hex"` 指定，见 tools/README_render_waveform.md）。
> ★ 现存 PNG 为 2026-09-20 规则 7 改造**前**渲染，图内总线标签仍是旧名 `dut.state`
> （说明见 [02_cdr_design.md §4](02_cdr_design.md)）。

📎 [打开波形图：CDR 波形总览](../fig/cdr_wave_overview.png)

> 完整 OUT Token（`cdr_case_nominal`）：rxdp / rxdn（差分线）、dclk（恢复时钟）、rx_bit（NRZI 电平）

📎 [打开波形图：锁存波形](../fig/cdr_lock.png)

> 锁存放大：clk（48MHz 参考）、rxdp、rx_bit、dut.state；state 走 C(12)→D(13)→5（锁定进入右环）

📎 [打开波形图：F 绕行波形](../fig/cdr_f_detour.png)

> F 绕行放大（`cdr_case_long_bit_f`）：state 走 3→F(15)→6→4，恢复时钟高电平加 1 个 48MHz 周期

📎 [打开波形图：多包事务](../fig/cdr_multi_pkt.png)

> 3 包事务（`cdr_case_multi_pkt`）：SETUP + DATA0 + ACK；dclk 持续恢复 12MHz，rx_bit 跟踪 NRZI 电平

📎 [打开波形图：短 bit J 跳过](../fig/cdr_short_bit_j.png)

> 短 bit data=1/J（`cdr_case_short_bit_j`，CRC5[2]=bit29 压到 3cyc）：state 轨迹 …→5→7→6→**1**→3→2→0，6 处直跳 1（跳 4/5）；该位恢复时钟 3 ref_clk = 62502 ps

📎 [打开波形图：短 bit K 跳过](../fig/cdr_short_bit_k.png)

> 短 bit data=0/K（`cdr_case_short_bit_k`，CRC5[3]=bit30 压到 3cyc）：state 轨迹 …→1→3→2→**5**→7→6→4，2 处直跳 5（跳 0/1）；短周期同为 3 ref_clk = 62502 ps

## 5. 端到端回环验证（case_loopback）—— 核心

这是对 CDR **最严格**的验证：不再依赖"电平跟踪"等间接判据，而是走完整链路，
用 CDR 恢复的时钟和数据**还原出原始包数据位**，与发送位逐 bit 对比。

### 5.1 方法

```
发送 bit_task (NRZI + 位填充) ──> 差分线 DP/DN ──> CDR ──> dclk + rx_bit
                                                           └─ 采样 rx_bit @dclk 上升沿
                                                           └─ NRZI 解码 (变→0, 不变→1)
                                                           └─ 恢复数据位 rx_q
对比:  rx_q  vs  发送时记录的 exp_tx_q (含 stuffed bit)
```

- **发送端**：`bit_task` 把实际线上数据位（含位填充 stuffed bit）按序记入 `exp_tx_q`；
- **接收端**：`always @(posedge dclk)` 采样 `rx_bit`，NRZI 解码（相邻采样电平变→0、不变→1）到 `rx_q`；
- **对齐**：用 SYNC 尾巴定位包起点（见 §5.2），从 PID 起逐 bit 比。

### 5.2 关键发现：SYNC 相位对齐"吃掉" 1~2 位

调试中先用 Python 精确比对恢复流与发送流，发现恢复流是发送流的**完美平移拷贝**：

| 包 | 偏移 | 比对结果 |
|----|------|---------|
| SETUP（首包，从复位锁存） | 2 bit | 30/30 位 0 差异 |
| DATA0（后续包，已锁存） | 1 bit | 97/97 位 0 差异 |

原因：CDR 的时钟相位对齐会"吃掉" SYNC 开头的 1~2 个 bit（首包锁存吃 2 个、
后续包再对齐吃 1 个）。这正是 USB 设计 SYNC 字段的用途——SIE 只用 SYNC 对齐
采样时钟，**从不把 SYNC 当数据解码**。因此对齐逻辑不再要求完整 `00000001`
（7 个 0），而是找 SYNC 尾巴（连续 ≥4 个 0 + 1），把那个 `1` 对齐到 `exp[7]`，
从 PID 开始逐 bit 比。该方案对 0/1/2 位偏移都鲁棒。

### 5.3 结果

| 包 | 数据位（PID + …） | 结果 |
|----|------------------|------|
| SETUP token | 24 bit（PID+ADDR+ENDP+CRC5） | ✅ 0 差异（吃掉 2 SYNC 位） |
| DATA0（8B payload + CRC16） | 90 bit | ✅ 0 差异（吃掉 1 SYNC 位） |
| ACK handshake | 8 bit | ✅ 0 差异（吃掉 1 SYNC 位） |

**共 122 个数据位，0 bit 差异**，直接证明 CDR 恢复的时钟与数据正确配对。

### 5.4 全 9 类合法正常包回环（case_pkt_all）—— 全包型推广

`case_loopback` 只覆盖 SETUP+DATA0+ACK 3 种包。真实总线上会出现的合法正常包
共有 9 类，`case_pkt_all` 用与 §5 完全相同的方法逐类验证一遍，确认 CDR 对**所有
USB1.1 Full-Speed 正常包型**都保持位级正确：

| # | 包 | 结构 | 恢复数据位 | 结果 |
|---|----|------|-----------|------|
| 1 | Token OUT | PID+ADDR+ENDP+CRC5 | 24 bit | ✅ 0 差异 |
| 2 | Token IN | PID+ADDR+ENDP+CRC5 | 24 bit | ✅ 0 差异 |
| 3 | Token SETUP | PID+ADDR+ENDP+CRC5 | 24 bit | ✅ 0 差异 |
| 4 | SOF（frame=0x7FF） | PID+Frame(11)+CRC5 | 26 bit（含 2 stuffed） | ✅ 0 差异 |
| 5 | DATA0（8B payload） | PID+payload+CRC16 | 93 bit（含 5 stuffed） | ✅ 0 差异 |
| 6 | DATA1（3B payload） | PID+payload+CRC16 | 50 bit（含 2 stuffed） | ✅ 0 差异 |
| 7 | Handshake ACK | 仅 PID | 8 bit | ✅ 0 差异 |
| 8 | Handshake NAK | 仅 PID | 8 bit | ✅ 0 差异 |
| 9 | Handshake STALL | 仅 PID | 8 bit | ✅ 0 差异 |

实测输出摘录：

```
[OUT  token]  ✓ 24 data bits recovered identical (吃掉 2 SYNC 位)   ← 首包锁存
[IN/…/STALL]  ✓ … recovered identical (吃掉 1 SYNC 位)
9/9 packets round-trip bit-exact, 0 bit mismatches
PASS: case_pkt_all
```

要点：

- **位填充也被原样还原**：#4/#5/#6 故意用 frame=0x7FF、payload 含 0x7F/0xFF
  强制触发 stuffed 0，恢复数据位数比"逻辑位"多（26/93/50 vs 24/88/48），
  且与发送端记录的含 stuffed 位流 **0 差异**——证明 CDR 不吞、不丢 stuffed bit；
- **每包独立回环**：9 个包连续发送，包与包之间 EOP + idle J，CDR 每包 SYNC
  重新对齐（首包吃 2 SYNC 位、后续吃 1 位），全程不失锁；
- **覆盖全部 3 类包结构**：Token（CRC5）/ Data（CRC16 + 位填充）/ Handshake
  （无 CRC）——三种帧长、三种检错编码下恢复一致。

## 6. 结论

| 验证点 | 结果 |
|--------|------|
| 锁存 C→D→5 | ✅ PASS（因果链：延迟 4 ref_clk = 1 bit，见 §3.1） |
| 右/左环循环 | ✅ PASS |
| rx_bit 电平跟踪 | ✅ PASS（最大滞后 2 ref_clk） |
| dclk 恢复时钟 | ✅ PASS（12MHz，周期 4 ref_clk，126 沿 0 坏周期） |
| 长 bit → F 绕行 | ✅ PASS（3→F→6） |
| 长 bit → B 绕行 | ✅ PASS（7→B→2） |
| 短 bit 频率自适应（J/K 双向） | ✅ PASS（J：`6→1`×1 + `2→5`×0；K：`2→5`×1 + `6→1`×0；均 3-ref_clk×1、不过冲、不失锁，§4.1） |
| SE0/EOP | ✅ PASS（能重新锁存） |
| 随机激励 | ✅ PASS（64 bit 全程锁存） |
| **端到端回环（case_loopback）** | ✅ **PASS（122 数据位逐 bit 一致）** |
| **全 9 类正常包回环（case_pkt_all）** | ✅ **PASS（9/9 包逐 bit 一致，含 stuffed bit）** |

**10 个测试用例全部通过。** 端到端回环验证（`case_loopback` + `case_pkt_all`）用
"恢复的 `dclk` + `rx_bit` 还原包数据 → 与发送包逐 bit 对比"的方式，覆盖了
**全部 9 类合法正常包型**（OUT/IN/SETUP/SOF Token、DATA0/DATA1、ACK/NAK/STALL），
从功能上严格证明了 CDR 时钟恢复与数据恢复的正确性。

本次回归按新确认方法论（**§3.1**，通用规范见 `sim/common/README.md`「仿真结果确认
规范」）重跑：锁存证明从"只看 `locked` 标志"升级为**逐拍时间线还原 C→D→5 因果链
并带前后窗**；短 bit 自适应进一步拆成 J/K 两 case，各自证明独立跳过路径（6→1 /
2→5）且互不串扰。全部 10 case 重跑通过。
