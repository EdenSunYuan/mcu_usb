#!/usr/bin/env python3
#============================================================================
# gen_tx_timing.py — usb_tx_serial 关键信号时序图生成器
# Timing diagrams for the TX serializer design report.
#
# 为什么不用 render_waveform.py：那个工具要真 VCD，而 usb_tx_serial 的 RTL 还没写。
# 本工具用 Python 按设计语义跑一个**位级参考模型**，逐拍画出信号波形，
# 图注标明「设计意图，非仿真」。RTL + TB 完成后，应改用
#   python3 tools/render_waveform.py <vcd> <png> --signals ...
# 从真 VCD 截图替换这些图。
#
# 模型与设计报告的对应关系（doc/design_rpt/tx_serial_design.md）：
#   §2.5 SYNC(0x80) / EOP(SE0×2 + J×1)
#   §2.4 位填充：6 连 1 后插 0，插 0 那拍 hold（不移位、位计数不前进）
#   §2.6 S_DATA 出口要求 stuff_pend=0（末字节欠的填充 0 必须先发出去，EOP 恒 3 拍）
#   §2.7 握手：载入拍给 tx_ready；EOP 的 J 拍给 tx_done；SIE 下一拍拉低 tx_active
#
# 详细说明见 tools/README_gen_tx_timing.md。
#
# 用法 / Usage:
#   python3 tools/gen_tx_timing.py              # 生成全部图
#   python3 tools/gen_tx_timing.py handshake    # 只生成指定图
# 输出 / Output: doc/fig/tx_serial_*.png
# 依赖 / Dependency: matplotlib
#============================================================================

import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager
from matplotlib.patches import Rectangle

# 中文字体（macOS）：按可用性挑一个，避免标题/标签出方块
_AVAIL = {f.name for f in font_manager.fontManager.ttflist}
for _f in ("Heiti TC", "PingFang SC", "Arial Unicode MS", "Hiragino Sans GB",
           "Songti SC", "DejaVu Sans"):
    if _f in _AVAIL:
        plt.rcParams["font.sans-serif"] = [_f, "DejaVu Sans"]
        break
plt.rcParams["axes.unicode_minus"] = False

# 常量（与 src/inc/usb_const.vh 一致）
SYNC_BYTE = 0x80
PID_ACK = 0xD2
PID_DATA0 = 0xC3

FIG_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "doc", "fig")

# 配色
CLK_COL = "#7F8C8D"
BIT_COL = "#1565C0"
BUS_FILL = "#E3F2FD"
BUS_EDGE = "#1565C0"
PULSE_COL = "#C62828"
MARK_SYNC = "#FFF59D"
MARK_BYTE = "#E8F5E9"
MARK_EOP = "#FFCDD2"
GRID_COL = "#DDDDDD"


