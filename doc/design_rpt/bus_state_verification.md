# usb_bus_state 模块验证报告

> 模块：`usb_bus_state`（总线状态检测：连接 / 复位 / 挂起 / 唤醒）
> 被测 RTL：`src/phy/usb_bus_state.v`
> 设计报告：[bus_state_design.md](bus_state_design.md)
> 仿真目录：`sim/busstate/`（14 用例）　规范：`sim/common/README.md`
> 日期：2026-09-28　结论：14/14 PASS，DUT 四个覆盖率维度全 100%

---

## 1. 概述

要证明的事就一条：每一次总线宏观事件，都恰好变成一个 `clk12m` 单拍脉冲。四个输出是 SIE 的输入，多一个脉冲 SIE 会多解一次事务，少一个它就一直停在挂起态出不来。

判据在 `ref_clk` 域算，输出在 `clk12m` 域组合直出，中间隔着两个标志位、两个翻转位和四条两拍同步链。这条链不短，所以验证没有只盯输出，而是按「因 → 变 → 果」在三个位置各数一遍：

| 位置 | 信号 | 期望 |
|---|---|---|
| 因（判据） | `con_cond` / `sus_cond` / `rst_cond` / `rsm_cond` | 每次事件恰好 1 拍 |
| 变（载体） | `connected` / `suspended` 上升沿，`rst_tgl` / `rsm_tgl` 变化 | 恰好 1 次 |
| 果（输出） | 四个事件脉冲 | 恰好 1 个，宽 1 个 `clk12m` 拍 |

三个数对得上，就排除了「一次判据出两个脉冲」和「一次脉冲来自两次判据」这两类错误。翻转通知还有它自己的失效方式，两次翻转挨得太近会互相抵消，这条单列了用例（§4.3）。

## 2. 测试环境

- DUT 直连：`tb_bus_state.v` 里的 `u_dut` 就是被测模块，没有回环链，也没有参考模型。
- 时钟：`ref_clk` 48MHz（半周期 ≈10.417ns）；`clk12m` 由它派生、上升沿对齐，标称周期 4 拍（`div4[1]`）。加 `+jit=1` 时按 3/4/5 拍轮转，模拟 `dclk` 的抖动（§4.6）。
- 激励：直接驱 `line_s`/`tx_en` 两根输入，电平保持多久就用拍数写（`drive(a,b,n)`）。TB 里有一级打拍模型上游 `usb_rx_deserial` 的采样寄存器，`line_s` 端口看到的时序与它自己采时一致，所以门限和延迟读数不变。本模块不解析位，激励也就不必造包。
- 观测：三组总线，`cond_bus`（四条判据）、`mid_evt`（四个载体）、`pulse_bus`（四个输出），逐拍比较取沿或取变化，计数由 TB 自己维护。
- 全局不变量四条：`global_output_mutex`（任意 `clk12m` 拍至多一路输出为高）、`global_unreachable_flag_combo`（`connected=0 且 suspended=1` 的停留拍数必须为 0），外加两条盯住第五个输出 `bus_suspended` 的：任一 `clk12m` 沿上与 `u_dut.sus_s[0]` 不等的拍数必须为 0（防止接成 `ref_clk` 域那个 `suspended`），上升沿与 `suspend_evt` 不同拍的次数必须为 0。

每个用例的判据写在 `sim/busstate/case_*.v` 文件头，带前后文窗口和量化值。

```bash
make -C sim/busstate run          # 14 用例，约 20 秒（含 3ms 挂起窗）
make cov MOD=busstate             # 覆盖率（14 用例合并）+ fsmcov
make -C sim/busstate debugwave CASE=bs_connect   # VCD + wave_debugger
```

## 3. 测试用例与结果

| 用例 | 考什么 | 关键读数 |
|---|---|---|
| `bs_reset_default` | 复位清零；冷启动长 SE0 不报复位 | `cnt` 停在 121，四条判据全 0 |
| `bs_connect` | J ≥2.5µs 出一次 `connect_evt` | 三处计数 1/1/1，宽 1 拍 |
| `bs_suspend` | 空闲 J ≥3ms 出一次 `suspend_evt` | 三处计数 1/1/1，再等 3ms 不重复 |
| `bs_resume` | 挂起中主机 K 出 `resume_evt` | 三处计数 1/1/1，`suspended` 落 0 |
| `bs_short_k` | 短 K（28 拍）不算唤醒 | 判据/脉冲 0，挂起保持 |
| `bs_threshold_scan` | 门限扫描 SE0 / K 各 116..130 拍 | 首出拍 = 122（§4.1） |
| `bs_self_drive` | 自驱 K / 自驱 SE0 都不出事件 | 两窗口判据与脉冲全 0 |
| `bs_bus_rst` | 已附着后 SE0 出 `usb_bus_rst` | 10ms 长 SE0 里只 1 个脉冲 |
| `bs_two_resets` | 两次复位各报一次 | 累计三处计数都 = 2，`rst_tgl` 回 0 |
| `bs_usb_rst` | `usb_rst` 清标志位、不动翻转位 | 无假脉冲，清后能重连 |
| `bs_k_when_awake` | 未挂起时的长 K 不报唤醒 | 判据 0，回 J 后照常挂起 |
| `bs_se1_stuck` | SE1 持续 10ms 不出事件 | 四条判据全 0 |
| `bs_clk_jitter` | 周期 3/4/5 拍轮转下四类事件照常 | 四个脉冲宽度都是 1 拍 |
| `bs_latency_phase` | 触发沿平移扫 `clk12m` 四相位 | 延迟全落在 1..4 `ref` 拍（§4.4） |

