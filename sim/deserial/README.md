# usb_rx_deserial 模块仿真

## 模块简介

`usb_rx_deserial` — USB 1.1 RX 反序列化 / 字节恢复（**`usb_dpll_phy` 的子模块**，位于 `src/phy/`；2026-09-20 由 SIE 改挂 PHY，接口/行为未变）。

- 位→字节流水线跑 `clk12m`（12MHz，接收时 = CDR 恢复时钟 `dclk`，经 `usb_clk_mux` 切换，未建前 tb 直连）
  1× 域：NRZI 解码 → SYNC 检测（容 CDR 吃 1~2 位，找 `≥4 个 0 + 1` 尾巴）→ 位解填充 → 字节对齐（LSb first）；
- SE0/EOP 定界跑 `ref_clk`（48MHz，4×）域：5 态 EOP FSM（Fig.7，SE0 ≥3 采样 ≈62.5ns 判决点）；
- 输出 UTMI RX 三信号：`rx_data`（满 667ns 维持）+ `rx_valid`（每字节一拍脉冲）+ `rx_active`（`↓` = 包结束）+
  `rx_error`（电平，坏包标志）；`tx_active`/`rx_abort`/`usb_reset` 终止输入。
- 设计报告：`doc/design_rpt/rx_deserial_design.md`；验证报告：`doc/design_rpt/rx_deserial_verification.md`。

RTL 源码：`../../src/phy/usb_rx_deserial.v`（定稿）。tb 前级链 `usb_rx_cdr`：`../../src/phy/usb_rx_cdr.v`。

## 仿真架构

```
sim/deserial/
├── tb_deserial.v            # 顶层 testbench (CDR 前端 + DUT + 帧监视器 + case 分发 + 因果链打印)
├── case_out_normal.v          # 10 个独立 test case (经 `include` 进 tb, +case= 分发)
├── case_tail_scan.v
├── case_stuff_viol.v
├── case_se0_stuck.v
├── case_conformant_scan.v
├── case_byte_exact.v
├── case_tail7.v
├── case_pkt_all.v
├── case_err_eop.v
├── case_sync_scan.v
├── usb_rx_deserial_gate.v   # 研究用 EOP SE0 区门控 / NRZI 解码改法变体 (MODE=gate...nrzi2, 非交付)
├── Makefile                 # 编译 + 逐个 case 运行 (MODE 产物分离 + debugwave)
└── README.md

sim/common/                 # 共享 (所有模块共用)
├── usb_pkt_tasks.vh        # USB 包激励: bit_task/byte_task/pid_task/out_packet_task...
└── *_ref.vh                # CRC5/16、NRZI、位填充参考模型
```

DUT 链：`usb_rx_cdr ──dclk/rx_bit──> usb_rx_deserial`。`clk12m` 直接接 CDR 的 `dclk`（恢复时钟），
因 `usb_clk_mux` 尚未建；与定稿"接收时 clk12m=dclk 经 mux"功能等价（本 tb 不含冷启动 clk12s 域）。

每个 case 通过 vvp 的 `+case=<name>` plusarg 独立运行，一次 vvp 调用只跑一个 case。

## MODE（DUT 来源 / 断言严格度）

MODE 全由编译期宏决定。**产物按 MODE 命名**（`deserial_$(MODE).vvp`、`sim_$(MODE)_*.log`）——
切 MODE 自动重编、无需手 `rm`，base/fixed 日志证据并存（2026-09-07 改）。

| MODE | DUT 源 | 附加宏 | 语义 |
|------|--------|--------|------|
| `base`（默认） | `../../src/phy/usb_rx_deserial.v`（定稿） | — | 基线回归 |
| `fixed` | 同上（定稿） | `-DTAIL_EXP_CLEAN -DCONFORM_EXP_CLEAN` | 定稿模块 + 严格断言：tail R5/R6 与 conformant 必须清 0，否则 FAIL |
| `gate` | sim 本地 `usb_rx_deserial_gate.v` | `-DTAIL_EXP_CLEAN -DCONFORM_EXP_CLEAN` | EOP SE0 区门控（组合读 eop_state）——研究尾 7 连 1 假阳性门控改法 |
| `gatesync` | 同上 | `-DGATE_SYNC …` | 门控打一拍跨域 → 观察漏拦首个 SE0 解码 |
| `linese0` | 同上 | `-DGATE_LINESE0 …` | 门控源 = ref 域 `line_se0` 组合读 |
| `rawse0` | 同上 | `-DGATE_RAWSE0 …` | 门控源 = 原始 `!rxdp&&!rxdn` 引脚组合读 |
| `nrzi2` | 同上 | `-DNRZI2 …` | 2 拍寄存 + 同或 NRZI 解码（门控恒 0）→ 测解码改法本身 |

