# usb_rx_deserial 模块验证报告

> 模块：`usb_rx_deserial`（RX 反序列化 / 字节恢复，**`usb_dpll_phy` 子模块**）——clk12m 域位流水线
> **2026-09-20 归属调整**：由 SIE 改挂 PHY（`src/sie/` → `src/phy/`），**接口、RTL 行为、验证结论一字未改**
> 日期：2026-09-16（初版 2026-09-04；2026-09-07 按 sim/common README「仿真结果确认规范」改写：逐结论补
> 因→变→果 + 前窗/后窗 + 量化判据，tb 加因果链打印，报告补波形图；2026-09-14 补 §4.10 SYNC 接受窗口
> 边界用例与第 7 项自检机制；2026-09-16 解填充计数改为"从 PID 起算"、加第 8 项自检机制；同日按覆盖率要求
> 加 §4.11 `eop_glitch` 用例 + §7 覆盖率章节、修 TB 复位序列缺陷；见 §2/§3/§4/§7）
> 工具：iverilog + vvp（`-g2012 -Wall`）为功能判据 + Verilator 5.052 出覆盖率；自检全部在 Verilog 内完成（非人工看波形）
> 源码：`src/phy/usb_rx_deserial.v` | 上游链：`src/phy/usb_rx_cdr.v`（已单独验证）
> 测试：`sim/deserial/tb_deserial.v` + 11 个 `case_*.v`（+case 分发，逐 case 独立 log，产物按 MODE 命名）
> 相关：设计报告 [rx_deserial_design.md](rx_deserial_design.md)（§4.10 验证计划 / §4.11 回归简表；
> 波形图 §4.3/4.6/4.7/4.8 与本报告同源）

---

## 1. 概述

`usb_rx_deserial` 把 PHY（CDR + 未来 clk_mux）恢复的 `clk12m` 位时钟 + `rx_bit`（NRZI 电平）变成 SIE
事务逻辑可直接消费的**对齐字节流 + 包边界信号**（`rx_data`/`rx_valid`/`rx_active`/`rx_error`，UTMI RX
模型）。两条流水各自成域：

- **clk12m（1×）域位流水线**：NRZI 解码（2 拍寄存同或）→ SYNC 检测（容吃位）→ 位解填充 →
  字节对齐（LSb first）→ 4 态帧状态机 `USB_IDLE/USB_SYNC_SEEK/USB_DATA/USB_ERROR`；
- **ref_clk（4×）域**：EOP/SE0 定界（5 态 EOP FSM）+ 事件展宽跨域。

验证目标：在**正常包 / 全包型 / 边界形态 / 异常 / 中止**下证明——

1. **字节保真**：恢复字节流 = 发送端理想字节流（PID/地址/端点/载荷/CRC 全覆盖，含位填充跨字节）；
2. **定界正确**：每包 `rx_active`↓ 恰一次，正常 SE0→J 关包 err=0；宽容收尾（SE0→K 后回 J）不误报；
3. **错误检测与释放**：**真** 7 连 1 / EOP 错 置 `rx_error`；EOP SE0 假阳性被门控消除（合规包不误判）；
   `USB_ERROR` 三条释放路径（eop / 7 连 1 idle 探针 / `tx_active`、`rx_abort`）行为正确，无卡死、无幽灵帧；
4. **职责边界**：坏 PID / 坏 CRC 的包**只恢复字节、不置错**（PID/CRC 校验属 SIE 事务层）；
5. **中止/自收发门控/core 复位**：`rx_abort`、`tx_active`、`usb_rst` 强制回 IDLE 且 `rx_error` 复位时机正确
   （`usb_rst` 三条路径不置错，且不碰 ref 域的线采样寄存器）。

## 2. 测试环境

| 项目 | 说明 |
|------|------|
| RTL（DUT） | `src/phy/usb_rx_deserial.v`（**定稿 clk12m 域位流水线**，EOP SE0 门控内置于模块） |
| 上游链 | `src/phy/usb_rx_cdr.v`（Intel 16 态 DPLL，已单独验证） |
| Testbench | `sim/deserial/tb_deserial.v`：实例化 CDR+deserial + 自检逻辑 + `+case=` 分发；含 `usb_rst` 激励任务与 `line_s` 观测器（§3 第 9 项） |
| Case 文件 | `sim/deserial/case_*.v`（10 个），`+case=<name>` 独立运行、独立 log `sim_<MODE>_<case>.log`（MODE 分离） |
| 激励任务 | `sim/common/usb_pkt_tasks.vh`：全包型 builder + 坏包变体（bad PID / bad CRC5 / bad CRC16 / 截断无 EOP 等）；`bit_task` 内置 NRZI 编码 + 位填充（6 连 1 插 0） |
| 参考模型 | `sim/common/crc5_ref.vh`、`crc16_ref.vh`（CRC5/CRC16 黄金向量）——`byte_exact` 期望字节由此算 |
| 时钟 | `ref_clk` 48MHz（`#(1000/48/2)`）；USB bit 时间 = 83.33ns；跨域边沿对齐（派生时钟） |
| 自检 | PASS/FAIL = Verilog 内 `errors` 计数；make 按 `TEST PASSED` 判定；日志可 grep |

仿真方式（`sim/deserial/` 下；2026-09-07 起 **Makefile 产物按 MODE 命名**，切 MODE 自动重编、无需手 `rm`）：

```bash
make -C sim/deserial run MODE=base           # 11 case 逐个运行并汇总（定稿模块，裸编）
make -C sim/deserial run MODE=fixed          # 11 case + 严格断言（-DTAIL_EXP_CLEAN -DCONFORM_EXP_CLEAN）
make -C sim/deserial run MODE=base VCD=1     # 每 case 存独立 <case>.vcd（波形图/波形调试用）
make -C sim/deserial scan MODE=fixed RMIN=3 RMAX=6      # tail_scan 单独跑（可调 R 范围）
make -C sim/deserial debugwave CASE=deserial_out_normal                 # 重编 VCD=1 + 只跑所选 + 开波形
make -C sim/deserial debugwave MODE=fixed CASE=deserial_tail_scan       # 指定严格断言 MODE 复看波形
make deserial                              # 仓库根一键双模回归（base + fixed 连跑）
make debugwave MOD=deserial CASE=deserial_out_normal                    # 仓库根入口开波形
```

**产物（均按 MODE 分离，2026-09-07 改）**：`.vvp` = `deserial_<MODE>.vvp`；汇总日志 = `sim_<MODE>.log`；
每 case 独立日志 = `sim_<MODE>_<case>.log`（含因果链打印，见 §3.1）；`VCD=1` 时每 case 一个
`<case>.vcd`（**不随 MODE 变**，base 生成后 fixed 复用同窗取图；`make clean` 保留 `.vcd`/`.wvs`，只删
可再生 `.vvp`/`.log`）。

**MODE 说明**：`base` 与 `fixed` 编译**同一个定稿模块**（EOP 门控已内置），差别只在 `fixed` 加两个严格断言宏
（`TAIL_EXP_CLEAN`：tail_scan R=3..6 必须全 err=0；`CONFORM_EXP_CLEAN`：conformant 候选帧必须全 err=0），
把"信息性打印"升级为"硬性 FAIL"。**同一逻辑在 base/fixed 各编一次、各跑一次** → 避免"宏被 make 缓存、
串用旧二进制"的隐性风险（初版曾要求手 `rm -f deserial.vvp` 才能换 MODE，改名后根治）。

## 3. 自检机制

