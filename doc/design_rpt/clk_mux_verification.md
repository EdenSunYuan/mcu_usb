# usb_clk_mux 模块验证报告

> 模块：`usb_clk_mux`（SIE 1× 时钟 `clk12m` 的无毛刺切换开关，PHY 子模块）——`ref_clk` 域
> 日期：2026-09-20（首版；本文含**首跑就抓出的 1 个真实 RTL 缺陷**，见 §5）
> 工具：iverilog + vvp（`-g2012 -Wall`），自检全部在 Verilog 内完成（非人工看波形）
> 源码：`src/phy/usb_clk_mux.v`
> 测试：`sim/clkmux/tb_clk_mux.v` + 7 个 `case_*.v`（`+case=` 分发，逐 case 独立 log）
> 相关：设计报告 [02_clk_mux_design.md](02_clk_mux_design.md)（§4.2/§4.3 已按本文 §5 修订）；
> 波形用 `make debugwave MOD=clkmux` 或 `tools/wave_debugger.py sim/clkmux/*.vcd`

---

## 1. 概述

`usb_clk_mux` 在**恢复时钟 `dclk`**（接收）与**本地 `clk12s` = ref_clk÷4**（发送/空闲）
之间二选一输出 `clk12m`，靠「切断旧时钟 → 拉低过渡 → 接入新时钟」三段式切换保证无毛刺。
它不产生时钟、不知道包边界，只管把谁接到 SIE 上。

验证目标：在**复位默认态 / 两个切换方向 / 过渡开销 / 切换途中改主意 / 连续切换 /
恢复时钟缺失**六类场景下证明——

1. **选路正确**：逐拍 `clk12m` == 当前状态应选的那路（或过渡态恒 0），无例外；
2. **无毛刺**：`clk12m` 的每个跳变都来自当拍所选时钟自己（不截短、不多沿）；
3. **可用性**：复位后即可用；`dclk` 恒 0（DPLL 未锁）时本地时钟照常工作；
4. **过渡必要**：两个方向都必须经过渡态，不做直通切换。

**本模块无 MODE 派生**：只有一份 RTL、7 个用例各跑一次。

## 2. 测试环境

| 项目 | 说明 |
|---|---|
| RTL（DUT） | `src/phy/usb_clk_mux.v`（`ref_clk` 域：÷4 分频 + 4 态 FSM + 组合 MUX） |
| Testbench | `sim/clkmux/tb_clk_mux.v`：dclk 发生器 + 逐拍采样统计 + `+case=` 分发 |
| Case 文件 | `sim/clkmux/case_*.v`（7 个），逐 case 独立 log `sim_clkmux_<case>.log` |
| 激励方式 | TB 直接驱动 `rcv`，并自造 `dclk`；不需要 PHY/CDR 模型 |
| 时钟 | `ref_clk` 48MHz（半周期 10.417ns）；`clk12s` 由 DUT 内部 ÷4 产生 |

**`dclk` 的建模（本 TB 的关键）**：不是简单 ÷4，而是**边沿对齐 ref_clk、周期在 3/4/5 拍
之间轮转**的恢复时钟——这正是 DPLL 用 4× 量化把主机相位「掰」到 ref_clk 格子上的样子。
只有非整除的 `dclk` 才能真正验证「切换只等电平、不数拍」：任何「数够 4 拍再切」的实现
都会在这里挂掉。`dclk_en=0` 时 `dclk` 恒 0，模拟 DPLL 未锁。

## 3. 判据：两层，缺一不可

**① 恒定判据（逐拍完备）**：`clk12m` 必须逐拍等于「当前状态应选的那路」——
`ST_RCV→dclk`、`ST_TX→clk12s`、过渡态→`0`。

> 这条覆盖是**完备**的：两路被切换的时钟边沿都对齐 `ref_clk`，状态机也只在 `ref_clk` 沿变，
> 所以 `clk12m` 在两次采样之间**恒为常数**，不存在藏在采样点之间的 runt。
> 故「逐拍采样 + 三态比对」等于对波形的完整刻画。

**② 沿的来路判据（无毛刺的严格定义）**：`clk12m` 的**每一个跳变，都必须是当拍所选时钟
自己的跳变**。MUX 只是三选一，输出的沿只允许来自被选中的那一路；若某个沿不是它的
（典型：把还高着的旧时钟一刀切断），就是多出来的沿 → 计入 `glitch_cnt`
（细分 `spur_rise` / `spur_fall`）。

