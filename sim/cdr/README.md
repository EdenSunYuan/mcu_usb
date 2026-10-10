# CDR 模块仿真

## 模块简介

`usb_rx_cdr` — USB 1.1 时钟数据恢复 (Intel SIE DPLL)

- 48MHz `ref_clk`，16 态 FSM
- a/b 双沿采样 D+ (posedge/negedge)
- 恢复 12MHz `dclk` + NRZI 电平 `rx_bit`
- 左右双环循环 + 长 bit 绕行 (F/B)

RTL 源码: `../../src/phy/usb_rx_cdr.v`

## 仿真架构

```
sim/cdr/
├── tb_cdr.v               # 顶层 testbench (DUT + 自检 + case 分发)
├── case_nominal.v          # 10 个独立 test case
├── case_long_bit_f.v
├── case_long_bit_b.v
├── case_short_bit_j.v      # 短 bit data=1/J (3cyc) → 右环 6→1
├── case_short_bit_k.v      # 短 bit data=0/K (3cyc) → 左环 2→5 (J 的镜像)
├── case_se0.v
├── case_random.v
├── case_multi_pkt.v
├── case_loopback.v
├── case_pkt_all.v          # 全 9 类合法正常包端到端回环 (case_loopback 全包型推广)
├── Makefile                # 编译 + 逐个 case 运行
└── README.md

sim/common/                 # 共享 (所有模块共用)
├── usb_pkt_tasks.vh        # USB 包激励: bit_task/byte_task/pid_task/out_packet_task
└── crc5_ref.vh             # CRC5 参考函数 (out_packet_task 使用)
```

每个 case 通过 vvp 的 `+case=<name>` plusarg 独立运行，一次 vvp 调用只跑一个 case。

## 自检机制

pass/fail 判定基于以下**硬件级别的自动检测**：

### 1. 锁存检测 (关键)

```verilog
// FSM 首次进入右环 (stat_cur 5, stat_nxt 7) → locked=1
always @(posedge clk) begin
    if (!locked && dut.stat_cur == 4'd5 && dut.stat_nxt == 4'd7)
        locked <= 1;
end
```

### 2. F 绕行检测 (stat_cur 3→15)

```verilog
always @(posedge clk) begin
    if (prev_state == 4'd3 && dut.stat_cur == 4'd15)
        f_detected <= 1;
end
```

### 3. B 绕行检测 (stat_cur 7→11)

```verilog
always @(posedge clk) begin
    if (prev_state == 4'd7 && dut.stat_cur == 4'd11)
        b_detected <= 1;
end
```

### 4. rx_bit 跟踪 (信息性，不计入 pass/fail)

```verilog
always @(posedge clk) begin
    if (locked && rstn) begin
        if (rx_bit !== rxdp)
            d_out_mismatches++;    // 仅记录，因 DPLL 有流水延迟
    end
end
```

rx_bit 跟踪不匹配不参与 pass/fail 判定（DPLL 内部流水线有 2-3 拍的延迟，正常情况每个 case 有 ~40-90 次不匹配），仅作为调试信息输出。真正的判定依据是 `locked` 和 `f_detected`/`b_detected` 标志。

### 5. 因果链自检（锁存 C→D→5，用户 2026-09-07 定）

上面的 #1 只给"已锁存"的最终结果。`causal_arm` / `causal_lock_check`
（`tb_cdr.v`，`case_nominal` / `case_pkt_all` 首包调用）逐 `ref_clk` 采样
`dut.stat_cur` + `dclk` 进时间线，按 **因→变→果 + 前后窗** 断言锁存过程：

- **前窗**：idle J 下 `state` 恒 C 且 `dclk=0`（无数据不吐时钟）；
- **因①**：线上首 K → `C→D`（首个非 C 态必须 = D）；
- **因②**：线上回 J → `D→5`，锁存延迟 ∈ [1,8] ref_clk；
- **果**：锁定后 16 ref_clk 内 `dclk` 上升沿 ≥2（12MHz 恢复时钟在运行）。

实测锁存延迟 **4 ref_clk = 1 bit**（见回归日志），与 SYNC 两次边沿间隔精确吻合。
通用确认规范（所有模块仿真通用）见 `sim/common/README.md`「仿真结果确认规范」。

### 6. 短 bit 自适应自检（J/K 双向：6→1 与 2→5，用户 2026-09-07 定）