| # | 检测点 | 实现 | 判据 |
|---|--------|------|------|
| 1 | 字节保真 | `chk_frame`/`chk_byte` 逐字节比对（模块任务，`case_byte_exact` 定义） | 每字节 got==exp；坏帧不比对 |
| 2 | 字节脉冲计数 | `nbyte`（`rx_valid` 脉冲数）vs 参考模型理想字节数 | 无漏/无多脉冲 |
| 3 | 关包 | `wait_close(cnt, tmo)`：等 `rx_active` 第 cnt 次↓，超时(250 周期)判 NO CLOSE | 每帧关包恰一次、不超时 |
| 4 | 错误电平 | 关包沿（`rx_active`↓）采样 `rx_error` | =1 判坏包、=0 判正常（设计契约：电平保持到回 IDLE 第 1 周期末） |
| 5 | 严格断言（fixed） | `-DTAIL_EXP_CLEAN`/`-DCONFORM_EXP_CLEAN` 把 info 打印变 FAIL | 危险帧（尾 run R5/R6、合规候选）err 必须 =0 |
| 6 | 编译卫生 | iverilog `-Wall`，base/fixed（VCD 开/关）干净编译（产物按 MODE 分离） | 零 error / 零 warning |
| 7 | SYNC 判决定格（`sync_*` 记录器，2026-09-14） | 判决拍采 `code`/`run`(黑盒解码 0 连跑)/`cnt`(DUT `zero_cnt` 折算)，供 `case_sync_scan` | 命中 ⟺ `cnt∈[4,7]`；每次注入首发判决 `run==cnt`（黑盒钉死数器，避免自证） |
| 8 | 填充规则（`rones_prev_st` 块，2026-09-16） | **全用例通用**：进 `USB_DATA` 当拍断言 `u_dut.ones_cnt==0`，否则报错计入 `errors` | 解填充计数从 PID 起算（设计报告 §2.4）；退回旧窗口写法即刻 FAIL |
| 9 | `usb_rst` 契约（`pulse_usb_rst` + `ls_watch`/`ls_dirty`） | 脉冲在 `negedge dclk` 拉起/撤销 → **恰好覆盖一个 `posedge clk12m`**；`line_s` 观测窗内线静止时逐 ref 沿比对 `dut_line_s` 与引脚 | 脉冲后当拍帧机回 IDLE（迟一拍或多拍就 FAIL）；窗内 `ls_dirty=0`（复位碰了线采样寄存器即 FAIL） |

> 判错不靠人工看波形：字节、`rx_valid` 脉冲数、`rx_active` 关包次数、`rx_error` 电平全部硬件级自动断言。
> 波形仅作复现佐证（`VCD=1` + `tools/wave_debugger.py` / `tools/render_waveform.py` 出图）。

### 3.1 因果链打印（2026-09-07，仅打印证据、不参与 PASS/FAIL）

按 sim/common/README「仿真结果确认规范」的 **因→变→果 + 前窗/后窗 + 量化判据** 三段式落地：tb 加一套
**逐帧状态时间记录**（`causal_*`：在 posedge dclk 采 `u_dut.st_stat_cur` 转移记 t_seek/t_data/t_err/t_rel，
自计帧内字节数；在 posedge ref_clk 计量"线 J(idle) 且 DUT 停 USB_IDLE"的**前窗 idle 拍数**）+ 打印任务
`causal_print`/`causal_post`，挂在三个旗舰 case 的关键帧（case_out_normal 关包、case_stuff_viol 真 7 连 1、
case_err_eop **E1** bad-EOP 自愈与 **E4** rx_abort@ERROR 立即清）。每条只**加打印、不改任何断言**，10 case
× 2 MODE 的 PASS/FAIL 语义与旧版完全一致（零回归）。日志分段与各节结论一一对应，例如
`sim_base_deserial_out_normal.log`：

```
因果链·out_normal 正常关包
  前窗: 本帧首沿前 线保持 J(idle) 且 st=USB_IDLE 共 … ref_clk 拍 (干净 idle 起点)
  因: 首个 0 (SYNC 首 K) 离开 idle → st: USB_IDLE→USB_SYNC_SEEK @…
  变: SYNC 尾 ≥4 个 0 + 1 命中 → st: USB_SYNC_SEEK→USB_DATA @… (进 DATA 时 ones_cnt=0, 解填充从 PID 起算)
  果: 正常 EOP 关包 (st: USB_DATA→USB_IDLE), 关包采样: [frame] close@… nbyte=… err=… bytes=…
    (期望 err=0, 判据: 正常包必于关包沿采到 err=0)
因果链·out_normal 后窗: 关包后 4 ref_clk 内 rx_error 最值=0 …, 末拍 st=0 (USB_IDLE)
```

下列各用例节（§4.1/4.7/4.9 等）把该日志的因/变/果数值抄出，配量化判据；波形图（📎）与本日志同源、同 case
VCD，可互验。deserial 各结论的**前后文窗口**：前窗 = 帧首沿前 J(idle) idle 拍数（证干净起点非脏起点）、
后窗 = 关包后 4 ref_clk 内 `rx_error` 最值 + 末拍 st（证晚一拍清除 / 回 IDLE 稳定）。

## 4. 测试用例与结果

11 个 case 全部通过（`MODE=base` 与 `MODE=fixed` **各独立重编后均 11/11 PASS**）：

| Case | `+case=` | 测试目的 | 关键判据 | 结果 |
|------|----------|---------|---------|------|
| 正常 OUT | `deserial_out_normal` | 整链：SYNC→DATA→PID→2 字节→干净关包 | err=0、nbyte=3、字节 `e1 05 58` | ✅ |
| 全包型 | `deserial_pkt_all` | **全部 USB1.1 FS 包类型**逐字节 + 坏 PID/坏 CRC 透明 | 全 got==exp、err=0 | ✅ |
| 逐字节 oracle | `deserial_byte_exact` | 恢复流 vs 理想流全量比对（含 CRC、高 1 密度载荷） | 每帧 (a)(b)(c) 全过 | ✅ |
| 末字节形态 | `deserial_tail7` | 末字节贴 EOP 的 A–D 边界（填充/违规/直尾） | A/C err=0、B/D err=1 | ✅ |
| 尾 run 扫描 | `deserial_tail_scan` | EOP 前假连续 1 R=3..6 + 真 EOP | fixed 断言全 err=0 | ✅ |
| 合规扫描 | `deserial_conformant_scan` | 合规 DATA0 是否被误判（A:1B 穷举 / B:8B 随机） | false-err=0、fixed 断言 | ✅ |
| 真 7 连 1 | `deserial_stuff_viol` | K 电平真违规仍须检错（门控不误杀） | err=1 | ✅ |
| SE0 卡死 | `deserial_se0_stuck` | ≥2.5µs SE0（disconnect 场景） | dur≈3.5µs、err=0、干净释放 | ✅ |
| 异常释放 | `deserial_err_eop` | 坏 EOP / 截断无 EOP / 中止 / 自发送 / core 复位 `usb_rst` → 回 IDLE | 各回 IDLE、err 复位对、无幽灵帧 | ✅ |
| SYNC 窗口 | `deserial_sync_scan` | SYNC 的 0 个数 z=1..11 扫描（0 少 / 窗口内 / 0 多） | 命中 ⟺ 解码 0 连跑 ∈ [4,7]；边界恰为 4 与 7 | ✅ |
| SE0 毛刺 | `deserial_eop_glitch` | 帧内亚判决点 SE0：1/2 拍作废、SE0→K→J 宽容收尾 | 1/2 拍帧不关且无 eop；`SE0×3+K×1+J` err=0 | ✅ |

### 4.1 正常 OUT token（case_out_normal）—— 整链基线

发合规 OUT token（SYNC + PID + addr/endp + CRC5 + EOP），走整链：
SYNC 对齐（容 CDR 吃位）→ 进 DATA → PID 为首字节 → 解填充 → 3 字节 → EOP 干净关包。