14 个用例全过。每个用例末尾会打印三处计数、脉冲宽度和延迟范围，这些读数都在预期区间里。

## 4. 关键场景

### 4.1 实测门限 122 拍，比标称多 2 拍流水

`bs_threshold_scan` 是这么扫的：前后各静置 200 拍 J，中间给一段定长 SE0（或 K），长度从 116 拍一路加到 130 拍。两种线的结果一样，121 拍不出事件，122 拍出，再长也只出一次。

多出来的 2 拍是固定流水，不是门限漂移。`line_s` 那一拍采样占 1 拍，线变化那一拍 `cnt` 被清零、要到下一拍才开始累加。也就是说，输出落在第 122 拍时，线上的电平正好是 2.5µs 整（120 拍）。

📎 [图：SE0 门限与判据（busstate_bus_rst.png）](../fig/busstate_bus_rst.png)

图从 `line_s` 落到 SE0 起画：`rst_cond` 只高 1 拍（判据是单拍），`rst_tgl` 随即翻一次（clk12m 上升沿），两拍后 `rst_s` 由 `2'b00` 变 `2'b01`，`usb_bus_rst` 同时拉起，下一个 `clk12m` 沿 `rst_s` 变 `2'b11`、脉冲落下。高电平恰好一个 `clk12m` 周期。

### 4.2 两类载体：标志位取沿、判据取翻转

四个事件源分两类，跨域走两条不同的路（设计报告 §2.6）：

| 事件 | 载体 | 取法 | 为什么 |
|---|---|---|---|
| `connect_evt` | `connected` | 上升沿 | 标志位，连上后一直保持 |
| `suspend_evt` | `suspended` | 上升沿 | 标志位，挂起后一直保持 |
| `usb_bus_rst` | `rst_tgl` | 异或（新旧不同） | 判据是单拍脉冲，取不了沿 |
| `resume_evt` | `rsm_tgl` | 异或（新旧不同） | 同上 |

📎 [图：标志位取沿（busstate_connect_pulse.png）](../fig/busstate_connect_pulse.png)

`con_cond` 高 1 拍后 `connected` 置起，同步链 `con_s` 走 `2'b00 → 2'b01 → 2'b11`，`connect_evt = con_s[0] & ~con_s[1]` 只在 `2'b01` 那一拍为高。取沿的两位是同一条链上相邻的触发器，每个 `clk12m` 沿最多变一位，与和异或都不出毛刺。

📎 [图：门限与计数（busstate_connect_threshold.png）](../fig/busstate_connect_threshold.png)

同一景换个宽窗口看：线保持 J，`cnt` 一路爬，`cnt_2p5u` 只在到门限那一拍为高（20.8ns），`con_cond` 与它同拍，`connect_evt` 等同步链走完才出脉冲。

### 4.3 翻转通知不会两翻相消

`rst_tgl` 每来一次判据翻一次。两次事件挨得太近的话，第二翻会把第一翻抵消掉，两个事件在 `clk12m` 侧看起来只跳变了一次。两次同类事件至少隔 2.5µs（120 拍），比一个 `clk12m` 周期（4 拍）长得多，所以不会发生。

`bs_two_resets` 就是奔着这条去的：两次总线复位中间隔 600 拍空闲 J，结果是两个脉冲，累计三处计数都 = 2，`rst_tgl` 最后回到 0。

`bs_usb_rst` 测的是另一面：`usb_rst` 只清 `cnt` 和两个标志位，不动两个翻转位。它要是把翻转位一起清了，`clk12m` 一侧会看到一次跳变，凭空多出一个事件脉冲。用例先把两个翻转位置到 1，再打 `usb_rst`，检查没有脉冲出来。