短 bit 有 J/data=1 与 K/data=0 两种极性，各自走独立的"跳过切环"路径——**镜像长 bit
的 f/b 分成两个 case**：`case_short_bit_j.v`（右环 6→1）与 `case_short_bit_k.v`
（左环 2→5）。早先单一 `case_short_bit` 只查"短 bit 后不失锁"——短 bit 机制从未被
真正验证（对比长 bit 有显式 `f_detected`/`b_detected`）。tb_cdr.v 新增
`short_meas_en`/`short_edges`/`short_c3`/`short_over`/`short_skip`(6→1)/
`short_skip_k2`(2→5) 监测，case 在发包窗口内断言：

- **因**：1 个 bit 压到 3cyc → 下一个翻转沿比标称早 1 ref_clk；
- **变**：
  - J（`case_short_bit_j`，CRC5[2]=bit29，data=1/J）：早到的 **K** 沿打在右环
    第 3 态 `6`（b=0）→ **`6→1` 跳过切环**（跳 4/5，state 6 `(b==1)?4:1`）；
  - K（`case_short_bit_k`，CRC5[3]=bit30，data=0/K）：早到的 **J** 沿打在左环
    第 3 态 `2`（b=1）→ **`2→5` 跳过切环**（跳 0/1，state 2 `(b==0)?0:5`）；
- **果**：该位恢复时钟周期 = **3 ref_clk**（其余 4），不失锁；
- **界**：`<3` ref_clk 过短周期 = 0（自适应不过冲）；且对向跳过 = 0（J/K 不串扰）。

量化判据（两 case 各自硬断言）：本向跳过恰 1、对向跳过 0、`short_c3==1`、
`short_over==0`、`short_edges≥20`。回归实测（VCD 核对短周期窗口状态轨迹 + 周期）：

```
J:  6→1 跳过 1 次 | 2→5 跳过 0 次 | 3-ref_clk 周期 1 个 | 过短(<3) 0 | dclk 沿 44
    状态轨迹 5→7→6→1→3→2→0 (6 遇提前 K 沿跳 4) | 短周期 62502 ps = 3 ref_clk
K:  6→1 跳过 0 次 | 2→5 跳过 1 次 | 3-ref_clk 周期 1 个 | 过短(<3) 0 | dclk 沿 44
    状态轨迹 1→3→2→5→7→6→4 (2 遇提前 J 沿跳 0) | 短周期 62502 ps = 3 ref_clk
```

## 测试用例

| Case | `+case=` 名称 | 测试目的 | 判定标准 |
|------|--------------|---------|---------|
| Nominal | `cdr_case_nominal` | 标称 4-cycle OUT Token，验证基本锁存 | `locked=1` + 因果链窗口 |
| Long Bit F | `cdr_case_long_bit_f` | J 电平下长 bit (5cyc) → F 绕行 | `f_detected=1` |
| Long Bit B | `cdr_case_long_bit_b` | K 电平下长 bit (5cyc) → B 绕行 | `b_detected=1` (非致命) |
| Short Bit J | `cdr_case_short_bit_j` | 短 bit data=1/J (3cyc) 频率自适应 | 因果链：`6→1`×1 + 3-ref_clk 周期×1 + 无 `2→5`/`<3`（§自检机制 6） |
| Short Bit K | `cdr_case_short_bit_k` | 短 bit data=0/K (3cyc) 频率自适应（J 的镜像） | 因果链：`2→5`×1 + 3-ref_clk 周期×1 + 无 `6→1`/`<3`（§自检机制 6） |
| SE0 | `cdr_case_se0` | 注入 SE0 后 CDR 能重新锁存 | 第二次 `locked=1` |
| Random | `cdr_case_random` | 64 bit 随机数据 + 随机宽度 (3/4/5cyc) | `locked` 保持全程 |
| Multi Pkt | `cdr_case_multi_pkt` | 3 包事务 (SETUP+DATA0+ACK) 时钟/数据持续恢复 | 周期 3~5 ref_clk，`max_run≤6` |
| Loopback | `cdr_case_loopback` | 端到端逐 bit 对比（dclk+rx_bit 还原数据位 vs 发送位） | 122 数据位 0 差异 |
| 全包型回环 | `cdr_case_pkt_all` | 全部 9 类合法正常包端到端逐 bit（含 stuffed bit 还原） | 9/9 包 0 差异 |

