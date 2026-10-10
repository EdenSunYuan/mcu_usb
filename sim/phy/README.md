# sim/phy — usb_dpll_phy 顶层集成测试

被测：`src/phy/usb_dpll_phy.v`。它是**纯连线**，把下面五个子模块接成一个数字收发器：

| 子模块 | 源文件 |
|---|---|
| CDR | `src/phy/usb_rx_cdr.v` |
| 时钟切换 | `src/phy/usb_clk_mux.v` |
| RX 反序列化 | `src/phy/usb_rx_deserial.v` |
| TX 串行器 | `src/phy/usb_tx_serial.v` |
| 总线状态检测 | `src/phy/usb_bus_state.v` |

设计报告：`doc/design_rpt/phy_design.md`；验证报告：`doc/design_rpt/phy_verification.md`。

六个源文件必须一起编，但 TB 只例化顶层——子模块各自的单元测试不在这里，
见 `sim/cdr`、`sim/deserial`、`sim/tx`、`sim/clkmux`、`sim/busstate`。
本目录只管**接起来之后还对不对**：跨模块的接线、时钟 MUX 的方向、复位往哪分、
四个事件脉冲的宽度与次数、半双工互斥。

## 跑法

```bash
make -C sim/phy run                # 18 用例全跑
make -C sim/phy build              # 只编译
make -C sim/phy clean              # 清 .vvp/.log（保留 .vcd/.wvs）

# 根入口
make phy                           # 等价于 make -C sim/phy run（已进 MODULES）
make cov MOD=phy                   # Verilator 覆盖率（18 用例合并）
make covclean MOD=phy              # 删 cov/
make debugwave MOD=phy CASE=phy_rx_data    # 出 VCD + 打开 wave_debugger
```

Verilator lint（改 RTL 后先过一遍，在仓库根跑）：

```bash
verilator --lint-only -Wall -Wno-fatal -Isrc/inc src/phy/usb_dpll_phy.v \
    src/phy/usb_rx_cdr.v src/phy/usb_clk_mux.v src/phy/usb_rx_deserial.v \
    src/phy/usb_tx_serial.v src/phy/usb_bus_state.v
```

## 用例

| 用例 | 考什么 |
|---|---|
| `phy_reset_default` | 冷启动：线是长 SE0，`rcv` 初值 0、`clk12m` 起振、四个事件一个不报 |
| `phy_connect` | 插入：SE0→J，一次 `connect_evt`，时钟源 clk12s→dclk |
| `phy_suspend` | 挂起：连接后空闲 J 满 3ms |
| `phy_resume` | 被动唤醒：挂起中主机驱 K ≥2.5µs |
| `phy_bus_rst` | 总线复位：长 SE0 → `usb_bus_rst`，出去并进 `usb_rst` 清附着 |
| `phy_unplug_susp` | 挂起中拔出：长 SE0 照样出复位且清挂起标志；插回重报 connect |
| `phy_rx_token` | 主机发 OUT token，整条链路字节级复现 |
| `phy_rx_data` | 连发 OUT token + DATA0，两帧字节流都逐字节对 |
| `phy_rx_hshake` | 单字节握手包（ACK/NAK/STALL）：EOP 紧跟 PID 关帧，1 字节帧不串包 |
| `phy_rx_maxlen` | 满长包：64 字节净荷（整帧 67 字节）逐字节对，压位填充最密处 |
| `phy_rx_bad` | 物理检错（截断包）冒得出来，字节不丢，且不跨帧残留 |
| `phy_rx_abort` | `rx_abort` 中途拉高：立刻收干净、不留后遗症 |
| `phy_rx_usb_rst` | 收包中途打软复位：`usb_rst` 从端口进得来、分得到两个子模块 |
| `phy_tx_line` | 发一包：握手、EOP 波形、自驱期间不误判总线事件 |
| `phy_tx_driving` | 挂起中违约发包：旁路把线压住，包发不出去、一个事件都不报 |
| `phy_tx_rx_turn` | 半双工往返：收 token → 发应答 → 收 DATA0，换向两次后链路还接得上 |
| `phy_susp_wkup` | 远程唤醒旁路：未挂起单拉 `sie_wkup` 不动线，挂起后 `sie_wkup` 驱 K |
| `phy_clk_switch` | 反复切换时钟源：换完还得是 12MHz，且不多出沿 |

每条用例的判据都写在文件头（因 → 变 → 果 + 前后文窗口 + 量化判据），见
`sim/common/README.md` 的仿真规范。

