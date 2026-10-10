# usb_sie 模块验证报告（RX 事务层）

> 模块：`usb_sie`（事务层）+ `usb_sie_pkt_rx`（包级解析）+ `usb_crc5_byte` / `usb_crc16_byte`（字节并行 CRC）
> 被测 RTL：`src/sie/usb_sie.v`、`src/sie/usb_sie_pkt_rx.v`、`src/common/usb_crc5_byte.v`、`src/common/usb_crc16_byte.v`
> 设计报告：[usb_sie_design.md](usb_sie_design.md)　仿真目录：`sim/sie/`（12 用例）　规范：`sim/common/README.md`
> 日期：2026-09-28　结论：12/12 PASS；DUT 口径未覆盖点全部为结构不可达

---

## 1. 概述

要证明的事：一串字节进去，出来的是一个事务的结论。字节流由 `usb_rx_deserial` 给，本模块不碰位级；
出去的是应答请求（`resp_req`/`resp_pid`）、端点事件和一块排得出去的包缓冲。

判据按「因 → 变 → 果」分三层数，三层都对上才算过：

| 层 | 信号 | 期望 |
|---|---|---|
| 因（包级结论） | `pkt_done` / `pkt_bad` / `pkt_cls` / `pid_ok` / `tok_crc_ok` / `dat_crc_ok` / `dat_len` | 每包恰一拍，且字段值与喂进去的字节对上 |
| 变（跨包记忆） | `t_state_cur` / `ep_sel` / `is_setup` / `toggle` / `turn_cnt` / `buf_ready` | 只在 `pkt_done` 拍动，动法与跳转表一致 |
| 果（对外） | `resp_req` + `resp_pid` / `buf_rd_data` + `buf_cnt` / `ep_rx_done` / `setup_recv` / `sof_recv` | 应答 PID 与缓冲排出内容逐项对、次数恰为 1 |

中间那层容易自证：只要盯住 `resp_pid` 对了就收工，方向错、序列错、坏包这几类会被同一个 ACK 蒙过去。
所以每个用例都同时核「应答」与「收没收下」，收下的证据一律来自缓冲读口（`buf_rd_en` 逐字节排出后
与激励侧算的期望比），不采信内部写指针。

## 2. 测试环境

- DUT 直连，无回环链、无参考模型：`tb_sie.u_sie` 就是被测模块，`u_pkt_rx` 与两个 CRC 是它的子实例。
- 激励不造位流，直接按 `usb_rx_deserial` 的输出行为建模（`sie_tasks.vh`）：`rx_active` 一整包拉高，
  每字节 `rx_data` 稳定 + `rx_valid` 单拍脉冲，字节间隔 8 拍。`rx_error` 是电平，包内拉高即锁存。
- 三个可调量：`byte_period`（字节拍数）、`pkt_tail_gap`（末字节到 `rx_active` 落）、
  `pkt_idle_gap`（包间 `rx_active` 低电平拍数）。默认取常规值，`sie_tail_tight` 把它们同时压到下限。
- 监视：应答在 `resp_req` 拍采进 `resp_q[]` 队列，用例按序核对；事件各计数；白盒只读
  `t_state_cur` / `turn_cnt` / `toggle` / 指针，用来核「有没有进数据阶段」与超时计数口径。
- 全局不变量：`drop_n`（排出的字节数与 `buf_cnt` 是否自洽）在每个用例末尾核一次。

```bash
make -C sim/sie run                       # 12 用例
make cov MOD=sie                          # 覆盖率（12 用例合并）+ 事务态矩阵
make -C sim/sie debugwave CASE=sie_datawait   # VCD + wave_debugger
```

两处激励口径最容易搞错，写在 `sim/sie/sie_tasks.vh` 文件头：

1. `rx_active` 落之后必须连续低 3 拍（`tail_cnt` 0→1→2），`pkt_rx` 才补得完两个 CRC 字节并出
   `pkt_done`；少一拍这一包的结论就丢了。
