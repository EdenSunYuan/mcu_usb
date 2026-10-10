# CRC5 模块仿真

## 模块简介

`usb_crc5` — USB 1.1 Token CRC5 校验器，多项式 x⁵+x²+1 (0x05)，种子 0x1F。

| 参数 | 值 |
|------|-----|
| 多项式 | x⁵ + x² + 1 (0x05) |
| 种子 | 0x1F (全 1) |
| 数据序 | LSB first |
| CRC 发送序 | MSB first |
| 发送前 | 取反 (~) |
| 残差 | 0x0C |

RTL 源码: `src/common/usb_crc5.v`

## 测试用例

| Case 文件 | 测试目的 | 预期结果 |
|-----------|---------|---------|
| `case_token.v` | 6 组标准 addr/endp 组合的黄金向量 | 余数 + 残差全部匹配 |
| `case_boundary.v` | 边界条件 (addr=0x00/0x7f, endp=0x0/0xf) | 边界值通过残差检查 |

黄金向量来源: `tools/gen_crc_gold.py`

## 如何仿真

```bash
# 从项目根目录
make crc5

# 或进入子目录
make -C sim/crc5 run

# 单独编译
make -C sim/crc5 build

# 清理
make -C sim/crc5 clean
```

## 验证方法

每个 test case 采用自检机制:
1. 喂入 ADDR+ENDP 11 bit → 检查 `crc_out` 与黄金向量的期望余数一致
2. 再喂入 5 bit 发送 CRC → 检查残差 = 0x0C (USB 规范 §8.3.5.1)
3. 不匹配时 `$display("FAIL: ...")` 并累加 errors 计数器
4. 全部通过 → `$finish(0)`; 有错误 → `$fatal(1)`
