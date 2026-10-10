# 第一章 公共原语（Common Primitives）

## 1.1 模块介绍

本模块是 USB 1.1 控制器最底层的可复用元件，提供协议/链路层共用的基础运算单元。它们是上层两个模块的**公共依赖**：

- **CRC5 / CRC16**：由 SIE（串行接口引擎）用于数据包保护字段的错误检测/生成；
- **NRZI 编解码 / 位填充（解）填充**：由数字收发器（usb_dpll_phy）用于位级串行数据的物理编码。

所有原语均为 **bit-serial（逐位）** 处理、纯同步逻辑、可综合、无任何时序延迟语句，且不依赖 `usb_const.vh` 之外的任何模块。

## 1.2 模块内容

| 模块文件 | 功能 | 所属层次 |
|----------|------|----------|
| `usb_crc5.v` | TOKEN 包 ADDR+ENDP 字段的 5-bit CRC 生成/校验 | SIE 用 |
| `usb_crc16.v` | DATA 包数据字段的 16-bit CRC 生成/校验 | SIE 用 |
| `usb_nrzi_enc.v` | NRZI 编码（数据位→差分电平） | PHY 用 |
| `usb_nrzi_dec.v` | NRZI 解码（差分电平→数据位） | PHY 用 |
| `usb_bit_stuff.v` | 位填充：连续 6 个 1 后插入 0 | PHY 用 |
| `usb_bit_unstuff.v` | 位解填充：删除 stuffed 0 | PHY 用 |

## 1.3 模块划分及其模块图

📎 [打开模块图：公共原语框图（common_block.png）](fig/common_block.png)

划分原则：**CRC 在包级（SIE）、NRZI/位填充在位级（PHY）**。CRC 不放在 PHY，因为 PHY 不做包结构解析；位填充不放 SIE，因为它属于物理位流处理。

## 1.4 模块接口

### usb_crc5 / usb_crc16（统一接口，宽度 N=5/16）

| 端口 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| `clk` | in | 1 | 时钟 |
| `rstn` | in | 1 | 异步复位，低有效 |
| `crc_en` | in | 1 | 高=处理一个数据位 |
| `crc_clr` | in | 1 | 高=种子加载（全 1） |
| `d_in` | in | 1 | 输入数据位（线上序，LSb first） |
| `crc_out` | out | N | 当前余数（未取反） |

### usb_nrzi_enc

| 端口 | 方向 | 说明 |
|------|------|------|
| `clk`/`rstn` | in | 时钟/复位 |
| `nrzi_rst` | in | 高=复位到空闲 J 态 |
| `nrzi_en` | in | 高=处理一个数据位 |
| `d_in` | in | 数据位（0=翻转，1=保持） |
| `nrzi_out` | out | 编码后电平（1=J，0=K） |

### usb_nrzi_dec

| 端口 | 方向 | 说明 |
|------|------|------|
| `clk`/`rstn` | in | 时钟/复位 |
| `dec_en` | in | 高=采样一个电平 |
| `dec_rst` | in | 高=上一电平复位到 J |
| `nrzi_in` | in | 输入电平（差分） |
| `d_out` | out | 解码数据位（相同=1，翻转=0） |
| `last_level` | out | 上一采样电平 |

### usb_bit_stuff / usb_bit_unstuff（统一流式接口）

| 端口 | 方向 | 说明 |
|------|------|------|
| `clk`/`rstn` | in | 时钟/复位 |
| `d_in` | in | 输入数据位 |
| `d_valid` | in | 输入位有效（每 bit-slot 一拍） |
| `d_out` | out | 输出数据位 |
| `d_out_valid` | out | 输出位有效 |

## 1.5 设计关键点

1. **CRC 严格遵循 USB 1.1 规范 §8.3.5**：
   - 种子 = 全 1（CRC5=0x1F，CRC16=0xFFFF）；
   - 每数据位：`fb = crc[MSB]^d` → 左移一位低位补 0 → `if fb: crc ^= poly`（CRC5 poly=0x05，CRC16 poly=0x8005）；
   - 数据字段按线上序（LSb first）喂入；
   - **发送前 CRC 取反、MSB first 发送**（这是最容易漏的一点）；
   - 接收残差：CRC5=0x0C，CRC16=0x800D。
   - 黄金向量已用 Python 实现并对照规范残差验证（`tools/gen_crc_gold.py`）。

2. **CRC 选择 bit-serial 而非 byte-parallel**：TOKEN 的 ADDR+ENDP 共 11 bit，**不按字节对齐**（跨第 2/3 字节边界），bit-serial 最自然；FS 12Mbps 下 SIE ≥24MHz 性能充裕。

3. **位填充器采用「2 深 FIFO + 直通旁路」**：
   - 插入 stuffed 0 时输入位被推迟一拍，最坏需缓存 2 bit（推演证明深度 2 足够）；
   - 队列空且无插入时**直通**，避免启动气泡；
   - 连续 1 计数器统计**输出流**（含插入位），输出第 6 个 1 时置 `stuff_nxt`，下一拍输出 0。

4. **NRZI 初始态 = J（空闲）**：编码器 `nrzi_rst` 复位到 J=1；解码器 `dec_rst` 把上一电平复位到 J，与收到的第一个电平比较。

5. **位解填充的丢弃条件**：输入为 0 且连续 1 计数已达 6 → 该 0 为 stuffed bit，丢弃（`d_out_valid=0`），计数清零。

## 1.6 验证计划

| 验证点 | 方法 | 通过标准 |
|--------|------|----------|
| CRC5 余数 | 喂 ADDR+ENDP 11 bit 后比对未取反余数 | 与黄金向量一致 |
| CRC5 残差 | 再喂 5 bit 发送 CRC（MSB first） | 残差 == 0x0C |
| CRC16 余数/残差 | 同上，16 bit | 残差 == 0x800D |
| NRZI 编码 | 已知序列（SYNC+PID）逐位比对期望电平 | 电平序列与 Python 参考一致 |
| NRZI 解码 | 已知电平序列解码 | 还原原数据 |
| NRZI 回环 | enc→dec | 恢复原序列 |
| 位填充 | 5 组已知输入→期望填充输出 | 与 Python 参考一致 |
| 位解填充回环 | stuff→unstuff | 恢复原输入 |

**测试实现**：`tests/tb_crc5.v`、`tests/tb_crc16.v`、`tests/tb_nrzi.v`、`tests/tb_bitstuff.v`，iverilog 编译 + vvp 运行，Makefile 回归（`make`）。测试台遵守「激励在周期中部、`@(posedge clk)` 后 `#1` 采样」纪律规避竞态。

**仿真结果**：4 个 testbench 全部 PASS。

---

*本章对应源码：`src/common/*.v`，测试：`tests/tb_crc*.v`、`tests/tb_nrzi.v`、`tests/tb_bitstuff.v`*