### case_nominal — 标称 4-cycle OUT Token

- 发送标准 OUT Token (SYNC + PID + ADDR + ENDP + CRC5 + EOP)
- 触发锁存: C(12) → D(13) → 5 → 7 → 6 → 4 → ...
- **预期**: locked 置位，CDR 进入右环循环
- 首包前先记 idle 前窗（`causal_arm`），发完调用 `causal_lock_check` 断言
  C→D→5 因果链 + 恢复时钟起振（实测锁存延迟 4 ref_clk = 1 bit，见 §自检机制 5）

### case_long_bit_f — F 绕行

- PID bit 5 (data=1, J 电平) 拉长到 5-cycle
- DPLL 在状态 3 时 a_reg=1 → 触发 3 → F(15) → 6
- **预期**: `f_detected` 置位

### case_long_bit_b — B 绕行

- ADDR bit 5 (data=0, K 电平) 拉长到 5-cycle
- DPLL 在状态 7 时 a_reg=0 → 触发 7 → B(11) → 2
- **预期**: `b_detected` 置位（对时序敏感，未触发不强制 FAIL）

### case_short_bit_j — 短 bit data=1/J

- CRC5 bit 2（data=1/J, bit 29）缩短到 3-cycle → 其后 K 翻转沿比标称早 1 ref_clk
- **因果链自检（§自检机制 6）**：右环第 3 态 6 遇提前 K 沿（b=0）→ `6→1` 跳过切环
  （跳 4/5），该位恢复时钟压到 3 ref_clk；判据 `6→1` 跳过恰 1 次、`2→5` 跳过 0 次、
  3-ref_clk 周期恰 1 个、无 `<3` 过短周期、不失锁
- **预期**: CDR 不失锁且频率自适应正确（实测 6→1×1 / 2→5×0 / 3-ref_clk×1 / 44 沿 0 过短）

### case_short_bit_k — 短 bit data=0/K（J 的镜像）

- CRC5 bit 3（data=0/K, bit 30）缩短到 3-cycle → K 段缩短，段末回 J 沿比标称早 1 ref_clk
- **因果链自检（§自检机制 6）**：左环第 3 态 2 遇提前 J 沿（b=1）→ `2→5` 跳过切环
  （跳 0/1），该位恢复时钟压到 3 ref_clk；判据 `2→5` 跳过恰 1 次、`6→1` 跳过 0 次、
  3-ref_clk 周期恰 1 个、无 `<3` 过短周期、不失锁
- **预期**: 与 J 方向完全镜像（实测 2→5×1 / 6→1×0 / 3-ref_clk×1 / 44 沿 0 过短）

### case_se0 — SE0/EOP 处理

- 先发 OUT Token 正常锁存
- 注入额外 SE0 (DP=0, DN=0) 2 bit-time
- 回到 idle J 后再发 OUT Token
- **预期**: CDR 在 SE0 后能重新锁存

### case_random — 随机激励

- 6-bit LFSR (x⁶+x⁵+1) 生成 64 bit 伪随机数据
- 每个 bit 宽度随机 3/4/5 cycle
- 先发 SYNC 建立锁存，再发随机序列
- **预期**: CDR 全程保持锁存

### case_multi_pkt — 多包事务

- 发送一次 SETUP 控制传输：SETUP token + DATA0(8B, 含 0x7F 触发位填充) + ACK
- 验证 CDR 在包间 EOP + idle J 间隔后仍持续恢复
- **自检**: `dclk` 126 沿（预期 ≈124）、0 坏周期；`rx_bit` 最大连续滞后 ≤6 ref_clk
- **预期**: locked 恒 1，时钟周期全正常

### case_loopback — 端到端回环（最严格）

- 发送端 `bit_task` 记录实际数据位（含 stuffed bit）到 `exp_tx_q`
- 接收端在 `posedge dclk` 采样 `rx_bit` 做 NRZI 解码还原到 `rx_q`
- CDR 相位对齐会吃掉 SYNC 开头 1~2 位，故用 SYNC 尾巴（≥4 个 0 + 1）对齐，从 PID 逐 bit 比
- **预期**: SETUP(24) + DATA0(90) + ACK(8) = 122 数据位 0 差异