**因果链（`sim_base_deserial_out_normal.log`，量化判据：`nbyte=3`、每字节 `got==exp`、关包沿 `err=0`）**：

```
前窗: 本帧首沿前 线保持 J(idle) 且 st=USB_IDLE（tb 计量前窗 idle 拍）
因:  首个 0 (SYNC 首 K) 离开 idle → st: USB_IDLE→USB_SYNC_SEEK @1802000
变:  SYNC 尾 ≥4 个 0 + 1 命中 → st: USB_SYNC_SEEK→USB_DATA @2219000 (进 DATA 时 ones_cnt=0, 解填充从 PID 起算)
果:  正常 EOP 关包 → [frame] close@4469000 nbyte=3 err=0 bytes=e1 05 58
判据: 逐字节 e1 05 58 == 参考模型（PID 0xE1 + {addr6:0,endp0}=05 + {endp3:1,CRC5}=58）；err 须 =0
后窗: 关包后 4 ref_clk 内 rx_error 最值=0、末拍 st=0(USB_IDLE)  → 晚一拍清、回 IDLE 稳定
```

**波形（与上日志同源 VCD）**：

📎 [图：SYNC 容差 + 字节输出（deserial_sync_byte_out.png）](../fig/deserial_sync_byte_out.png)
&nbsp;zero_cnt 数 SYNC 尾巴 ≥4 个 0、st 0→1→2、`rx_active`↑ 后第 1 个 `rx_valid` 脉冲字节 = `e1`(PID)，
第 2 = `05`（设计报告图 4.3/4.5/4.8）。

📎 [图：干净 EOP 关包（deserial_eop_close.png）](../fig/deserial_eop_close.png)
&nbsp;eop_stat_cur 计数 SE0 ≥3 拍后 st 2→0、`rx_active`↓ = 包结束、`rx_error` 全程 0（设计报告图 4.6a）。

结论：整链基线通路正确——CDR 吃 SYNC 位后仍命中尾巴、字节锚定、EOP 干净关包，全链路 got==exp。

### 4.2 全 USB1.1 包类型（case_pkt_all）—— 核心

用公共任务库把**每一种** USB1.1 FS 包都发一遍并逐字节校验恢复结果（此前用例只覆盖 OUT/DATA0/DATA1，
本 case 补齐 IN/SETUP/SOF/四种 handshake/PRE/NYET 及坏包变体）。对坏 PID / 坏 CRC 的期望是
**deserial 只恢复字节、不置 err=0**（校验归 SIE 层，deserial 必须透明，否则 SIE 无法按自身逻辑判坏）。

```
frame0 got : 69 05 58  exp: 69 05 58     # IN  token
frame1 got : 2d 05 58  exp: 2d 05 58     # SETUP token
frame2 got : a5 ff 3b  exp: a5 ff 3b     # SOF  frame 0x3FF (CRC5 真值 0x3B)
frame3 got : d2  exp: (len1)             # ACK
frame4 got : 5a  exp: (len1)             # NAK
frame5 got : 1e  exp: (len1)             # STALL
frame6 got : 3c  exp: (len1)             # PRE (低速前缀, 1 byte)
frame7 got : 96  exp: (len1)             # NYET
frame8 got : 61  exp: (len1)             # 坏 PID: OUT 0xE1 bit7 翻转 → 0x61, err=0 (透明)
frame9 got : e1 05 a0  exp: e1 05 a0     # token 坏 CRC5, err=0 (透明)
frame10 got: c3 01 02 03 61 61  exp: ... # DATA0 坏 CRC16, err=0 (透明)
```

全帧 got==exp、err=0；坏 PID/CRC 帧与正常帧**同样干净关包**，符合职责边界。
（早期一帧"FAIL"为该 case 自身的期望值笔误——SOF 帧后残留旧期望字节；非 DUT 问题，修正后即全对。）

### 4.3 逐字节 oracle（case_byte_exact）—— 核心

对每帧断言：(a) err=0；(b) `rx_valid` 脉冲数 == 参考模型字节数（无漏/无多）；(c) 每字节 ==
`crc5_ref`/`crc16_ref` 算出的理想字节。载荷故意选高 1 密度（0xFC/0xFE/0xFF…）同时压解填充跨字节正确性。
CRC16 期望字节按"发送 MSB first、恢复端 LSB 对齐"折算（`crc_b0[k]=tx_crc[15-k]` 等）。

```
frame0 got : e1 05 58  exp: e1 05 58
frame1 got : c3 00 01 02 0e 6e  exp: c3 00 01 02 0e 6e    # DATA0 + CRC16(00 01 02)=0e6e
frame2 got : c3 fc fe ff 4e 2f  exp: c3 fc fe ff 4e 2f    # 高1载荷 fc fe ff
frame3 got : 4b ff 55 aa 01 20  exp: 4b ff 55 aa 01 20    # DATA1 + CRC16
frame4    : DATA pid=3 nbytes=8                            # 8B 载荷帧
  PASS: case_byte_exact (all bytes + rx_valid count match ideal)
```

结论：恢复流与"参考模型理想流"**逐字节、逐脉冲一致**，字节保真成立（含位填充跨字节、CRC 恢复）。

### 4.4 末字节贴 EOP 的边界形态（case_tail7）

USB LSB first 下，末数据字节的 1 密度会贴着 EOP 的 SE0，形成 A–D 四种形态：
A=`0xFE` 正常填充（run 被 stuffed 0 拆开，干净）、C=`0xFC` 直尾恰 6 连 1 顶 SE0（门控须保证 SE0 不被
当成第 7 个 1，干净关闭恢复 0xFC）、B=`0xFE`/D=`0x7F` 不插填充 = 真 7 连 1（须报错）。

```
A(0xfe stuffed): close@3886000 nbyte=2 err=0 bytes=e1 fe
B(0xfe nostuff): close@6802000 nbyte=1 err=1 bytes=e1
C(0xfc nostuff): close@9719000 nbyte=2 err=0 bytes=e1 fc
D(0x7f nostuff): close@12636000 nbyte=1 err=1 bytes=e1
  PASS: case_tail7 (A clean / C 6-ones-tail clean / B,D 7-ones flagged)
```

结论：**门控只掐 EOP-SE0 假阳性**（C 干净），**不误杀真 7 连 1**（B/D 报错），一刀切得准。

### 4.5 EOP 尾假连续 1 扫描（case_tail_scan）

对 R∈[3,6] 各发一帧"SYNC+PID+归零 K + R 个 1 + 真 EOP"。R=4 是安全的；R=5/6 时 SE0 解码出的 1 会补到
第 7 个——本是为"门控是否必须进模块"做的对照扫描。现门控（`eop_conf_r`）内置于定稿模块，**base 与 fixed
（RTL 相同）都全清**，fixed 用 `TAIL_EXP_CLEAN` 把它变成硬断言：

```
R=3:  close dur≈1.33us nbyte=1 err=0
R=4:  close dur≈1.42us nbyte=1 err=0
R=5:  close dur≈1.50us nbyte=2 err=0   # 危险档: SE0 解码补到 7 个 1, 被门控掩掉
R=6:  close dur≈1.58us nbyte=2 err=0   # 最危险档: 同样全清
PASS: case_tail_scan  (fixed: TAIL_EXP_CLEAN 断言 R=3..6 全 err=0 通过)
```

（时长由 log 换算，约 1.3→1.6µs 随 R 增大 = 多出的 R 个 K 位 + 位填充。）结论：**合规帧尾不再误判 7 连 1**。

### 4.6 合规 DATA0 扫描（case_conformant_scan）

随机/穷举合规 DATA0 包（1B 载荷穷举 256 帧 + 8B 载荷随机 400 帧），在 EOP 前抓发送端尾状态，标记
"收尾 K + 尾连续 1≥5"的候选，关包看 err。目的：回答"正常 USB 包到底会不会触发假阳性"。

