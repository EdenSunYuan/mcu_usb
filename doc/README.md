# APB USB 1.1 设备控制器 — 设计报告（总）

> 本报告按模块分章节撰写，每章遵循统一结构：模块介绍 / 模块内容 / 模块划分及模块图 / 接口 / 设计关键点 / 验证计划。
> 各章随设计推进逐步充实，最终合并为完整设计报告。
> 对应规范：USB 1.1 Specification（`docs/usb_1_1_spec.pdf`）。

## 顶层架构概览

三个时钟域，只有 **SIE↔FIFO 一处异步 CDC**（`usb_sie_cdc`），PHY↔SIE 为同步派生时钟交接（无异步 CDC、与 pclk 无关）：

```
apb_usb_top
│
│  ┌── [ref_clk 48MHz 域（4×）] usb_dpll_phy（数字收发器）─────────────┐
│  │     usb_rx_cdr        CDR：DP/DN → dclk(恢复时钟) + rx_bit(NRZI)   │
│  │     usb_clk_mux       dclk / clk12s 无毛刺切换 → clk12m           │
│  │     usb_rx_deserial   RX 反序列化（位→字节+包边界）                │
│  │     usb_tx_serial     TX 串行器（1× clk12m 域）                   │
│  │     总线状态检测       J≥2.5µs=connect / SE0≥2.5µs=reset（待设计） │
│  └──────────────────────────────────────────────────────────────────┘
│                        │ 字节级交接：rx_data/rx_valid/rx_active/rx_error/line_state
│                        ▼   + 反向 rcv / tx_active / tx_data / tx_last
│  ┌── [clk12m 12MHz 域（1×）] usb_sie（串行接口引擎）────────────────┐
│  │     + 事务逻辑        包解析 / PID / CRC / toggle / 控制传输      │
│  └──────────────────────────────────────────────────────────────────┘
│                        │  ←— 唯一异步 CDC（clk12m ↔ pclk）—→
│                        ▼
│  ┌── [CDC 桥] usb_sie_cdc   四相闭环握手（数据稳定 + req/ack 同步）──┐
│  └──────────────────────────────────────────────────────────────────┘
│                        │ pclk
│                        ▼
│  ┌── [pclk 域] usb_ep_fifos / usb_apb_slave / usb_regs（+ 中断）────┐
│  └──────────────────────────────────────────────────────────────────┘
```

- **PHY↔SIE**：`dclk`（接收恢复）/ `clk12s`（发送 = ref_clk÷4）经 `usb_clk_mux` 无毛刺切换成 `clk12m`，
  直接驱动 SIE。二者边沿都对齐 `ref_clk`，是**同步派生时钟交接**，**没有异步 CDC、与 pclk 无关**。
- **SIE↔FIFO**：`usb_sie_cdc`，全设计**唯一的异步 CDC**，用四相闭环握手（无 FIFO）跨 `clk12m ↔ pclk`。

## 设计决策摘要

| # | 决策 | 选定值 |
|---|------|--------|
| A | APB 数据宽度 | 32-bit |
| B | APB 地址宽度 | 12-bit |
| C | 时钟方案 | 三时钟域：ref_clk(48MHz/4×) / clk12m(12MHz/1×, 恢复+发送) / pclk(APB) |
| D | 端点 FIFO 深度 | EP0/EP1/EP2 各 64B |
| E | 语言 | Verilog-2001（可综合，RTL 禁延迟语句） |
| F | 位序 | LSb-first |
| G | 恢复时钟 | 恢复的 `dclk` 当作真实时钟用（经 clk_mux → clk12m 驱动 SIE，Intel 方案） |
| H | CDC 跨域 | 仅 SIE↔FIFO 一处异步 CDC：四相闭环握手（无 FIFO）；约束 pclk≥24MHz |

## 设计报告编写规范

- [模块设计报告编写规范（模板）](README_design_report.md) 📐 4 节结构，后续所有模块统一遵循

## 参考资料

- [精读 Intel《Designing A Robust USB Serial Interface Engine》](intel_sie_whitepaper_notes.md) 📖 白皮书阅读笔记（DPLL 状态机 / dclk 与 clk12s 切换 / 带内带外信号 / 四相握手 CDC）

## 章节目录

