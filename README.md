# APB USB 1.1 Device Controller

USB 1.1 **Device**（从设备）控制器 RTL，通过 APB 总线接入 SoC。

## 特性
- USB 1.1 Full-Speed（12 Mbit/s）设备控制器
- APB 从接口：12-bit 地址 / 32-bit 数据
- PHY 接入：内部数字收发器，直接采集模拟 PHY 的 DP/DN 差分线
- 端点：EP0（控制）+ EP1 + EP2，各 64B FIFO
- 三时钟域：`ref_clk`(48MHz/4×) 给收发器，`clk12m`(12MHz/1×，恢复+发送) 给 SIE，`pclk` 给核心逻辑；仅 SIE↔FIFO 一处异步 CDC（四相握手，无 FIFO）

## 目录结构

```
src/                   RTL 源码
  inc/usb_const.vh     全局常量（PID/寄存器地址/时钟参数）
  common/              公共原语（CRC5/CRC16/NRZI/位填充）✅
  phy/                 数字收发器（DP/DN ⇄ 字节流）：CDR/RX 反序列化/时钟切换 ✅ CDR 完成
  sie/                 串行接口引擎 + CDC 桥（usb_sie / usb_sie_cdc）   TODO
  ep/                  端点 FIFO                          TODO
  apb/                 APB 从接口 + 寄存器文件            TODO
sim/                   模块级仿真（每个模块独立目录）
  common/              共享参考模型 + USB 包激励任务
  crc5/ crc16/ nrzi/ bitstuff/ cdr/   各模块 testbench + case
doc/                   设计报告（分章节 .md + .docx 导出）
  fig/                 状态机图 / 框图
docs/                  参考文档（Intel SIE 论文、USB 1.1 规范 PDF）
tools/                 Python 工具（CRC 黄金向量、FSM 图、VCD 调试）
```

> `sim/common/` 放所有模块共享的纯 Verilog 参考模型（`*_ref.vh`）和 USB 数据包
> 激励任务（`usb_pkt_tasks.vh`），testbench 内计算期望值，避免硬编码黄金向量。

## 仿真

```bash
make                 # 编译并运行全部测试
make crc5            # 运行单个模块（crc5/crc16/nrzi/bitstuff/cdr）
make cdr VCD=1       # CDR 每 case 单独保存 VCD 波形
make debugwave       # 选模块→弹出该模块现有 case 名供选→出 VCD→直接开 wave_debugger
                     # (直选: make debugwave MOD=cdr CASE=cdr_case_short_bit_k; 菜单规范见 sim/common/README.md)
make clean           # 清仿真产物 (保留 *.wvs 波形会话与 *.vcd 波形, 跑仿真不删 vcd)
```

波形查看一律用 `tools/wave_debugger.py`（GUI）或 `tools/render_waveform.py`（离屏渲染 PNG），
不用 GTKWave。

工具链：Icarus Verilog（iverilog/vvp，`-g2012`）。