```
A: frames=256  K-tail>=5 cand=5  false-err=0     # 1B 穷举: 5 个候选全干净
B: frames=400  K-tail>=5 cand=8  false-err=0     # 8B 随机: 8 个候选全干净
PASS: case_conformant_scan  (fixed: CONFORM_EXP_CLEAN 断言候选帧全 err=0 通过)
```

结论：即使存在"尾 K + 连续 1 高"的合规包（约占被检样本 1–2%），门控下 **0 误判**；兼容合规流不成问题。

### 4.7 真位填充违规（case_stuff_viol）

对照组 4.4/4.5/4.6：真 7 连 1 发生在 **K 电平**（线不是 SE0）→ EOP FSM 停在 eop_idle → 门控不生效 →
7 连 1 必须照常进 `USB_ERROR` 并置 `rx_error`。注入：SYNC+PID 后 `raw_hold` 物理发 7 个 K 位，再 EOP。

**因果链（`sim_base_deserial_stuff_viol.log`，量化判据：进 `USB_ERROR` 前已出 2 字节、关包沿 `err=1`）**：

```
前窗: 帧首沿前 线 J(idle) 干净起点（tb 计量）
因:  SYNC 首 K 离开 idle → st: USB_IDLE→SYNC_SEEK；尾 ≥4 个 0+1 → DATA (进 DATA 时 ones_cnt=0)
变: 线在 K 电平连发 7 个 1 → ones_cnt 越限 → st: USB_DATA→USB_ERROR @…, 停吐 (进 ERROR 前已出 2 字节)
果:  坏帧 EOP 收尾释放 → [frame] close@3886000 nbyte=2 err=1 bytes=e1 fc
判据: 真违规必须 err=1（若门控误杀会 err=0 而 FAIL）；收尾字节 = PID e1 + 残缺字节 fc，坏包整体丢弃
后窗: 关包后 4 ref_clk 内 rx_error 最值=0、末拍 st=0  → 释放干净、晚一拍清
```

**波形（同源 VCD）**：

📎 [图：真 7 连 1 检错 + 释放（deserial_stuff_viol_err.png）](../fig/deserial_stuff_viol_err.png)
&nbsp;rx_bit 在 K 电平连发 1 → ones_cnt 爬升越限 → st 2→3、`rx_error`=1 电平保持、`rx_active` 保持、
`rx_valid` 停吐；坏帧 EOP → st 3→0、`rx_error` 晚一拍清（设计报告图 4.7）。

结论：门控的适用面被限定在 EOP-SE0 区，**真违规照样 err=1**（EOP FSM 未进 SE0 态 → 门控不生效，
7 连 1 正常检错），坏包丢弃不污染下一包。

### 4.8 SE0 卡死（case_se0_stuck）

disconnect 场景对照：SE0 长 ≥2.5µs（注入 2.6µs）再回 idle J。门控在模块内时，SE0 区 7 连 1 被掩 → 不检错
不自愈，停在 DATA（`rx_active` 高、不吐字节），直到 SE0→J 才经 eop 干净关包（err=0）。

```
    t=2900000  SE0 asserted (frame should be open)
    t=5500000  J released
    frame: open@2219000 close@5719000  dur≈3.5us  nbyte=1  err=0
    NOTE: dur≈3.5us + err=0 => clean release on SE0->J (gated path)
```

**量化判据**：SE0 保持期（≈2.6µs）内**无新关包**（帧仍开，`close_cnt` 不增）、`rx_error` 恒 0；SE0→J 单沿
关包恰一次、err=0。**前后文窗口**：前窗 = SE0 前已在 DATA 收字节（干净帧），后窗 = 释放后能收下一正常包
（`err_eop` 同链证明无幽灵帧）。

**波形（同源 VCD）**：

📎 [图：长 SE0 自环不误判 + SE0→J 干净释放（deserial_se0_long.png）](../fig/deserial_se0_long.png)
&nbsp;eop_stat_cur 计到 SE0 确认后**自环等 J**；SE0 全程 st 停 DATA（=2）不误关包、`rx_error` 恒 0（SE0 区
被门控掩、无假 7 连 1）；SE0→J 拉 `eop` → st 2→0、`rx_active`↓（设计报告图 2.6）。

结论：SE0 卡死不误报、SE0→J 单沿干净收尾（时长 ≈3.5µs = SE0 保持期），插拔检测留给总线状态检测模块按 2.5µs
门限另行计时，deserial 只保证此期间不误关包/不置错。

### 4.9 异常释放路径（case_err_eop）

对设计报告 §2.6 错误模型的释放条件（`USB_ERROR` 三条释放 + 中止 / 自发送 / core 复位强制）逐条打 E1–E8，
每条后跟一正常 OUT token 验**无幽灵帧**：

| # | 注入 | 期望 | 实测 |
|---|------|------|------|
| E1 | 坏 EOP（SE0→K 后回 J，宽容收尾） | err=1、eop 放行回 IDLE、自释放 | ✅ |
| E2 | 截断无 EOP（token 后静默） | err=1、7 连 1 idle 探针自愈（零定时器） | ✅ |
| E3 | `rx_abort`@DATA | 立即回 IDLE、rx_error=0 | ✅ |
| E4 | `rx_abort`@ERROR（先确认 err=1/态=3 再中止） | 回 IDLE 当拍 rx_error 即清 | ✅ |
| E5 | `tx_active`@DATA（自收发门控） | 回 IDLE、rx_error=0 | ✅ |
| E6 | `usb_rst`@DATA，线静止在 J（软复位场景） | 1 个 `clk12m` 周期脉冲内回 IDLE、err=0、只吐 PID 一字节 | ✅ |
| E7 | `usb_rst`@长 SE0（总线复位场景，帧仍开着） | 回 IDLE、丢帧、err=0、总线回 J 后无幽灵帧 | ✅ |
| E8 | `usb_rst`@ERROR（已置 err=1 电平） | 回 IDLE 且 `rx_error` 当场清（不等 idle 探针） | ✅ |

```
    E1 ok: bad-EOP(SE0->K) -> err=1, self-released
    E2 ok: no-EOP truncated pkt -> err=1, self-released (zero-timer)
    E3 ok: rx_abort@DATA -> IDLE, rx_error=0
    E4 ok: rx_abort@ERROR -> IDLE, rx_error cleared immediately
    E5 ok: tx_active@DATA -> IDLE, rx_error=0
    E6 ok: usb_rst@DATA(J) -> IDLE in 1 clk12m, err=0, line_s untouched
    E6 ok: frame closed with nbyte=1 (PID only), err=0
    E7 ok: usb_rst@SE0 -> IDLE, frame dropped
    E7 ok: closed err=0, no ghost frame on SE0->J
    E8 ok: usb_rst@ERROR -> IDLE, rx_error cleared immediately
  PASS: case_err_eop (bad-EOP/no-EOP/abort/tx_active/usb_rst all recover to IDLE)
```

**E6–E8 的量化判据（`sim_base_deserial_err_eop.log`）**：

| 判据 | 注入 | 量化 |
|---|---|---|
| 当拍生效 | `usb_rst` 覆盖且只覆盖一个 `posedge clk12m`（`negedge` 拉起/撤销） | 脉冲后立即采 `st_stat_cur==0` 且 `rx_active==0`；E6/E7/E8 三条同为 IDLE |
| 不置错 | 三条都断言 `rx_error===0` | E8 是从 `rx_error=1`（ERROR 态）被清成 0，与 E1 的"自愈后关包沿仍读 1"区分 |
| 不越界清 | E6 观测窗内线静止，逐 `ref_clk` 沿比对 `dut_line_s` 与引脚 | `ls_pre==ls_post==2'b10`（J）、`ls_dirty==0` |
| 无幽灵帧 | E6/E7 后各接一个正常 OUT token | 帧号 15/16 收到 `e1 05 58`，E6 关的那帧 `nbyte=1 err=0`、E7 `err=0` |

