# sim/common — 共享参考模型与 USB 包激励

所有模块 testbench 共用的纯 Verilog 参考模型 (reference model) 与 USB 数据包激励任务。
testbench 在仿真时于本地计算期望值，避免硬编码黄金向量 (golden vector)。

---

## 仿真结果确认规范（强制：因果链 + 前后文窗口）

> 本文档是**所有模块**仿真（含后续 SIE / deserial / clk_mux）通用的确认规范。
> 由用户 2026-09-07 定：**只看最终结果/只看单拍太局部，判据要能落到
> "哪个驱动信号 → 哪些信号变化 → 最终什么结果"，且前后留上下文窗口**。
> CDR 已按此改造（见下方示例），新仿真的 tb 自检与报告须照此撰写。

### 规则 1：每个结论要写全「因 → 变 → 果」三段因果链

确认任何一条仿真结果，不能只说"通过了/标志=1"，要写明：

1. **因（驱动信号）**：外部激励或上级信号里**是什么触发了**这件事
   （例：线上从 idle J 变成 K——SYNC 首个 0）；
2. **变（中间信号变化）**：沿着 RTL 内部哪几个信号逐级变化
   （例：`rxdp`→`a/b 采样`→DPLL `state` 从 C 变 D）；
3. **果（最终结果）**：链的终点输出了什么、是否满足预期
   （例：`dclk` 起振 + `rx_bit` 恢复出正确数据位，回环 0 差异）。

报告正文、日志自检、口头汇报三者都用这个三段式，禁止只甩一个 PASS。

### 规则 2：每条结论挂**量化判据**，不空谈

判据 = 可复算的数值/布尔门限，打印在证据旁边。例：

| 结论 | 量化判据 |
|------|---------|
| CDR 锁定 | 锁存延迟 D→5 ∈ [1,8] ref_clk（标称 1 bit = 4）；首个非 C 态必须=D |
| 恢复时钟 12MHz | 相邻 `dclk` 上升沿间隔 ∈ [3,5] ref_clk（标称 4） |
| 回环逐位一致 | 恢复位 vs 发送位 mismatch = 0，且比对位数 = 期望位数 |
| 空闲不吐时钟 | idle 期 `dclk` 恒 0、`state` 恒 C 连续 ≥3 拍 |

判据若由经验/容忍放宽，注释里写清"为什么能放"。

### 规则 3：**前后文窗口**观察，禁止单拍定论

判断一个事件是否正确，要在事件**前后各留一段观察窗**：

- **前窗**：事件发生前应维持的状态（空闲/前一包/复位后的静默），
  证明事件不是从脏起点发生——例：SYNC 之前先确认 `state` 连续多拍恒 C；
- **后窗**：事件发生后效应应延续/成规律（时钟持续翻、锁存保持、跨包不失锁），
  例：锁定后数 16 ref_clk 内 ≥2 个 `dclk` 上升沿，证明 12MHz 真在跑而非单沿假象。

打包间连续用例要跨 EOP+idle 前窗看下一包 SYNC，不能只看单包中点。

### 规则 4：尽量把因果链编码为 tb 自检（assert + errors），打印证据

自动化断言优于事后翻波形；但断言打印必须把上面的因果链证据带出来
（事件 tick、计数、判据区间），让 PASS/FAIL 可从日志直接复算，而非仅一个布尔。
tb 负责加错误 → 加打印；`make run` 的汇总只数 `errors`。

### 规则 5：波形截图的取信号要覆盖「因 → 变 → 果」，不能只截结果

> 用户 2026-09-21 定：**截波形时把结论本身、以及导致这个结论的信号都放进同一张图**。

规则 1 管文字怎么把因果链写出来，这条管图。图上没有的信号，读者没法自己把因果复算一遍，
只能相信 caption 的说法。

- 果：结论落在哪个信号上，它必须在图里。像 `resp_pid` / `tx_done` / `rx_error` /
  `buf_ready` 这类终点信号。