### 4.4 跨域延迟 1..4 个 `ref` 拍，上界一个 `clk12m` 周期

延迟取决于判据落在 `clk12m` 的哪个相位。`bs_latency_phase` 把触发事件的那次线变化整体平移 0..3 拍，扫遍四个相位，四类事件的读数一致：

| 相位 p | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| 判据 → 脉冲（`ref` 拍） | 3 | 2 | 1 | 4 |

四类的范围都是 1..4，上界 4 拍就是一个 `clk12m` 周期 ≈83ns，一次事件最晚 83ns 到达。这是 SIE 侧握手要留的余量。

### 4.5 自驱期间不出事件

远程唤醒时设备自己驱 K 1~15ms，包尾 EOP 也是自己驱的 SE0。这两种都得算「无事件」，不然自己发的 K 会把自己唤醒，自己的 EOP 会被当成总线复位。挡的只是设备自己驱的这一段：设备交高阻后主机接管驱 K ≥20ms，那段是主机驱的，`resume_evt` 照常出，远程唤醒最终也是靠它收尾（设计报告 §2.7）。

📎 [图：自驱 K 期间判据被挡（busstate_self_drive.png）](../fig/busstate_self_drive.png)

`tx_en=1`（`driving=1`）期间线被驱成 K 持续 1ms，远过 2.5µs 门限，但 `rsm_cond` 恒 0、`resume_evt` 无脉冲：`driving` 每拍清 `cnt`，四个判据又各带 `~driving`。撤掉驱动后主机再驱 K 400 拍，`resume_evt` 照常出、`suspended` 落 0，门控没有把判据弄坏。

### 4.6 `clk12m` 抖动下脉冲形状不变

`+jit=1` 让 `clk12m` 周期按 3/4/5 拍轮转，也就是 `dclk` 经 `usb_clk_mux` 切过来时的样子。四类事件依次来一遍，三处计数各自相等，四个脉冲宽度都是 1 个 `clk12m` 拍。两拍同步链只依赖「边沿对齐 `ref_clk`」，不依赖周期恒定。

### 4.7 挂起与被动唤醒

📎 [图：空闲 3ms 出 suspend_evt（busstate_suspend.png）](../fig/busstate_suspend.png)

线一路保持 J（`2'b10`），到 3ms 时 `cnt_3ms` 高 1 拍、`sus_cond` 同拍，`suspended` 置起，`suspend_evt` 出 1 拍。`cnt` 的上界是 `CNT_3MS+1`，到顶即停，判据就这一拍。

📎 [图：主机 K 出 resume_evt（busstate_resume.png）](../fig/busstate_resume.png)

挂起中主机驱 K：`rsm_cond` 1 拍 → `rsm_tgl` 翻一次 → `rsm_s` 变 `2'b01` → `resume_evt` 1 拍，同一拍 `suspended` 落下。`suspended` 的下降沿不算事件，唤醒有自己的通路。

## 5. 编译卫生

```bash
iverilog -g2012 -Wall -I../../src/inc -I../common -o /tmp/x.vvp tb_bus_state.v usb_bus_state.v
verilator --lint-only -Wall -Wno-fatal --top-module usb_bus_state usb_bus_state.v
```

两条都零 error、零 warning。

## 6. 覆盖率（Verilator 5.052，14 用例合并）

### 6.1 结论：DUT 四个维度全 100%

报数口径是 DUT 模块 `tb_bus_state.u_dut`，由 `--report summary,hier` 取该行：

| 维度 | DUT | 判定 |
|---|---|---|
| 行 line | 10/10 = 100% | ✅ |
| 分支 branch | 42/42 = 100% | ✅ |
| 表达式 expr | 76/76 = 100% | ✅ |
| 翻转 toggle | 178/178 = 100% | ✅ |
| 标志位状态 | 3/3 | ✅ 自建统计（§6.4） |
| 标志位迁移 | 8/8 合法弧 | ✅ 零意图外迁移 |

没有未覆盖项，也就没有需要豁免的兜底分支。本模块没有 `case`/`default`，四条判据和两条 `_nxt` 三目链的每一侧都被真实激励走过。

### 6.2 复跑方法

```bash
make -C sim/busstate cov        # 建 → 跑全 14 用例 → 合并 → 打印 summary
make -C sim/busstate fsmcov     # 合并 TB 侧的状态/迁移矩阵
make -C sim/busstate covclean   # 删 cov/

# DUT 口径：
verilator_coverage --report summary,hier cov/merged.dat      # 取 tb_bus_state.u_dut 那几行
verilator_coverage --filter-type <line|branch|expr|toggle> \
    --write /tmp/o.dat cov/merged.dat                        # 单维度复核
```