**E1/E4 因果链（`sim_base_deserial_err_eop.log`，量化判据：两条释放路径的 `rx_error` 复位时机）**：

```
E1 (bad-EOP SE0→K 探针自愈)
  变: 帧中检错 → st: USB_DATA→USB_ERROR @3302000, 停吐 (进 ERROR 前已出 1 字节)
  果: 关包采样 [frame] close@3969000 nbyte=1 err=1 bytes=e1   ← 关包沿 err=1 (晚一拍清, 沿仍可读)
  后窗: 4 ref_clk 内 rx_error 最值=0、末拍 st=0                ← 释放后即清、回 IDLE
E4 (rx_abort@ERROR 立即清)
  变: 真 7 连 1 已进 ERROR @22969000 (rx_error=1 保持), 停吐
  果: rx_abort@ERROR 注入 → 采样 rx_error=0                    ← 当场清 (与 E1 自愈的"关包沿 err=1"区分)
  后窗: 4 ref_clk 内 rx_error 最值=0、末拍 st=0                ← 中止不回走 7连1 探针, 直接回 IDLE 稳定
```

**波形（同源 VCD，E1 帧）**：

📎 [图：bad-EOP（SE0→K）探针自愈（deserial_err_selfheal.png）](../fig/deserial_err_selfheal.png)
&nbsp;SE0 后回 K → eop_stat_cur 走 `eop_dead` 判定 → st 2→3、`rx_error`=1 电平保持（`rx_active` 保持、停吐）；
总线静默回 J → 7 连 1 idle 探针 → st 3→0、`rx_error` 晚一拍清（设计报告图 4.6b）。

**波形（同源 VCD，E6/E7 帧，同一份 `deserial_err_eop.vcd`）**：

📎 [图：`usb_rst`@DATA 强退与 `line_s` 不受扰动（deserial_usb_rst_e6.png）](../fig/deserial_usb_rst_e6.png)
&nbsp;因：`usb_rst` 高 1 个 `clk12m` 周期，`rx_abort`/`tx_active` 全程 0，`frame_clr` 的拉高只能来自它。
果：下一个 `clk12m` 沿 st 2'h2→2'h0、`rx_active` 1→0、`rx_error` 保持 0；`dut_line_s` 全程 2'b10（复位没碰
线采样寄存器）；`close_cnt` 10→11 关帧（只吐 PID）。取景 33.72–34.06µs。

📎 [图：`usb_rst`@SE0（总线复位场景）丢帧不留幽灵帧（deserial_usb_rst_e7.png）](../fig/deserial_usb_rst_e7.png)
&nbsp;因：帧开着（`in_frame`=1、st=2'h2）时线转 SE0，`usb_rst` 一个 `clk12m` 周期。果：st→2'h0、
`rx_active`/`in_frame` 同拍落 0、`rx_error` 恒 0；`eop_stat_cur` 3'h3→3'h0 是 `~in_frame` 自动回待命。
之后线回 J，st 自 2'h1 重新搜 SYNC 收下一正常包。取景 39.08–39.44µs。

E1–E8 后第 10–17 帧全为正常 `e1 05 58`：释放后**能立即命中下一包 SYNC**，无幽灵关包。E4 专项印证
`rx_error` 释放简化实现（帧机回 `USB_IDLE` 即清，无需关包沿标志）在 ERROR 态中止下行为正确；E8 把同一
条实现放到 `usb_rst` 上再验一遍。

### 4.10 SYNC 接受窗口边界（case_sync_scan）

设计报告 §4.3 的 `SYNC_MIN_ZERO = 4` 只给出了窗口**下界**。本用例补测：① 下界确实"恰好 4"（3 个 0 拒、4 个 0 收）；
② 窗口还有**上界 7**（`zero_cnt` 数到第 8 个 0 立即放弃），即接受区间是 **[4,7]**，而非"≥4 就无限容忍"。

**注入与判据（为什么不能拿"我发了几个 0"当判据）**：把 SYNC 的 7 个 0 换成 z 个扫 z=1..11。CDR 会吃位
（帧间 idle 后第一个 SYNC 吃 1 bit，见 §4.5），到达 deserial 的连跑可能短于 z，发射值下判据会被吃位污染。
故 tb 记录器在**判决拍**（`st_stat_cur==SEEK` 且**组合** `st_stat_nxt!=SEEK`——用 `st_stat_nxt` 而非延后一拍的 `st_stat_cur`，
否则定格时 `d_bit`/`zero_cnt` 已被下一数据位覆盖）定格三元组：判决类型 `code`（命中 / 拒收-0 少 / 拒收-0 多）、
tb 自数的解码 0 连跑 `run`（黑盒）、DUT `zero_cnt` 折算的"本轮 SEEK 计入 0 个数" `cnt`（白盒）。判据用 `cnt`，
并用"每次注入**首个**判决 `run == cnt`"把数器钉死——否则会陷入"用 DUT 的数器验 DUT 的判据"的自证。

```
因: SYNC 替身 = z 个 0 + 1 个 1 (z=1..11), 线路 NRZI 逐拍翻转; z∈{1,2,3,10,11} 后接 raw_hold(J,16)
变: 判决拍定格 SEEK 出口 —— 命中(st_stat_nxt=DATA) / 拒收-0少(d_bit=1, cnt<4) / 拒收-0多(d_bit=0, 第 8 个 0)
果: 实测判决表 (sim/deserial/sim_base_deserial_sync_scan.log, 空格归一)
    z=1 : [拒收-0少 run=1] [拒收-0少 run=1]                      close_delta=0
    z=2 : [拒收-0少 run=2]                                       close_delta=0
    z=3 : [拒收-0少 run=3] [拒收-0少 run=1]                      close_delta=0
    z=4 : [命中 run=4]                                           close_delta=1
    z=5 : [命中 run=5]                                           close_delta=1
    z=6 : [命中 run=6]                                           close_delta=1
    z=7 : [命中 run=7]                                           close_delta=1
    z=8 : [拒收-0多 run=8] [命中 run=4]                          close_delta=1
    z=9 : [拒收-0多 run=8] [拒收-0少 run=9 cnt=1] [命中 run=4]   close_delta=1
    z=10: [拒收-0多 run=8] [拒收-0少 run=10 cnt=2]               close_delta=0
    z=11: [拒收-0多 run=8] [拒收-0少 run=11 cnt=3] [拒收-0少 run=1] close_delta=0
    判决统计: 命中 6 次 (最小 cnt=4) / 拒收-0少 9 次 (最大 cnt=3) / 拒收-0多 4 次 (最小 cnt=8)
后窗: z∈{1,2,3,10,11} 全程 close_delta=0 (无幽灵帧); 扫描后再发标准 OUT → nbyte=3、bytes=e1 05 58、err=0 (无卡死)
```

**量化判据与结论**（base / fixed 双模式均 PASS，两块数据一致）：

| 判据 | 实测 | 结论 |
|------|------|------|
| 命中最小 `cnt` | 4 | 窗口下界**恰为 4**（3 收不了、4 能收），与 `SYNC_MIN_ZERO=4` 一致 |
| "0 少"拒收最大 `cnt` | 3 | 0 少于 4 个即拒（假触发回 `USB_IDLE`），无一例漏拒 |
| "0 多"拒收最小 `cnt` | 8 | 第 8 个 0 即拒 → 窗口上界**恰为 7**，不存在"≥4 就无限容忍" |
| 每次注入首发判决 `run == cnt` | 全部相等（零 FAIL） | DUT `zero_cnt` 与物理解码 0 连跑一致 → 用 `cnt` 判窗口非自证 |
| 越界带（z≤3 / z≥10）幽灵帧 | `close_delta` 全 0 | 坏 SYNC 不开包、不残留半帧 |
| 命中带（z=4..7）字节保真 | 关包采样 `nbyte=3`、`b0=e1`、`err=0` | SYNC 命中点正确锚定 PID 起点，整包解码不乱 |

