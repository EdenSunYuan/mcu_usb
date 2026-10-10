# NRZI 模块仿真

## 模块简介

USB 1.1 NRZI (Non-Return to Zero Inverted) 编解码器。

| 模块 | 功能 |
|------|------|
| `usb_nrzi_enc` | 数据位 → NRZI 电平编码 (data=0 翻转, data=1 保持) |
| `usb_nrzi_dec` | NRZI 电平 → 数据位解码 (电平变→0, 电平不变→1) |

RTL 源码: `src/common/usb_nrzi_enc.v`, `src/common/usb_nrzi_dec.v`

## 参考模型

`sim/common/nrzi_ref.vh` — 纯 Verilog function 实现的 NRZI 编解码规则，testbench 用它实时计算期望值。

## 测试用例

| Case 文件 | 测试目的 | 预期结果 |
|-----------|---------|---------|
| `case_enc_golden.v` | 编码器: SYNC+PID 序列逐 bit 编码 | 编码输出与参考模型一致 |
| `case_dec_golden.v` | 解码器: 已知电平序列逐 bit 解码 | 解码输出与参考模型一致 |
| `case_roundtrip.v` | enc→dec 回环: 16-bit 随机序列 | 解码输出 = 原始序列 |

## 如何仿真

```bash
make nrzi
# 或
make -C sim/nrzi run
```
