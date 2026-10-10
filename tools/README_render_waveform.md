# render_waveform.py — 波形离屏渲染导出 PNG

## 功能描述

复用 `wave_debugger.py` 的波形渲染引擎（`WaveformScene` / `WaveformPanel`），在
离屏（offscreen）模式下加载 VCD、添加信号、设置可见时间窗口，然后 `grab()` 出
位图保存为 PNG。

用途：把交互式波形调试器的显示结果**截图**到验证报告等文档，无需人工操作 GUI。

## 使用方法

```bash
# 只截波形面板（推荐，适合报告插图）
python3 tools/render_waveform.py sim/cdr/cdr_case_nominal.vcd doc/fig/cdr_lock.png \
    --signals "tb_cdr.clk,tb_cdr.rxdp,tb_cdr.d_out,tb_cdr.dut.state" \
    --start 350000 --end 800000 --radix "tb_cdr.dut.state=hex"

# 截整个主窗口（含模块树 / 信号列表 / 代码查看器）
python3 tools/render_waveform.py sim/cdr/cdr_case_nominal.vcd out.png \
    --signals "tb_cdr.rxdp,tb_cdr.clk12m,tb_cdr.d_out" \
    --start 0 --end 4200000 --full-window

# 自定义窗口尺寸
python3 tools/render_waveform.py <vcd> <out.png> --signals "..." --start 0 --end 1000000 \
    --width 1800 --height 1000
```

| 参数 | 说明 |
|------|------|
| `vcd` | VCD 文件路径（位置参数 1） |
| `out` | 输出 PNG 路径（位置参数 2） |
| `--signals` | 逗号分隔的信号全路径（按显示顺序，如 `tb_cdr.dut.state`） |
| `--start` / `--end` | 可见时间窗口，单位 **ps**（VCD timescale 1ps） |
| `--radix` | 按信号全路径指定**多 bit 总线**的显示进制：`路径=进制`，逗号分隔多个。进制取 `hex`/`bin`/`dec`/`oct`/`unsigned`（默认 `bin`）。例：`--radix "tb_cdr.dut.state=hex,tb_cdr.addr=dec"`。未列出的总线仍按二进制标值 |
| `--full-window` | 截整个主窗口；默认只截波形面板 |
| `--width` / `--height` | 窗口尺寸，默认 1500×950 |

信号全路径可用 `vcd_analyzer.py list <vcd>` 查看。

## 输入/输出

- **输入**：VCD 文件（`make VCD=1` 生成）+ 信号路径 + 时间窗口
- **输出**：PNG 截图（波形面板或整个主窗口）

## 依赖

- Python 3.10+
- PySide6（`pip install PySide6`，系统 Python 已装 6.11.1）
- `wave_debugger.py`、`vcd_analyzer.py`（同目录）

## 说明

- 渲染在 `QT_QPA_PLATFORM=offscreen` 下进行，不弹出窗口，适合脚本批量出图。
- 输出为 RGBA PNG，Markdown 直接引用即可；如需 RGB 可用 PIL 转一次。
- 多 bit 总线默认按二进制标值。`--radix` 与 GUI（wave_debugger 信号标签右键 → 🔢 Radix）
  是同一套进制设置：报告插图想让状态机/地址等总线好读时，通常加
  `--radix "路径=hex"`（状态编码看 hex 最直观，如 DPLL 态 `4'hC`=C、`4'hD`=D、`4'h5`=锁定）。
- 已知偶发：macOS 离屏下连续启动多个 Qt 进程渲染可能报
  `libshiboken: Internal C++ object already deleted`（进程退出时的时序竞态）。
  遇错**原命令重跑一次即可**，与命令行参数无关。