#--------------------------------------------------------------------------
# 位级参考模型：按设计语义逐拍产生信号快照（不是 RTL 仿真）
#--------------------------------------------------------------------------
def tx_trace(tx_bytes, pre_idle=2, post_idle=2):
    """跑一次完整发送，返回每拍信号快照 list[dict]。

    每拍字段：state / active / en / bit / se0 / data / last / ready / done / held
    （held=1 表示本拍输出的是插入的填充 0，数据通路 hold 一拍）
    """
    n = len(tx_bytes)
    trace = []

    # --- 各寄存器的初值 ---
    state, shift, bit_cnt, ones = "S_IDLE", 0, 0, 0
    stuff = False               # 下拍插 0（hold）
    level = 1                   # NRZI 电平 1=J 0=K
    byte_idx = 0                # 当前摆在 tx_data 上的字节序号
    last_flag = (n == 1)        # SIE 当前摆的字节是不是最后一个
    last_q = False              # 载入字节时锁存的 last_flag（位 FSM 用）
    load_now = False            # 本拍载入 + 打 tx_ready
    present_pending = None      # 下一拍 SIE 摆上的字节序号
    eop_cnt = 0
    idle_cnt = 0                # 收尾空闲拍计数

    def rec(**kw):
        row = dict(t=len(trace), state=state, active=0, en=0, bit=level,
                   se0=0, data=None, last=0, ready=0, done=0, held=0)
        row.update(kw)
        trace.append(row)

    # --- 发送前的空闲拍（tx_en=0，线路高阻，模块输出保持 J）---
    for _ in range(pre_idle):
        rec()

    # --- tx_active↑：进 SYNC，载入 0x80 ---
    # S_SYNC 不跑填充（ones 保持 0）：SYNC 尾 1 不可能与 PID 凑出 6 连 1，见报告 §2.5
    state, shift, bit_cnt, ones, stuff = "S_SYNC", SYNC_BYTE, 0, 0, False
    level = 1

    while len(trace) < 2048:                # 防呆：模型写错时不至于死循环
        # 拍首：SIE 摆上被取走的下一字节（上一拍 tx_ready 之后）
        if present_pending is not None:
            byte_idx = present_pending
            present_pending = None
            last_flag = (byte_idx == n - 1)

        ready, done, held, se0 = 0, 0, 0, 0

        # 拍首：字节边界上的"载入移位寄存器 + tx_ready 脉冲"
        if load_now:
            ready = 1
            load_now = False
            shift = tx_bytes[byte_idx]          # 载入本字节（连续 1 计数不清零）
            last_q = last_flag                  # 锁存"本字节是不是最后一个"（§2.6）
            if byte_idx + 1 < n:
                present_pending = byte_idx + 1

        if state == "S_IDLE":
            rec()
            idle_cnt += 1
            if idle_cnt >= post_idle:
                break
            continue

        if state == "S_EOP":
            if eop_cnt < 2:                 # SE0 两位时间
                se0, level = 1, 0
            else:                           # J 一位时间 + tx_done
                se0, level, done = 0, 1, 1
            rec(active=1, en=1, data=tx_bytes[byte_idx], last=last_flag,
                ready=ready, done=done, se0=se0, bit=level)
            eop_cnt += 1
            if eop_cnt == 3:
                state = "S_IDLE"            # 下一拍 SIE 拉低 tx_active
            continue

        # --- S_SYNC / S_DATA：本拍输出 1 个位 ---
        if stuff:
            b, held = 0, 1                  # 插入的 0，数据通路 hold
        else:
            b = shift & 1
        level = level if b else 1 - level   # NRZI：0 翻转，1 保持
        rec(active=1, en=1, data=tx_bytes[byte_idx], last=last_flag,
            ready=ready, held=held, bit=level)

        # --- 拍尾推进 ---
        if held:
            stuff, ones = False, 0          # 插 0 已发出，连续 1 计数归零
        else:
            shift >>= 1
            bit_cnt += 1
            if state == "S_SYNC":           # SYNC 不参与填充计数（§2.5）
                ones = 0
            else:
                ones = ones + 1 if b else 0
                if b and ones == 6:
                    stuff = True            # 下拍插 0（hold）

        # 字节边界（正常移完 8 位，或第 8 位刚触发填充、补发完那个 0）
        if bit_cnt == 8 and not stuff:
            bit_cnt = 0
            if state == "S_SYNC":
                state = "S_DATA"
                load_now = True             # 下一拍载入 byte0 + tx_ready
            elif last_q:
                state, eop_cnt = "S_EOP", 0
            else:
                load_now = True             # 下一拍载入下一字节 + tx_ready

    # --- 收尾空闲拍 ---
    while len(trace) < len(trace):
        break
    return trace


#--------------------------------------------------------------------------
# 自检：证明"SYNC 尾 1 计不计入"对位流无影响（报告 §2.5 / §4.2）
#--------------------------------------------------------------------------
def _bits_of(bs):
    """字节列表 → 线上位序列（每字节 LSb 先）。"""
    out = []
    for b in bs:
        out += [(b >> i) & 1 for i in range(8)]
    return out