两点如实说明：① z=8/z=9/z=10/z=11 的**首个**判决都是"第 8 个 0 拒收"（`cnt=8`），随后的判决是**残余 0
重新进 `SEEK`** 后的结果（`cnt` 只数到 1/2/3，仍被拒）——证明拒收不是"一次性锁死"，每次 0 连跑独立计；② z=8/z=9
落在扫描带（后接真 token body），其第二次"命中 run=4"发生在 body 内部，是数据中出现"4 个 0 + 1"的**合法重触发**，
非误判（deserial 无 CRC 无从区分，本就需要 SIE 层用 CRC 兜底），故判据只对**首个**判决断言字节保真。

### 4.11 帧内亚判决点 SE0 毛刺（case_eop_glitch，2026-09-16 覆盖率驱动新增）

**为什么加**：§7 覆盖率排查发现，DUT 只剩 L335/L341（EOP 定界 FSM 的"SE0 撤销作废"两条 else 臂）
与 L363/L375（`eop_evt2` 宽容收尾）没有任何用例走到。这两条不是冗余补全，而是**真实可达的总线场景**：
线上几十 ns 的 SE0 抖动、以及 SE0 收尾时先回 K 再回 J。缺了它们，"毛刺会不会把关中的帧截断"
和"异常收尾会不会被误判成 EOP 错"这两条设计意图就没有验证。

**时序依据（能把 1 拍 / 2 拍 SE0 精确构造出来）**：TB 的电平跳变全部落在 `BIT_TIME` 整数倍，
而 `ref_clk` 上升沿落在 `BIT_TIME` 的 1/8、3/8、5/8、7/8 处 —— 跳变点恰好落在两个上升沿**正中间**。
`line_s` 在 `posedge ref_clk` 采 `{rxdp,rxdn}`，故宽 `w*(BIT_TIME/4)` 的脉冲必被采到**恰好 w 次**。
EOP 判决点 = `eop_stat_cur` 走到 `ST_EOP_SE0_3`（连续 ≥3 拍，≈62.5ns）。

| 子步 | 注入 | 期望（判据） | 实测 |
|------|------|-------------|------|
| G1 | 帧中 SE0×1 拍（0.25 bit） | 帧不关、`eop_w`/`eop_err_w` 恒 0、`st_stat_cur` 仍 `USB_DATA` | ✅ 帧仍 DATA，`eop_stat_cur` 走 IDLE→SE0_1→IDLE |
| G2 | 帧中 SE0×2 拍（0.5 bit） | 同上 | ✅ 帧仍 DATA，走 IDLE→SE0_1→SE0_2→IDLE |
| G3 | SE0×3 拍 + K×1 拍 + J | 宽容关包且**关包 err=0**（走 `eop_evt2` 而非 `eop_err_evt`） | ✅ 关包 err=0，`SE0_3`→DEAD→(见 J) `eop_evt2` |
| G4 | 毛刺后干净 OUT token | 正常关包 err=0（模块可复用） | ✅ nbyte=3、err=0 |

G1/G2 还各跟一个**后窗**：毛刺之后补一个真 EOP，帧必须照常关包且 `err=0` —— 证明短 SE0 只是被作废，
没有在 FSM 里留下残留状态（若作废路径写错状态，后窗会立刻暴露）。三段因果链在日志里逐条打印：

```
G1 ok: 因 SE0×1 拍 → 变 eop_stat_cur IDLE→SE0_1→IDLE (L335 作废) → 果 帧仍 DATA, 无 eop/eop_err
G2 ok: 因 SE0×2 拍 → 变 eop_stat_cur IDLE→SE0_1→SE0_2→IDLE (L341 作废) → 果 帧仍 DATA, 无 eop/eop_err
G3 ok: 因 SE0×3+K×1+J → 变 eop_stat_cur SE0_3→DEAD→(见 J) eop_evt2 (L363/L375) → 果 宽容关包 err=0
G4 后窗 ok: 毛刺后干净 OUT token 正常关包 err=0 (nbyte=3)
```

**边界意义**：G1/G2/G3 合起来把判决点夹死了 —— 2 拍 SE0 必须作废、3 拍 SE0 必须生效，这正是
RTL 里 `ST_EOP_SE0_3` 这一级的定义本身；G3 进一步区分了"SE0 后非 J"的两种收尾（下一拍是 J 则宽容
补判 eop，否则判 eop_err，后者已由 §4.9 的 E1 覆盖）。

## 5. 专项交叉验证（独立于 DUT 的旁证）

1. **CRC 参考模型自证防"镜像 bug"**：`byte_exact` 的期望 CRC 由 `crc16_ref.vh`/`crc5_ref.vh` 在**同一 Verilog
   编译内**算出——若模型与 DUT 犯了同一个位序/多项式错误，会"互相对上"而不被发现。为此用 **Python 独立镜像**
   CRC16 LFSR（左移、poly 0x8005、LSB 先喂、发送 ~rem bit15..0）复算 3 组载荷：`00 01 02`→`0e 6e`、
   `fc fe ff`→`4e 2f`、`ff 55 aa`→`01 20`，与 `byte_exact` 恢复字节全部一致；CRC5 用规范多项式复算 token
   `05 00`→`0x58`、SOF `0x3FF`→`0x3B` 亦一致。→ 恢复出的 CRC 字节是**真 USB CRC 值**（早期一次
   "MISMATCH" 系脚本位序误用，修正算法后即全对，非 DUT 问题）。
2. **坏 PID/CRC 透明性**（`pkt_all`）：deserial 对坏 PID（0x61）、坏 CRC5（`e1 05 a0`）、坏 CRC16
   （`c3 01 02 03 61 61`）**一律 err=0 干净关包**——物理检错只抓位填充违规/EOP 错，不越权判 PID/CRC，
   把判定完整留给 SIE 事务层。
3. **释放语义与设计契约**：E1–E5 + 正常帧交叉验证 `rx_error` 电平时序——坏帧在 `USB_ERROR` 期保持、关包沿
   （`rx_active`↓）后第 1 个 IDLE 周期仍可读 1、随后清 0，SIE 于下降沿采样判坏包的契约不因"回 idle 即清"
   简化实现而改变。
4. **解填充计数窗口改动的前后等价性（2026-09-16）**：`ones_cnt` 的窗口从"仅 `USB_IDLE` 保持 0"改为
   "帧外（`!rx_active`，含 `USB_SYNC_SEEK`）保持 0"，即计数改为从 PID 起算（理由/证明见设计报告 §2.4）。
   **两路独立证据表明行为不变**：① 模型级——穷举 16 种合法 PID（`XX~XX` 形态）× 8 种后续字节，两种计法
   输出的线上位流逐位相同（TX 侧 `tools/gen_tx_timing.py --check`）；② RTL 级——把旧窗口写法编译成对照
   DUT，10 个 case 逐 case 与定稿对比，**解码字节流、时刻、PASS/FAIL 语义完全一致**（仅诊断打印文字与新增
   断言不同）。新增 §3 表第 8 项自检机制把新规则钉死；反向验证：旧窗口写法跑 `deserial_out_normal` 立刻报
   `ERROR: 进 USB_DATA 时 ones_cnt=1`（断言非空判）。新规则下 base/fixed 仍各 10/10 PASS。