- 因：驱动这次变化的信号也要在。外部激励、上级握手（`tx_active` / `rx_valid` / `tx_ready`）、
  状态机现态。缺了因，图只能说明"结果是这个样"，说明不了"结果为什么是这个样"。
- 变：链中间的计数器、状态、指针尽量都留，尤其是判据里点到名的（`bit_cnt` / `turn_cnt` /
  `wr_ptr`）。
- caption 里念到的信号名，图上必须真找得到。写了"@2260489 `tx_last`↓"就得有那个沿。

前后文窗口按规则 3 留在同一张图里。信号多到图太宽时宁可拆两张（一张给因、一张给果），
别为了塞进一张把因砍掉。

反例：TX 验证报告 §4.7 的 `tx_serial_abort.png` 初版，caption 写了"`tx_done` 全程为 0"，
但取信号时漏了 `tx_done`，图上根本看不到那个信号，只能补渲染重出。

自检：拿 caption 从头念一遍，念到的每个信号名在图上找一遍，缺哪个补哪个。

### 规范示例：CDR 锁存（已落地）

`sim/cdr/tb_cdr.v` 的 `causal_arm` / `causal_lock_check` 任务（`case_nominal` /
`case_pkt_all` 首包调用）。日志输出即三段式 + 前后窗 + 判据：

```
因果链·前窗: idle J 下 state=C 持续 10 ref_clk, dclk 恒 0 (无数据不吐时钟) ✓   ← 前窗
因果链·因①: 线上首 K (SYNC 首 0) → C(12)→D(13) @ref_clk#19 ✓                  ← 因→变
因果链·因②: 线上回 J → D(13)→5 锁定 @ref_clk#23, 锁存延迟 4 ref_clk            ← 变→果
  (判据: 延迟 4 ref_clk ∈ [1,8], 对应 SYNC 0→0 两次边沿间隔 ~4 ref_clk) ✓
因果链·果: 锁定后 16 ref_clk 内 dclk 上升沿 4 个 → 12MHz 恢复时钟运行 ✓         ← 后窗
```

同类改造：`clk12m` 周期健康（跨多包统计 0 坏周期）、回环 SYNC 尾巴对齐逐位对比
（`case_loopback.v` / `case_pkt_all.v`）均已按"整窗证据 + 量化判据"落地。CDR 短 bit
自适应同理（见下方第 3 节）。

---

## debugwave Makefile 目标（强制，所有模块仿真通用）

> 用户 2026-09-07 定：**以后每个 `sim/<模块>/Makefile` 都要有 `debugwave`**，
> 用于"选一个对应仿真 → 自动出波形 → 直接打开波形软件"。
> 波形软件一律用 `tools/wave_debugger.py`（禁止 GTKWave）。样板在 `sim/cdr/Makefile`。

**用法**（以 cdr 为例；cdc 多相位、deserial 多 case+MODE 同理扩展）：

```bash
# 仓库根目录入口 (推荐): 模块菜单→该模块的 case 菜单, 供选全部可用 case 名
make debugwave                              # 目前仅 cdr 有 debugwave, 自动直通其 case 菜单
make debugwave MOD=cdr CASE=cdr_case_short_bit_k   # 直选模块 + case
make debugwave CASE=cdr_case_short_bit_k           # 单模块时省 MOD

# 模块目录内直选 (可脚本化)
make -C sim/cdr debugwave                   # 交互菜单: 列出该模块可选仿真, 输入编号/case 名
make -C sim/cdr debugwave CASE=cdr_case_short_bit_k  # 直接指定
```

**行为约定**（各模块实现须满足）：
1. **自动以 VCD=1 重编译再跑所选仿真**——`-DVCD_SAVE` 是编译期宏，直接 `run` 不写 `.vcd`；
   样板用 `rm .vvp` + `$(MAKE) build VCD=1` 强制重建；
2. **只跑所选的那一个仿真**（`+case=`/`+phase=`…），不全量回归；
3. 跑完**直接 `python3 ../../tools/wave_debugger.py <所选>.vcd`** 打开波形；
4. 多仿真模块提供**交互菜单 + CASE= 直选**两种选择；非法选择报错并列出可选值；
   **选 case 前先弹出该模块现有的全部 case 名供选**（模块≥2 时根入口先列模块再列 case）；