> 这两条判据是**独立**的：① 只看电平，② 只看沿。缺陷可能只被其中一条抓到——
> §5 那个 runt 两条都抓到了（② 报 `spur_fall=1`，① 的伴随现象是上升沿间隔掉到 2 拍）。

辅助统计（不单独作判据，用于把「切换开销」量化）：高/低电平宽度极值、上升沿间隔极值、
自建的 FSM 停留拍数与迁移矩阵。

## 4. 测试用例与结果（7/7 PASS）

| 用例 | 因 → 变 → 果 | 实测数字 |
|---|---|---|
| `mux_reset_default` | 复位撤销、`rcv=0`、`dclk` 恒 0 → FSM 停 `ST_TX` 选 `clk12s` → 干净 12MHz | 周期 4..4 拍、高 2..2 拍、低 2..2 拍、上升沿 49 |
| `mux_tx2rx_glitchfree` | `ST_TX` 稳态 40 拍后 `rcv`↑ → 低点断离 `clk12s` → `HOLD2` → 等 `dclk` 低接入 | 上升沿 11、间隔 3..5 拍、`HOLD2` 停 2 拍、毛刺 0 |
| `mux_rx2tx_glitchfree` | `ST_RCV` 稳态 40 拍后 `rcv`↓ → 低点断离 `dclk` → `HOLD1` → 等 `clk12s` 低接入 | 切换段间隔 4..4 拍、`HOLD1` 停 2 拍；回到 `ST_TX` 后 40 拍周期 4..4、高 2..2 |
| `mux_hold_deadtime` | `ST_RCV` 稳态后 `rcv`↓ → 断离 + 等低点接入 → 量这次的低电平窗口 | **3 拍 ≈62.5ns**，毛刺 0 |
| `mux_rcv_midswitch` | `rcv` 1→0 发起 RX→TX，刚进 `HOLD1` 就把 `rcv` 翻回 1 → `HOLD1` 只认 `clk12s` 低点、不含 `rcv`，本次迁移**不被中止** → 走完到 `ST_TX` 后按新 `rcv` 转回 `ST_RCV` | 两条过渡腿都走过、毛刺 0 |
| `mux_toggle_stress` | `ST_TX` 稳态后 `rcv` 连续翻转 20 次（每次切到位再跑 5 拍） → 每次都由 3/4/5 拍抖动的 `dclk` 决定断离/接入相位 → 累计毛刺 | 20 次切换、**毛刺 0**、间隔 3..7 拍、TX→HOLD2 与 RCV→HOLD1 各 10 次 |
| `mux_noclk_at_reset` | DPLL 未锁 `dclk` 恒 0 → A 段 `rcv=0` 走本地 `clk12s`；B 段 `rcv=1` 进 `ST_RCV` 选到恒 0 的 `dclk`；C 段回 `ST_TX` | A 段周期 4..4；B 段 `ST_RCV` 内上升沿 **0**（干净停住）；C 段周期 4..4 |

**为什么"过渡开销 = 3 拍"是合理的**（`mux_hold_deadtime`）：低电平窗口 =
正常低电平的一部分 + 等 `clk12s` 低的过渡 + 接入后到下一个 `clk12s` 上升沿的余量，
上界 6 拍（≈125ns）。实测 3 拍落在区间中段。这是**切换的固有代价**：一个 12Mbps 的位
83ns，一次方向切换最多吃掉 1.5 个位时间；且它必然发生在事务之间（`rcv` 只在事务切换时
才动），不落在任何一个位窗口里。用例判据取 `[2,6]` 拍并已在文件头写明推导。

## 5. 仿真发现的 RTL 缺陷（首跑即抓到，已修）

### 5.1 现象

`mux_tx2rx_glitchfree` **首跑 FAIL**：`spur_fall=1`、最短上升沿间隔 **2 拍**（标称 4）。

### 5.2 波形证据（`mux_tx2rx_glitchfree.vcd`，单位 ps，`ref_clk` 半周期 10417）

| 时刻 | 变化 | 说明 |
|---|---|---|
| 1385461 | `clk12s`→1、`clk12m`→1、**`rcv`→1** | `rcv` 恰好在 `clk12s` 上升沿那一拍起来 |
| 1406295 | `st`→`HOLD2`、`clk12m`→0；**`clk12s` 仍为 1** | 断离点落在高相位的**第 1 拍** |
| 1427129 | `st`→`ST_RCV`、`clk12m`→1（`dclk`↑）、`clk12s`→0 | 2 拍后接上 `dclk` |