`make cov` 先用 iverilog 的同一套功能判据卡一遍，任用例非 `TEST PASSED` 即中止，不会拿一次跑挂的激励去出覆盖率数字。

### 6.3 工具与口径

1. 为什么是 Verilator：iverilog 没有覆盖率能力。功能判据以 iverilog 回归为准，Verilator 只负责出数字。
2. 必须跨用例合并：单用例只走自己那条路径（`bs_reset_default` 里 `connected` 恒 0，`bs_k_when_awake` 里 `suspended` 恒 0）。表里的百分比是 14 用例合并后的口径。
3. 标志位那一维是自建的：本模块没有状态机，`--coverage-fsm` 无对象可认（`fsm_state`/`fsm_arc` 恒 0/0）。这一维改数 `{connected, suspended}` 两个标志位的组合与迁移，它就是本模块的状态。TB 每拍记一次组合与跳转，`tools/merge_fsm_cov.py` 按 `busstate` profile 跨用例相加（状态 0/1/2 = OFF/ATT/SUSP，8 条合法弧照 RTL 的次态逻辑抄）。

### 6.4 标志位状态与迁移（14 用例合并）

| from\to | OFF | ATT | SUSP |
|---|---:|---:|---:|
| OFF | 964600 | 16 | 0 |
| ATT | 4 | 5784325 | 26 |
| SUSP | 1 | 22 | 217585 |

停留拍数 OFF=964605 / ATT=5784363 / SUSP=217611，8 条合法弧全中，零意图外迁移。

组合 `(connected=0, suspended=1)` 在 14 个用例里停留 0 拍，它在 RTL 里结构不可达（`suspended` 置位要求 `connected` 已在），TB 单独数它，不进矩阵。

矩阵里的小数字格都能对上具体路径：`OFF→ATT`(16) 是各用例的连接前置；`ATT→OFF`(4) 与 `SUSP→OFF`(1) 是 `usb_rst` 清标志位；`ATT→SUSP`(26) / `SUSP→ATT`(22) 是挂起与唤醒/复位。没有哪一格需要靠猜。

### 6.5 覆盖率查出的 RTL 缺陷：一个常量 MUX 造出 17 个不可达翻转点

首轮覆盖率的 toggle 只有 92.3%，17 个未覆盖点全在同一条 MUX 上：

```verilog
// 改前：上界先按线状态选常量，再与 cnt 比
assign cnt_top   = line_j ? CNT_3MS_TOP : CNT_2P5U_TOP;
assign cnt_at_top = (cnt == cnt_top);
```

两个常量在高位上的位值相同，这条 MUX 的高位输出恒定不变，永远翻不动。改成一条三目比较之后（`assign cnt_at_top = line_j ? (cnt == CNT_3MS_TOP) : (cnt == CNT_2P5U_TOP);`），那些翻转点不再存在，还少一级 18 位 MUX，DUT toggle 到 100%。

### 6.6 非 DUT 层级的口径（避免误读 summary）

`make cov` 打出的 summary 是全层级的，会被 TB 自身的时钟发生器与统计逻辑稀释：

| 层级 | line | branch | expr | toggle |
|---|---|---|---|---|
| `u_dut`（本模块 DUT） | 10/10 | 42/42 | 76/76 | 178/178 |
| `tb_bus_state`（TB 自身） | 104/107 | 114/126 | 131/153 | 526/1386 |

TB 那几行的低值来自挂起/唤醒窗口里大段不变的电平与未用到的抖动分支，跟 DUT 质量无关。

## 7. 结论

1. 四种总线事件各自「一次判据 → 一次载体变化 → 恰好一个 `clk12m` 单拍脉冲」，14/14 PASS；
2. 门限实测 122 拍（2.542µs），比标称多 2 拍固定流水，与门限定义一致；
3. 跨域延迟 1..4 个 `ref` 拍，上界一个 `clk12m` 周期 ≈83ns，不随 `clk12m` 周期抖动而变；
4. 自驱 K 与自驱 SE0 期间不出任何事件；`usb_rst` 不制造假脉冲；
5. DUT 覆盖率四个维度全 100%，无未覆盖项，无意图外状态迁移；
6. 第五个输出 `bus_suspended` 与 `sus_s[0]` 逐拍相同、上升沿与 `suspend_evt` 同拍（两条全局不变量，14 用例零违规）。

下游（SIE）可以按这三条契约用：四个事件脉冲互斥、宽度恒 1 个 `clk12m` 拍、最晚 83ns 到达。
`bus_suspended` 是同一件事的电平形式，供 `usb_tx_serial` 的唤醒旁路直接读。

---

*本模块的仿真基建：`sim/busstate/`（Makefile / TB / 14 个 case / README）。*