5. **不删 `.wvs` 也不删 `.vcd`**（`.wvs` = 波形会话：信号列表+进制/颜色，用户手动配置；
   `.vcd` = 波形文件，跑仿真时保留供查看——用户 2026-09-07 定。`make clean` 两者都保留，
   只清可再生的 `.vvp/.log`；切换 VCD 模式只需删 `.vvp` 重编译，`.vcd` 由下次
   `VCD=1` 运行按名覆盖刷新）。
6. macOS 离屏 Qt 偶发 `libshiboken: C++ object already deleted`：属进程退出竞态，
   **原命令重跑一次即可**，与参数无关。

根 Makefile 用 `WAVE_MODULES := cdr` 登记**已带 debugwave 的模块**；新模块加 debugwave
时把它追加进去即可（>1 个时根入口自动弹模块菜单）。交互菜单样板：`sim/cdr/Makefile`。

---

## cov / fsmcov Makefile 目标（**强制**：覆盖率，用户 2026-09-16 定）

> 用户定：行覆盖率、分支覆盖率等**都要跑全**，单用例覆盖不全就**多个 case 合并**，
> 且**最终要体现到验证报告里**。
>
> **这是仿真要求，不是可选动作**：`sim/<模块>/` 的仿真没有 `cov`/`fsmcov` 目标、或没有把
> 覆盖率章节写进 `doc/design_rpt/<模块>_verification.md`，就不算验证完成。
> 已登记模块见根 `Makefile` 的 `COV_MODULES`（目前 `tx deserial`）。
> 完整强制条款见仓库根 `CLAUDE.md`「仿真规范」。

**为什么是 Verilator**：iverilog 没有覆盖率能力。**功能判据仍以 iverilog 回归为准**，
Verilator 只负责出数字。代价是**该模块的 TB 必须先过 Verilator 的可移植性**——
`sim/tx` 为此改了 4 处（`ifdef VERILATOR` 的 PHY 模型、`disable <自身任务名>`、
显式敏感表 `always` 改连续赋值、数组深度），详见
[tx_serial_verification.md §8](../../doc/design_rpt/tx_serial_verification.md)。

**用法**（以 tx 为例）：
```bash
make cov MOD=tx          # 根入口 → 转发到模块的 cov + fsmcov（COV_MODULES 登记）
make -C sim/tx cov       # 建 → 跑全用例 → 合并 → 打印 summary
make -C sim/tx fsmcov    # 合并 FSM 状态/迁移矩阵
make covclean            # 删各模块的覆盖率构建目录
```

**实现约定**（新模块照 `sim/tx/Makefile` 抄）：
1. **必须跨用例合并再判读**——单用例只走自己那条路径，合并用 `verilator_coverage --write`。
   报告里的百分比一律是合并口径。
2. **覆盖率运行要卡功能判据**：任用例非 `TEST PASSED` 即中止，不拿跑挂的激励出数字。
3. **`make clean` 不动覆盖率构建目录**，另设 `covclean`（与 `.vcd/.wvs` 同一条理由）。
4. **FSM 那一维可能要自建**：Verilator 的 `--coverage-fsm` 只认单段式 FSM，认不出
   `code_rtl.md` 要求的**两段式**（组合算次态 + 时序搬现态）→ 它在 TB 侧分层引用状态寄存器
   自己数（`print_fsm_coverage` + `tools/merge_fsm_cov.py`）。**不要为工具改已验收的 RTL。**

**覆盖目标怎么定**：以 **DUT 模块**为口径报数（全层级 summary 会被 TB 自身、Verilator
`std::*` 库和回环链上已验证的其它模块稀释）。未覆盖项要逐条定性：**编码规范要求的、
结构不可达的补全分支属正常豁免**，其余一律当缺口查。

---

## 3. CDR 短 bit 自适应自检（因果链范例：J→6→1 与 K→2→5 双向，用户 2026-09-07 定）