5. **接口加端口在下游 TB 的连带项（`usb_rst`）**：`usb_rst` 是本模块新增输入，任何一个回环 TB 漏接它都会
   拿到 `z`，把 `frame_clr`、`rx_valid`、帧态一起拖成 `x`，现象是"回环收不到字节"。加端口后 `sim/tx`
   立刻报出 `tx_tail_stuff` 的 `tail_FD`/`tail_FF_FF_FC`/`tail_00` 三例"回环收到 0 字节"；在
   `sim/tx/tb_tx_serial.v`（及 `sim/tx/scratch/tb_sy.v`）的 deserial 例化里补 `.usb_rst(1'b0)` 后
   **tx 20/20 PASS** 复原。本模块自己的 TB 同一处约束记在 §3 第 9 项。

## 6. 编译卫生（零 error / 零 warning）

用户要求 iverilog 编译不得出现 error/warning。`-Wall` 下 base/fixed（各带 VCD 开/关）干净编译（产物按 MODE
命名，2026-09-07 起切 MODE 不需手 `rm`，见 §2）：

| 配置 | error | warning |
|------|:---:|:---:|
| `fixed` VCD=0 | 0 | 0 |
| `fixed` VCD=1（覆盖 ifdef 波形块） | 0 | 0 |
| `base` VCD=0 | 0 | 0 |

修掉的两类告警：① `usb_rx_deserial.v` / `usb_rx_cdr.v` 补插 `` `timescale 1ns/1ps ``（消除 timescale 继承
告警；各 sim 均 1ns/1ps，行为中性）；② `case_tail_scan.v` 的 `$value$plusargs()` 语句式调用改
`if (!$value$plusargs(…)) ;`（用返回值免 as-task 告警）。

## 7. 覆盖率（Verilator 5.052，MODE=base+fixed 合并 = 22 次运行）

用户 2026-09-16 定：行/分支等覆盖率要跑全、单用例不够就跨用例合并，并落到验证报告。iverilog 没有覆盖率
能力，故**另起 Verilator 跑同一份 TB 出数字，功能判据仍以本报告 §4 的 iverilog 回归为准**。

### 7.1 结果（口径 = DUT 模块 `tb_deserial.u_dut`）

| 维度 | 覆盖 | 说明 |
|------|------|------|
| branch | **60/60 = 100%** | |
| expr | **119/119 = 100%** | |
| toggle | **174/174 = 100%** | |
| line | 75/76 = 98.7% | 唯一缺口 L288 见 §7.4 |
| FSM 状态 | **4/4** | TB 侧自建统计，见 §7.3 |
| FSM 合法弧 | **10/10** | 且无设计意图外的迁移 |

> **点数口径说明**：DUT 于 2026-09-20 按 `code_rtl.md` 规则 7 重写（七段骨架 + 输出 `<out>_nxt`
> D 线 + `stat_cur`/`stat_nxt` 命名），规则 7.5 要求的 `_nxt` 中间线**本身就是新的覆盖点**，
> 故点数比首版高（branch 48→60、toggle 150→174）。此后 `usb_rst` 落地时把 6 处重复的
> `(tx_active || rx_abort)` 收成一根 `frame_clr`，表达式点跟着合并（expr 132→119），
> 同时多出 `frame_clr`/`usb_rst` 的翻转点（toggle 170→174）。**四个维度仍是 100%**，
> 点数变化来自写法的合并与新增端口，不是覆盖缺口。

全层级 summary（含 TB 自身、Verilator `std::*`、回环链上已验证的其它模块）会被稀释，故报数只取 DUT 域：

| 层级 | line | branch | expr | toggle |
|------|------|--------|------|--------|
| `tb_deserial.u_dut`（**报数口径**） | 75/76 | 60/60 | 119/119 | 174/174 |
| `tb_deserial.u_cdr`（已单独验证，非本模块） | 17/18 | 24/24 | 24/24 | 40/40 |
| `tb_deserial`（TB 自身） | 209/254 | 144/216 | 95/152 | 769/2036 |

> `u_cdr` 行只作旁证（说明全层级 summary 被什么稀释），**不是本模块的质量指标**：它未被覆盖的 1 行是
> DPLL 状态译码的 `default:` 臂（L162/L163，`stat_cur` 是 4 bit、合法态只用了几个），与 DUT 的口径无关。

### 7.2 复跑命令

```bash
make cov MOD=deserial        # 根入口: 建 → 跑全 11 用例 × base/fixed → 合并 → 打印 summary + fsmcov
make -C sim/deserial cov     # 模块内等价命令
make -C sim/deserial fsmcov  # 只重算 FSM 状态/弧维度
make covclean                # 删 cov/ (构建目录 + 数据); make clean 不动它
```

覆盖率运行**卡功能判据**：任一用例非 `TEST PASSED` 即中止，不会拿跑挂的激励出数字。

### 7.3 工具与两个口径决定

1. **为什么是 Verilator**：iverilog 无覆盖率能力。代价是该模块 TB 必须先过 Verilator 可移植性 ——
   本模块比 `sim/tx` 顺利（tx 为它改了 4 处），`tb_deserial.v` 一次通过，无需改动。
2. **为什么 base + fixed 一起合并**：两个 MODE 跑的是**同一份 DUT**（`src/phy/usb_rx_deserial.v`），
   区别只是编译期断言宏 `-DTAIL_EXP_CLEAN -DCONFORM_EXP_CLEAN` 是否把"应当清 0"的偏差判成 FAIL
   （见 §4.5/§4.6）。激励完全相同，合并后才是"这套激励整体覆盖了多少 DUT"。
   `gate/gatesync/linese0/rawse0/nrzi2` 几个 MODE 用的是 sim 本地变体 `usb_rx_deserial_gate.v`，
   **不是交付 RTL，不计入**。
3. **FSM 那一维是自建的**：Verilator 的 `--coverage-fsm` 只认单段式 FSM，认不出 `code_rtl.md` 要求的
   两段式（组合算 `st_stat_nxt` + 时序搬 `st_stat_cur`），merged.dat 里 fsm 记录为 0。改由 TB 分层引用
   `u_dut.st_stat_cur` 自己数（`print_fsm_coverage` + `tools/merge_fsm_cov.py`）。
   **不为工具改已验收的 RTL。** 22 个日志合并后的矩阵：

```
          to:     IDLE    SEEK    DATA   ERROR        停留拍数: IDLE 13156 / SEEK 10052