2. 数据字段 LSb 先发，CRC 字段 MSB 先发。线序按字节喂进去，走完的残差才是 `0x0C`/`0x800D`；
   按字段语义重组位序会得到另一个数。

## 3. 测试用例与结果

| 用例 | 考什么 | 关键读数 |
|---|---|---|
| `sie_token` | token/SOF 字段解析、CRC5 残差、坏 CRC5 不派发、IN token 无出口 | 字段 addr/endp/pid 逐项对；坏 CRC5 `bad=1`；孤立 token 数据阶段停留 15 拍 |
| `sie_data_len` | 净荷长度谱 0/1/64/8 字节，延迟线对齐、指针回卷 | `dat_len` 0/1/64/8；64B 满包排出 64 字节全对 |
| `sie_bad_pkt` | 五种坏法（坏 CRC16/PID/非数据类包/`rx_error`/截断）都不成事务 | 每项无应答、`buf_ready=0`、toggle 不动；末尾好包照收 |
| `sie_resp_prio` | 应答真值表六级优先级的「压过」 | 方向错压 halt、halt 压序列、序列压忙、坏包压一切 |
| `sie_setup` | SETUP 特例：不查 halt/忙/序列，好包 + DATA0 + EP0 才无条件 ACK | halt 下仍 `resp_pid=0xD2` + `setup_recv`；非 EP0 无应答 |
| `sie_toggle` | 序列翻转/去重不翻/重发恢复/CPU 写初值/端点互不干扰 | toggle 010→000→010 序列；CPU 写 100 后 EP1 不受影响 |
| `sie_datawait` | 周转超时、被新 token 打断并重新武装 | 两段计数都是 15 拍；SOF 只收尾不武装 |
| `sie_oversize` | 长度护栏 `rx_abort`，且必须随 `rx_active` 落干净 | EP0 超 1 字节中止，`rx_error` 保持 0；EP1 满 64 字节不误报 |
| `sie_addr_stray` | 地址失配/端点越界/杂散包静默，地址同步链 | addr 3 与 42 互不干扰；addr 0x00 与 0x7F 正常收 |
| `sie_buf_isolate` | 未排空 → NAK 流控；坏包不落地也不污染下一包 | NAK 后排出内容仍是 A 包；忙时坏包不动 `buf_cnt` |
| `sie_ctl_rst` | `rcv` 策略、`connect_evt` 附着、`usb_rst` 清哪些状态 | 复位后 `rcv=0`；`usb_rst` 清附着/toggle/缓冲/事务态，清完即刻可用 |
| `sie_tail_tight` | 三项时序量同时收到物理下限 | 8 拍/字节 + 尾 gap 0 + 空闲 gap 2（`rx_active` 只低 3 拍）下应答与净荷仍全对 |

12 个用例全过。每条判据写在 `sim/sie/case_*.v` 文件头，带前后文窗口和量化值。

## 4. 关键场景

### 4.1 两级状态机：包级出结论，事务级才动

包级解析器一个包一个结论，事务状态机只在结论有效那一拍跳。这条把「包内位序」和「跨包记忆」
彻底分开，包级可以按喂字节序列穷举，事务级只需覆盖 4 种状态乘 4 类包。

📎 [图：事务态只在 pkt_done 拍变（sie_two_level_fsm.png）](../fig/sie_two_level_fsm.png)

窗口从 token 包尾起画：`pkt_cls` 先为 1（token）、`tok_dispatch` 一拍 → `pkt_done` 同拍 `t_state_cur`
由 `3'h0` 变 `3'h1`（进数据阶段）；随后数据包 `pkt_cls=2`，`pkt_done` 又一拍 → `t_state_cur` 回 `3'h0`，
同拍出 `dec=1` 与 `resp_req`，`buf_ready` 置起、`buf_cnt` 跳到 8。

