# sim/clkmux — usb_clk_mux 单元测试

被测：`src/phy/usb_clk_mux.v`（ref_clk 域 4 态切换 FSM + ÷4 分频 + 组合 MUX）。
设计报告：`doc/design_rpt/02_clk_mux_design.md`；验证报告：`doc/design_rpt/clk_mux_verification.md`。

## 跑法

```bash
make -C sim/clkmux run          # 7 用例全跑（≈2 秒）
make -C sim/clkmux build        # 只编译
make -C sim/clkmux clean        # 清 .vvp/.log（保留 .vcd）

# 根入口
make clkmux                     # 等价于 make -C sim/clkmux run（已进 MODULES）
make cov     MOD=clkmux         # Verilator 覆盖率，7 用例合并
make fsmcov  MOD=clkmux         # FSM 状态/弧覆盖率（TB 侧统计后合并）
make covclean MOD=clkmux        # 删 cov/
make debugwave MOD=clkmux CASE=mux_tx2rx_glitchfree   # 出 VCD + 打开 wave_debugger
```

没有 MODE 开关：本模块只有一份 DUT（不像 deserial 有 sim 本地变体）。

## 用例

| 用例 | 考什么 |
|---|---|
| `mux_reset_default` | 复位默认态 ST_TX：clk12m 立即可用 = clk12s，周期/高低恒 4/2/2 拍 |
| `mux_tx2rx_glitchfree` | TX→RX 无毛刺（低点断离 → HOLD2 → 等 dclk 低接入） |
| `mux_rx2tx_glitchfree` | RX→TX 无毛刺（低点断离 → HOLD1 → 等 clk12s 低接入） |
| `mux_hold_deadtime` | 过渡态"拉低缓冲"把低电平拉长了多少拍（实测 3 拍 ≈62.5ns） |
| `mux_rcv_midswitch` | 切换途中 rcv 反转不中止本次迁移，走完再重新判决 |
| `mux_toggle_stress` | 连续反向切换 20 次，累计毛刺 = 0 |
| `mux_noclk_at_reset` | dclk 恒 0（DPLL 未锁）时本地时钟仍可用；进 ST_RCV 后输出干净地停住 |

每条用例的判据都写在文件头（因 → 变 → 果 + 前后文窗口 + 量化判据），见
`sim/common/README.md` 的仿真规范。

## 两条判据（其它模块没有第二层）

**① 恒定判据（逐拍完备）**：`clk12m` 必须逐拍等于"当前状态应选的那路时钟"——
`ST_RCV→dclk`、`ST_TX→clk12s`、过渡态→`0`。这条覆盖是完备的：两路源时钟的边沿都
对齐 ref_clk，状态机也只在 ref_clk 沿变，所以 `clk12m` 在两次采样之间恒为常数，
不存在藏在采样点之间的 runt。

**② 沿的来路判据（无毛刺的严格定义）**：`clk12m` 的**每一个跳变，都必须是当拍所选
时钟自己的跳变**。MUX 只是三选一，输出的沿只允许来自被选中的那一路；若某个沿不是它
的（典型：把还高着的旧时钟一刀切断），就是多出来的沿 —— 计入 `glitch_cnt`
（细分 `spur_rise` / `spur_fall`）。

> ★ 这条是本模块的核心判据，不是可选项。2026-09-20 第一次跑就靠它抓出真实缺陷：
> `ST_TX` 原按设计报告 §4.3 在 `clk12s` **高点**断离，当 `rcv` 恰在 `clk12s` 上升沿
> 那一拍起来时，高电平被截成 1 拍（标称 2 拍）、并多出一个 `clk12s` 自己没有的下降沿
> （`spur_fall=1`、最短间隔 2 拍）。改成低点断离后 7/7 全过。详见验证报告。

## dclk 为什么要做成 3/4/5 拍摆动

TB 不用"简单 ÷4"产生 `dclk`，而是边沿对齐 ref_clk、周期在 3/4/5 拍之间轮转 —— 这正是
DPLL 用 4× 量化把主机相位"掰"到 ref_clk 格子上的样子。只有非整除的 `dclk` 才能真正
验证「切换只等电平、不数拍」：凡是"数够 4 拍再切"的实现都会在这里挂掉。

## clk12m 为什么是组合输出

规则 6 要求输出 DFF 直出，`clk12m` 是**显式例外**（RTL 里已登记）：无毛刺的全部机理
就是「过渡态输出恒 0 + 只在目标时钟为低时接入」，把它寄存器化等于给时钟加一拍延迟，
并毁掉"0→0 无缝"这个性质。时钟路径不适用 DFF 直出。

## 覆盖率

```bash
make cov MOD=clkmux     # 报数口径看 usb_clk_mux 模块那一行, 不是全层级 summary
make fsmcov MOD=clkmux  # Verilator 的 --coverage-fsm 认不出两段式 FSM(0/0), 故由 TB 自数
```

数字与未覆盖项定性见 `doc/design_rpt/clk_mux_verification.md` 的覆盖率章节。
