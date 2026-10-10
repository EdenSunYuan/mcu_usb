# CRC16 模块仿真

## 模块简介

`usb_crc16` — USB 1.1 Data CRC16 校验器，多项式 x¹⁶+x¹⁵+x²+1 (0x8005)，种子 0xFFFF。

| 参数 | 值 |
|------|-----|
| 多项式 | x¹⁶ + x¹⁵ + x² + 1 (0x8005) |
| 种子 | 0xFFFF (全 1) |
| 数据序 | LSB first (per byte) |
| CRC 发送序 | MSB first |
| 发送前 | 取反 (~) |
| 残差 | 0x800D |

RTL 源码: `src/common/usb_crc16.v`

## 参考模型

`sim/common/crc16_ref.vh` — 纯 Verilog function 实现的 CRC16 参考模型，testbench 用它实时计算期望值，无需依赖外部 Python 工具。

## 测试用例

| Case 文件 | 测试目的 | 预期结果 |
|-----------|---------|---------|
| `case_data.v` | 不同长度 payload (5/8 byte)，不同数据模式 | 余数 + 残差全部匹配 |
| `case_boundary.v` | 边界条件 (最小 1byte、全 0xFF) | 边界值通过残差检查 |

## 如何仿真

```bash
# 从项目根目录
make crc16

# 或进入子目录
make -C sim/crc16 run
```

## 验证方法

每个 test case 采用自检机制:
1. 参考模型计算期望余数 → 喂入 payload → 检查 `crc_out` 匹配
2. 参考模型计算发送 CRC → 喂入 → 检查残差 = 0x800D
3. 不匹配时 `$display("FAIL: ...")` → errors++
4. 全部通过 → `$finish(0)`; 有错误 → `$fatal(1)`
