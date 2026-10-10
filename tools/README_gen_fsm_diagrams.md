# gen_fsm_diagrams.py — 项目状态机图与模块框图生成

## 功能描述

生成 USB 1.1 Device Controller 项目各模块的状态机跳转图和内部模块框图。所有图通过 `state_machine_gen.py` 的 `FSM` 类描述，或直接写 Graphviz DOT 源码，渲染为 PNG 图片输出到 `doc/fig/` 目录。

**已包含的图**：
- **DPLL 状态机图**（`dpll_diagram`）：USB 1.1 时钟恢复 16 态跳转图（Intel SIE 结构），左右双环布局 + 锁存态 C/D + 长 bit 绕行 F/B
- **TX 位状态机图**（`tx_serial_diagram`）：`usb_tx_serial` 6 态
  （`S_IDLE`/`S_SYNC`/`S_DATA`/`S_DATA_LAST`/`S_EOP1`/`S_EOP2`）横向跳转图
- **PHY 内部模块框图**（`phy_block_diagram`）：`usb_dpll_phy` 五个子模块
  （CDR / clk_mux / RX Deserializer / TX Serializer / bus_state）及其字节级边界
- **公共原语框图**（`common_block_diagram`）：CRC5/CRC16 + NRZI 编解码 + 位填充模块关系

## 使用方法

### 生成全部图

```bash
python3 tools/gen_fsm_diagrams.py
# -> doc/fig/dpll_state_machine.png
# -> doc/fig/tx_serial_state_machine.png
# -> doc/fig/phy_block.png
# -> doc/fig/common_block.png
```

> 必须在**仓库根目录**运行：图片路径 `doc/fig/` 是相对当前目录的。

### 只生成指定图

```bash
python3 tools/gen_fsm_diagrams.py dpll         # 只生成 DPLL 状态机图
python3 tools/gen_fsm_diagrams.py tx_serial    # 只生成 TX 位状态机图
python3 tools/gen_fsm_diagrams.py block        # 只生成 PHY 框图
python3 tools/gen_fsm_diagrams.py common       # 只生成公共原语框图
```

### 添加新图

在 `gen_fsm_diagrams.py` 中添加新的函数，例如：

```python
def my_new_diagram():
    """我的新模块状态机图"""
    fsm = FSM(title="模块XXX 状态机", init="IDLE")
    fsm.state("IDLE", label="IDLE", fillcolor="#C6EFCE")
    fsm.state("ACTIVE", label="ACTIVE", fillcolor="#FFF2CC")
    fsm.edge("IDLE", "ACTIVE", "start")
    fsm.edge("ACTIVE", "IDLE", "done")
    fsm.render("my_new_state_machine")
```

然后在 `__main__` 的 `jobs` 字典中注册：

```python
jobs = {"dpll": dpll_diagram, "tx_serial": tx_serial_diagram,
        "block": phy_block_diagram, "common": common_block_diagram,
        "my_new": my_new_diagram}
```

状态标签里可以写 `\n` 换行（`_esc` 会转成 dot 的换行），例如
`label="S_IDLE\ntx_en=0"`；`rankdir="LR"` 可画横向链路。

## 配色说明

| 颜色名 | 色值 | 用途 |
|--------|------|------|
| `CLK_HIGH` | `#C6EFCE` (浅绿) | 恢复时钟高电平态 |
| `CLK_LOW` | `#DDEBF7` (浅蓝) | 恢复时钟低电平态 |
| `LOCK` | `#FFF2CC` (浅黄) | 锁存态 C/D |
| `DETOUR` | `#FCE4D6` (浅橙) | 长 bit 绕行态 F/B |

## 输入/输出

- **输入**：`state_machine_gen.py` API + 直接编写的 Graphviz DOT 源码
- **输出**：`doc/fig/*.png`（图片）+ `doc/fig/*.dot`（源码）

## 依赖

- `state_machine_gen.py`（同目录）
- Graphviz (`brew install graphviz`)