### case_pkt_all — 全 9 类合法正常包回环

- 复用 case_loopback 的 `roundtrip_begin`/`roundtrip_check`，把覆盖推广到 USB1.1
  Full-Speed **全部 9 类合法正常包**：Token OUT/IN/SETUP/SOF + DATA0/DATA1 +
  Handshake ACK/NAK/STALL
- SOF 用 frame=0x7FF、DATA payload 含 0x7F/0xFF → 强制触发 stuffed 0，
  验证 CDR 把 stuffed bit 也原样还原（数据位数 > 逻辑位数，仍 0 差异）
- 首包（OUT，从复位锁存事件）额外跑 `causal_lock_check` 因果链断言（同 case_nominal）
- **预期**: 9/9 包逐 bit 一致（含 stuffed bit），全程不失锁

## 如何仿真

```bash
# 从项目根目录 — 默认不保存 VCD (快速)
make cdr

# 保存每个 case 的独立 VCD 波形文件
make cdr VCD=1

# 从 sim/cdr 子目录
make -C sim/cdr run            # 不保存 VCD
make -C sim/cdr run VCD=1      # 保存 VCD

# 单独跑一个 case
make -C sim/cdr build
vvp sim/cdr/cdr.vvp +case=cdr_case_nominal
vvp sim/cdr/cdr.vvp +case=cdr_case_random +vcd=my_test.vcd

# 跑所选仿真并直接打开波形软件 (wave_debugger) —— 自动 VCD=1 重编译 + 只跑所选
make -C sim/cdr debugwave                             # 交互菜单: 列 10 case 供选
make -C sim/cdr debugwave CASE=cdr_case_short_bit_k   # 直接指定 (可脚本化)

# 也可从仓库根目录: 先选模块(目前仅 cdr, 自动直通) 再弹 cdr 的 case 菜单
make debugwave
```

## VCD 控制

- `make cdr` (VCD=0，默认)：不生成 VCD 文件，仿真速度快，适合回归测试
- `make cdr VCD=1`：编译时加 `-DVCD_SAFE`，每个 case 生成独立 VCD 文件：

```
sim/cdr/cdr_case_nominal.vcd
sim/cdr/cdr_case_long_bit_f.vcd
sim/cdr/cdr_case_long_bit_b.vcd
sim/cdr/cdr_case_short_bit_j.vcd
sim/cdr/cdr_case_short_bit_k.vcd
sim/cdr/cdr_case_se0.vcd
sim/cdr/cdr_case_random.vcd
sim/cdr/cdr_case_multi_pkt.vcd
sim/cdr/cdr_case_loopback.vcd
sim/cdr/cdr_case_pkt_all.vcd
```

> **注意**: 切换 VCD 模式需要 `make clean` 重新编译（因为 `-DVCD_SAVE` 是编译期宏）。
> `make clean` **保留 `*.wvs`**（波形会话：信号列表 + 每信号进制/颜色）与 **`*.vcd`**
> （波形文件，跑仿真不删——用户 2026-09-07 定），只删 `.vvp`/`.log` 这些可再生编译产物；
> `.vcd` 由下一次 `VCD=1` 运行按 case 名覆盖刷新。

## 仿真产物

| 产物 | 说明 |
|------|------|
| `cdr.vvp` | 编译后的仿真可执行文件 |
| `sim.log` | 全 case 汇总日志 |
| `sim_cdr_case_*.log` | 每个 case 的独立日志 |
| `cdr_case_*.vcd` | 每个 case 的独立波形 (仅 VCD=1) |

## 依赖

- **RTL**: `../../src/phy/usb_rx_cdr.v`
- **仿真工具**: iverilog ≥ 12.0 + vvp (`-g2012`)
- **无外部依赖**，自检全部在 Verilog 内完成

## 参考模型

`sim/common/usb_pkt_tasks.vh` 中的 NRZI 编码 + 位填充逻辑，以及 `sim/common/crc5_ref.vh`
的 CRC5 计算即为参考模型：

- `bit_task(d, cyc)`: 数据位 → NRZI 编码 → 位填充 → DP/DN 驱动
- `byte_task`, `pid_task`, `out_packet_task`: 逐级包构建
- `crc5_tx(addr, endp)`: USB CRC5 (x⁵+x²+1, seed 0x1F, 取反输出)