def _wire_with_stuff(bits, ones0=0):
    """按"6 连 1 后插 0"把数据位变成线上位；返回 (线上位, 插入的 0 的个数)。"""
    out, ones, n = [], ones0, 0
    for b in bits:
        out.append(b)
        ones = ones + 1 if b else 0
        if b and ones == 6:
            out.append(0)
            ones = 0
            n += 1
    return out, n


def check_sync_not_counted():
    """断言：SYNC 段跑不跑填充计数，线上位流完全一致。

    PID 字节 = 低 4 位 code + 高 4 位 ~code，结构上最多 4 连 1；SYNC 尾 1 + 4 = 5 < 6，
    所以 SYNC→PID 边界永远不插位。这里对全部 16 种合法 PID × 各种后续字节暴力验证。
    """
    sync = _bits_of([SYNC_BYTE])
    pids = [c | ((~c & 0xF) << 4) for c in range(16)]      # 全部 XX~XX 形态
    tails = [0x00, 0x0F, 0xF0, 0xFF, 0xFC, 0xF8, 0x3F, 0xE0]

    # ① 单字节：PID 在 SYNC 尾 1 之后也不插位（起始计数 0 与 1 都不插）
    for pid in pids:
        for ones0 in (0, 1):
            _, n = _wire_with_stuff(_bits_of([pid]), ones0)
            assert n == 0, f"PID 0x{pid:02X} 在 ones0={ones0} 下插了位"
    # ② 两种规则下整包位流逐位相同
    for pid in pids:
        for t in tails:
            a, _ = _wire_with_stuff(sync + _bits_of([pid, t]), 0)   # 计 SYNC 尾 1
            b = sync + _wire_with_stuff(_bits_of([pid, t]), 0)[0]   # 不计
            assert a == b, f"PID 0x{pid:02X} + 0x{t:02X} 两种规则位流不同"
    print("自检通过：16 种 PID × 8 种后续字节，SYNC 计/不计入 → 线上位流完全一致")


#--------------------------------------------------------------------------
# 画图：把逐拍快照画成时序波形
#--------------------------------------------------------------------------
def _runs(pairs):
    """把 [(拍号, 值), ...] 切成稳定段 [(起始拍, 结束拍, 值), ...]。"""
    out = []
    for (t, v) in pairs:
        if out and out[-1][2] == v and out[-1][1] == t - 1:
            out[-1][1] = t
        else:
            out.append([t, t, v])
    return out


