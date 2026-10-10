# gen_crc_gold.py — USB 1.1 CRC5 / CRC16 黄金向量生成器

## 功能描述

严格按照 USB 1.1 规范 §8.3.5 实现 CRC5 和 CRC16 的黄金向量（golden vectors）生成与验证。用于 RTL 仿真的 CRC 参考值比对和测试向量生成。

**核心能力**：
- 按 USB 规范实现逐位 CRC 移位寄存器算法
- 生成 CRC5 Token（ADDR + ENDP）的 CRC 发送值
- 生成 CRC16 Data 的 CRC 发送值
- 验证残差（residual）是否匹配规范值（CRC5: `0x0C`, CRC16: `0x800D`）
- 作为 Python 库或独立运行自检

**USB 1.1 CRC 规范参数**：

| 参数 | CRC5 | CRC16 |
|------|------|-------|
| 多项式 | x⁵+x²+1 (0x05) | x¹⁶+x¹⁵+x²+1 (0x8005) |
| 种子 | 0x1F (全 1) | 0xFFFF (全 1) |
| 数据序 | LSB first | LSB first (per byte) |
| CRC 发送序 | MSB first | MSB first |
| 发送前 | 取反 (~) | 取反 (~) |
| 残差 | 0x0C | 0x800D |

## 使用方法

### 作为 Python 库使用

```python
from gen_crc_gold import crc5_token, crc5_residual, crc16_data, crc16_residual

# CRC5: 计算 addr=5, endp=0 的 Token CRC
crc5_val = crc5_token(addr=5, endp=0)
# -> 0x0C（示例值，取反后发送）

# 验证 CRC5 残差
res = crc5_residual(addr=5, endp=0)
assert res == 0x0C, "CRC5 残差不匹配!"

# CRC16: 计算数据包的 CRC
payload = bytes([0x80, 0, 0, 0, 0, 0, 0, 0])
crc16_val = crc16_data(payload)

# 验证 CRC16 残差
res = crc16_residual(payload)
assert res == 0x800D, "CRC16 残差不匹配!"
```

### 命令行自检

```bash
python3 tools/gen_crc_gold.py
# 输出: 多组 CRC5/CRC16 测试向量的 token + residual
# 全部向量通过残差校验后打印 "ALL GOLD VECTORS VERIFIED"
```

### API

| 函数 | 说明 |
|------|------|
| `crc_step(crc, width, poly, d)` | 单步 CRC 移位寄存器计算 |
| `crc_run(width, poly, bits)` | 对位流计算 CRC（不取反） |
| `crc5_token(addr, endp)` | 计算 Token 包的 CRC5 发送值（已取反），addr 7bit + endp 4bit |
| `crc5_residual(addr, endp)` | 计算包含 CRC 位的完整残差（应等于 0x0C） |
| `crc16_data(payload)` | 计算 Data 包的 CRC16 发送值（已取反），payload 为 bytes |
| `crc16_residual(payload)` | 计算包含 CRC 位的完整残差（应等于 0x800D） |

## 输入/输出

- **输入**：addr (0–127), endp (0–15), payload (bytes)
- **输出**：CRC 发送值（hex）、残差验证结果

## 依赖

- 纯 Python 标准库，无外部依赖

## 被调用方

- RTL 仿真验证脚本（CRC 参考值比对）
- USB Packet 生成器（提供标准 CRC 值）