from IDLE         11682    1474       0       0                   DATA 93840 / ERROR 68
from SEEK            52    8578    1422       0
from DATA          1408       0   92418      14        合法弧 10/10, 无意图外迁移
from ERROR           14       0       0      54
```

### 7.4 未覆盖项定性

| 项 | 位置 | 性质 |
|----|------|------|
| `default: st_stat_nxt = USB_IDLE;` | L288 | **正常豁免**：`st_stat_cur` 是 2 bit，4 个取值已全部枚举，该臂结构不可达。它是 `code_rtl.md`「if-else 条件完整 / case 补全」强制要求的兜底写法的必然产物，不是缺口（TX 报告 §8.4 的 L99 同型） |

> 判据取自 lcov（`verilator_coverage --write-info`）里 DUT 文件的 `DA:` 零项：只有 L288/L289 两行（同一条
> `default:` 臂），对应 Verilator 行指标里的 1 行缺口。

至此 DUT 域**不再有功能缺口**：其余三维（branch/expr/toggle）均已 100%。早先的两组缺口已收掉 ——
EOP 判决点那一簇由 `deserial_eop_glitch` 用例补上，`ref_rstn` 相关的一整簇由 TB 复位序列缺陷修复后
消失（§7.5）。

### 7.5 覆盖率暴露的 TB 缺陷：复位分支从未执行（已修）

初次跑覆盖率时，DUT 域有 **10 条 `(ref_rstn==0) => 1` 表达式 + L31 的 `ref_rstn:1->0` 翻转**未覆盖，
且全部落在 `always @(posedge clk12m or negedge ref_rstn)` 块里。根因是 TB 的复位序列：

```verilog
ref_rstn = 0;   // 初始化区
...
#200;  ref_rstn = 1;   // 撤复位
```

在 Verilator 里 reg 初值本就是 0，这条 `ref_rstn = 0` 是 **0→0，不产生任何沿** —— 异步复位分支一次都
没进去过。危害不止覆盖率：**寄存器初值退化成仿真器默认值**（iverilog 是 `x`、Verilator 是 `0`），
两家行为漂移，`x` 参与比较恒假会悄悄放过错误。

修法（`tb_deserial.v` 初始化区）是"**放开 → 拉低制造真 1→0 → 再放开**"。这里比 `sim/tx` 多一层讲究：
`clk12m` 在本模块是 `dclk`（CDR 恢复时钟），**冷启动未锁时停摆**，靠 `@(posedge clk12m)` 等不到沿；
但异步复位分支由 `negedge ref_rstn` 触发，**与时钟无关**，只要做出一次真的 1→0 就能命中。

| 阶段 | line | branch | expr | toggle |
|------|------|--------|------|--------|
| 修复位序列前 | 73/83 = 88.0% | 43/48 = 89.6% | 116/130 = 89.2% | 147/150 = 98.0% |
| 修复位序列后 | 82/83 = 98.8% | 46/48 = 95.8% | 128/130 = 98.5% | 148/150 = 98.7% |
| **再加 `eop_glitch` 用例后** | 82/83 = 98.8% | **48/48 = 100%** | **130/130 = 100%** | **150/150 = 100%** |

> 三行是那一轮修复过程的绝对点数（口径与 §7.1 的当前点数不同，规则 7 重写后点数变过），比值才是结论。

功能上这次修复不可见（iverilog 修前修后各 11/11 PASS），但它消掉了"初值随仿真器变"的隐患，是本轮覆盖率
最实在的产出 —— 与 TX 报告 §8.6 是同一类缺陷。

## 8. 结论

| 设计报告 §4.10 验证点 | 覆盖 case | 结果 |
|---|---|---|
| 字节对齐（逐字节=发送 PID/ADDR/ENDP/CRC/数据） | pkt_all / byte_exact / out_normal | ✅ PASS |
| 位解填充（含高 1 密度跨字节、0x7F） | byte_exact / pkt_all / tail7 | ✅ PASS |
| SYNC 容差（每包命中、PID 首字节） | 全部 11 case 首字节均对 | ✅ PASS |
| SYNC 窗口**边界**（下界恰 4、上界恰 7） | sync_scan | ✅ PASS（z≤3 拒、z=4..7 收、z≥8 拒） |
| 字节脉冲（`rx_valid` 每字节恰一脉冲） | byte_exact（nbyte==理想数） | ✅ PASS |
| EOP 宽度（放宽 2-bit/1-bit SE0+J） | tail_scan / out_normal | ✅ PASS |
| EOP 尾假 7 连 1（合规包不误判） | tail_scan / tail7-C / conformant | ✅ PASS（门控内置，0 误判） |
| 帧中错误（7 连 1 保持+释放、坏帧 EOP 收尾） | stuff_viol / tail7-B,D | ✅ PASS（err=1，正确丢弃） |
| 静默 idle（无 EOP）释放 | err_eop-E2 | ✅ PASS（零定时器自愈，无幽灵帧） |
| EOP 错（SE0 无 J 收尾）+ 宽容收尾 | err_eop-E1 / eop_glitch-G3 | ✅ PASS |
| EOP 判决点下界（<3 拍 SE0 作废、≥3 拍生效） | eop_glitch-G1/G2/G3 | ✅ PASS（2 拍不关、3 拍关） |
| SE0 毛刺/长 SE0 / disconnect 场景 | se0_stuck / tail_scan | ✅ PASS（err=0、单沿收尾） |
| 溢出中止 `rx_abort` / 自收发 `tx_active` | err_eop-E3/E4/E5 | ✅ PASS |
| core 复位 `usb_rst`（回 IDLE、不置错、不碰 `line_s`） | err_eop-E6/E7/E8 | ✅ PASS |
| 职责边界（坏 PID/CRC 透明） | pkt_all 坏包帧 | ✅ PASS（err=0） |

**11 个测试用例在 `MODE=base` 与 `MODE=fixed`（各独立重编）下全部通过；编译零 error/零 warning；合并日志无
FAIL/timeout/assert 残留。** 其中 byte_exact（逐字节 oracle）、pkt_all（全包型 + 坏包透明）、err_eop
（异常释放全集）三例从功能上严格证明了字节保真、定界、错误检测/释放与门控边界的正确性；Python 独立 CRC
复算提供了参考模型之外的旁证。

**覆盖率（§7，Verilator，MODE=base+fixed 合并）**：DUT 域 **branch 60/60、expr 119/119、toggle 174/174
全部 100%**，line 75/76 = 98.7%（唯一缺口 L288 是 2-bit 状态已全枚举后的 `default:` 兜底，结构不可达，
属编码规范强制写法的正常豁免）；FSM **4/4 状态 + 10/10 合法弧**，无意图外迁移。覆盖率还反向暴露了
TB 复位序列的一处缺陷（复位分支从未执行 → 寄存器初值随仿真器漂移），已修复，见 §7.5。

**是否符合「仿真结果确认规范」（sim/common README）**：逐用例已按 **因→变→果 + 前窗/后窗 + 量化判据** 组织
（§4.1/4.7/4.8/4.9 附 tb `causal_print` 日志摘录，§4.10 附判决记录器实测表，§3.1/§3.2 说明机制）；旗舰 case 关键帧另配**波形图**（📎，同源
VCD 经 `tools/render_waveform.py` 出图）可复算复核：

| 结论 | 因果链日志节 | 波形图 |
|---|---|---|
| 整链字节保真（SYNC 容差 / 字节对齐 / 每字节脉冲） | §4.1（+§4.2/4.3 oracle） | 📎 图 §4.1 `deserial_sync_byte_out.png` |
| 干净 EOP 关包定界 | §4.1 果/后窗 | 📎 `deserial_eop_close.png` |
| 真 7 连 1 检错 + 释放（门控边界） | §4.7 | 📎 `deserial_stuff_viol_err.png` |
| bad-EOP（SE0→K）探针自愈 / `rx_abort` 立即清 | §4.9 E1/E4 | 📎 `deserial_err_selfheal.png` |
| `usb_rst` 强退（线静止 J / 帧中长 SE0）+ `line_s` 不受扰动 | §4.9 E6/E7 判据表 | 📎 `deserial_usb_rst_e6.png`、`deserial_usb_rst_e7.png` |
| 长 SE0 不误判 + SE0→J 干净释放 | §4.8 | 📎 `deserial_se0_long.png` |
| SYNC 接受窗口边界 [4,7] | §4.10 | （判决表 + `sync_scan.vcd`） |

> 复跑：`make deserial`（根入口，base+fixed 双模各 11/11）或 `make -C sim/deserial run MODE=base`
> （`MODE=fixed` 同）；`make -C sim/deserial build VCD=1` 后重跑刷新 `<case>.vcd`；波形
> `make -C sim/deserial debugwave CASE=<name>`（或根入口 `make debugwave MOD=deserial CASE=<name>`）；
> 覆盖率 `make cov MOD=deserial`。本报告所有波形图都由 `<case>.vcd` 经 `tools/render_waveform.py`
> 离屏渲染得到，取景时间印在图 caption 里，可逐张复算。