def draw_timing(trace, rows, out_name, title, x0=None, x1=None,
                marks=(), figsize=(15, 7), note=""):
    """rows: [(key, kind, label)]，kind ∈ {clock, bit, bus}。"""
    t_all = [r["t"] for r in trace]
    x0 = t_all[0] if x0 is None else x0
    x1 = t_all[-1] if x1 is None else x1
    sel = [r for r in trace if x0 <= r["t"] <= x1]

    fig, ax = plt.subplots(figsize=figsize, dpi=150)
    nrow = len(rows)

    # 高亮区间（SYNC / 字节 / EOP 等）
    for (a, b, color, label) in marks:
        ax.add_patch(Rectangle((a - 0.5, 0), b - a + 1, nrow,
                               facecolor=color, edgecolor="none", zorder=0))
        if label:
            ax.text((a + b) / 2, nrow - 0.04, label, ha="center", va="top",
                    fontsize=8, color="#555555", zorder=5,
                    bbox=dict(facecolor="white", edgecolor="none", alpha=0.85, pad=1.0))

    # 逐拍网格
    for t in range(x0, x1 + 2):
        ax.plot([t - 0.5, t - 0.5], [0, nrow], color=GRID_COL, lw=0.6, zorder=1)

    for i, spec in enumerate(rows):
        key, kind, label = spec[0], spec[1], spec[2]
        fmt = spec[3] if len(spec) > 3 else None
        # 行号自上而下
        base = nrow - 1 - i

        if kind == "bus":
            for (a, b, v) in _runs([(r["t"], r[key]) for r in sel]):
                if v is None:
                    continue
                ax.add_patch(Rectangle((a - 0.5, base + 0.15), b - a + 1, 0.7,
                                       facecolor=BUS_FILL, edgecolor=BUS_EDGE,
                                       lw=1.0, zorder=3))
                txt = f"0x{v:02X}" if fmt == "hex" else str(v)
                ax.text((a + b) / 2, base + 0.5, txt, ha="center", va="center",
                        fontsize=8, color="#0D47A1", zorder=4)
        else:
            if kind == "clock":
                vals = [(1 - r["t"] % 2) for r in sel]
            else:
                vals = [r[key] for r in sel]
            ys = [base + 0.15 + 0.7 * (1 if v else 0) for v in vals]
            ax.step([r["t"] - 0.5 for r in sel], ys, where="post",
                    color=(PULSE_COL if key in ("tx_ready", "tx_done") else CLK_COL
                           if kind == "clock" else BIT_COL),
                    lw=1.8, zorder=3)
            if kind == "clock":     # 时钟淡一点
                ax.step([r["t"] - 0.5 for r in sel],
                        [base + 0.15 + 0.7 * (1 if v else 0) for v in vals],
                        where="post", color="#CFD8DC", lw=1.2, zorder=2)

    ax.set_yticks([nrow - 1 - i + 0.5 for i in range(nrow)])
    ax.set_yticklabels([spec[2] for spec in rows], fontsize=9)
    ax.set_ylim(0, nrow)
    ax.set_xlim(x0 - 0.5, x1 + 0.5)
    ax.set_xticks(range(x0, x1 + 1, 1 if (x1 - x0) <= 18 else 2))
    ax.tick_params(axis="x", labelsize=8)
    ax.set_xlabel("clk12m 拍数（1 拍 = 1 bit = 83.3 ns）", fontsize=9)
    ax.set_title(title, fontsize=11)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)

    if note:
        fig.text(0.012, 0.006, note, fontsize=7.5, color="#999999", ha="left")

    fig.tight_layout(rect=(0, 0.02, 1, 1))
    path = os.path.join(FIG_DIR, out_name)
    fig.savefig(path)
    plt.close(fig)
    print(f"  -> {path}")


#--------------------------------------------------------------------------
# 各张图
#--------------------------------------------------------------------------
ROWS_FULL = [
    ("clk", "clock", "clk12m"),
    ("active", "bit", "tx_active"),
    ("state", "bus", "state"),
    ("data", "bus", "tx_data[7:0]", "hex"),
    ("last", "bit", "tx_last"),
    ("ready", "bit", "tx_ready"),
    ("done", "bit", "tx_done"),
    ("bit", "bit", "tx_bit (J/K)"),
    ("se0", "bit", "tx_se0"),
    ("en", "bit", "tx_en"),
]
ROWS_WAVE = [
    ("clk", "clock", "clk12m"),
    ("active", "bit", "tx_active"),
    ("state", "bus", "state"),
    ("data", "bus", "tx_data[7:0]", "hex"),
    ("last", "bit", "tx_last"),
    ("bit", "bit", "tx_bit (J/K)"),
    ("se0", "bit", "tx_se0"),
    ("en", "bit", "tx_en"),
]

NOTE = "设计意图（Python 位级参考模型生成，非 RTL 仿真）"


def fig_pid_only():
    """单字节包：SYNC + 8 bit + EOP，全握手信号一览。"""
    tr = tx_trace([PID_ACK])
    n = len(tr)
    marks = [(2, 9, MARK_SYNC, "SYNC"), (10, 17, MARK_BYTE, "PID"),
             (18, 20, MARK_EOP, "EOP")]
    draw_timing(tr, ROWS_FULL, "tx_serial_pid_only.png",
                "usb_tx_serial 时序（设计意图）：单字节包（PID-only，如 ACK/NAK/STALL）",
                x0=0, x1=n - 1, marks=marks, note=NOTE)


