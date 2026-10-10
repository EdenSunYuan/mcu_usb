# vcd_analyzer.py — VCD 解析与波形分析工具

## 功能描述

VCD（Value Change Dump）解析器与查询引擎。用于解析 iverilog / Verilator 等仿真器生成的 VCD 文件，提供信号查询、波形提取、时钟采样、条件搜索等功能。

**核心能力**：
- 解析 VCD 文件头（信号层级、位宽、timescale）
- 信号值查询与格式化
- 按时间范围提取信号跳变（transitions）
- 基于时钟沿的信号采样（clock-synchronized sampling）
- 条件表达式解析与搜索（`ConditionParser`）
- Python 数据类风格 API（`SignalDef`、`TransitionEvent`）

## 使用方法

### 命令行使用

```bash
# 列出所有信号
python3 tools/vcd_analyzer.py sim/cdr.vcd --list

# 提取指定信号的全部跳变
python3 tools/vcd_analyzer.py sim/cdr.vcd --signal "tb_rx_cdr.dut.state"

# 提取多个信号（逗号分隔）
python3 tools/vcd_analyzer.py sim/cdr.vcd --signal "*.state,*.clk12m"

# 在时钟沿上采样信号
python3 tools/vcd_analyzer.py sim/cdr.vcd --clock "*.clk12m" --edges posedge --signal "*"

# 搜索条件满足时刻
python3 tools/vcd_analyzer.py sim/cdr.vcd --search "*.state==5"
```

### 作为 Python 库使用

```python
from vcd_analyzer import VcdAnalyzer, VcdQueryEngine, SignalDef

# 加载 VCD
analyzer = VcdAnalyzer("sim/cdr.vcd")

# 获取信号信息
for sig in analyzer.header["signals"]:
    print(f"{sig.full_path}: {sig.width}-bit, type={sig.type}, vcd_id={sig.vcd_id}")

# 格式化值
formatted = VcdQueryEngine.format_value("b1010", 4)  # -> "4'hA"

# 提取跳变
events = analyzer.extract_transitions("*.state", start_time=0, end_time=500000, max_changes=1000)
for ev in events:
    print(f"  @{ev.time}ps: {ev.signal_path} -> {ev.new_value}")

# 快照
snapshot = analyzer.get_snapshot(100000, "*.dut.*")

# 基本信息
info = analyzer.get_info()  # timescale, 信号数, 时间范围等
```

### API 关键类

| 类 | 说明 |
|---|------|
| `VcdAnalyzer(filepath)` | VCD 解析入口，整合 Parser + Engine |
| `VcdQueryEngine` | 信号查询、值格式化、跳变提取 |
| `SignalDef` | 信号定义数据类（vcd_id, name, full_path, type, width, scope_path） |
| `TransitionEvent` | 跳变事件（time, vcd_id, signal_path, old_value, new_value） |
| `ConditionParser` | 条件表达式解析器，支持 `==`, `!=`, `>`, `<`, `&&`, `\|\|` 等运算符 |

## 输入/输出

- **输入**：VCD 文件（ASCII 格式，`$dumpvars` / `$dumpfile` 生成）
- **输出**：结构化信号数据、格式化值字符串

## 依赖

- 纯 Python 标准库，无外部依赖

## 被调用方

- `wave_debugger.py` — 波形调试器 GUI 的数据层
- 其它需要分析 VCD 波形的脚本