> `base`/`fixed` 是**交付回归**（design/verification 报告以此为准）；`gate…nrzi2` 是早期 EOP 尾
> 研究留下的**改法变体**，仅供回看，非交付物。
>
> **★ 变体文件 `usb_rx_deserial_gate.v` 已冻结**（2026-09-20 定）：
> 它是当初研究 EOP 门控时从主干分叉出去的副本，结构与主干**已明显不同**（1 段式 FSM、无
> `stat_nxt`），**不按 `code_rtl.md` 规则 7 改造、不计入覆盖率**，主干继续演进时也不回灌。
> 它至今仍叫 `st_state`，而交付 RTL 已按规则 7 改名为 `st_stat_cur` —— 两者靠
> `tb_deserial.v` 里的**编译宏别名**隔开：
> ```verilog
> `ifdef GATE_VARIANT
>     wire [1:0] dut_st_cur = u_dut.st_state;        // 冻结副本
> `else
>     wire [1:0] dut_st_cur = u_dut.st_stat_cur;     // 交付 RTL
> `endif
> ```
> **TB 与所有 case 文件一律只引用 `dut_st_cur`**，共享的 case 不必知道当前编译的是哪一份 DUT。
> 新增对 DUT 内部状态的只读引用时，照这个规矩走 `dut_st_cur`，别再往 `u_dut.<名字>` 直连。
>
> `gate`/`linese0`/`rawse0` 三种门控取法 **10/10 PASS**（合规）；`gatesync`/`nrzi2` **有意 FAIL 在
> tail_scan / conformant_scan / tail7 三个 case** —— 这两个变体正是反例：门控打一拍跨域会漏拦首个
> SE0 解码、纯改 NRZI 解码改法本身也不行，所以最终定稿选了 `gate` 那一路（组合读 `eop_state`）。
> 对 `gatesync`/`nrzi2` 看到这三项 FAIL 属**预期观察结果**，不是回归。

## 自检机制

pass/fail 判定基于**硬件级自动检测**，均打印在日志、可复算：

### 1. 帧监视器（逐字节 oracle 的骨架）

直接读 DUT 内部 `u_dut.in_frame`（=`rx_active` 同源），沿检测记**最近一帧**：
`last_open_t`/`last_close_t`（开/关时刻）、`last_err`（**关包当拍 `rx_error`**——坏帧标志，晚一拍才清，
沿当拍仍可读到 1）、`last_nbyte`（本帧吐字节数 = `rx_valid` 脉冲数）、`last_bytes[0..]`（逐字节内容）、
`close_cnt`（累计关包帧数）。`wait_close(tgt, timeout_bt)` 等第 tgt 帧关包。

### 2. 逐字节 oracle（case_byte_exact / case_pkt_all / case_conformant_scan 复用）

`chk_frame`/`chk_byte` 在 tb 本地按 USB 包结构（PID/ADDR/ENDP/CRC5/CRC16/payload + 去填充）算**期望字节**，
与帧监视器 `last_bytes` 逐字节比对（`got==exp`），并校验 `rx_valid` 脉冲数与字节数一致。参考模型
`sim/common/usb_pkt_tasks.vh` 发什么、`crc5_ref.vh`/`crc16_ref.vh` 算什么，判据即参考模型自身。

### 3. 白盒状态断言（case_err_eop）

`wait_dut_idle(tmo, ok)`：等 `u_dut.st_stat_cur` 回 `USB_IDLE`(0) 且 `rx_active=0`，验证每步异常释放路径。
`chk_clean_out(idx)`：报错后发一个干净 OUT token，逐字节断言仍收对——证明模块可复用、无幽灵帧。

### 4. SYNC 判决记录器（2026-09-14，供 `case_sync_scan`）

tb 内独立的 `sync_*` 记录器（紧邻因果链记录器，同样只写本组信号、不碰帧监视器）。每次 SYNC 判决
（`上拍==SEEK && 本拍!=SEEK`，**回放上拍寄存的 `d_bit/zero_cnt/sync_zrun` 得到判决拍的值**——
等价于旧版引 `u_dut.st_nxt` 的写法，但不依赖 DUT 内部信号，故 sim 本地 1 段式实验副本也能跑）定格三项：
`sync_code_q`（0 命中 / 1 拒收-0 少 / 2 拒收-0 多）、`sync_run_q`（tb 自数的解码 0 连跑，黑盒）、
`sync_cnt_q`（DUT `zero_cnt` 折算的"本轮计入 0 个数"，白盒）。`case_sync_scan` 用 `cnt` 判窗口 `[4,7]`，
并用"每次注入首个判决 `run==cnt`"把数器正确性钉死——否则窗口判据会陷入"用 DUT 的数器验 DUT 的判据"的自证。

### 5. 因果链打印（2026-09-07，仅打印、不参与 pass/fail）

按 sim/common/README「仿真结果确认规范」的**因→变→果 + 前窗/后窗**分段打印（tb 的
`causal_*` 逐帧 tick 记录 + `causal_print`/`causal_post` 任务），挂在旗舰 case：
`case_out_normal`（正常关包）、`case_stuff_viol`（7 连 1 错保持+释放）、`case_err_eop` E1（bad-EOP 探针自愈）
与 E4（rx_abort@ERROR 立即清）。日志形如：

```
因果链·out_normal 正常关包
  前窗: 首个数据沿前 线保持 J(idle) 连续 … ref_clk 拍 (包从干净 idle 起)
  因: 首个 0 (SYNC 首 K) 离开 idle → st: USB_IDLE→USB_SYNC_SEEK @…
  变: SYNC 尾 ≥4 个 0 + 1 命中 → st: SYNC_SEEK→USB_DATA @… (进 DATA 时 ones_cnt=0)
  果: 关包采样  [frame] close@… nbyte=… err=… bytes=…
  后窗: 关包后 ref_clk 内 rx_error 保持 0
