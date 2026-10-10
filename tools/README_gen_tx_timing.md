# gen_tx_timing.py — usb_tx_serial 参考模型 / 自检工具

> **现在只做参考模型与自检，不再出图**（2026-09-16 起）。设计报告 §4.7 的 6 张图已改为从
> `sim/tx/*.vcd` 用 `tools/render_waveform.py` 截的**真实波形**。

## 功能描述

用 Python 按 `usb_tx_serial` 的设计语义跑一个位级参考模型，提供三条用途：

- **`--check`（主用途）**：填充规则的**机器证明**——断言"SYNC 尾 1 计入连 1 计数"与"从 PID 起算"
  两条规则输出的线上位流逐位相同（16 种 PID × 8 种后续字节）。
- **`--dump`**：打印一条 trace 的逐拍信号，作为 TB 的**跨语言旁证**（第二条独立实现）。
- **`<键>` / 无参**：仍能渲染 `doc/fig/tx_serial_*.png`，但**只作临时对照**——正式配图走
  `python3 tools/render_waveform.py <vcd> <png> --signals ...`，别用它覆盖报告里的图
  （脚本画的标着"设计意图图"，会污染"报告配图必须是真波形"这条约定）。

**历史**：RTL 未落地前本脚本是那 6 张图的唯一来源；RTL + TB 落地后按用户 2026-09-16 的要求
整体换成真波形。**已包含的图**（现由 `render_waveform.py` 从 `sim/tx/` 同名 VCD 出）：

| 键 | 输出 | 内容 |
|---|---|---|
| `pid_only` | `tx_serial_pid_only.png` | 单字节包（ACK/NAK/STALL）：SYNC + 8 位 + EOP，全握手信号 |
| `handshake` | `tx_serial_handshake.png` | `tx_active`/`tx_ready`/`tx_last`/`tx_done` 字节边界握手 |
| `stuffing` | `tx_serial_stuffing.png` | 全 1 数据触发填充，插 0 处 hold 一拍 |
| `tail_stuff` | `tx_serial_tail_stuff.png` | 末字节 6 连 1 收尾，EOP 紧接插入的 0 |
| `eop` | `tx_serial_eop.png` | EOP：SE0 2 拍 + J 1 拍 + 交高阻 |
| `nrzi_sop` | `tx_serial_nrzi_sop.png` | 空闲 J → SOP K 沿（NRZI 复位到 J） |

## 使用方法

```bash
python3 tools/gen_tx_timing.py              # 生成全部图
python3 tools/gen_tx_timing.py handshake    # 只生成指定图（上面的"键"）
python3 tools/gen_tx_timing.py --dump       # 打印一条 trace 的逐拍信号，人工核对模型
python3 tools/gen_tx_timing.py --check      # 自检：SYNC 计不计入填充，位流是否一致
```

`--check` 是**机器证明**，不是示意：对全部 16 种合法 PID（`XX~XX` 形态）× 8 种后续字节，
断言"把 SYNC 尾 1 计入连 1 计数"与"从 PID 起算"输出的**线上位流逐位相同**。
结论（SYNC 之后必是 PID，PID 结构上最多 4 连 1，5 < 6 不插位）见设计报告 §2.5 / §4.2。
这条用例已照抄进 RTL TB（`sim/tx/case_sync_pid_nostuff.v`，16 PID × 9 包）。

## 模型与设计报告的对应关系

模型不是随手的示意，严格对齐 [tx_serial_design.md](../doc/design_rpt/tx_serial_design.md)：

- §2.5 SYNC = `0x80`；**SYNC 不参与填充计数，计数从 PID 起算**；EOP = SE0×2 + J×1；
- §2.4 位填充 = 6 连 1 后插 0，插 0 那拍 **hold**（不移位、位计数不前进）；
- §2.6 位 FSM 4 态，`S_SYNC` 恒 8 拍不跑填充；`S_DATA` 出口要求 `stuff_pend`=0（末字节欠的填充 0 必须先发出去）；
- §2.7 握手 = 载入拍给 `tx_ready`（含最后一个字节）；EOP 的 J 拍给 `tx_done`；SIE 下一拍拉低 `tx_active`。

> 画这套图时暴露过一处真问题（末字节 6 连 1 收尾时欠的填充 0 被丢掉），过程记在设计报告 §4.7；
> RTL 落地时它对应缺陷 2（`data_end` 把中途插 0 误判成字节收尾），见验证报告 §5.2。
> 改模型时如果波形对不上报告，**先怀疑报告**，两边一起改。

## 输入/输出

- **输入**：模块内写死的激励（字节列表，如 `[PID_DATA0, 0xFC]`）
- **输出**：stdout（`--check` 断言结果 / `--dump` 逐拍 trace）；`<键>` 模式另写临时 `doc/fig/tx_serial_*.png`

## 依赖

- Python 3 + `matplotlib`
- 中文字体（macOS 上自动探测 Heiti TC / PingFang SC 等，找不到会退化成方块）

## 已知限制

- trace 上限 2048 拍（防模型写错时死循环），正常包远达不到；
- 只建模 `usb_tx_serial` 自身，不含 SIE 侧的预取行为（`tx_data` 在图上只显示"当拍摆的值"）。
