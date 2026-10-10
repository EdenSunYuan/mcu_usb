# merge_fsm_cov.py — FSM 状态/迁移弧覆盖率合并

## 功能描述

把各用例日志里的 FSM 状态停留拍数与 N×N 迁移矩阵**逐元素相加**，给出合并后的状态/弧
覆盖率，并判定是否所有合法弧都被走过。

**为什么需要它**：Verilator 的 `--coverage-fsm` **认不出 `code_rtl.md` 规则 8 要求的两段式
FSM** —— 它只识别单段式写法（状态变量在组合块里直接 `case` 赋值），而我们的模块是组合算
`*_stat_nxt` + 时序搬 `*_stat_cur`，且 `case` 常外套优先分支 → 检测器放弃，`merged.dat` 里
0 条 fsm 记录（`fsm_state`/`fsm_arc` 恒为 `0/0`）。与其为工具改已验收的 RTL，不如在 TB 侧
分层引用 `u_x.*_stat_cur` 自己数（TB 的 `print_fsm_coverage`），本脚本负责跨用例合并 ——
与 `verilator_coverage` 对其它维度做的事同构。

同一个脚本按 `PROFILES` 表服务多个模块，用 `--profile` 选。

## 使用方法

```bash
# 推荐: 走 Makefile (先跑一遍保证日志是新的, 再合并)
make -C sim/<模块> fsmcov
make cov MOD=<模块>          # 根入口: cov + fsmcov 一起

# 直接指定日志 + profile
python3 tools/merge_fsm_cov.py --profile sie sim/sie/cov/fsm_*.log
```

`--profile` 省略时取 `tx`（兼容旧调用）。默认日志 glob 为
`cov/fsm_*.log`、`cov/dat/*.log`、`sim_tx_*.log`。

## PROFILES 表

| profile | 模块 | 状态数 |
|---|---|---|
| `tx` | `usb_tx_serial` | 6（IDLE/SYNC/DATA/DATA_LAST/EOP1/EOP2） |
| `clkmux` | `usb_clk_mux` | 4 |
| `busstate` | `usb_bus_state` | 3（标志位组合，无状态机） |
| `deserial` | `usb_rx_deserial` | 4 |
| `sie` | `usb_sie` | 4（IDLE/DATA_WAIT/TX/HS_WAIT） |

每个 profile 四样东西：`title`、`visit`（抓状态停留拍数的正则）、`states`（编号→名字，
**矩阵维度由它决定**，不写死列数）、`legal`（设计意图内的弧，照 RTL 次态 `case` 逐条抄）。

加新模块时按 RTL 的次态逻辑抄 `legal`：漏写会把真实弧误报成「意图外」，多写会漏报缺口，
两边都要核。

## 判定口径

- **未停留过的状态**或**未覆盖的合法弧** → 打印清单，退出码 1。
- 出现 **`legal` 之外的迁移** → 标 ⚠ 并列次数，供人工确认（若属正常路径，应补进 profile）。
- `unreachable: [<状态号>...]`：声明**本轮结构上到不了**的状态（如 `sie` 的 `TX`/`HS_WAIT`
  是发包轮的编码预留态）。它们不进缺口清单，改在 `○ 本轮结构不可达` 一行列出，不影响退出码。

## 输入/输出

- **输入**：各用例日志（须含 TB `print_fsm_coverage` 的「停留拍数」与矩阵输出）
- **输出**：stdout 报告（状态停留拍数 + 迁移矩阵 + 缺口清单）；退出码 0/1

## 依赖

- 纯 Python 标准库，无外部依赖

## 被调用方

- `sim/tx`、`sim/clkmux`、`sim/busstate`、`sim/deserial`、`sim/sie` 的 `fsmcov` 目标
- 各模块验证报告的 FSM 覆盖章节（报告里的合并矩阵即本脚本输出）