```

### 6. 填充规则断言（2026-09-16，全用例通用、参与 pass/fail）

`rones_prev_st` 块：**每次进 `USB_DATA` 的当拍，`u_dut.ones_cnt` 必须为 0**，否则报
`ERROR: 进 USB_DATA 时 ones_cnt=…` 并计入 `errors`。这条钉死"解填充计数从 PID 起算"（设计报告 §2.4）：
SYNC 之后必是 PID，PID = `code + ~code` 结构上最多 4 连 1，与 SYNC 尾 1 合起来 5 < 6 → SYNC/PID 段
不可能出现填充位。若有人把 `ones_cnt` 的窗口退回旧写法（只 `USB_IDLE` 保持 0），本断言立刻报错。

## 测试用例

| Case | `+case=` 名称 | 测试目的 | 判定标准 |
|------|--------------|---------|---------|
| out_normal | `deserial_out_normal` | 整链回归：SYNC 对齐→DATA→PID 首字节→3 字节→EOP 干净关包 | 关 1 帧：`err=0`、`nbyte=3`、`bytes=e1 05 58`（+ 因果链打印） |
| tail_scan | `deserial_tail_scan` | 包尾 K 电平 R 个 1 + 真 EOP 扫描 R=3..6（EOP 假 7 连 1 门控） | `fixed`（`TAIL_EXP_CLEAN`）：R=3..6 全 `err=0` |
| stuff_viol | `deserial_stuff_viol` | 真 7 连 1（K 电平、非 SE0）照常检错 | 关包 `err=1`（+ 因果链打印） |
| se0_stuck | `deserial_se0_stuck` | SE0 卡死 ~3.5µs | 不误关包、`err=0`，SE0→J 干净释放 |
| conformant_scan | `deserial_conformant_scan` | 合规 DATA0 全扫（256×1B + 400×8B）找误判 | `fixed`（`CONFORM_EXP_CLEAN`）：无幽灵关包、字节全清 0 |
| byte_exact | `deserial_byte_exact` | 整帧字节流 vs 理想 oracle（PID/payload/CRC + `rx_valid` 数） | 每帧 `got==exp` |
| tail7 | `deserial_tail7` | 末字节 7 个 1 边界 A–D 扫描（正常填充 vs 填充错误） | 边界符合：真 EOP 收尾不误判 |
| pkt_all | `deserial_pkt_all` | **全部 USB1.1 FS 包类型**逐字节：IN/SETUP/SOF(0x3FF)/ACK/NAK/STALL/PRE/NYET/坏 PID/坏 CRC5/坏 CRC16 | 全 `got==exp`、`err=0`；坏 PID/CRC **只恢复字节不检错**（deserial 必须透明） |
| err_eop | `deserial_err_eop` | 异常释放 E1–E5：坏 EOP(SE0→K)/截断无 EOP/`rx_abort`@DATA/`rx_abort`@ERROR/`tx_active`@DATA | 各回 `USB_IDLE` 且 `rx_error` 复位时机正确；随后能收下一干净 OUT（无幽灵帧，+ E1/E4 因果链打印） |
| sync_scan | `deserial_sync_scan` | **SYNC 接受窗口扫描**：把 SYNC 的 7 个 0 改成 z 个（z=1..11），查 0 少/0 多是否按窗口 `[4,7]` 判 | 逐判决：命中 ⟺ cnt∈[4,7]、0 少拒收 cnt≤3、0 多拒收 cnt≥8；首发判决 `run==cnt`；z∈{1,2,3,10,11} 无幽灵帧；命中后 token 仍干净解出 |

### case 说明摘要

- **deserial_out_normal**：标准 OUT token（PID `0xE1` + addr/endp + CRC5）。验证 CDR 吃 SYNC 位后
  deserial 仍命中 SYNC 尾巴、`rx_active`↑ 后第 1 个 `rx_valid` 脉冲字节 = PID，EOP 干净关包 `err=0`。
- **deserial_stuff_viol**：`raw_hold(K,7)` 物理注入 7 个 K 位 = 数据中段真 7 连 1（线非 SE0 →
  EOP FSM 停在 idle、门控不生效），必须进 `USB_ERROR` 置 `rx_error`，坏帧 EOP 后释放，关包 `err=1`。
- **deserial_err_eop**：
  - E1 bad-EOP：帧尾 SE0 后回 K（非 J）→ `eop_err` → `USB_ERROR`；总线静默回 J → 7 连 1 idle 探针 → 释放；
  - E2 no-EOP：截断包（body 后无 SE0，线回 J）→ DATA 内 idle J 凑出 7 连 1 → 检错 + 探针自愈（零定时器）；
  - E3 `rx_abort`@DATA / E5 `tx_active`@DATA：强制回 IDLE、**不置** `rx_error`；
  - E4 `rx_abort`@ERROR：真 7 连 1 已进 ERROR 后中止 → **立即**回 IDLE 且 `rx_error` 当场清。
- **deserial_sync_scan**：`SYNC_MIN_ZERO = 4` 的接受窗口 `[4,7]` 边界测试。
  - 注入：把 SYNC 的 7 个 0 换成 z 个（`bit_task(0)×z + bit_task(1)`）；z=1..3 / 10..11 只发 SYNC 替身
    后接 `raw_hold(J,16)`（后续解码全 1，杜绝残余 0 再凑出假 SYNC，让"不开包"成为确定判据）；
    z=4..9 后接真 token body（PID/ADDR/ENDP/CRC5/EOP），收/拒都要求正确。
  - 判据不用"我发了几个 0"：CDR 吃位（帧间 idle 后第一个 SYNC 会吃 1 bit，见 tail_scan）会让到达
    deserial 的连跑变短。改为 tb 记录器在**判决拍**（`dut_st_cur==SEEK && 本拍出口!=SEEK`，用回放上拍
    寄存值得到判决拍，见 §4）定格两个量：`run` = tb 自数解码 0 连跑（黑盒），`cnt` = DUT `zero_cnt`
    折算（白盒）。用 `cnt` 判窗口，并用"每次注入首个判决 `run==cnt`"把数器正确性用黑盒钉死，避免自证。
  - 实测结果（base/fixed 均 PASS）：z=1/2/3 → 连跑 1/2/3 拒收；**z=4/5/6/7 → 命中且连跑恰为 4/5/6/7**
    （窗口下边界正好 4）；**z=8 → 第 8 个 0 拒收**（窗口上边界正好 7）；z=9..11 → 8 个 0 处拒收后，
    余下 1/2/3 个 0 再进 SEEK 也够不到 4，再次拒收；全程无幽灵帧、无卡死。

## 如何仿真

```bash
# 双模回归 (推荐; 产物按 MODE 命名, 切 MODE 自动重编, 无需手 rm)
make -C sim/deserial run MODE=base
make -C sim/deserial run MODE=fixed
make deserial                       # 根入口: 双模连跑

