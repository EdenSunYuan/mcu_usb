# Bit-Stuffing 模块仿真

## 模块简介

USB 1.1 位填充/解填充器 (USB 1.1 §7.1.9)。

| 模块 | 功能 |
|------|------|
| `usb_bit_stuff` | 数据流中每连续 6 个 data=1 后插入一个 stuffed 0 |
| `usb_bit_unstuff` | 检测 6 个连续 1 后丢弃紧跟的 stuffed 0 |

RTL 源码: `src/common/usb_bit_stuff.v`, `src/common/usb_bit_unstuff.v`

## 参考模型

`sim/common/bitstuff_ref.vh` — 纯 Verilog function 实现的填充规则：
- `stuff_check(cnt, d)`: 预测是否需要插入 stuffed 0
- `stuff_next_cnt(cnt, d)`: 更新连续 1 计数

## 测试用例

| Case 文件 | 测试目的 | 预期结果 |
|-----------|---------|---------|
| `case_stuff_golden.v` | 5 组已知输入模式的填充输出 | 输出位宽和位值匹配 |
| `case_roundtrip.v` | stuff→unstuff 回环, 5 组输入 | 恢复数据 = 输入 |

## 如何仿真

```bash
make bitstuff
# 或
make -C sim/bitstuff run
```