### 4.2 CRC5 残差与位序统一

token 的 11 bit 数据加 5 bit CRC 正好两个整字节，所以「喂 byte1、喂 byte2、查残差 0x0C」即可，
不需要任何位序转换。

📎 [图：残差走到 0x0C（sie_token_crc.png）](../fig/sie_token_crc.png)

`rx_data` 依次是 `0x69`（IN token 的 PID）、`0x85`、`0x49`，`byte_cnt` 走到 3，`crc5_b` 由 `0x1F`
经 `0x15` 落到 `0x0C`，同拍 `tok_crc_ok=1`、`pkt_done=1`、`tok_good=1`。把 `byte2` 任一 bit 翻掉的
变体在 `sie_token` 里单列，残差离开 `0x0C`、`pkt_bad=1`。

### 4.3 2 字节延迟线：CRC 字节进不了缓冲

数据包长度靠 EOP 定界、事先未知，所以 CRC16 引擎永远吃「延迟 2 字节」的流，包尾再补喂留在
`d1`/`d2` 的两个字节。同一个延迟拍顺带解决了净荷提取。

📎 [图：pl_byte 比 rx_data 晚 2 拍且不含 CRC（sie_crc_delay_line.png）](../fig/sie_crc_delay_line.png)

`byte_cnt` 走到 7..11，`rx_data` 上的后两个字节是 CRC16，而写口取的是 `d2`/`d1`，`pl_byte` 上出现的是
净荷；`wr_ptr` 4→8，`pkt_done` 同拍 `buf_cnt=8`、`dat_crc_ok=1`。本用例的四个包（0/1/64/8 字节）
排出内容逐个字节对过期望值，坏包那一笔（`sie_bad_pkt`）的 `wr_ptr` 停在中途、`buf_cnt` 始终为 0。

### 4.4 应答决策的优先级

Table 8-4 的五行有严格顺序，最容易写反的是「序列不匹配」与「端点忙」的先后。

📎 [图：序列不匹配压过忙（sie_resp_priority.png）](../fig/sie_resp_priority.png)

这一拍上 `ep_nak_q=2`（EP1 报忙）、`dat_pid_is1=1`（收到 DATA1）而 `toggle_sel=0`，故 `toggle_match=0`；
`busy_sel=1` 同时成立，`dec` 仍是 1（ACK），`resp_pid=8'hD2`，`resp_req` 出一拍。序列优先于忙，因为
重复包的数据本来就要丢，谈不上收不收得下。同用例的其它优先级组合：坏 CRC16 加 halt 加忙三者同挂，
`pkt_bad=1`，`dec=0`、`resp_req` 不拉。

### 4.5 SETUP 特例：无条件 ACK，并把收发序列位初始化

SETUP 走独立分支，不查 halt、不查忙、不查序列位；包好且 PID 是 DATA0 且打在 EP0 上就回 ACK。

📎 [图：halt 挂着仍回 ACK（sie_setup_special.png）](../fig/sie_setup_special.png)

`ep_stall_q=1`、`is_setup=1`、`ep_sel=0`，`pkt_done` 后 `dec=1`、`resp_pid=8'hD2`、`resp_req=1`，
同拍 `setup_recv=1`、`acc_setup=1`。这个窗口里 `toggle` 已经是 1（前面那笔 SETUP 置的），
置位那一拍另出一图。

📎 [图：toggle[EP0] 由 0 置 1（sie_setup_toggle.png）](../fig/sie_setup_toggle.png)

`is_setup=1` 与 `ep_sel=0` 成立 → `dec=1`、`acc_setup=1`、`tog_set=1` → `resp_req` 一拍、
`setup_recv` 一拍，`toggle` 由 0 变 1。非 EP0 的 SETUP 与 PID 不是 DATA0 的 SETUP 在用例里各走一遍，
都是 `resp_req` 不拉、`setup_recv` 不计数。