def fig_nrzi_sop():
    """SOP：空闲 J → tx_active↑ → 第一个 SYNC 位（0）翻转成 K。"""
    tr = tx_trace([PID_ACK])
    draw_timing(tr, ROWS_FULL, "tx_serial_nrzi_sop.png",
                "usb_tx_serial 时序（设计意图）：SOP = 空闲 J → K（NRZI 复位到 J）",
                x0=0, x1=7,
                figsize=(11, 7), note=NOTE)


def fig_handshake():
    """字节边界握手：载入 + tx_ready 脉冲；SIE 下一拍摆上下一字节。"""
    tr = tx_trace([PID_DATA0, 0x11, 0x22])
    draw_timing(tr, ROWS_FULL, "tx_serial_handshake.png",
                "usb_tx_serial 时序（设计意图）：字节边界握手（载入拍给 tx_ready）",
                x0=6, x1=26, figsize=(15, 7), note=NOTE)


def fig_eop():
    """EOP 细节：SE0×2 + J×1 → tx_done → SIE 拉低 tx_active → 高阻。"""
    tr = tx_trace([PID_DATA0, 0x11])
    n = len(tr)
    eop = [r["t"] for r in tr if r["state"] == "S_EOP"]
    draw_timing(tr, ROWS_FULL, "tx_serial_eop.png",
                "usb_tx_serial 时序（设计意图）：EOP = SE0 2 拍 + J 1 拍，随后交高阻",
                x0=n - 14, x1=n - 1,
                marks=[(eop[0], eop[-1], MARK_EOP, "EOP: SE0×2 + J×1")],
                figsize=(13, 7), note=NOTE)


def fig_stuffing():
    """位填充：全 1 数据，每 6 连 1 后插 0（并 hold 一拍）。"""
    tr = tx_trace([PID_DATA0, 0xFF, 0xFF])
    rows = ROWS_WAVE + [("held", "bit", "填充位 (stuffed 0)")]
    draw_timing(tr, rows, "tx_serial_stuffing.png",
                "usb_tx_serial 时序（设计意图）：位填充（6 连 1 后插 0，数据通路 hold 一拍）",
                x0=16, x1=len(tr) - 1, figsize=(15, 7), note=NOTE)


def fig_tail_stuff():
    """尾字节 6 连 1 收尾：EOP 紧接插入的 0，不多不少。"""
    tr = tx_trace([PID_DATA0, 0xFC])
    n = len(tr)
    held = [r["t"] for r in tr if r["held"]]
    eop = [r["t"] for r in tr if r["state"] == "S_EOP"]
    draw_timing(tr, ROWS_FULL, "tx_serial_tail_stuff.png",
                "usb_tx_serial 时序（设计意图）：末字节 6 连 1，EOP 紧接插入的 0",
                x0=n - 15, x1=n - 1,
                marks=[(held[0] - 5, held[0], "#FFE0B2", "末尾 6 连 1 后插 0"),
                       (eop[0], eop[-1], MARK_EOP, "EOP")],
                figsize=(13, 7), note=NOTE)


FIGS = {"pid_only": fig_pid_only, "nrzi_sop": fig_nrzi_sop,
        "handshake": fig_handshake, "eop": fig_eop,
        "stuffing": fig_stuffing, "tail_stuff": fig_tail_stuff}


if __name__ == "__main__":
    only = sys.argv[1] if len(sys.argv) > 1 else None
    # 自检：打印一条 trace 的关键位，便于人工核对模型是否符合设计语义
    if only == "--check":
        check_sync_not_counted()
        sys.exit(0)
    if only == "--dump":
        for r in tx_trace([PID_DATA0, 0x11]):
            print(r)
        sys.exit(0)
    if only:
        FIGS[only]()
    else:
        for fn in FIGS.values():
            fn()
    print("全部图已生成 / all timing diagrams generated")
