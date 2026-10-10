# sim/sie — usb_sie 单元测试

被测：`src/sie/usb_sie.v`（事务层，只做接收）及其三个子模块
`src/sie/usb_sie_pkt_rx.v`（包级解析）、`src/common/usb_crc5_byte.v` /
`src/common/usb_crc16_byte.v`（字节并行 CRC）。
设计报告：`doc/design_rpt/usb_sie_design.md`；验证报告：`doc/design_rpt/usb_sie_verification.md`。

**输入契约是字节级**（`rx_data`/`rx_valid`/`rx_active`/`rx_error`）= `usb_rx_deserial`
的输出，本仿真不接 CDR/deserial —— 位级链路已在 `sim/cdr`、`sim/deserial` 验过。

## 跑法

```bash
make -C sim/sie run               # 12 用例全跑
make -C sim/sie build             # 只编译
make -C sim/sie clean             # 清 .vvp/.log（保留 .vcd）

# 根入口
make sie                          # 等价于 make -C sim/sie run（已进 MODULES）
make cov     MOD=sie              # Verilator 覆盖率 + 事务态矩阵（12 用例合并）
make covclean MOD=sie             # 删 cov/
make -C sim/sie fsmcov            # 只跑事务态那一维（根 Makefile 无此入口）
make debugwave MOD=sie CASE=sie_datawait   # 出 VCD + 打开 wave_debugger
```

Verilator lint（改 RTL 后先过一遍，在仓库根跑，四个源文件缺一不可）：
`verilator --lint-only -Wall -Wno-fatal -Isrc/inc -Isrc/common src/sie/usb_sie.v`
`src/sie/usb_sie_pkt_rx.v src/common/usb_crc5_byte.v src/common/usb_crc16_byte.v`。

## 用例

| 用例 | 考什么 |
|---|---|
| `sie_token` | token/SOF 字段解析、CRC5 残差、坏 CRC5 不派发、帧号两端、孤立 token 周转超时 |
| `sie_data_len` | 数据包长度谱 0/1/64/8 字节；净荷与 CRC16 延迟线对齐、指针回卷 |
| `sie_bad_pkt` | 五种坏法（坏 CRC16/PID/非数据类包/`rx_error`/截断）一律不成事务 |
| `sie_resp_prio` | 应答真值表与六级优先级，逐级验「压过」 |
| `sie_setup` | SETUP 特例分支：不查 halt/忙/序列，好包 + DATA0 + EP0 才无条件 ACK |
| `sie_toggle` | 序列翻转/去重不翻/重发恢复/CPU 写初值/端点互不干扰 |
| `sie_datawait` | 数据阶段收尾与打断：周转超时、新 token 重新武装 |
| `sie_oversize` | 长度护栏 `rx_abort`：越端点净荷上限即中止，且必须随 `rx_active` 落干净 |
| `sie_addr_stray` | 地址失配/端点越界/杂散数据包/杂散握手包静默；地址同步链 |
| `sie_buf_isolate` | 包缓冲流控（未排空 → NAK）与坏包隔离（不落地、不污染下一包） |
| `sie_ctl_rst` | `rcv` 策略、`connect_evt` 附着、`usb_rst` 清哪些状态、复位后即刻可用 |
| `sie_tail_tight` | 三项时序量同时收到物理下限（8 拍/字节、尾 gap 0、空闲 gap 2） |

每条用例的判据都写在文件头（因 → 变 → 果 + 前后文窗口 + 量化判据），见
`sim/common/README.md` 的仿真规范。

## 监视口径

- **应答**：`resp_req` 拍采 `resp_pid` 进 `resp_q[]` 队列，用例按序核对（`resp_chk_one` /
  `resp_chk_none`），不看内部译码中间量。
- **事件**：`ep_rx_done`/`setup_recv`/`sof_recv`/`ep_rx_bad`/`rx_abort` 各计数。
- **缓冲**：净荷对不对**不由内部信号自证** —— 一律经 `buf_rd_en` 读口逐字节排出记进
  `drain_rec[]`，与将来 CDC 桥的读法同口径。写指针有没有错位、坏包有没有污染下一包，
  都靠这条查。
- **白盒**：事务态 `t_state_cur`、`turn_cnt`、`toggle`、缓冲指针只读不驱动，用来核
  「有没有进数据阶段」（看 `T_DATA_WAIT` 停留拍数）与超时计数口径。

## 激励的口径（`sie_tasks.vh`）

照 `usb_rx_deserial` 的输出行为建模：`rx_active` 一整包拉高、每字节 `rx_data` 稳定 +
`rx_valid` 单拍脉冲、字节间隔 8 拍。三个可调量（`byte_period`/`pkt_tail_gap`/
`pkt_idle_gap`）默认取常规值，`sie_tail_tight` 把它们同时压到下限。

两处最容易搞错的口径写在 `sie_tasks.vh` 文件头，改激励前先读：

1. `rx_active` 落之后**必须连续低 3 拍**，`pkt_rx` 才补得完两个 CRC 字节并出 `pkt_done`；
   少了这 3 拍这一包的结论就丢了。
2. 数据字段 LSB first，但 **CRC 字段 MSB first**。CRC5 的 byte2 低 3 位是 `endp`，
   不是 CRC —— 线序按文件头那张表喂，走完的残差才是 `0x0C`/`0x800D`。

## 覆盖率

```bash
make cov MOD=sie                       # 报数口径取 output 末尾的 Design Unit Coverage Summary
make -C sim/sie fsmcov                 # 事务态矩阵 (profile 见 tools/merge_fsm_cov.py)
```

`--report hier` 的每一行**含子实例**（`tb_sie.u_sie` 那行把 `u_pkt_rx` 与两个 CRC 的都算进去了），
逐模块看数得读 Design Unit Coverage Summary，别读全层级 summary。

12 用例合并后的 DUT 数字与未覆盖项逐条定性见
`doc/design_rpt/usb_sie_verification.md` 的覆盖率章节。事务态 `T_TX`/`T_HS_WAIT` 是发包轮的
编码预留态，本轮没有入口弧，已在 profile 里声明为结构不可达。