短 bit 有 J/data=1 与 K/data=0 两种极性、两条独立跳过路径——**镜像长 bit 的 f/b 拆成
两个 case**（`case_short_bit_j.v` / `case_short_bit_k.v`）。过去单一 `case_short_bit`
只查"短 bit 后不失锁"，等于没验证短 bit 机制（长 bit 有显式 `f_detected`/
`b_detected` 而短 bit 无）。现升级为显式因果链自检（tb_cdr.v 的
`short_meas_en`/`short_c3`/`short_over`/`short_skip`(6→1)/`short_skip_k2`(2→5) 监测）：

- **因**：1 个 bit 被压到 3cyc → 下一个翻转沿比标称早 1 ref_clk 到达；
- **变**：
  - **J**（`case_short_bit_j`，CRC5[2]=bit29，data=1/J）：早到的 **K** 沿打在右环
    第 3 态 `6`（b=0）→ **6→1 跳过切环**（跳过 4/5，state 6 `(b==1)?4:1`）；
  - **K**（`case_short_bit_k`，CRC5[3]=bit30，data=0/K）：早到的 **J** 沿打在左环
    第 3 态 `2`（b=1）→ **2→5 跳过切环**（跳过 0/1，state 2 `(b==0)?0:5`）；
- **果**：该位恢复时钟周期压到 **3 ref_clk**（其余仍 4），不失锁；
- **界**：无 `<3` ref_clk 过短周期（自适应不过冲）；对向跳过 = 0（J/K 不串扰）。

量化判据（两 case 各自硬断言）：本向跳过恰 1、对向跳过 0、`short_c3==1`、
`short_over==0`、`locked` 保持、`dclk` 沿≥20。实测日志（回归，VCD 已核对状态轨迹）：

```
J:  6→1×1 | 2→5×0 | 3-ref_clk×1 | 过短(<3)=0 | dclk 44 沿, 轨迹 5→7→6→1→3→2→0
K:  6→1×0 | 2→5×1 | 3-ref_clk×1 | 过短(<3)=0 | dclk 44 沿, 轨迹 1→3→2→5→7→6→4
    两 case 短周期均 62502 ps = 3 ref_clk (VCD 实测)
```

## 文件

| 文件 | 内容 | 使用者 |
|------|------|--------|
| `crc5_ref.vh` | USB CRC5 参考函数 (`crc5_rem_11` / `crc5_rem` / `crc5_tx` / `crc5_tx_11`) | crc5, cdr (via usb_pkt_tasks) |
| `crc16_ref.vh` | USB CRC16 参考函数 (`crc16_step` / `crc16_feed_byte` / `crc16_rem` / `crc16_tx`) | crc16, cdr (via usb_pkt_tasks) |
| `nrzi_ref.vh` | NRZI 编解码参考函数 (`enc_ref` / `dec_ref`) | nrzi |
| `bitstuff_ref.vh` | 位填充参考函数 (`stuff_check` / `stuff_next_cnt`) | bitstuff |
| `usb_pkt_tasks.vh` | USB 数据包激励任务 (全包类型, 见下) | cdr, 后续 SIE |

## 使用约定

每个模块的 `Makefile` 通过 `-I../common` 加入 include 搜索路径，tb 内直接用文件名 include：

```verilog
`include "crc5_ref.vh"          // crc5 tb
`include "usb_pkt_tasks.vh"     // cdr tb (内含 `include "crc5_ref.vh")
```

所有文件带 `ifndef 守卫，可安全被多次 include 或传递 include。

## usb_pkt_tasks.vh 接口约定

包含该文件的 tb 模块必须预定义以下内容：

```verilog
reg            rxdp, rxdn;       // 差分线 (被 drive_dpdn 驱动)
parameter real BIT_TIME    = 1000.0/12.0;   // 1 bit 时间
parameter real EOP_SE0_TIME = 2.0*BIT_TIME; // EOP SE0 段
parameter real EOP_J_TIME  = 1.0*BIT_TIME;  // EOP J 段
```