- [第一章 公共原语](01_common_primitives.md) ✅ 已完成并通过验证
- [第二章 usb_dpll_phy 数字收发器](02_usb_dpll_phy.md) ✅ 顶层 + 五个子模块 RTL + 验证完成（CDR / clk_mux / RX 反序列化 / TX 串行器 / 总线状态检测）
  - [CDR 设计报告](design_rpt/02_cdr_design.md) 📐 模块介绍 / 原理 / 信号列表 / 关键设计点+波形
  - [CDR 验证报告（独立）](design_rpt/02_cdr_verification.md) 📊 10 个用例全通过（含端到端回环验证）
  - [RX 反序列化设计报告](design_rpt/rx_deserial_design.md) 📐 设计定稿 + RTL 已落地（clk12m 域位流水线：NRZI 解码/SYNC/解填充/字节对齐/EOP；输出 rx_valid/rx_active/rx_error，UTMI RX 三信号，无 rx_start/rx_last），回归见 §4.11
  - [RX 反序列化验证报告（独立）](design_rpt/rx_deserial_verification.md) 📊 11 用例 × base/fixed 双模式全过（全包型逐字节 / 异常释放 / 门控边界 / SYNC 接受窗口 [4,7] 边界 / `usb_rst` 强退 E6·E7·E8 / 编译零 error·warning）
  - [时钟切换设计报告](design_rpt/02_clk_mux_design.md) 📐 Intel 方案（已选定）：dclk/clk12s 无毛刺切换 → clk12m 驱动 SIE
  - [时钟切换验证报告（独立）](design_rpt/clk_mux_verification.md) 📊 7 用例全过；含**首跑就抓出的 1 个 RTL 毛刺缺陷**；§7 = DUT branch/expr/toggle 全 100%、line 7/8
  - [TX 串行器设计报告](design_rpt/tx_serial_design.md) 📐 设计定稿 + RTL 已落地（1× clk12m 域；自产 SYNC/位填充/EOP，出 `tx_bit`/`tx_se0`/`tx_en`；不碰 CRC/PID）；§4.7 = **7 张真 VCD 波形图**，§4.8 = 验证环境与覆盖矩阵（20 用例）
  - [TX 串行器验证报告（独立）](design_rpt/tx_serial_verification.md) 📊 20 用例全过（回环 + 逐位 oracle；全字节扫描 256×2 / 跨字节边界扫描 256 组 / 随机压测 300 包×5 种子 / 挂起·远程唤醒旁路；含 **2 个 RTL 缺陷的定位·修正·反向验证**；编译零 error·warning；§8 = **Verilator 覆盖率**：DUT 分支/表达式/翻转 100%、行 25/26、FSM 6 态 16/16 弧，且覆盖率反揪出一个 TB 复位序列缺陷）
  - [总线状态检测设计报告](design_rpt/bus_state_design.md) 📐 判据跑 ref_clk、四个 clk12m 单拍脉冲；一条计数器 + 两个标志位 + 两个翻转位，无状态机
  - [总线状态检测验证报告（独立）](design_rpt/bus_state_verification.md) 📊 14 用例全过（判据/载体/脉冲三处计数相等、脉冲宽 1 个 clk12m 拍、跨域延迟 1..4 ref 拍）；§6 = **Verilator 覆盖率**：DUT 四维全 100% + 标志位 3/3 状态、8/8 合法弧，并揪出一个 RTL 缺陷
- [第三章 usb_sie_cdc 跨时钟域桥](03_usb_sie_cdc_design.md) ✅ 已实现 + 仿真验证
  - 全设计唯一异步 CDC：clk12m ↔ pclk 四相闭环握手（无 FIFO），pclk≥24MHz
- 第四章 usb_sie 串行接口引擎
  - [SIE 设计报告](design_rpt/usb_sie_design.md) 📐 RTL 已落地，**本轮只做接收（RX）**：两级 FSM + 字节并行 CRC + 包缓冲，收发边界见 §1.2；§4 = 13 张真 VCD 波形图
  - [SIE 验证报告（独立）](design_rpt/usb_sie_verification.md) 📊 12 用例全过（token/长度谱/五类坏包/应答真值表六级优先/SETUP 特例/toggle/周转超时/溢出护栏/杂散包/缓冲流控/附着复位/时序下限）；§6 = **Verilator 覆盖率**（DUT 口径）+ 事务态矩阵 4/4 合法弧，并查出 `turn_cnt` 饱和臂为死逻辑
- 第五章 usb_ep_fifos 端点存储
- 第六章 usb_apb_slave + usb_regs
- 第七章 apb_usb_top 顶层集成
- 第八章 验证环境
- [PHY 设计报告（汇总）](design_rpt/phy_design.md) 📐 PHY 全貌（RX/TX 通路 + 时钟域 + 顶层端口与接线 + 子模块 + 模块框图）
- [PHY 顶层集成验证报告](design_rpt/phy_verification.md) 📊 18 用例全过（冷启动 / 连接 / 挂起唤醒 / 总线复位 / 挂起中拔出再插回 / RX 字节级复现 / 单字节握手包与 64 字节满长包 / 中止与软复位 / 发送与 driving / 收发往返换向 / 40 趟时钟源切换）；§6 = **Verilator 覆盖率**：DUT toggle 92/92 = 100%，并逐条定性子模块经顶层这一遍的差值

---

*状态：模块① 公共原语已验证；PHY 顶层 `usb_dpll_phy` 与五个子模块（CDR / clk_mux / RX 反序列化 / TX 串行器 / 总线状态检测）RTL + 验证完成；
usb_sie_cdc 已验证；SIE 事务层（RX 侧）RTL + 验证完成，发包轮待做。*