⇒ `clk12m` 高电平只有 **1 拍 (20.8ns)**，标称是 2 拍 (41.7ns)；相邻两个上升沿只隔 **2 拍**，
即这一拍时钟跑成了 ~24MHz。**多出来的那个下降沿 `clk12s` 自己并没有** → 判据 ② 判为毛刺。

### 5.3 根因

`ST_TX` 的断离条件是 `rcv && clk12s`（**高点**断离）。`clk12s` 高相位有 2 拍，若 `rcv`
恰在第 1 拍起来，FSM 下一拍就切走 —— 等于把一个还没走完的高电平**一刀截断**。

设计报告 §4.3 当时的口径是「高点断离、输出 1→0 是一次干净下降沿」，并断言「只要守住两条
不变式（断开后必进过渡态、接入前必等低电平），无论在哪点断都不会出毛刺」。**仿真的结论是
这两条不变式不充分**：下降沿确实"干净"（落在 `ref_clk` 沿上），但它是一个**原时钟没有的沿**，
并且把高电平腰斩 —— 这正是经典意义上的 runt。

### 5.4 修复与 A/B 证据

把 `ST_TX` 的四条件口径统一为**低点断离**（`rcv && clk12s_low`，一行）：

```verilog
stat_nxt[1:0] = (rcv && clk12s_low) ? ST_HOLD2 : ST_TX;   // 原: (rcv && clk12s)
```

| RTL | 结果 |
|---|---|
| 修复前（高点断离） | **4/7 PASS**；`mux_tx2rx` / `mux_rcv_midswitch` / `mux_toggle_stress` 均报 `spur_fall=1` |
| 修复后（低点断离） | **7/7 PASS**；`mux_tx2rx` 最短间隔 2→**3** 拍，`HOLD2` 停 1→2 拍 |

修复后 `clk12m` 的所有沿都来自当拍所选时钟自己，判据 ② 全程零违例。
代价：`rcv` 起来后最多多等 2 拍（41.7ns）才切换 —— 在事务之间，无影响。

设计报告 §4.2 / §4.3 已按本节同步修订。

### 5.5 顺带修掉的两个 **TB** 缺陷（非 RTL，记录以免误读旧日志）

1. **窗口起点的假边沿**：`win_clear` 原把 `clk12m_d` 清 0，而窗口起点不落在时钟沿上——
   若此刻 `clk12m` 恰为高，就会凭空造出一个"上升沿"，再与真实沿相减得到虚假的 **3 拍周期**。
   改为以**当前值**打底后，`mux_reset_default` 的周期从 `3..4` 收敛到 `4..4`。
2. **FSM 统计被入口路径污染**：`rx2tx` / `rcv_midswitch` 必须先从复位默认态 `ST_TX` 走到
   `ST_RCV`，这段入口路径本身就会经过 `HOLD2`；若不重开统计，`fsm_visit[F_HOLD2]==0`
   这条断言会被弄成假阳性（实测在换 RTL 后立刻暴露）。改为在**发起切换前** `fsm_clear`
   并跑 2 拍对齐基准。

## 6. 编译卫生

`iverilog -g2012 -Wall` 编译本模块**零 error**；唯一输出是 `timescale` 继承提示
（模块不写 `\`timescale`、跟随 TB），与 `usb_rx_cdr` / `usb_tx_serial` 一致。

`rtl_auto_tools` lint（`design.f` 已加入本模块）：无未驱动 / 未使用 / 未声明；
报出的 4 条 `[多驱动]` 是工具的启发式误报（把 `wire X;` 声明本身当成一个驱动），
与 `usb_rx_cdr`（5 条）、`usb_tx_serial`（12 条）同一类，非真问题。

## 7. 覆盖率（Verilator，7 用例合并）

### 7.1 结论：DUT 分支/表达式/翻转全 100%，行余 1 条为 `case` 兜底

| 维度 | DUT `usb_clk_mux` | 判定 |
|---|---|---|
| 行 line | 7/8 = 87.5% | 余 1 条为 `case` 的 `default` 兜底，**结构不可达**（§7.4） |
| 分支 branch | 16/16 = **100%** | ✅ |
| 表达式 expr | 20/20 = **100%** | ✅ |
| 翻转 toggle | 28/28 = **100%** | ✅ |
| FSM 状态 | 4/4 | ✅ TB 自建统计（§7.3） |
| FSM 迁移弧 | **8/8 合法弧** | ✅ 零非法迁移 |