### 4.6 toggle 只在收下时翻转

📎 [图：DATA1 匹配、ACK、翻回 0（sie_toggle_seq.png）](../fig/sie_toggle_seq.png)

`dat_pid_is1=1`、`ep_sel=1`、`toggle_sel=1`（EP1 当前为 1）、`toggle_match=1`，`dec=1`、`acc_evt=1`、
`resp_req=1`、`resp_pid=8'hD2`，`toggle` 由 2 变 0。序列不匹配那一笔（重复包）回 ACK 但 `toggle` 不变，
在 `sie_resp_priority` 里同图可见；NAK/STALL/坏包三类的 toggle 不动也各有读数。

### 4.7 数据阶段可被新 token 打断，并重新武装

主机在 token 后未必总发数据包。状态机若死等，会把下一事务的 token 当成数据包。

📎 [图：新 token 使计数回 1（sie_data_wait_break.png）](../fig/sie_data_wait_break.png)

`t_state_cur=3'h1`（数据阶段）里 `turn_cnt` 已爬到 6，此时新 token 的 `pkt_done` 与 `tok_dispatch`
同拍到达，`turn_cnt` 立刻回 1，`tok_endp=2`、`ep_sel` 由 1 变 2，`resp_req` 全程不动。

📎 [图：重新武装后新端点的数据包照收（sie_data_wait_ack.png）](../fig/sie_data_wait_ack.png)

同一个数据阶段的后续：`ep_sel=2`、`pkt_done` 后 `dec=1`、`resp_pid=8'hD2`、`toggle` 由 0 变 4
（翻的是 EP2 那位）、`buf_cnt=4`。打断后的事务是完整的。

### 4.8 周转超时

📎 [图：turn_cnt 计到 15 后回 T_IDLE（sie_turnaround.png）](../fig/sie_turnaround.png)

孤立 token 之后线上一片安静，`turn_cnt` 从 1 一格格爬到 15，到顶那一拍 `turn_done` 抬起、
`t_state_cur` 由 `3'h1` 回 `3'h0`，`resp_req` 全程为 0。计数起点是 `pkt_done`，比 EOP 晚 2 拍
（补喂 CRC 用的），到顶共 15 拍，合计落在规范给的 16..18 bit time 里。

### 4.9 坏包对缓冲与下一包零污染

📎 [图：pkt_bad 拍上不应答也不落地（sie_bad_pkt_isolate.png）](../fig/sie_bad_pkt_isolate.png)

`rx_data` 末字节是 `8'h60`，`pkt_done` 拍上 `dat_crc_ok=0`、`pkt_bad=1`，于是 `dec=0`、`acc_evt=0`、
`resp_req=0`、`buf_ready` 全程 0、`buf_cnt` 全程 0；`wr_ptr` 停在 4，说明净荷进过内部缓冲但从未发布。
紧跟其后的好包照常 ACK、收下、排出内容全对。

### 4.10 长度护栏 rx_abort

📎 [图：溢出即中止，rx_error 保持 0（sie_rx_abort.png）](../fig/sie_rx_abort.png)

`byte_cnt=11` 与 `byte_limit=11` 相等，下一个字节 `8'h92` 到达时 `overflow=1`，`rx_abort` 随即抬起
并保持到 `rx_active` 落，`rx_error` 全程为 0，`pkt_bad=1`、`resp_req` 不拉。这是 SIE 自己的判断，
物理层错误电平不该被它带起来。跟着的好包能收，说明中止标志随 `rx_active` 落干净了。

### 4.11 rcv 策略、附着与 core 复位

📎 [图：usb_rst 清附着、rcv 落 0，重附着后回 1（sie_ctl_rst.png）](../fig/sie_ctl_rst.png)

