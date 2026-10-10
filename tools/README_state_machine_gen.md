# state_machine_gen.py — 状态机图生成器

## 功能描述

基于 Graphviz `dot` 的状态机跳转图生成库。用于设计报告中生成美观的状态机图，无 Python 第三方依赖（通过 `subprocess` 调用系统 `dot` 二进制）。

**核心能力**：
- 声明式 FSM 构建 API（状态、跳转、分组、同行约束）
- 自定义节点颜色/形状/标签
- Cluster 分组（虚线框）
- Rank 同行约束（控制布局）
- 导出 `.dot` 源码 + 渲染 PNG/SVG/PDF

## 使用方法

### 基本用法

```python
from state_machine_gen import FSM

# 创建 FSM
fsm = FSM(title="DPLL 时钟恢复状态机（USB 1.1）", init="C")

# 添加状态（name, label, **dot_attrs）
fsm.state("C", label="C", fillcolor="#FFF2CC")   # 锁存态
fsm.state("D", label="D", fillcolor="#FFF2CC")
fsm.state("0", label="0", fillcolor="#DDEBF7")   # 左环
fsm.state("1", label="1", fillcolor="#DDEBF7")
fsm.state("5", label="5", fillcolor="#DDEBF7")   # 右环

# 添加跳转（src, dst, label, **dot_attrs）
fsm.edge("C", "C", "b≠0", constraint="false")  # 自环不参与布局
fsm.edge("C", "D", "b=0")
fsm.edge("D", "5", "b=1")

# 同行约束（强制这些状态在同一水平行）
fsm.rank("C", "D")
fsm.rank("1", "5")
fsm.rank("0", "4")

# 分组（虚线框）
fsm.cluster("左环 (data 0)", ["1", "3", "2", "0"],
            fillcolor="#F0F4FF", color="#4472C4")

# 生成 .dot 文件和渲染
fsm.save_dot("doc/fig/dpll.dot")
fsm.render("dpll_state_machine", outdir="doc/fig", fmt="png")
# -> doc/fig/dpll_state_machine.dot + doc/fig/dpll_state_machine.png
```

### API

| 方法 | 说明 |
|------|------|
| `FSM(title, init, rankdir)` | 创建 FSM 构建器。init=初始态（双圈），rankdir=TB/LR |
| `state(name, label, **attrs)` | 添加状态节点，attrs 为 Graphviz 属性（fillcolor, color 等） |
| `edge(src, dst, label, **attrs)` | 添加跳转，label 为条件标注，attrs 如 constraint=false |
| `cluster(name, states, **attrs)` | 把一组状态归入虚线框分组 |
| `rank(*states)` | 强制这些状态放在同一水平行 |
| `to_dot()` | 返回 dot 源码字符串 |
| `save_dot(path)` | 保存 dot 源码到文件 |
| `render(name, outdir, fmt)` | 生成 dot 源码并调用系统 `dot` 渲染为图片 |

### Dot 属性说明

| 属性 | 说明 |
|------|------|
| `fillcolor` | 节点填充颜色 |
| `color` | 节点/框边框颜色 |
| `constraint="false"` | 跳转不参与布局计算（跨环切换用） |
| `peripheries="2"` | 双圈（自动用于 init 状态） |

## 输入/输出

- **输入**：Python API 调用构建 FSM 结构
- **输出**：`.dot` 源码 + PNG/SVG/PDF 图片

## 依赖

- Python 标准库
- Graphviz (`brew install graphviz` 或 `apt install graphviz`)，需要 `dot` 命令在 PATH 中

## 被调用方

- `gen_fsm_diagrams.py` — 项目各模块的 FSM 图生成脚本