`usb_pkt_tasks.vh` 内部还会 `include "usb_const.vh"`（PID 类型宏），
因此 tb 的 Makefile 需同时提供 `-I../../src/inc` 与 `-I../common` 两个搜索路径。

## usb_pkt_tasks.vh 任务清单

分层设计：bit → byte → pid → 完整 packet，内含 NRZI 编码 + 位填充。

| 层次 | 任务 | 说明 |
|------|------|------|
| 电气 | `drive_dpdn(lv, t)` | 驱动 DP/DN 到指定电平并保持 t |
| bit | `bit_task(d, cyc)` | 发 1 个数据位 (NRZI + 位填充)，cyc 为周期数(3/4/5) |
| byte | `byte_task(b, cyc, ofs, lcyc)` | 发 1 字节 LSB-first，可指定 bit 拉长 |
| pid | `pid_task(type, cyc, ofs, lcyc)` | 发 PID 字节 (type + ~type) |
| 段 | `sync_task(cyc, lbit, lcyc, bit_cnt)` | 发 SYNC (00000001) |
| 段 | `eop_task` | 发 EOP (SE0×2 + J) |

**完整包任务**（均含 SYNC + 载荷 + EOP，`cyc`=标称周期数(4)，`long_bit_idx`=全局 bit 索引，`-1` 不指定拉长 bit，`long_cyc`=该 bit 周期数）：

| 任务 | 结构 |
|------|------|
| `token_packet_task(pid_type, addr, endp, ...)` | 通用 Token (OUT/IN/SETUP) |
| `out_packet_task(addr, endp, ...)` | OUT Token 封装 |
| `in_packet_task(addr, endp, ...)` | IN Token 封装 |
| `setup_packet_task(addr, endp, ...)` | SETUP Token 封装 |
| `sof_packet_task(frame_num, ...)` | SOF (11-bit 帧号 + CRC5) |
| `data_packet_task(pid_type, b0..b7, nbytes, ...)` | DATA0/DATA1 (payload + CRC16, ≤8B) |
| `handshake_packet_task(pid_type, ...)` | ACK/NAK/STALL (仅 PID) |

**每个 PID 独立封装**（转发到上表通用任务，`cyc/long_bit_idx/long_cyc` 签名一致）：

| 任务 | 转发到 |
|------|--------|
| `data0_packet_task` / `data1_packet_task` | DATA0 / DATA1 |
| `ack_packet_task` / `nak_packet_task` / `stall_packet_task` | ACK / NAK / STALL |
| `nyet_packet_task` | NYET (USB2.0 握手，测未知 PID 忽略) |
| `pre_packet_task` | PRE (Special 低速前导) |

**坏包/错误注入变体**（供 SIE/deserial 容错验证，单字段注入错误）：

| 任务 | 注入的错误 |
|------|-----------|
| `bad_pid_packet_task(pid_type, ...)` | PID 补码高位翻转 → PID 校验失败 |
| `token_badcrc_packet_task(pid_type, addr, endp, ...)` | Token CRC5 全位翻转 |
| `sof_badcrc_packet_task(frame_num, ...)` | SOF CRC5 全位翻转 |
| `data_badcrc_packet_task(pid_type, b0..b7, nbytes, ...)` | Data CRC16 全位翻转 |
| `token_noeop_packet_task(pid_type, addr, endp, ...)` | 发完 body 无 EOP (截断) |
| `data_noeop_packet_task(pid_type, b0..b7, nbytes, ...)` | 发完 body 无 EOP (截断) |
| `oversize_data_packet_task(pid_type, fill, nbytes, ...)` | payload 超端点上限 (无 CRC16, 溢出中止) |

全局状态 `ones_cnt`(连续 1 计数) 与 `nrzi_lv`(当前 NRZI 电平) 由本文件声明，
跨任务保持，`eop_task` 结束后会重置 `nrzi_lv = 1'b1` 回到 idle J。

参考模型的设计原则：纯 Verilog function/task，无时钟、无延时（除 `#` 驱动 DP/DN），
便于被任意 tb 复用，减少 AI 生成测试向量的 token 开销。