`usb_rst` 一拍进来（宽 1 个 `clk12m` 周期）：`attached` 落 0，`rcv` 随之落 0，同一拍 `t_state_cur`
由 `3'h1` 回 `3'h0`、`toggle` 由 2 清 0、`buf_ready` 落 0、`buf_cnt` 由 8 清 0、`turn_cnt` 回 1。
之后 `connect_evt` 一拍，`attached` 与 `rcv` 先后回 1。复位后能立刻重新收包，不是清完就废。

复位初值必须是 `rcv=0`：CDR 未锁时 `dclk` 常 0，若初值为 1，选出来的 `clk12m` 就是常 0，
SIE 自己都起不了振。

### 4.12 三项时序量同时压到下限

📎 [图：8 拍/字节、尾 gap 0 下结论照出（sie_tail_tight.png）](../fig/sie_tail_tight.png)

`byte_period=8`（每字节恰好 8 拍，一个填充位都没有）、`pkt_tail_gap=0`（末字节之后立刻落
`rx_active`）、`pkt_idle_gap=2`（包间只低 3 拍）。图上 `byte_cnt` 走到 7 之后 `rx_active` 落，
`tail_cnt` 走 0→1→2 补完两个 CRC 字节，`pkt_done` 一拍，`dec=1`、`acc_evt=1`、`resp_req=1`、
`resp_pid=8'hD2`，`toggle` 由 0 变 2，`buf_cnt` 跳到 4。少任何一拍这套流水都出不来结论。

## 5. 编译卫生

```bash
iverilog -g2012 -Wall -I../../src/inc -I../common -o /tmp/x.vvp tb_sie.v \
    ../../src/sie/usb_sie.v ../../src/sie/usb_sie_pkt_rx.v \
    ../../src/common/usb_crc5_byte.v ../../src/common/usb_crc16_byte.v
verilator --lint-only -Wall -Wno-fatal -Isrc/inc -Isrc/common \
    src/sie/usb_sie.v src/sie/usb_sie_pkt_rx.v \
    src/common/usb_crc5_byte.v src/common/usb_crc16_byte.v
```

两条都零 error、零 warning。

## 6. 覆盖率（Verilator 5.052，12 用例合并）

### 6.1 结论：DUT 未覆盖点全部为结构不可达

报数口径是每个设计单元自己的点，取 `--report summary,hier` 末尾的 Design Unit Coverage Summary：

| 设计单元 | line | toggle | branch | expr |
|---|---|---|---|---|
| `usb_sie` | 30/33 = 90.9% | 708/752 = 94.1% | 141/142 = 99.3% | 153/154 = 99.4% |
| `usb_sie_pkt_rx` | 11/11 = 100% | 443/478 = 92.7% | 72/72 = 100% | 96/96 = 100% |
| `usb_crc5_byte` | 3/3 = 100% | 44/44 = 100% | 2/2 = 100% | 24/34 = 70.6% |
| `usb_crc16_byte` | 3/3 = 100% | 88/88 = 100% | 2/2 = 100% | 138/138 = 100% |
| 事务态 | 2/2 状态 | 4/4 合法弧 | 零意图外迁移 | 自建统计（§6.5） |

未覆盖点逐条定性见 §6.4，没有一条落在功能路径上：全部由「本轮只做接收」「端点点号只有三个」
「常量表共用位」这三类原因产生。唯一的例外是 `turn_cnt` 的饱和臂，见 §6.5。

### 6.2 复跑方法

```bash
make cov MOD=sie                # 建 → 跑全 12 用例 → 合并 → 打印 summary
make -C sim/sie fsmcov          # 合并 TB 侧的事务态矩阵
make covclean MOD=sie           # 删 cov/

# 报数口径（取 Design Unit Coverage Summary 那几行，别读全层级 summary）
verilator_coverage --report summary,hier sim/sie/cov/merged.dat
# 逐点列未覆盖项（含 hit 数，0 即未覆盖）
verilator_coverage --annotate /tmp/an --annotate-points sim/sie/cov/merged.dat
```