## 激励的口径（`tb_phy.v` + `phy_tasks.vh`）

- **总线**：`bus_dp = tx_en ? (tx_se0 ? 0 : tx_bit) : rxdp`，`bus_dn` 用 `~tx_bit`。
  `tx_en=1` 时设备驱动器赢；否则主机模型（`rxdp`/`rxdn` 两个 reg，`drive_dpdn` 写）给电平。
  `drive_dpdn(1)` = J，`drive_dpdn(0)` = K，两个都 0 = SE0。
- **`rcv`**：TB 照 `usb_sie_design.md` §1.3 建模 —— `sie_attached` 由 `connect_evt` 置、
  由 `usb_rst` 清，`rcv = sie_attached & ~(tx_active | (sie_susp & sie_wkup))`。
  PHY 不产生 `rcv`，所以它必须在 TB 里。
  TB 里的 `sie_susp` 是 SIE 自己那份挂起标志，**只**用来算 `rcv`，不进 DUT：
  DUT 的唤醒旁路读的是它自己 `bus_state` 判出的 `bus_suspended`（PHY 内部一根线，
  2026-09-29 起）。两者由用例按需拉开：`phy_clk_switch` 硬掰 `sie_susp` 来回切 `rcv`，
  `phy_susp_wkup` 段 0 单向拉 `sie_wkup` 证明未挂起时旁路不武装。
- **`usb_rst`**：`swrst | usb_bus_rst`，TB 扮的就是芯片顶层那个或门。PHY 自己不并。
- **期望字节**：token 的 byte2 低 3 位是 `endp`、CRC5 线上 MSB first；数据字段 LSB first 而
  CRC 字段 MSB first。算法在 `phy_tasks.vh` 的 `exp_token` / `exp_data` / `exp_hshake`，用例只比对。
  `sim/common/usb_pkt_tasks.vh` 的 data 任务净荷形参只有 8 个，满长包走本目录新增的
  `send_data_pay` + `crc16_pay`（逐字节喂 `crc16_feed_byte`，不限长度）+ `exp_data_n`；
  `crc16_pay` 与既有 `crc16_tx` 在 8 字节以内必须一致，`phy_rx_maxlen` 开头先比一次。
- **`$display` 的 tag 一律 ASCII**：字符串经宽向量形参传递按位截断，中文 UTF-8 续字节会被砍掉。

## 监视口径

- **事件**：四个脉冲各记次数与**最大宽度**（`clk12m` 拍）。宽度在 `chk_evt` 里查，
  查之前要等一拍——脉冲是子模块在 `clk12m` 沿上非阻塞拉起的，量宽的 `always` 块在同一沿读到的是旧值。
- **帧**：一段 `rx_active` 高电平记一条（字节数 + `rx_error`），**4 条历史环形缓冲**，
  用例按下标回看。只留最后一段会串帧——连发两包时前一包已经被后一包顶掉。
  每条历史留 128 字节（`FB_DEPTH`），够放满长包 67 字节。
- **`rcv` 换向**：`n_rcv_rise` / `n_rcv_fall` 在 `ref_clk` 域数沿，`phy_tx_rx_turn`
  用它判"收发各换一次向、不多不少"。
- **半双工**：`tx_active` 同时送 deserial，整个发送期间帧机被按在 idle，
  所以设备自己发的包不会被自己收下，`frame_cnt` 在那期间必须不动。
- **白盒**：`clk12m` 最小相宽、`se0_run_max`、`dclk`/`ref` 沿计数只读不驱动，
  用来核「时钟真的在 12MHz 上」与「EOP 的 SE0 只有两个位时间」。

## 覆盖率

```bash
make cov MOD=phy                    # 报数口径取输出末尾的 Design Unit Coverage Summary
```

本层的 DUT 行只有 `toggle` 一个维度（顶层没有表达式、没有分支、没有状态机），
18 用例合并后 92/92 = 100%；`fsmcov` 留空（子模块的 FSM 在各自 `sim/` 下验）。

`--report hier` 的每一行**含子实例**（`tb_phy.u_dut` 那行把五个子模块的都算进去了），
逐模块看数得读 Design Unit Coverage Summary。子模块经顶层这一遍的数字低于它们自己的单元测试
——整合 TB 的激励范围本来就窄，各模块的权威数字看各自的验证报告，逐条定性见
`doc/design_rpt/phy_verification.md` 的覆盖率章节。