### 7.2 复跑方法

```bash
make cov     MOD=clkmux       # Verilator 建 → 跑全 7 用例 → 合并 → 打印 summary
make fsmcov  MOD=clkmux       # 合并 TB 侧的 4×4 状态迁移矩阵
make covclean MOD=clkmux      # 删 cov/

# ★ 报数口径是「按模块取」，不是全层级 summary：
verilator_coverage --report hier cov/merged.dat       # 取 usb_clk_mux 那 4 行
verilator_coverage --annotate cov/ann --annotate-min 1 cov/merged.dat   # 未覆盖点定位到行
```

`make cov` 先用同一套 TB 的功能判据卡一遍：**任用例非 `TEST PASSED` 即中止**，
不会拿一次跑挂的激励去出覆盖率数字。

### 7.3 工具与口径（两点必须说明）

1. **为什么是 Verilator**：iverilog 无覆盖率能力。两仿真器跑同一份 TB，
   **功能判据仍以 iverilog 回归为准**，Verilator 只负责出数字。
2. **FSM 那一维是自建的**：Verilator 的 `--coverage-fsm` 认不出本 DUT 的两段式 FSM
   （组合算 `stat_nxt` + 时序搬 `stat_cur`），`merged.dat` 里 **0 条 fsm 记录**
   （`fsm_state/fsm_arc` 恒为 0/0）。故在 TB 侧分层引用 `u_dut.stat_cur` 自己数
   （`print_fsm_coverage`），再用 `tools/merge_fsm_cov.py --profile clkmux` 跨用例相加。

**合并后的 FSM 迁移矩阵**（拍数，7 用例相加）：

| from\to | RCV | HOLD1 | HOLD2 | TX |
|---|---:|---:|---:|---:|
| RCV | 176 | 14 | 0 | 0 |
| HOLD1 | 0 | 4 | 0 | 14 |
| HOLD2 | 14 | 0 | 1 | 0 |
| TX | 0 | 0 | 14 | 465 |

每态只有「自环 + 一条出边」，与 `stat_nxt` 的 `case` 逐条对应；4 个状态全停留过，
8 条合法弧全走到，**零意图外迁移**（脚本未报 `⚠`）。

### 7.4 未覆盖项的定性：只剩一条 `case` 兜底

`cov/ann/usb_clk_mux.v` 里唯一 `%000000` 的行是 `default: stat_nxt = ST_TX;`。

**定性：结构不可达，属正常豁免。** `stat_cur` 是 2 bit、4 个编码全被 `localparam` 占满，
不存在未定义编码，故 `default` 臂永不可达。它是 `code_rtl.md` 规则 4「`case` 必须补全」
的强制产物 —— 与 `usb_tx_serial`（§8.4）、`usb_rx_deserial`（§7.4）的豁免项同一类。
**除此之外无任何未覆盖项**。

### 7.5 非 DUT 层级的口径（避免误读 summary）

`make cov` 打印的全层级 summary 里 toggle 只有 26.6%、branch 63.7% —— 那是把 **TB 自己**
（`dclk` 发生器的 `dclk_hp_seq[8]`、`dclk_idx[2:0]`、`dclk_cnt[3:0]` 等一大批常量初值表
与统计变量）算进去的结果，**与 DUT 质量无关**。判读一律用 §7.1 的 DUT 口径。

## 8. 结论

- **7/7 用例 PASS**，覆盖 6 类场景；`clk12m` 逐拍选路正确、全程无毛刺。
- DUT（`usb_clk_mux`）**分支 / 表达式 / 翻转全 100%**，行 7/8（唯一缺口是结构不可达的
  `case` 兜底）；FSM **4/4 状态 + 8/8 合法弧**，零非法迁移。
- 验证过程**抓出并修复 1 个真实 RTL 缺陷**（TX→RX 高点断离把 `clk12s` 高电平腰斩，
  §5），同时改掉 2 个会污染判读的 TB 缺陷（§5.5）。
- 遗留：`usb_clk_mux` 尚未接入顶层（PHY 组装 + SIE 事务层未做），`rcv` 的 STA 约束
  （`set_max_delay`，点对点形式）待综合阶段落地，见设计报告 §4.6。