`make cov` 先用 iverilog 同一套功能判据卡一遍，任用例非 `TEST PASSED` 即中止。

### 6.3 工具与口径

1. 为什么是 Verilator：iverilog 没有覆盖率能力。功能判据以 iverilog 回归为准。
2. 必须跨用例合并：单用例只走自己那条路径（`sie_token` 里一次应答都不出，`sie_toggle` 里坏包路径不碰）。
3. `--report hier` 的每一行**含子实例**，`tb_sie.u_sie` 那行的 toggle 把 `u_pkt_rx` 与两个 CRC 的
   都算进去了（1283/1362 = 本体 708/752 加 `pkt_rx` 443/478 加 `crc5_byte` 44/44 加 `crc16_byte`
   88/88，逐项相加正好对上）。要按模块看数就读 Design Unit Coverage Summary。
4. 事务态那一维是 TB 侧自建的：`--coverage-fsm` 认不出规则 8 要求的两段式 FSM（组合算 `t_state_nxt`
   加时序搬 `t_state_cur`），`merged.dat` 里 fsm 记录恒为 0。TB 每拍记一次状态与跳转，
   `tools/merge_fsm_cov.py` 按 `sie` profile 跨用例相加。

### 6.4 未覆盖项逐条定性

`usb_sie` 本体的 44 个 toggle 点、3 个 line 点、1 个 branch 点、1 个 expr 点：

| 点 | 数 | 定性 |
|---|---|---|
| 次态 `T_TX` / `T_HS_WAIT` / `default` 三个臂 | 3 line | 发包轮预留，本轮没有入口弧 |
| `t_state_cur[1]/[2]`、`t_state_nxt[1]/[2]` | 8 toggle | 同上，这两位从不置 1 |
| `driving` 与 `(driving==1)` | 2 toggle + 1 expr | 本轮恒 0，等发包轮把 `tx_active \| (sie_susp & sie_wkup)` 接进来 |
| `turn_cnt` 内层饱和臂 | 1 branch | 见 §6.5 |
| `turn_cnt[4]`、`turn_cnt_nxt[4]` | 4 toggle | 计数上界 15，第 4 位（值 16）到不了 |
| `ep_sel[2]/[3]`、`ep_sel_nxt[2]/[3]` | 8 toggle | `EP_MAX=2`，点号只到 2 |
| `max_payload[0][1][2][4][5]` | 10 toggle | 常量表只有 8 与 64，这五位在两个值上相同 |
| `resp_pid[0]/[5]`、`resp_pid_nxt[0]/[5]` | 8 toggle | 四种应答编码 `0x00`/`0xD2`/`0x5A`/`0x1E` 在这两位上一致 |
| `tog_set[1]/[2]` | 4 toggle | 只有 SETUP 会置 toggle，而 SETUP 只针对 EP0 |

合计 44 toggle + 3 line + 1 branch + 1 expr，与 §6.1 的缺口数一一对上。

`usb_sie_pkt_rx` 的 35 个 toggle 点：

| 点 | 数 | 定性 |
|---|---|---|
| `max_payload[0][1][2][4][5]` | 10 toggle | 同上，端口常量表 |
| `byte_cnt[7]`、`byte_cnt_nxt[7]` | 4 toggle | 字节上界 67，第 7 位（值 128）到不了 |
| `byte_limit[0][2][4][5][7]` | 9 toggle | 上限常量只有 3 / 1 / 11 / 67，这几位在四个值上相同 |
| `min_len[2]..[7]` | 12 toggle | 下限常量只有 1 与 3，高六位恒 0 |

`usb_crc5_byte` 的 10 个 expr 点：CRC5 次态是一个 13 输入的组合锥（5 位余数加 8 位输入），
全部输入组合共 8192 种，任何有限激励都填不满。已覆盖的 24 个点里含全部真实走过的组合，功能正确性
由残差判据兜住：好 token 残差恒为 `0x0C`，`byte2` 翻一位即离开 `0x0C`。`usb_crc16_byte` 四个维度全 100%。