# 带波形 (每 case 单独存 <case>.vcd)
make -C sim/deserial run MODE=base VCD=1

# 单独跑一个 case
make -C sim/deserial build MODE=base
vvp sim/deserial/deserial_base.vvp +case=deserial_out_normal
vvp sim/deserial/deserial_base.vvp +case=deserial_tail_scan +rmin=3 +rmax=6 +vcd=ts.vcd

# tail_scan 带 R 范围单独跑 (tee 到 sim_<MODE>.log)
make -C sim/deserial scan MODE=base RMIN=3 RMAX=6

# 跑所选仿真并直接打开波形软件 (wave_debugger) —— 自动 VCD=1 重编当前 MODE + 只跑所选
make -C sim/deserial debugwave                              # 交互菜单: 列 10 case 供选
make -C sim/deserial debugwave CASE=deserial_out_normal     # 直接指定 (可脚本化)
make -C sim/deserial debugwave MODE=fixed CASE=deserial_tail_scan  # 指定 MODE 严格断言版

# 也可从仓库根目录: 选模块 (cdr/deserial) → 再选该模块的 case
make debugwave MOD=deserial CASE=deserial_out_normal
```

## VCD 控制

- `run`（VCD=0，默认）：不写波形，仿真快，适合回归；仍传 `+vcd=` 无害。
- `VCD=1`：编译加 `-DVCD_SAVE`，每个 case 生成独立 VCD：

```
sim/deserial/deserial_out_normal.vcd
sim/deserial/deserial_tail_scan.vcd
sim/deserial/deserial_stuff_viol.vcd
sim/deserial/deserial_se0_stuck.vcd
sim/deserial/deserial_conformant_scan.vcd
sim/deserial/deserial_byte_exact.vcd
sim/deserial/deserial_tail7.vcd
sim/deserial/deserial_pkt_all.vcd
sim/deserial/deserial_err_eop.vcd
sim/deserial/deserial_sync_scan.vcd
```

> **注意**：`-DVCD_SAVE` 是编译期宏 → 切换 VCD 模式需 `rm -f deserial_$(MODE).vvp` 重编
> （或 `make -C sim/deserial clean`，再 `run VCD=1`）。`make clean` **保留 `*.wvs`**（波形会话：
> 信号列表 + 每信号进制/颜色，用户手动配置）与 **`*.vcd`**（波形文件，跑仿真不删——用户 2026-09-07 定），
> 只删可再生的 `deserial_*.vvp` / `sim_*.log`；`.vcd` 由下一次 `VCD=1` 运行按 case 名覆盖刷新。

## 仿真产物

| 产物 | 说明 |
|------|------|
| `deserial_base.vvp` / `deserial_fixed.vvp`（…每 MODE 一个） | 编译后的仿真可执行文件 |
| `sim_base.log` / `sim_fixed.log`（`sim_$(MODE).log`） | 该 MODE 全 case 汇总日志 |
| `sim_<MODE>_<case>.log` | 每个 case 独立日志（含因果链打印，MODE 分离） |
| `deserial_<case>.vcd` | 每个 case 独立波形（仅 VCD=1） |

## 依赖

- **RTL**：`../../src/phy/usb_rx_deserial.v`（定稿）+ 前级 `../../src/phy/usb_rx_cdr.v`（已验证）；
  MODE=gate…nrzi2 另用 sim 本地 `usb_rx_deserial_gate.v`（研究变体）。
- **仿真工具**：iverilog ≥ 12.0 + vvp（`-g2012`）。
- **无外部依赖**，自检全部在 Verilog 内完成；波形软件 `tools/wave_debugger.py`（禁止 GTKWave）。

## 参考模型

`sim/common/usb_pkt_tasks.vh`（NRZI 编码 + 位填充 + 全包发送）、`crc5_ref.vh`/`crc16_ref.vh`
（CRC 参考函数）即参考模型：发什么 = 期望值来源；`chk_frame` 逐字节比对即判据。通用确认规范
（所有模块仿真通用）见 `sim/common/README.md`「仿真结果确认规范」。