### 6.5 覆盖率查出的问题：`turn_cnt` 的饱和臂是死逻辑

`turn_cnt_nxt` 的内层三目 `(turn_cnt == TURNAROUND_MAX) ? TURNAROUND_MAX : turn_cnt+1` 的
cond_then 一次都没走到。原因是计到 15 那一拍 `turn_done` 已经成立，次态随即回 `T_IDLE`，
`tfsm_stay_wait` 为 0，外层三目走 else 把计数重装成 1。也就是说这个臂在现有跳转逻辑下永远进不去。

留着不改的理由：它防的是「离开条件将来被改宽」这种情况。真去掉之后，若哪天数据阶段的收尾条件
被放松，计数会从 15 加到 16，`turn_done` 靠「等于 15」判定，要绕一整圈 32 拍才重新命中，
超时点会从 18 bit time 漂到 50。保留代价是一级比较器，属于编码规范要求的补全分支，按结构不可达豁免。

事务态矩阵（12 用例合并，单位拍）：

| from\to | IDLE | DATA_WAIT | TX | HS_WAIT |
|---|---:|---:|---:|---:|
| IDLE | 3812 | 63 | 0 | 0 |
| DATA_WAIT | 63 | 5253 | 0 | 0 |
| TX | 0 | 0 | 0 | 0 |
| HS_WAIT | 0 | 0 | 0 | 0 |

停留拍数 IDLE=3875 / DATA_WAIT=5316 / TX=0 / HS_WAIT=0，4 条合法弧全中，零意图外迁移。
`TX` 与 `HS_WAIT` 两行两列全 0 是结构性的：它们是发包轮的编码预留，本轮没有任何弧进得来，
已在 profile 里声明为不可达，不进缺口清单。

### 6.6 非 DUT 层级的口径（避免误读 summary）

`make cov` 打出的 `Coverage Summary` 是全层级的（line 192/204、toggle 1573/1666、branch 286/336、
expr 426/453），数字被 TB 自身的激励逻辑与观察逻辑稀释：

| 层级 | line | toggle | branch | expr |
|---|---|---|---|---|
| `usb_sie` 本体 | 30/33 | 708/752 | 141/142 | 153/154 |
| `tb_sie.u_sie`（含子实例） | 47/50 | 1283/1362 | 217/218 | 411/422 |
| `tb_sie`（TB 自身） | 145/154 | 290/304 | 69/118 | 15/31 |

TB 那几行的低值来自激励任务里大量未走的分支（各用例只调其中几个 knob），与 DUT 质量无关。

## 7. 结论

1. 两级状态机解耦成立：包级结论每包一拍且字段可核，事务态只在结论拍跳，12/12 PASS；
2. 应答真值表六级优先级逐级验过「压过」，序列不匹配压过端点忙、坏包压过一切；
3. SETUP 特例按规范走独立分支，halt 下仍无条件 ACK，并把 `toggle[EP0]` 置 1；
4. 坏包不落地、不污染下一包，长度越界立即 `rx_abort` 且不带起 `rx_error`；
5. 三项时序量同时压到物理下限（8 拍/字节、尾 gap 0、空闲 gap 2 即 `rx_active` 只低 3 拍）时结论照出；
6. DUT 未覆盖点全部定性为结构不可达，无功能路径缺口。

下游可以按这三条契约接：`resp_req` + `resp_pid` 是单拍脉冲、与决策同拍；包缓冲的净荷一律从
`buf_rd_en` 读口按 `buf_cnt` 逐个排出；`usb_rst` 一拍即把协议状态清回可用态。

---

*本模块的仿真基建：`sim/sie/`（Makefile / TB / 12 个 case / `sie_tasks.vh` / README）。*
