#!/usr/bin/env python3
#============================================================================
# wave_debugger.py — VCD 波形调试器 GUI（类似 Verdi / SimVision）
# Waveform Debugger GUI — interactive VCD waveform viewer with
# signal tree, RTL source browser, and waveform display.
#
# 用法 / Usage:
#   python3 tools/wave_debugger.py                  # 启动 GUI
#   python3 tools/wave_debugger.py sim/cdr.vcd      # 启动并自动加载 VCD
#
# 依赖 / Dependencies: PySide6, vcd_analyzer.py
#============================================================================

import bisect
import os
import re
import sys
import json

from PySide6.QtCore import (
    Qt, QRect, QRectF, QPointF, QLineF, QTimer, Signal, Slot,
    QSortFilterProxyModel, QRegularExpression, QItemSelectionModel,
)
from PySide6.QtGui import (
    QAction, QKeySequence, QFont, QColor, QPen, QBrush, QPainter,
    QTextCharFormat, QSyntaxHighlighter, QStandardItemModel, QStandardItem,
    QFontMetrics, QIcon, QWheelEvent, QMouseEvent, QTextCursor, QShortcut,
    QCursor, QPolygonF,
)
from PySide6.QtWidgets import (
    QApplication, QDialog, QDialogButtonBox, QMainWindow, QWidget,
    QVBoxLayout, QHBoxLayout, QSplitter, QTreeView, QListView,
    QPlainTextEdit, QGraphicsView, QGraphicsScene,
    QMenuBar, QMenu, QToolBar, QStatusBar, QLabel, QLineEdit,
    QComboBox, QScrollBar, QPushButton, QFileDialog, QMessageBox,
    QStyleFactory, QHeaderView, QAbstractItemView, QFrame, QListWidget,
    QListWidgetItem, QTabWidget, QCheckBox, QToolButton,
)

# ---- Import vcd_analyzer / wave_groups ----
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)
from vcd_analyzer import VcdAnalyzer, VcdQueryEngine, SignalDef
import wave_groups
from wave_groups import SignalGroup, is_group

#============================================================================
# Constants / 常量
#============================================================================

ROW_HEIGHT = 28       # 每行信号高度 / signal row height in pixels
RULER_HEIGHT = 30     # 时间轴高度 / time ruler height
# 硬不变量（改前先读 bug.md B11）：**组头行也恰好占一个 ROW_HEIGHT**。
# 行高统一是"标签列与波形列几何零改动"的前提，任何变高行都会让两列滚动错位。
FOLD_ZONE_W = 18      # 组头行最左侧这段宽度是折叠三角命中区 / fold triangle hit zone
GROUP_INDENT_PX = 10  # 组内成员行在标签列里的缩进 / member-row indent
COLOR_GROUP_BG = QColor("#E8EEF7")   # 组头行底色 / group header row background
COLOR_GROUP_ACCENT = QColor("#4A7EBB")  # 组头左侧色条 / group header accent bar
LABEL_WIDTH_DEFAULT = 170     # 信号名标签宽度默认值 / signal label column default width
MIN_PIXELS_PER_TICK = 60  # 刻度最小间距 / min pixels between ruler ticks

# 配色 / Color palette
COLOR_BG = QColor("#FFFFFF")
COLOR_GRID = QColor("#E0E0E0")
COLOR_RULER_BG = QColor("#F5F5F5")
COLOR_RULER_TEXT = QColor("#555555")
COLOR_CURSOR = QColor("#FF0000")
COLOR_TRACE_HIGH = QColor("#00AA00")
COLOR_TRACE_LOW = QColor("#006600")
COLOR_TRACE_X = QColor("#CC0000")
COLOR_TRACE_Z = QColor("#CC6600")
COLOR_BUS_BG = QColor("#E8F0FE")
COLOR_BUS_BORDER = QColor("#90A4CC")
COLOR_BUS_TEXT = QColor("#1A237E")
COLOR_LABEL_BG_EVEN = QColor("#FAFAFA")
COLOR_LABEL_BG_ODD = QColor("#F0F0F0")
COLOR_ROW_BG_EVEN = QColor("#FCFCFC")
COLOR_ROW_BG_ODD = QColor("#F4F4F4")

# 信号颜色轮 / Signal trace color wheel
SIGNAL_COLORS = [
    QColor("#2196F3"), QColor("#4CAF50"), QColor("#FF9800"), QColor("#9C27B0"),
    QColor("#00BCD4"), QColor("#E91E63"), QColor("#3F51B5"), QColor("#009688"),
    QColor("#CDDC39"), QColor("#795548"), QColor("#607D8B"), QColor("#FF5722"),
]

#============================================================================
# ModuleResolver — RTL 模块名→文件映射 / module-name → file resolution
#============================================================================

class ModuleResolver:
    """Scans .v files to build module-name → filepath and
    instance-name → module-name mappings, enabling the design tree
    to find the right source file for each VCD scope.
    """

    def __init__(self, search_dirs: list[str] | None = None):
        self._module_file: dict[str, str] = {}   # module_name → filepath
        self._inst_module: dict[str, str] = {}   # instance_name → module_name
        self._module_insts: dict[str, list[tuple[str, str]]] = {}  # file → [(inst, mod), ...]
        if search_dirs:
            for d in search_dirs:
                self.scan(d)

    def scan(self, directory: str):
        """Scan a directory tree for .v files. / 扫描目录下的 .v 文件."""
        if not os.path.isdir(directory):
            return
        for root, _dirs, files in os.walk(directory):
            for fn in files:
                if fn.endswith(".v") or fn.endswith(".sv"):
                    self._index_file(os.path.join(root, fn))

    def _index_file(self, filepath: str):
        """Parse one Verilog file for module declarations and instantiations."""
        try:
            with open(filepath, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except Exception:
            return

        # Find module declarations:  module foo (...);  or  module foo;
        for m in re.finditer(r'^\s*(?:module|macromodule)\s+(\w+)', text, re.MULTILINE):
            mod_name = m.group(1)
            if mod_name not in self._module_file:
                self._module_file[mod_name] = filepath

        # Find module instantiations:  mod_name inst_name ( ... );
        insts = []
        for m in re.finditer(r'(?m)^\s+(\w+)\s+(?:#\([\s\S]*?\)\s*)?(\w+)\s*\(', text):
            mod_name = m.group(1)
            inst_name = m.group(2)
            if mod_name not in ("begin", "end", "for", "if", "else", "case",
                                "while", "forever", "repeat", "assign", "always",
                                "initial", "module", "endmodule", "posedge", "negedge",
                                "or", "and", "not", "nand", "nor", "xor", "xnor",
                                "buf", "specify", "endspecify", "function", "task"):
                # First mapping wins (typically the main testbench)
                if inst_name not in self._inst_module:
                    self._inst_module[inst_name] = mod_name
                insts.append((inst_name, mod_name))
        if insts:
            self._module_insts[filepath] = insts

    def resolve_module_name(self, scope_name: str) -> str:
        """Map a VCD scope name to its Verilog module name.
        e.g. 'dut' → 'usb_rx_cdr'."""
        return self._inst_module.get(scope_name, scope_name)

    def resolve_file(self, scope_name: str) -> str | None:
        """Find the .v source file for a scope/module name."""
        if scope_name in self._module_file:
            return self._module_file[scope_name]
        mod_name = self._inst_module.get(scope_name)
        if mod_name and mod_name in self._module_file:
            return self._module_file[mod_name]
        return None

    def apply_overrides(self, module_files: dict[str, str]):
        """Apply per-VCD source overrides: module_name → filepath (win over scan order).

        Scan order resolves duplicate module names to the first file found, which is
        wrong when a VCD was compiled from a *different* file declaring the same module
        (e.g. sim/deserial/usb_rx_deserial_gate.v vs src/phy/usb_rx_deserial.v). A
        sidecar next to the VCD records which file this VCD really came from.
        """
        for mod, fp in (module_files or {}).items():
            if os.path.isfile(fp):
                self._module_file[mod] = fp

    def all_modules(self) -> dict[str, str]:
        """Return all known module_name → filepath mappings."""
        return dict(self._module_file)


# ── 状态名识别：常量声明解析（B10） ─────────────────────────────────────────
# 关键字与名字之间允许夹「范围 / 类型」限定词，例如：
#   localparam [1:0] S_IDLE = 2'd0;      ← 有范围，老正则直接一条都匹配不到
#   localparam integer N = 4;
#   parameter signed [7:0] X = 8'h5A;
_PARAM_QUAL_RE = re.compile(
    r"^(?:\[[^\[\]]*\]|signed\b|unsigned\b|integer\b|int\b|logic\b|reg\b|bit\b"
    r"|byte\b|shortint\b|longint\b|time\b|real\b)", re.I)
_PARAM_KEYWORD_RE = re.compile(r"\b(?:localparam|parameter)\b")
_PARAM_LITERAL_RE = re.compile(
    r"^(\d+)\s*'\s*[sS]?\s*([dDbBoOhH])\s*([0-9a-fA-FxXzZ?_]+)$")
_PARAM_DECIMAL_RE = re.compile(r"^(\d+)$")
_PARAM_ARITH_OK_RE = re.compile(r"^[0-9+\-*/() \t]+$")
_ENUM_RE = re.compile(r"\benum\b[^{]*\{([^}]*)\}", re.S)
_IDENT_ONLY_RE = re.compile(r"^[A-Za-z_]\w*$")


def _param_stmt_end(text: str, start: int) -> int | None:
    """从 start 起找该声明语句的 ';'（跳过 ( ) [ ] { } 内部，可跨行）。"""
    depth = 0
    for i in range(start, len(text)):
        ch = text[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth = max(0, depth - 1)
        elif ch == ";" and depth == 0:
            return i
    return None


def _eval_param_expr(expr: str, known: dict[str, int]) -> int | None:
    """求常量表达式的值：字面量 / 已定义常量名 / 只含 + - * / ( ) 的算术式。

    只认纯算术字符，且先把已知常量名替换成数值，所以不会执行到任何标识符或函数
    （`eval` 的 globals 也清空了 builtins）。
    """
    s = expr.strip().rstrip(";").strip()
    if not s:
        return None
    m = _PARAM_LITERAL_RE.match(s)
    if m:
        radix, digits = m.group(2), m.group(3)
        if digits[0] in "xXzZ?":
            return None
        base = {"d": 10, "b": 2, "o": 8, "h": 16}[radix.lower()]
        try:
            return int(re.sub(r"[xXzZ?]", "0", digits), base)
        except ValueError:
            return None
    m = _PARAM_DECIMAL_RE.match(s)
    if m:
        return int(m.group(1))
    for name in sorted(known, key=len, reverse=True):
        s = re.sub(r"\b" + re.escape(name) + r"\b", str(known[name]), s)
    if len(s) > 200 or "**" in s or not _PARAM_ARITH_OK_RE.match(s):
        return None
    try:
        val = eval(s, {"__builtins__": {}}, {})   # noqa: S307 —— 已限定为纯算术字符
    except Exception:
        return None
    if isinstance(val, bool):
        return None
    if isinstance(val, int):
        return val
    if isinstance(val, float) and val == int(val):
        return int(val)
    return None


def _collect_param_values(text: str) -> dict[str, int]:
    """收集源码里 localparam/parameter/enum 的 名字→数值（按出现顺序）。

    覆盖老实现漏掉的写法：范围/类型限定（`localparam [1:0] X = 2'd0;`）、
    一行多声明（`localparam A = 0, B = 1;`）、跨行声明、以及引用其它常量的
    表达式（`localparam S_LAST = S_A + 3;`）、SystemVerilog `enum {A, B}`。
    """
    out: dict[str, int] = {}
    # ① enum 先收（数值是裸字面量，参数可能引用它）
    for m in _ENUM_RE.finditer(text):
        nxt = 0
        for seg in _split_top_level(m.group(1), ","):
            eq = _assign_eq_pos(seg)
            if eq is None:
                name, val = seg.strip(), nxt
            else:
                ids = re.findall(r"[A-Za-z_]\w*", seg[:eq])
                if not ids:
                    continue
                name = ids[-1]
                v = _eval_param_expr(seg[eq + 1:], out)
                val = nxt if v is None else v
            if _IDENT_ONLY_RE.match(name):
                out[name] = val
                nxt = val + 1
    # ② 再收 localparam / parameter（可引用 ① 里的名字，也可引用前面的参数）
    for m in _PARAM_KEYWORD_RE.finditer(text):
        end = _param_stmt_end(text, m.end())
        if end is None:
            continue
        decl = text[m.end():end]
        while True:                       # 剥掉 `[..]` / signed / integer 等限定词
            nm = _PARAM_QUAL_RE.match(decl)
            if not nm:
                break
            decl = decl[nm.end():]
        for seg in _split_top_level(decl, ","):
            eq = _assign_eq_pos(seg)
            if eq is None:
                continue
            ids = re.findall(r"[A-Za-z_]\w*", seg[:eq])
            if not ids:
                continue
            val = _eval_param_expr(seg[eq + 1:], out)
            if val is not None:
                out[ids[-1]] = val
    return out


# 赋值对：两侧名字后可带**位选/部分选择**（`st_stat_cur[1:0] <= st_stat_nxt[1:0];`）。
# 规则 7 强制显式位宽，故位选必须容忍，否则两段式 FSM 的"次态变量补一跳"整条失效（B14）。
_ASSIGN_PAIR_RE = re.compile(
    r"\b([A-Za-z_]\w*)(?:\[[^\]]*\])?\s*(?:<=|=)\s*([A-Za-z_]\w*)(?:\[[^\]]*\])?\s*;")


def _state_var_aliases(varname: str, lines: list[str], pval: dict[str, int]) -> set[str]:
    """与 varname 直接互相赋值的其它标识符（如 `st_state <= st_nxt;` 的 st_nxt）。

    两段式写法里比较/`case` 可能全挂在次态变量上，只认 varname 会漏掉大半状态常量；
    这里只跳一跳、且排除常量名，所以不会把别的状态机的常量串进来。
    """
    aliases: set[str] = set()
    var_re = re.compile(r"\b" + re.escape(varname) + r"\b")
    for ln in lines:
        if "=" not in ln or not var_re.search(ln):
            continue
        for m in _ASSIGN_PAIR_RE.finditer(ln):
            a, b = m.group(1), m.group(2)
            if a == varname and b not in pval:
                aliases.add(b)
            elif b == varname and a not in pval:
                aliases.add(a)
    return aliases


def _params_used_with(varname: str, lines: list[str],
                      pval: dict[str, int]) -> set[str]:
    """收集与 varname 同现的常量名：同一行赋值/比较，或位于 `case(varname)` 块内。"""
    var_re = re.compile(r"\b" + re.escape(varname) + r"\b")
    used: set[str] = set()
    in_case, case_depth = False, 0
    for ln in lines:
        if in_case:
            # 简单统计嵌套 case/endcase，收集 case 项的常量（多为状态名）
            case_depth += len(re.findall(r"\bcase(?:z|x)?\b", ln))
            case_depth -= len(re.findall(r"\bendcase\b", ln))
            for p in pval:
                if re.search(r"\b" + re.escape(p) + r"\b", ln):
                    used.add(p)
            if case_depth <= 0:
                in_case = False
            continue
        if not var_re.search(ln):
            continue
        # 行内同现 / co-occurrence on the same line
        for p in pval:
            if re.search(r"\b" + re.escape(p) + r"\b", ln):
                used.add(p)
        # `case(varname)` / `casez(...)`，名字后可带**位选**：`case (st_stat_cur[1:0])`。
        # 只认"名字 + 可选单层 [..]"（不放开任意括号内容），避免把别的表达式的 case 误算进来（B14）。
        if re.search(r"\bcase(?:z|x)?\s*\(\s*" + re.escape(varname) + r"\s*(?:\[[^\]]*\])?\s*\)", ln):
            in_case, case_depth = True, 1
    return used


def detect_fsm_state_map(var_name: str, module_text: str, width: int) -> dict[int, str]:
    """为某个状态机变量识别它自己的状态名映射 {value: name}.

    Return {value: state_name} for a state variable, grouped by which
    localparams are *actually used with that variable* (same-line assignment /
    comparison, or inside a ``case(var)`` body). 同一模块有多个状态机、且位宽
    相同时，两套 localparam 不会互相串。
    """
    if not module_text or not var_name:
        return {}
    # 去注释 / strip comments before analysis
    text = re.sub(r"/\*.*?\*/", "", module_text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    lines = text.splitlines()

    # 1) 收集模块内 localparam/parameter/enum 的名字→数值
    #    e.g. localparam ST_IDLE = 2'd0;  /  localparam [1:0] S_IDLE = 2'd0;
    #         localparam N = 4;  /  'h1F / 'b11 / 'o7  /  enum {A, B}
    pval = _collect_param_values(text)
    if not pval:
        return {}

    # 2) 找出“这个变量”用到的参数：同句赋值/比较，或出现在 case(var) 块内
    used = _params_used_with(var_name, lines, pval)
    # 两段式写法的比较/case 可能挂在次态变量上 → 沿直接赋值关系补一跳
    for alias in _state_var_aliases(var_name, lines, pval):
        used |= _params_used_with(alias, lines, pval)

    # 3) 按参数定义顺序建表，宽度外的值丢弃
    out: dict[int, str] = {}
    for name, val in pval.items():
        if name in used and val not in out and 0 <= val < (1 << max(width, 1)):
            out[val] = name
    return out


def _dedup_signals(sigs):
    """按 vcd_id 去重并保持顺序 / Deduplicate by vcd_id preserving order."""
    seen, out = set(), []
    for s in sigs:
        if s.vcd_id not in seen:
            seen.add(s.vcd_id)
            out.append(s)
    return out


def _sig_struct_key(sig, resolver) -> tuple:
    """同一 RTL 层级在不同 VCD 里应得到相同 key（容忍顶层 tb / 例化改名）。

    取 (叶子名, 实例之下的模块链)：模块链 = scope_path[1:] 各段 resolve 出的模块名，
    即丢弃顶层 testbench 段（顶层名每个 case 都不同、无信息量）。
    resolver 为 None 时退化为实例名链（仅影响"结构适配"这一个匹配等级）。
    """
    segs = sig.scope_path
    if resolver is not None:
        mods = tuple(resolver.resolve_module_name(s) for s in segs)
    else:
        mods = tuple(segs)
    return (sig.name, mods[1:])


def resolve_session_signals(entries, current_sigs, resolver):
    """把 .wvs 里保存的每条 signal 解析到【当前 VCD】里的 SignalDef。

    status 取值:
      OK_EXACT      精确 full_path 命中
      OK_ADAPT      完整路径没有，但"去顶层tb的模块结构 + 叶子名"唯一命中（已适配改名）
      FAIL_NO_SUCH  当前 VCD 完全没有这个叶子信号名
      FAIL_AMBIG    结构相同实例有多个 / 或同名多处 → 无法确定，不擅自挑
      FAIL_SCOPE    同名信号只存在于模块结构不同的其它作用域

    位宽/类型变化不改变 status：匹配成功后照常显示，仅在 note 里注明。
    返回 (results, summary)；results 保序，每项 {entry, status, sig|None, note}。
    """
    exact: dict[str, SignalDef] = {}
    struct: dict[tuple, list[SignalDef]] = {}
    by_name: dict[str, list[SignalDef]] = {}
    for s in current_sigs:
        exact.setdefault(s.full_path, s)
        struct.setdefault(_sig_struct_key(s, resolver), []).append(s)
        by_name.setdefault(s.name, []).append(s)

    n_exact = n_adapt = n_fail = 0
    results = []
    for entry in entries:
        full = entry.get("full_path") or ""
        leaf = entry.get("leaf")
        if not leaf:
            leaf = full.rsplit(".", 1)[-1] if full else None
        saved_mods = entry.get("scope_modules")
        saved_key = (leaf, tuple(saved_mods[1:])) if (saved_mods and leaf) else None

        sig, status, note = None, None, ""
        cand = exact.get(full)
        if cand is not None:
            sig, status = cand, "OK_EXACT"
        elif saved_key is not None:
            cands = _dedup_signals(struct.get(saved_key, []))
            if len(cands) == 1:
                sig, status = cands[0], "OK_ADAPT"
                note = f"层级不同，按模块结构适配：{cands[0].full_path}"
            elif len(cands) > 1:
                status = "FAIL_AMBIG"
                show = [c.full_path for c in cands[:3]]
                more = "" if len(cands) <= 3 else f" 等 {len(cands)} 处"
                note = (f"模块结构相同的实例有 {len(cands)} 个、均含该信号"
                        f"（{'、'.join(show)}{more}），无法确定对应哪一个。")
            else:
                names = _dedup_signals(by_name.get(leaf, []))
                if not names:
                    status, note = "FAIL_NO_SUCH", "当前 VCD 中不存在该信号名。"
                else:
                    status = "FAIL_SCOPE"
                    show = [c.full_path for c in names[:3]]
                    more = "" if len(names) <= 3 else f" 等 {len(names)} 处"
                    note = (f"该信号只存在于模块结构不同的其它作用域"
                            f"（{'、'.join(show)}{more}），未自动匹配。")
        else:
            # 旧版会话没有模块链记录：只能按叶子名，全 VCD 唯一才敢配
            names = _dedup_signals(by_name.get(leaf, [])) if leaf else []
            if len(names) == 1:
                sig, status = names[0], "OK_ADAPT"
                note = f"旧版会话无层级记录，按全 VCD 唯一名称匹配：{names[0].full_path}"
            elif len(names) > 1:
                status = "FAIL_AMBIG"
                show = [c.full_path for c in names[:3]]
                more = "" if len(names) <= 3 else f" 等 {len(names)} 处"
                note = (f"同名信号存在于 {len(names)} 个作用域"
                        f"（{'、'.join(show)}{more}），无法确定对应哪一个。")
            else:
                status, note = "FAIL_NO_SUCH", "当前 VCD 中不存在该信号名。"

        if sig is not None:
            diffs = []
            if (isinstance(entry.get("width"), int) and sig.width is not None
                    and entry["width"] != sig.width):
                diffs.append(f"位宽 {entry['width']}→{sig.width}")
            if entry.get("type") and sig.type and entry["type"] != sig.type:
                diffs.append(f"类型 {entry['type']}→{sig.type}")
            if diffs:
                note = (note + "；" if note else "") + "，".join(diffs)

        results.append({"entry": entry, "status": status, "sig": sig, "note": note})
        if status == "OK_EXACT":
            n_exact += 1
        elif status == "OK_ADAPT":
            n_adapt += 1
        elif status:
            n_fail += 1

    summary = {"saved": len(entries), "exact": n_exact, "adapt": n_adapt, "fail": n_fail}
    return results, summary


#============================================================================
# RTL 静态分析纯函数 — Trace Driver / Trace Uses
# Pure helpers used by the "Trace Driver" / "Trace Uses" right-click actions.
#============================================================================

def _skip_paren_str(text: str, i: int) -> int | None:
    """Given text[i]=='(' return index just past the matching ')'."""
    depth = 0
    for j in range(i, len(text)):
        c = text[j]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return j + 1
    return None


def _strip_verilog_comments(text: str) -> str:
    """Remove // 与 /* */ 注释；保留换行符使行号/括号深度仍然对应原文。"""
    res = []
    n = len(text)
    i = 0
    in_block = False
    while i < n:
        c = text[i]
        if in_block:
            if text.startswith("*/", i):
                res.append("  ")
                i += 2
                in_block = False
                continue
            res.append(c if c == "\n" else " ")
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            if j == -1:
                break
            res.append("\n")
            i = j + 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            in_block = True
            res.append("  ")
            i += 2
            continue
        res.append(c)
        i += 1
    return "".join(res)


def _paren_depth_at(line: str, pos: int) -> int:
    """括号深度：统计 line[:pos] 里 '(' 与 ')' 的净差。"""
    d = 0
    for ch in line[:pos]:
        if ch == "(":
            d += 1
        elif ch == ")":
            d = max(0, d - 1)
    return d


def _assign_eq_pos(s: str) -> int | None:
    """continuous assign：返回语句里第一个单 '='（非 ==/<=/>=/!=）的位置。"""
    for i, ch in enumerate(s):
        if ch == "=":
            if i > 0 and s[i - 1] in "!<>=":
                continue
            if i + 1 < len(s) and s[i + 1] == "=":
                continue
            return i
    return None


def _proc_lhs(line: str, name: str) -> bool:
    """过程赋值左值：`name`（可带 [..] 位选）后跟 <= 或单 =，且位于括号深度 0。
    深度 >0 的 <= 多半是比较（if(a<=b)），不算赋值。"""
    for m in re.finditer(r"\b" + re.escape(name) + r"\b", line):
        if _paren_depth_at(line, m.start()) > 0:
            continue
        j = m.end()
        while j < len(line) and line[j] == "[":      # 跳过位选 [x:y]
            k = line.find("]", j)
            if k == -1:
                break
            j = k + 1
        while j < len(line) and line[j] in " \t":
            j += 1
        if j >= len(line):
            continue
        if line.startswith("<=", j):
            return True
        if line[j] == "=" and (j + 1 >= len(line) or line[j + 1] != "="):
            return True
    return False


# 声明/端口行（行首关键词）
_DECL_LINE_RE = re.compile(
    r"^\s*(input|output|inout|wire|reg|integer|real|time|"
    r"parameter|localparam|genvar|supply0|supply1)\b")
# 声明行里的非网络类型关键词：它们的初值是上电初值/常量定义，不是连续驱动
_DECL_NON_NET_RE = re.compile(r"\b(reg|integer|real|time|parameter|localparam|genvar)\b")


def _decl_is_netinit(line: str, name: str) -> bool:
    """声明行里的 `name` 是不是"网络声明即赋值"（`wire X = expr;`）—— 隐式连续驱动。

    只认网络类型（`reg/integer/parameter…` 不算）；按顶层逗号逐条 declarator 判，
    所以 `wire a = 1'b0, b = 1'b1;` 里 a、b 都算，而 `wire in_frame = (st_state == …)`
    里的 st_state（只在右边被引用）不算。
    """
    if not _DECL_LINE_RE.match(line):
        return False
    segs = _split_top_level(line.strip().rstrip(";"), ",")
    if not segs:
        return False
    eq0 = _assign_eq_pos(segs[0])
    type_part = segs[0][:eq0] if eq0 is not None else segs[0]
    if _DECL_NON_NET_RE.search(type_part):
        return False
    for seg in segs:
        eq = _assign_eq_pos(seg)
        if eq is None:
            continue                  # 纯声明，无初值
        ids = re.findall(r"[A-Za-z_]\w*", seg[:eq])
        if ids and ids[-1] == name:   # 被声明的名字就是 '=' 左边的最后一个标识符
            return True
    return False


def analyze_signal_refs(text: str, name: str) -> list[dict]:
    """逐行归类模块正文里 `name` 的所有出现（行号相对 text，1 起）。

    role 取值 / role values:
      driver:assign   continuous assign 左值
      driver:netinit  网络声明即赋值 (wire X = expr;) 左值 —— 隐式连续驱动
      driver:proc     过程赋值 (<= / =) 左值
      decl            声明/端口行 (input/output/wire/reg/…，无初值)
      use:sens        always @(posedge/negedge …)
      use:portlink    `.NAME(...)`  名字当被连接端口用
      use:inst        `.x(NAME …)`  NAME 作实例端口实参(连线/被驱动)
      use:logic       其它逻辑引用(RHS/条件等)
    """
    clean = _strip_verilog_comments(text)
    raw_lines = text.splitlines()
    clean_lines = clean.splitlines()
    if not name or not clean:
        return []
    name_re = re.compile(r"\b" + re.escape(name) + r"\b")
    decl_re = _DECL_LINE_RE
    sens_re = re.compile(r"\b(?:posedge|negedge)\b[^;\n]*?\b" + re.escape(name) + r"\b")
    portlink_re = re.compile(r"\.\s*" + re.escape(name) + r"\s*\(")
    instmap_re = re.compile(r"\.\s*\w+\s*\(")
    out = []
    for i, ln in enumerate(clean_lines, start=1):
        if not name_re.search(ln):
            continue
        raw = raw_lines[i - 1].strip() if i - 1 < len(raw_lines) else ln.strip()
        role = "use:logic"
        if decl_re.match(ln):
            # `wire X = expr;` 既是声明也是驱动（隐式连续赋值）—— 本项目组合逻辑
            # 大量用这种写法，若按纯声明丢掉，Trace Driver 会误报"未见明确驱动"、
            # Trace Uses 会漏掉这些行。
            role = "driver:netinit" if _decl_is_netinit(ln, name) else "decl"
        else:
            am = re.match(r"^\s*assign\b\s*(.*)$", ln)
            if am:
                eq = _assign_eq_pos(am.group(1))
                if eq is not None and name_re.search(am.group(1)[:eq]):
                    role = "driver:assign"
        if role == "use:logic" and _proc_lhs(ln, name):
            role = "driver:proc"
        if role == "use:logic" and sens_re.search(ln):
            role = "use:sens"
        if role == "use:logic" and portlink_re.search(ln):
            role = "use:portlink"
        if role == "use:logic" and instmap_re.search(ln):
            role = "use:inst"
        out.append({"line": i, "text": raw, "role": role})
    return out


def _split_top_level(text: str, sep: str) -> list[str]:
    """按顶层分隔符切分（忽略 ( ) [ ] { } 内部）。"""
    parts = []
    cur = []
    depth = 0
    for ch in text:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth = max(0, depth - 1)
        if ch == sep and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    return parts


def module_port_directions(text: str) -> dict[str, str]:
    """解析正文中第一个 module 的端口方向 {port: input|output|inout|None}。

    兼容 ANSI(端口在头部声明带方向) 与非 ANSI(端口名在头部、方向在体内 input a;)。
    """
    clean = _strip_verilog_comments(text)
    m = re.search(r"^\s*(?:module|macromodule)\s+\w+", clean, re.M)
    if not m:
        return {}
    i = m.end()
    while i < len(clean) and clean[i] in " \t\r\n":
        i += 1
    if i < len(clean) and clean[i] == "#":          # 参数块 #(…)
        k = clean.find("(", i)
        if k != -1:
            j = _skip_paren_str(clean, k)
            if j is not None:
                i = j
    while i < len(clean) and clean[i] in " \t\r\n":
        i += 1
    if i >= len(clean) or clean[i] != "(":
        return {}
    close = _skip_paren_str(clean, i)
    if close is None:
        return {}
    seg = clean[i + 1:close - 1]
    dirs: dict[str, str] = {}
    cur: str | None = None
    KEY = ("input", "output", "inout", "wire", "reg", "signed", "unsigned",
           "integer", "real", "time")
    for part in _split_top_level(seg, ","):
        part = part.strip()
        if not part:
            continue
        dm = re.search(r"\b(input|output|inout)\b", part)
        if dm:
            cur = dm.group(1)
        words = [w for w in re.findall(r"[A-Za-z_]\w*", part)
                 if w not in KEY]
        if not words:
            continue
        # 一个逗号 item 通常只含一个端口名；即便 `output reg [..] a`，
        # 过滤掉 reg/wire 等关键字后最后一个非关键字词就是端口名。
        dirs[words[-1]] = cur
    # 非 ANSI：体内 `input a, b;` 声明再补方向。必须只在头部 ')' 之后扫，
    # 否则 ANSI 头部的 `input wire x,` 会被当作非 ANSI 声明而整体覆盖方向。
    body_tail = clean[close:]
    for dm in re.finditer(r"(?m)^\s*(input|output|inout)\b([^;]*);", body_tail):
        d = dm.group(1)
        for w in re.findall(r"[A-Za-z_]\w*", dm.group(2)):
            if w not in KEY:
                dirs[w] = d
    return dirs


def module_region_of(text: str, mod_name: str) -> tuple[str | None, int]:
    """返回 (module 正文切片, 切片前已有多少行) — 正文内行号 + base = 文件绝对行号。"""
    m = re.search(r"(?m)^\s*(?:module|macromodule)\s+" + re.escape(mod_name) + r"\b", text)
    if not m:
        return (text, 0)                    # 找不到就退回整文件
    base = text[:m.start()].count("\n")
    em = re.search(r"(?m)^\s*endmodule\b", text[m.end():])
    end = m.end() + em.start() if em else len(text)
    return (text[m.start():end], base)


def find_instance_connects(text: str, mod: str, inst: str, port: str) -> list[dict]:
    """在文本里找 `mod inst ( .port(...) ... )` 实例的端口连接，返回:
    [{line, port, net}]  net 取实参里第一个标识符（忽略位选/拼接）。"""
    clean = _strip_verilog_comments(text)
    out = []
    start = 0
    pat = re.compile(r"\b" + re.escape(mod) + r"\s+" + re.escape(inst) + r"\b")
    while True:
        m = pat.search(clean, start)
        if not m:
            break
        j = m.end()
        while j < len(clean) and clean[j] in " \t\r\n":
            j += 1
        if j < len(clean) and clean[j] == "#":          # 参数 #(…) 块
            k = clean.find("(", j)
            if k != -1:
                after = _skip_paren_str(clean, k)
                if after is None:
                    break
                j = after
                while j < len(clean) and clean[j] in " \t\r\n":
                    j += 1
        if j >= len(clean) or clean[j] != "(":
            start = m.start() + 1
            continue
        seg_start = j + 1
        close = _skip_paren_str(clean, j)
        if close is None:
            break
        seg = clean[seg_start:close - 1]
        for pm in re.finditer(r"\.\s*(\w+)\s*\(", seg):
            if pm.group(1) != port:
                continue
            op = pm.end()                       # '(' 之后
            d = 1
            k = op
            while k < len(seg):
                c = seg[k]
                if c == "(":
                    d += 1
                elif c == ")":
                    d -= 1
                    if d == 0:
                        break
                k += 1
            expr = seg[op:k].strip()
            netm = re.search(r"[A-Za-z_]\w*", expr)
            net = netm.group(0) if netm else expr
            abs_char = seg_start + pm.start()
            line = clean[:abs_char].count("\n") + 1
            out.append({"line": line, "port": port, "net": net})
        start = m.start() + 1
    # 去重（同名实例可能被同模式多匹配）
    seen = set()
    dedup = []
    for e in out:
        key = (e["line"], e["port"], e["net"])
        if key not in seen:
            seen.add(key)
            dedup.append(e)
    return dedup


def iter_instance_blocks(text: str) -> list[dict]:
    """枚举正文里所有子模块实例及其端口映射（用于识别“实例输出在驱动某网络”）。

    Returns: [{mod, inst, hdr, ports:[(port, net, line)]}], line 1 起绝对行号。
    """
    clean = _strip_verilog_comments(text)
    SKIP = {
        "assign", "always", "initial", "if", "else", "for", "while", "case",
        "casex", "casez", "begin", "end", "module", "endmodule", "function",
        "task", "input", "output", "inout", "wire", "reg", "posedge", "negedge",
        "or", "parameter", "localparam", "genvar", "return", "repeat", "forever",
        "integer", "real",
    }
    pat = re.compile(
        r"(?m)^[ \t]*(\w+)[ \t]+"
        r"(?:\#[ \t]*\([^)]*\)[ \t]*)?"
        r"(\w+)[ \t]*\(")
    blocks = []
    for m in pat.finditer(clean):
        mod, inst = m.group(1), m.group(2)
        if mod in SKIP or inst in SKIP:
            continue
        oi = m.end() - 1                      # '(' index
        close = _skip_paren_str(clean, oi)
        if close is None:
            continue
        seg = clean[oi + 1:close - 1]
        ports = []
        for pm in re.finditer(r"\.\s*(\w+)\s*\(", seg):
            pname = pm.group(1)
            op = pm.end()                     # '(' 之后
            d = 1
            k = op
            while k < len(seg):
                c = seg[k]
                if c == "(":
                    d += 1
                elif c == ")":
                    d -= 1
                    if d == 0:
                        break
                k += 1
            expr = seg[op:k].strip()
            nm = re.search(r"[A-Za-z_]\w*", expr)
            net = nm.group(0) if nm else expr
            line = clean[:oi + 1 + pm.start()].count("\n") + 1
            ports.append((pname, net, line))
        blocks.append({"mod": mod, "inst": inst,
                       "hdr": clean[:m.start()].count("\n") + 1,
                       "ports": ports})
    return blocks


#============================================================================
# 位切片（bit slice）—— 纯函数 / bit-slice helpers (no Qt, unit-testable)
#============================================================================
#
# 「显示 rx_data[1] 的波形」= 从父信号的跳变里按位切出一条**派生信号**。
# 波形行模型里一切以字符串为键（`_displayed` / `_order` 里是 str | SignalGroup，
# 拖拽 / 分组 / 删除 / 复制 / 存盘全靠它），所以派生行同样是一个**合成字符串 key**
# （`父vcd_id[msb:lsb]`），不引入新对象类型 —— 行机制一行都不用改（见 bug.md B13）。

_BIT_VALID = "01xz"       # VCD 里位向量允许出现的字符（u/w/l/h/- 是强度扩展，这里当未知处理）


def parse_bit_spec(text: str) -> tuple[int, int] | None:
    """把用户输入解析成 (msb, lsb)：认 `1` / `[1]` / `7:4` / `[7:4]` / ` 3 : 0 `。

    msb < lsb 时自动交换（写成 `0:7` 也算对，用户想表达的就是 0..7）；
    空串 / 非数字 / 负数 → None（调用方负责报错）。
    """
    s = (text or "").strip().strip("[]").strip()
    if not s:
        return None
    try:
        if ":" in s:
            a, b = s.split(":", 1)
            msb, lsb = int(a.strip()), int(b.strip())
        else:
            msb = lsb = int(s)
    except ValueError:
        return None
    if msb < 0 or lsb < 0:
        return None
    return (msb, lsb) if msb >= lsb else (lsb, msb)


def value_to_bits(value: str, width: int) -> str | None:
    """把缓存里的值串还原成 width 位二进制串（**低位在右**，与 Verilog 一致）。

    缓存存的是 `format_value(raw, width)` 的输出（`vcd_analyzer.py:944`），实测形状：
      1-bit    → '0' / '1' / 'x' / 'z'（裸字符）
      多 bit   → "8'hC3" / "32'h0"（{宽度}'h{十六进制}）
      含 x/z   → 'bx '（`int()` 失败时原样返回的原始 VCD 串，**可能带尾空格**）
    短串补到 width：**最左字符是 x/z 才按 x/z 扩展，否则补 0**（与 `format_value` 对短二进制串
    的处理一致 —— 它是 `int(bits, 2)`，天然零扩展，父信号就是这么显示的）。实数 / 非法字符 → None。
    """
    v = (value or "").strip()
    if not v:
        return None
    if len(v) == 1:                       # 裸字符：整条向量都是这个字符
        return v.lower() * width if v.lower() in _BIT_VALID else None

    if "'" in v:                          # "8'hC3" / "'b1010"（省略位宽）
        _, rest = v.split("'", 1)
        if not rest:
            return None
        base_ch, digits = rest[0].lower(), rest[1:]
    else:                                 # "b1010"（VCD 原始二进制串）
        base_ch, digits = v[0].lower(), v[1:]

    def _digits_to_bits(digs: str, per: int, base: int) -> str | None:
        """按位展开：x/z 数字整段展开（x 在 hex 里 = 4 个 x），其余按进制转二进制。"""
        out = []
        for c in digs:
            cl = c.lower()
            if cl == "x":
                out.append("x" * per)
            elif cl == "z":
                out.append("z" * per)
            else:
                try:
                    out.append(format(int(cl, base), f"0{per}b"))
                except ValueError:
                    return None
        return "".join(out)

    if base_ch == "b":
        bits = digits
    elif base_ch == "h":
        bits = _digits_to_bits(digits, 4, 16)
    elif base_ch == "o":
        bits = _digits_to_bits(digits, 3, 8)
    elif base_ch == "d":
        try:
            bits = format(int(digits), "b")
        except ValueError:
            return None
    else:
        return None

    if not bits:
        return None
    bits = bits.lower()
    if any(c not in _BIT_VALID for c in bits):
        return None
    # 短值补到 width：最左是 x/z 就按 x/z 扩展，**否则补 0**（与 `format_value` 对
    # 短二进制串的处理一致 —— 它是 `int(bits, 2)`，天然零扩展，父信号就是这么显示的）；
    # 超宽的（VCD 里不该出现）按右锚定裁掉高位，与 `slice_bits` 的低位在右保持一致。
    if len(bits) < width:
        bits = bits.rjust(width, bits[0] if bits[0] in "xz" else "0")
    elif len(bits) > width:
        bits = bits[-width:]
    return bits


def slice_bits(bits: str, msb: int, lsb: int) -> str:
    """从二进制串里切出 [msb:lsb]（LSB 在右）。

    返回值的**形状**是给渲染层用的（本次最容易写错的地方，见 bug.md B13）：
      单 bit          → 裸 '0'/'1'/'x'/'z' —— `_draw_scalar_trace` 只认这个形状（它比较 ev_raw == '1'）
      整段全 x / 全 z → 裸 'x' / 'z'
      其余            → 'b' + 位串 —— `_draw_bus_trace` → `_format_value_radix` 认 'b' 前缀，
                        于是 Hex/Bin/Dec/Oct 切换白拿（段里夹 x/z 时它原样显示 'b1x0'，与父信号一致）
    """
    w = len(bits)
    seg = bits[w - 1 - msb: w - lsb]
    if msb == lsb:
        return seg
    uniq = set(seg)
    if uniq == {"x"}:
        return "x"
    if uniq == {"z"}:
        return "z"
    return "b" + seg


def slice_transitions(trans: list[tuple], width: int, msb: int, lsb: int) -> list[tuple]:
    """把父信号的整条跳变表切成 [msb:lsb] 的跳变表（时间戳直接复用父的 int 对象）。

    **位没变就不记**（相邻同值去重）：父信号变了不等于这一位变了 —— 32 位计数器的 bit31
    只有 4 次真实变化，照抄父表就是 670 条、渲染时每条都要 addLine/addRect（实测重绘
    1.6ms → 11ms）。去重只删值相同的点，任何时刻的取值函数不变，且**首条必须保留**：
    恒定不变的位去重后仍要留一条，否则 `_draw_signal_row` 的 `if not trans` 会把它画成
    红框 "no data"（静默错）。

    值解析不出来（实数等）时该点记成 'x'：**时间点一定要留住**，否则切片的时间轴会跟父信号错位。
    """
    out = []
    for ev_time, ev_value, _fmt in trans:
        bits = value_to_bits(ev_value, width)
        val = slice_bits(bits, msb, lsb) if bits is not None else "x"
        if out and out[-1][1] == val:
            continue
        out.append((ev_time, val, val))
    return out


#============================================================================
# WaveformDataCache — 波形数据缓存 / waveform transition data cache
#============================================================================

class WaveformDataCache:
    """预取和缓存信号的波形跳变数据。
    Pre-load and cache waveform transition data per signal.
    """

    def __init__(self, analyzer: VcdAnalyzer):
        self.analyzer = analyzer
        # vcd_id -> list of (time, raw_value, formatted_value) sorted by time
        self._transitions: dict[str, list[tuple]] = {}
        # 派生位切片：合成 key -> (父 vcd_id, msb, lsb) / 合成 SignalDef（见 bug.md B13）
        self._slices: dict[str, tuple] = {}
        self._slice_sigs: dict[str, SignalDef] = {}
        self.total_start = 0
        self.total_end = 0
        # Get time range from info
        try:
            info = analyzer.get_info()
            self.total_start = info.get("first_time", 0)
            self.total_end = info.get("last_time", 0)
        except Exception:
            pass

    def preload(self, signal_ids: list[str]):
        """预加载一组信号的所有跳变数据。
        Preload transition data for a set of signal VCD IDs.

        派生位切片的 key 在这里**自动换成它的父信号**去取数：片段本身没有 VCD 记录，
        它的数据是父信号切出来的（父数据换新后，它的所有切片跟着重切）。
        """
        # Build comma-separated glob from full paths（派生 key → 父 id 去重）
        # ⚠ 派生 key 的 full_path 绝不能进这个 glob：`match_signals` 把路径里的 `[` 当 fnmatch
        #   字符类（`vcd_analyzer.py:385`），`rx_data[7:4]` 会静默匹配到别的信号。一律先
        #   `slice_parent()` 换成父 id，再用 engine 查父的 full_path（见 bug.md B13）。
        id_to_path = {}
        for vid in signal_ids:
            if not isinstance(vid, str):
                continue
            real = self.slice_parent(vid) or vid          # 切片 → 父；真实 id 原样
            if real in id_to_path:
                continue
            sig = self.analyzer.engine.get_signal(real)
            if sig:
                id_to_path[real] = sig.full_path

        if id_to_path:
            glob_str = ",".join(id_to_path.values())
            try:
                events = self.analyzer.extract_transitions(
                    glob_str, start_time=0, end_time=None, max_changes=100000
                )
            except Exception:
                return

            # Group events by signal path
            by_path: dict[str, list[tuple]] = {}
            for ev in events:
                if ev.signal_path not in by_path:
                    by_path[ev.signal_path] = []
                by_path[ev.signal_path].append(
                    (ev.time, ev.new_value, ev.new_value)
                )

            # Store by vcd_id
            for rid, path in id_to_path.items():
                self._transitions[rid] = by_path.get(path, [])

            # 父数据换新了 → 它的每个切片都重切一遍（不然切片还停在旧数据上）
            for rid in id_to_path:
                self._rematerialize_slices_of(rid)

        # 查不到的 id 照旧记一张空表（保持原有语义：行照样在，只是没有数据）
        for vid in signal_ids:
            if isinstance(vid, str) and vid not in self._transitions:
                self._transitions[vid] = []

    def get_signal(self, vcd_id: str) -> SignalDef | None:
        """真实信号走 VCD 引擎；派生位切片返回合成的 SignalDef（name/width 都按切片算）。"""
        s = self._slice_sigs.get(vcd_id) if isinstance(vcd_id, str) else None
        return s if s is not None else self.analyzer.engine.get_signal(vcd_id)

    # ---- 位切片（派生信号）API ----

    def is_derived(self, vcd_id) -> bool:
        """这条 id 是不是派生出来的位切片（标签后缀 / 状态名 / Trace 都要区别对待）。"""
        return isinstance(vcd_id, str) and vcd_id in self._slice_sigs

    def slice_spec(self, vcd_id) -> tuple | None:
        """派生行 → (父 vcd_id, msb, lsb)；真实信号 → None。"""
        return self._slices.get(vcd_id) if isinstance(vcd_id, str) else None

    def slice_parent(self, vcd_id) -> str | None:
        """派生行 → 父 vcd_id（找不到父信号时用它回退）；真实信号 → None。"""
        spec = self.slice_spec(vcd_id)
        return spec[0] if spec else None

    def add_slice(self, parent_vcd_id: str, msb: int, lsb: int) -> str | None:
        """注册（已注册则复用）一条位切片，返回它的合成 key。

        位段非法 / 父信号不存在 / 父信号不是位向量（real / string）→ 返回 None，
        由调用方决定怎么报错。父数据已在缓存里时立刻切出切片数据。
        """
        parent = self.analyzer.engine.get_signal(parent_vcd_id) \
            if isinstance(parent_vcd_id, str) else None
        if parent is None or parent.width < 1:
            return None
        if not (0 <= lsb <= msb < parent.width):
            return None
        if str(getattr(parent, "type", "")).lower() in ("real", "string", "realtime"):
            return None

        key = self._make_slice_key(parent_vcd_id, msb, lsb)
        if key in self._slice_sigs:
            self._materialize_slice(key)          # 已注册：父数据可能刚更新，重切一次
            return key

        name = f"{parent.name}[{msb}]" if msb == lsb else f"{parent.name}[{msb}:{lsb}]"
        full = (f"{parent.full_path}[{msb}]" if msb == lsb
                else f"{parent.full_path}[{msb}:{lsb}]")
        self._slices[key] = (parent_vcd_id, msb, lsb)
        self._slice_sigs[key] = SignalDef(
            vcd_id=key, name=name, full_path=full,
            type=parent.type, width=msb - lsb + 1,
            scope_path=list(parent.scope_path),
        )
        self._materialize_slice(key)
        return key

    def _make_slice_key(self, parent_vcd_id: str, msb: int, lsb: int) -> str:
        """合成 key：`父id[msb:lsb]`（单 bit 为 `父id[msb]`）。同一段复用同一个 key；
        万一与真实 VCD id 撞车（理论上 id 也可以含 '['）就追加 #2/#3 兜底。"""
        for key, spec in self._slices.items():
            if spec == (parent_vcd_id, msb, lsb):
                return key                            # 同一段 → 幂等复用
        base = (f"{parent_vcd_id}[{msb}]" if msb == lsb
                else f"{parent_vcd_id}[{msb}:{lsb}]")
        key, n = base, 1
        while key in self._slice_sigs or self.analyzer.engine.get_signal(key) is not None:
            n += 1
            key = f"{base}#{n}"
        return key

    def _materialize_slice(self, key: str):
        """把父信号的跳变表切出来存进这个切片自己的表里（**物化**）。

        物化的好处：`get_visible` / `get_transitions` / 渲染全部零改动 —— 切片在缓存里
        就是一条普通信号。父还没取数时先不动（preload 时会被 `_rematerialize_slices_of` 补上）。
        """
        spec = self._slices.get(key)
        if not spec:
            return
        parent_id, msb, lsb = spec
        parent = self.analyzer.engine.get_signal(parent_id)
        trans = self._transitions.get(parent_id)
        if parent is None or trans is None:
            return
        self._transitions[key] = slice_transitions(trans, parent.width, msb, lsb)

    def _rematerialize_slices_of(self, parent_id: str):
        """父信号的跳变表更新后，重切它名下的所有切片。"""
        for key, spec in self._slices.items():
            if spec[0] == parent_id:
                self._materialize_slice(key)

    def get_transitions(self, vcd_id: str) -> list[tuple]:
        """Return all transitions for a signal: [(time, raw, formatted), ...]."""
        return self._transitions.get(vcd_id, [])

    def get_visible(self, vcd_id: str, t0: int, t1: int) -> list[tuple]:
        """Binary-search for transitions in [t0, t1]."""
        all_trans = self._transitions.get(vcd_id, [])
        if not all_trans:
            return []
        times = [t[0] for t in all_trans]
        lo = bisect.bisect_left(times, t0)
        hi = bisect.bisect_right(times, t1)
        # Include one transition before t0 for initial state
        if lo > 0:
            lo -= 1
        return all_trans[lo:hi]

    def remove(self, vcd_id: str):
        self._transitions.pop(vcd_id, None)

    def has(self, vcd_id: str) -> bool:
        return vcd_id in self._transitions


#============================================================================
# DesignTreePanel — 设计模块层级树 / design module hierarchy tree
#============================================================================

class DesignTreePanel(QWidget):
    """左上角面板：仅显示设计模块层级（不显示信号叶子节点）。
    Top-left panel: design module hierarchy only (no signal leaves).

    Double-click a module node → code panel loads its source file.
    Selection → signal panel shows that module's signals.
    """

    scope_selected = Signal(str)       # emits scope path string (e.g. "tb_rx_cdr.dut")
    module_selected = Signal(str, str)  # (scope_key, file path) for code navigation

    def __init__(self, parent=None):
        super().__init__(parent)
        self._analyzer: VcdAnalyzer | None = None
        self._resolver: ModuleResolver | None = None
        self._scope_signals: dict[str, list[SignalDef]] = {}   # scope_key → signals

        self._model = QStandardItemModel()
        self._model.setHorizontalHeaderLabels(["Module", "Signals"])

        # UI
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(2)

        self.tree = QTreeView()
        self.tree.setModel(self._model)
        self.tree.setHeaderHidden(False)
        self.tree.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.tree.setSelectionMode(QAbstractItemView.SingleSelection)
        self.tree.setContextMenuPolicy(Qt.CustomContextMenu)
        self.tree.setAnimated(True)
        self.tree.setIndentation(16)
        self.tree.header().setStretchLastSection(True)
        self.tree.header().resizeSection(0, 160)
        layout.addWidget(self.tree)

        # Connections
        self.tree.doubleClicked.connect(self._on_double_click)
        self.tree.selectionModel().selectionChanged.connect(self._on_selection_changed)

    def set_resolver(self, resolver: ModuleResolver):
        self._resolver = resolver

    def load_vcd(self, analyzer: VcdAnalyzer):
        """Build module hierarchy tree from VCD scopes.
        Only shows scope/block nodes — no individual signal leaves.
        """
        self._analyzer = analyzer
        self._model.removeRows(0, self._model.rowCount())
        self._scope_signals.clear()

        signals = analyzer.header.get("signals", [])
        if not signals:
            return

        # Group signals by their scope path
        top_name = signals[0].scope_path[0]
        scope_map: dict[str, list[SignalDef]] = {}

        for sig in signals:
            key = ".".join(sig.scope_path)
            if key not in scope_map:
                scope_map[key] = []
            scope_map[key].append(sig)

        self._scope_signals = scope_map

        # Identify scopes that have children (sub-scopes)
        parent_scopes: set[str] = set()
        for key in scope_map:
            parts = key.split(".")
            for d in range(len(parts) - 1):
                parent_scopes.add(".".join(parts[:d + 1]))

        # Build tree: only show scopes, no signal leaves
        root = self._model.invisibleRootItem()

        # Top-level item
        top_full = top_name
        top_item = self._build_module_node(top_full, top_name)
        root.appendRow([top_item, QStandardItem("")])

        # Find children scopes that are direct descendants of top
        child_scopes: dict[str, list[str]] = {}  # parent → [child_scopes]
        for key in scope_map:
            parts = key.split(".")
            if len(parts) >= 2:
                parent = ".".join(parts[:-1])
                if parent not in child_scopes:
                    child_scopes[parent] = set()
                child_scopes[parent].add(key)

        # Add first-level sub-scopes under top
        if top_full in child_scopes:
            for child_key in sorted(child_scopes[top_full]):
                child_name = child_key.split(".")[-1]
                child_item = self._build_module_node(child_key, child_name)
                top_item.appendRow([child_item, QStandardItem(str(len(scope_map.get(child_key, []))))])

                # Add deeper sub-scopes recursively
                if child_key in child_scopes:
                    for grandchild_key in sorted(child_scopes[child_key]):
                        gc_name = grandchild_key.split(".")[-1]
                        gc_item = self._build_module_node(grandchild_key, gc_name)
                        child_item.appendRow([gc_item, QStandardItem(str(len(scope_map.get(grandchild_key, []))))])

        self.tree.expandAll()

    def _build_module_node(self, scope_key: str, display_name: str) -> QStandardItem:
        """Create a tree node for a module/scope."""
        # Try to resolve the actual module name
        mod_name = display_name
        tooltip = f"Scope: {scope_key}"
        if self._resolver:
            resolved = self._resolver.resolve_module_name(display_name)
            if resolved != display_name:
                mod_name = f"{display_name} ({resolved})"
                tooltip += f"\nModule: {resolved}"
                src = self._resolver.resolve_file(display_name)
                if src:
                    tooltip += f"\nSource: {src}"

        item = QStandardItem(f"📁 {mod_name}")
        item.setEditable(False)
        item.setData(scope_key, Qt.UserRole)  # store full scope path
        item.setToolTip(tooltip)
        font = item.font()
        font.setBold(True)
        item.setFont(font)
        return item

    def _get_scope_key(self, proxy_index) -> str | None:
        """Get the scope path stored in a tree item."""
        if not proxy_index.isValid():
            return None
        item = self._model.itemFromIndex(proxy_index)
        if item:
            return item.data(Qt.UserRole)
        return None

    def _on_double_click(self, index):
        """Double-click → navigate code panel to module source (remembering its scope)."""
        scope_key = self._get_scope_key(index)
        if scope_key and self._resolver:
            filepath = self._resolver.resolve_file(scope_key)
            if not filepath:
                # resolve against the instance name (deep scopes / task scopes)
                inst_name = scope_key.split(".")[-1]
                filepath = self._resolver.resolve_file(inst_name)
            if filepath:
                self.module_selected.emit(scope_key, filepath)

    def _on_selection_changed(self):
        """Selection changed → tell signal panel what scope is selected."""
        idxs = self.tree.selectionModel().selectedIndexes()
        if idxs:
            scope_key = self._get_scope_key(idxs[0])
            if scope_key:
                self.scope_selected.emit(scope_key)


#============================================================================
# ModuleSignalPanel — 选中模块的信号列表 / signals in selected module
#============================================================================

class ModuleSignalPanel(QWidget):
    """左上角第二面板：显示当前选中模块的所有可调试信号。
    Second panel from left: shows all debuggable signals in the selected module.

    Two-column display: Signal Name [width] | Type
    Double-click a signal → add it to waveform.
    """

    signal_add_requested = Signal(list)    # emits list of vcd_ids
    signal_selected = Signal(object)       # emits SignalDef or None
    trace_driver_requested = Signal(str)   # vcd_id → Trace Driver (跳驱动代码)
    trace_uses_requested = Signal(str)     # vcd_id → Trace Uses (列到日志)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._all_signals: dict[str, list[SignalDef]] = {}  # scope_key → signals
        self._current_scope: str = ""
        self._current_sigs: list[SignalDef] = []  # currently displayed signals

        # Data model: two columns
        self._model = QStandardItemModel()
        self._model.setHorizontalHeaderLabels(["Signal", "Type"])
        self._proxy = QSortFilterProxyModel()
        self._proxy.setSourceModel(self._model)
        self._proxy.setFilterKeyColumn(0)
        self._proxy.setRecursiveFilteringEnabled(True)
        self._item_to_sig: dict[str, SignalDef] = {}  # model_path → SignalDef

        # UI
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(2)

        # Header label
        self.header_label = QLabel("Signals (select a module)")
        self.header_label.setStyleSheet(
            "font-weight: bold; padding: 3px 6px; background: #F0F0F0; "
            "border-bottom: 1px solid #D0D0D0; font-size: 11px;"
        )
        layout.addWidget(self.header_label)

        # Search box
        self.search_box = QLineEdit()
        self.search_box.setPlaceholderText("Filter signals...")
        self.search_box.setClearButtonEnabled(True)
        layout.addWidget(self.search_box)

        # Signal table (TreeView with 2 columns)
        self.tree = QTreeView()
        self.tree.setModel(self._proxy)
        self.tree.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.tree.setSelectionMode(QAbstractItemView.ExtendedSelection)
        self.tree.setContextMenuPolicy(Qt.CustomContextMenu)
        self.tree.setAlternatingRowColors(True)
        self.tree.setRootIsDecorated(False)
        self.tree.setItemsExpandable(False)
        self.tree.setIndentation(0)
        self.tree.header().setStretchLastSection(True)
        self.tree.header().resizeSection(0, 160)
        self.tree.setStyleSheet("""
            QTreeView { border: none; }  /* font via QFont/pt (Settings) — a QSS font-size here would override it */
            QTreeView::item { padding: 2px 6px; }
            QTreeView::item:selected { background: #0078D4; color: white; }
            QTreeView::item:hover { background: #E8F0FE; }
            QHeaderView::section {
                background-color: #F5F5F5; border: none;
                border-bottom: 1px solid #D0D0D0; border-right: 1px solid #E0E0E0;
                padding: 3px 6px; font-size: 10px; font-weight: bold; color: #555;
            }
        """)
        layout.addWidget(self.tree)

        # Connections
        self.search_box.textChanged.connect(self._on_search)
        self.tree.doubleClicked.connect(self._on_double_click)
        self.tree.customContextMenuRequested.connect(self._on_context_menu)
        self.tree.selectionModel().selectionChanged.connect(self._on_selection_changed)

    def load_vcd(self, analyzer: VcdAnalyzer):
        """Index all signals by scope path."""
        self._all_signals.clear()
        signals = analyzer.header.get("signals", [])
        for sig in signals:
            key = ".".join(sig.scope_path)
            if key not in self._all_signals:
                self._all_signals[key] = []
            self._all_signals[key].append(sig)

    def show_scope(self, scope_key: str):
        """Display all signals in the given scope as a two-column table."""
        self._current_scope = scope_key
        self._model.removeRows(0, self._model.rowCount())
        self._item_to_sig.clear()

        sigs = self._all_signals.get(scope_key, [])
        if not sigs:
            # Try partial match (sub-scopes)
            for key, slist in self._all_signals.items():
                if key.startswith(scope_key + "."):
                    sigs.extend(slist)
            if not sigs:
                top = scope_key.split(".")[0]
                sigs = self._all_signals.get(top, [])
                scope_key = top

        self._current_sigs = sigs
        scope_name = scope_key.split(".")[-1] if "." in scope_key else scope_key
        self.header_label.setText(f"📋 {scope_name}  ({len(sigs)} signals)")

        for sig in sigs:
            # Column 0: signal name + bit width
            if sig.width > 1:
                name_text = f"{sig.name}  [{sig.width - 1}:0]"
            else:
                name_text = sig.name

            name_item = QStandardItem(name_text)
            name_item.setEditable(False)
            name_item.setToolTip(
                f"{sig.full_path}\nType: {sig.type}, Width: {sig.width}"
            )

            # Column 1: type
            type_item = QStandardItem(sig.type)
            type_item.setEditable(False)
            # Color-code types
            type_colors = {
                "wire": QColor("#006600"),
                "reg": QColor("#CC6600"),
                "parameter": QColor("#880088"),
                "localparam": QColor("#880088"),
                "real": QColor("#0088AA"),
                "integer": QColor("#AA4400"),
            }
            if sig.type in type_colors:
                type_item.setForeground(type_colors[sig.type])

            self._model.appendRow([name_item, type_item])

            # Store mapping for double-click / selection
            self._item_to_sig[self._model_path(name_item.index())] = sig

    @staticmethod
    def _model_path(index) -> str:
        """Build a stable string key from a model index."""
        parts = []
        idx = index
        while idx.isValid():
            parts.append(str(idx.row()))
            parts.append(str(idx.column()))
            idx = idx.parent()
        return "/".join(reversed(parts))

    def _find_sig_for_index(self, proxy_index) -> SignalDef | None:
        """Map a proxy model index back to SignalDef."""
        if not proxy_index.isValid():
            return None
        source_idx = self._proxy.mapToSource(proxy_index)
        if source_idx.column() != 0:
            source_idx = source_idx.siblingAtColumn(0)
        return self._item_to_sig.get(self._model_path(source_idx))

    def _on_search(self, text: str):
        """Filter the signal table."""
        self._proxy.setFilterFixedString(text)

    def _on_double_click(self, index):
        """Double-click → add signal to waveform."""
        sig = self._find_sig_for_index(index)
        if sig:
            self.signal_add_requested.emit([sig.vcd_id])

    def _on_selection_changed(self):
        """Emit selected signal for code cross-linking."""
        idxs = self.tree.selectionModel().selectedIndexes()
        if idxs:
            sig = self._find_sig_for_index(idxs[0])
            if sig:
                self.signal_selected.emit(sig)
                return
        self.signal_selected.emit(None)

    def _on_context_menu(self, pos):
        """Right-click context menu."""
        idxs = self.tree.selectionModel().selectedIndexes()
        # 按 full_path 去重 — VCD 可能给不同作用域的同名信号复用同一 id，vcd_id 不能当唯一键
        seen: set[str] = set()
        sigs: list[SignalDef] = []
        for idx in idxs:
            sig = self._find_sig_for_index(idx)
            if sig and sig.full_path not in seen:
                seen.add(sig.full_path)
                sigs.append(sig)

        if not sigs:
            return

        vcd_ids = [s.vcd_id for s in sigs]
        menu = QMenu(self)
        if len(sigs) == 1:
            add_action = menu.addAction("➕ Add to Waveform")
            add_action.triggered.connect(lambda: self.signal_add_requested.emit(vcd_ids))
        else:
            menu.addAction(f"{len(sigs)} signals selected").setEnabled(False)
            menu.addSeparator()
            add_all = menu.addAction(f"📦 Add ALL {len(sigs)} to Waveform")
            add_all.triggered.connect(lambda: self.signal_add_requested.emit(vcd_ids))

        # Trace Driver / Trace Uses — 仅单选且无歧义时提供（trace 按 full_path 追溯）
        if len(sigs) == 1:
            menu.addSeparator()
            _fp = sigs[0].full_path
            act_tr = menu.addAction("🔍 Trace Driver（追溯驱动源码）")
            act_tr.triggered.connect(
                lambda checked=False, v=_fp: self.trace_driver_requested.emit(v))
            act_tu = menu.addAction("📖 Trace Uses（在日志列出使用它的行）")
            act_tu.triggered.connect(
                lambda checked=False, v=_fp: self.trace_uses_requested.emit(v))

        # "Add all signals in this module"
        all_vids = [s.vcd_id for s in self._current_sigs]
        if len(all_vids) > len(vcd_ids):
            menu.addSeparator()
            add_module = menu.addAction(
                f"📦 Add ALL signals in this module ({len(all_vids)})"
            )
            font = add_module.font()
            font.setBold(True)
            add_module.setFont(font)
            add_module.triggered.connect(lambda: self.signal_add_requested.emit(all_vids))

        menu.exec(self.tree.viewport().mapToGlobal(pos))

    def get_selected_vcd_ids(self) -> list[str]:
        """Return selected signal vcd_ids."""
        result = []
        for idx in self.tree.selectionModel().selectedIndexes():
            if idx.column() == 0:
                sig = self._find_sig_for_index(idx)
                if sig:
                    result.append(sig.vcd_id)
        return result


#============================================================================
# VerilogHighlighter — Verilog 语法高亮 / syntax highlighting
#============================================================================

class VerilogHighlighter(QSyntaxHighlighter):
    """Verilog/SystemVerilog 语法高亮器。"""

    # Patterns: (regex, format)
    KEYWORDS = [
        "module", "endmodule", "input", "output", "inout", "wire", "reg",
        "integer", "real", "parameter", "localparam", "assign", "always",
        "posedge", "negedge", "begin", "end", "if", "else", "case", "endcase",
        "default", "for", "function", "endfunction", "task", "endtask",
        "generate", "endgenerate", "genvar", "timescale",
    ]

    def __init__(self, parent=None):
        super().__init__(parent)
        self._formats: dict[str, QTextCharFormat] = {}

        # Keywords
        kw_fmt = QTextCharFormat()
        kw_fmt.setForeground(QColor("#0000CC"))
        kw_fmt.setFontWeight(QFont.Bold)
        self._formats["keyword"] = kw_fmt
        kw_pattern = r"\b(" + "|".join(self.KEYWORDS) + r")\b"
        self._rules = [(re.compile(kw_pattern), "keyword")]

        # Numbers
        num_fmt = QTextCharFormat()
        num_fmt.setForeground(QColor("#CC6600"))
        self._formats["number"] = num_fmt
        self._rules.append((re.compile(r"\b\d+'[bhBH][0-9a-fA-FxXzZ_?]+\b"), "number"))
        self._rules.append((re.compile(r"\b\d+(\.\d+)?\b"), "number"))

        # Strings
        str_fmt = QTextCharFormat()
        str_fmt.setForeground(QColor("#008800"))
        self._formats["string"] = str_fmt
        self._rules.append((re.compile(r'"[^"]*"'), "string"))

        # Comments
        cmt_fmt = QTextCharFormat()
        cmt_fmt.setForeground(QColor("#888888"))
        cmt_fmt.setFontItalic(True)
        self._formats["comment"] = cmt_fmt
        self._rules.append((re.compile(r"//[^\n]*"), "comment"))
        self._rules.append((re.compile(r"/\*[\s\S]*?\*/"), "comment"))

        # Preprocessor
        pp_fmt = QTextCharFormat()
        pp_fmt.setForeground(QColor("#880088"))
        self._formats["preprocessor"] = pp_fmt
        self._rules.append((re.compile(r"`\w+"), "preprocessor"))

    def highlightBlock(self, text: str):
        for pattern, fmt_name in self._rules:
            fmt = self._formats[fmt_name]
            for match in pattern.finditer(text):
                start, end = match.span()
                self.setFormat(start, end - start, fmt)


#============================================================================
# CodeViewerPanel — RTL 源码查看 / RTL source code viewer
#============================================================================

class LineNumberArea(QWidget):
    """行号区域 / line number gutter."""

    def __init__(self, panel):
        super().__init__(panel.editor)
        self.panel = panel

    def sizeHint(self):
        return self.panel._line_number_size()

    def paintEvent(self, event):
        self.panel._paint_line_numbers(event)


# 源码里可当信号用的标识符：单名 或 点分层次路径（u_dut.rx_bit）
IDENT_PATH_RE = re.compile(r'^[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*$')
# 层次路径左右扩展用的字符集（点分外的一切都断开，含换行）
PATH_CHARS = set("abcdefghijklmnopqrstuvwxyz"
                 "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.")
# 选区/扩展出的词两端允许附带的标点（拖选常带上分号/括号）
IDENT_TRIM = " \t;,()"


class CodeViewerPanel(QWidget):
    """右上角面板：RTL 源码查看器。
    Top-right panel: RTL source code viewer with syntax highlighting.

    Ctrl+Click on a signal name in source → add to waveform.
    """

    signal_add_requested = Signal(list)  # emits list of vcd_ids
    bit_slice_add_requested = Signal(str, int, int)  # (父 vcd_id, msb, lsb) → 加一条位切片
    trace_driver_requested = Signal(str)  # vcd_id → Trace Driver
    trace_uses_requested = Signal(str)    # vcd_id → Trace Uses

    def __init__(self, parent=None):
        super().__init__(parent)
        self._current_file: str = ""
        self._rtl_files: list[str] = []

        # Signal name → [vcd_id, ...] mapping (built from VCD)
        self._name_to_ids: dict[str, list[str]] = {}
        self._vcd_signals: list[SignalDef] = []
        # vcd_id → SignalDef / distinct scope paths, built in set_signal_index()
        self._id_to_sig: dict[str, SignalDef] = {}
        self._scope_paths: set[tuple[str, ...]] = set()

        # VCD scope context: which module instance the current file belongs to.
        # When double/Ctrl-click adds a signal, matches are restricted to this
        # subtree so one variable does not flood the wave window.
        self._scope_context: str | None = None
        self._resolver: ModuleResolver | None = None
        self._decl_module: str | None = None   # module declared by current file

        # Single-click module navigation state (single-vs-double disambiguation)
        self._nav_pending_word: str | None = None
        self._nav_pending_line: str | None = None
        self._suppress_nav = False
        self._ignore_next_release = False

        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(2)

        # Hint label
        self.hint_label = QLabel("Ctrl+Click signal name → add to waveform")
        self.hint_label.setStyleSheet(
            "color: #888; font-size: 10px; padding: 1px 4px;"
        )
        layout.addWidget(self.hint_label)

        # File selector
        top_bar = QHBoxLayout()
        top_bar.addWidget(QLabel("File:"))
        self.file_combo = QComboBox()
        self.file_combo.setMinimumWidth(200)
        self.file_combo.setSizeAdjustPolicy(QComboBox.AdjustToContents)
        top_bar.addWidget(self.file_combo, 1)
        layout.addLayout(top_bar)

        # Editor
        self.editor = QPlainTextEdit()
        self.editor.setReadOnly(True)
        self.editor.setFont(QFont("Menlo", 15))   # 默认字号：人眼舒适的代码窗口字号
        self.editor.setLineWrapMode(QPlainTextEdit.NoWrap)
        self.editor.setTabStopDistance(32)
        self.editor.setContextMenuPolicy(Qt.NoContextMenu)  # we handle right-click ourselves
        self.editor.setToolTip(
            "Ctrl+Click or Double-click on a signal name → add to waveform\n"
            "Single-click a module name → jump to its definition / instantiation\n"
            "Right-click → show signal context menu"
        )
        # Install event filter on the editor's viewport for click detection
        self.editor.viewport().installEventFilter(self)

        # Line number area
        self.line_area = LineNumberArea(self)
        self.editor.blockCountChanged.connect(self._update_line_area_width)
        self.editor.updateRequest.connect(self._update_line_area)
        self._update_line_area_width()

        # Syntax highlighter
        self.highlighter = VerilogHighlighter(self.editor.document())

        layout.addWidget(self.editor)

        # Connections
        self.file_combo.currentIndexChanged.connect(self._on_file_changed)

    def _line_number_size(self):
        digits = max(1, len(str(self.editor.blockCount())))
        fm = QFontMetrics(self.editor.font())
        return 8 + fm.horizontalAdvance('9') * digits

    def _update_line_area_width(self):
        self.editor.setViewportMargins(self._line_number_size(), 0, 0, 0)

    def _update_line_area(self, rect, dy):
        if dy:
            self.line_area.scroll(0, dy)
        else:
            self.line_area.update(0, rect.y(), self.line_area.width(), rect.height())
        if rect.contains(self.editor.viewport().rect()):
            self._update_line_area_width()

    def _paint_line_numbers(self, event):
        painter = QPainter(self.line_area)
        painter.fillRect(event.rect(), QColor("#F0F0F0"))

        block = self.editor.firstVisibleBlock()
        block_num = block.blockNumber() + 1
        top = self.editor.blockBoundingGeometry(block).translated(
            self.editor.contentOffset()).top()
        bottom = top + self.editor.blockBoundingRect(block).height()
        fm = QFontMetrics(self.editor.font())

        while block.isValid() and top <= event.rect().bottom():
            if block.isVisible() and bottom >= event.rect().top():
                number = str(block_num)
                painter.setPen(QColor("#999999"))
                painter.drawText(
                    0, int(top), self.line_area.width() - 4,
                    fm.height(), Qt.AlignRight | Qt.AlignVCenter, number
                )
            block = block.next()
            top = bottom
            bottom = top + self.editor.blockBoundingRect(block).height()
            block_num += 1

        painter.end()

    def resizeEvent(self, event):
        super().resizeEvent(event)
        cr = self.editor.contentsRect()
        self.line_area.setGeometry(
            QRect(cr.left(), cr.top(), self._line_number_size(), cr.height())
        )

    def find_rtl_files(self, base_dir: str):
        """扫描目录下所有 .v 文件 / Find all .v files under base_dir.

        可多次调用累积扫描多个目录 (src/ + tests/ + VCD 所在目录),
        这样 testbench (如 sim/cdr/tb_cdr.v) 也能进入文件下拉列表。"""
        if not base_dir or not os.path.isdir(base_dir):
            return
        for root, dirs, files in os.walk(base_dir):
            for f in files:
                if f.endswith(".v") or f.endswith(".sv"):
                    fp = os.path.join(root, f)
                    if fp not in self._rtl_files:
                        self._rtl_files.append(fp)
        self._rtl_files.sort()
        self.file_combo.clear()
        for f in self._rtl_files:
            self.file_combo.addItem(os.path.basename(f), f)

    def load_file(self, filepath: str):
        """加载并显示文件 / Load and display a source file (drops scope context)."""
        self._scope_context = None
        self._load_file_impl(filepath)

    def open_module_source(self, scope_key: str, filepath: str):
        """Load a module instance's source and remember that VCD scope, so later
        Ctrl+Click / double-click on a signal only adds that module's signal."""
        self._load_file_impl(filepath)
        self._scope_context = scope_key

    def set_resolver(self, resolver: ModuleResolver | None):
        self._resolver = resolver

    def _load_file_impl(self, filepath: str):
        if not filepath or not os.path.isfile(filepath):
            return
        self._current_file = filepath
        with open(filepath, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
        self.editor.setPlainText(content)
        m = re.search(r'(?m)^\s*(?:module|macromodule)\s+(\w+)', content)
        self._decl_module = m.group(1) if m else None
        # Update combo
        for i in range(self.file_combo.count()):
            if self.file_combo.itemData(i) == filepath:
                self.file_combo.blockSignals(True)
                self.file_combo.setCurrentIndex(i)
                self.file_combo.blockSignals(False)
                break

    def _on_file_changed(self, idx):
        if idx >= 0:
            self.load_file(self.file_combo.itemData(idx))

    # ---- Signal index for Ctrl+Click / 信号索引，支持 Ctrl+点击 ----

    def set_signal_index(self, signals: list[SignalDef]):
        """构建信号名→VCD ID 映射，用于 Ctrl+Click 添加信号。
        Build word->signal mapping for Ctrl+Click to add signals.
        """
        self._vcd_signals = signals
        self._id_to_sig = {sig.vcd_id: sig for sig in signals}
        self._scope_paths = {tuple(sig.scope_path) for sig in signals}
        self._name_to_ids.clear()
        for sig in signals:
            name = sig.name.lower()
            if name not in self._name_to_ids:
                self._name_to_ids[name] = []
            self._name_to_ids[name].append(sig.vcd_id)
        # Also index full paths
        for sig in signals:
            self._name_to_ids[sig.full_path.lower()] = [sig.vcd_id]

    def _word_under_cursor(self, cursor_pos) -> str | None:
        """Get the Verilog identifier word at the given cursor position."""
        tc = self.editor.cursorForPosition(cursor_pos)
        tc.select(QTextCursor.WordUnderCursor)
        word = tc.selectedText().strip()
        # Filter: only keep Verilog identifiers (alphanumeric + _)
        if word and re.match(r'^[a-zA-Z_]\w*$', word):
            return word
        return None

    def _menu_word_at(self, pos) -> str | None:
        """右键菜单的目标标识符（优先级从高到低）：
        1) 编辑器里已选中的标识符/点分路径（且右键落在选区内）；
        2) 光标下的点分路径（如 tb.u_dut.rx_bit）——能把同名信号缩小到一条；
        3) 光标下的单个单词。
        """
        sel = self._selected_identifier_at(pos)
        if sel:
            return sel
        path = self._path_word_at(pos)
        if path and self._sig_candidates_for_word(path):
            return path
        return self._word_under_cursor(pos)

    def _selected_identifier_at(self, pos) -> str | None:
        """右键点落在当前选区内且选区内容是一个标识符/点分路径时返回它。"""
        cur = self.editor.textCursor()
        if not cur.hasSelection():
            return None
        p = self.editor.cursorForPosition(pos).position()
        if not (cur.selectionStart() <= p <= cur.selectionEnd()):
            return None
        # 跨行选区在 Qt 里用段落分隔符 U+2029 拼接 → 换成换行，必然不是标识符
        sel = cur.selectedText().replace("\u2029", "\n").strip(IDENT_TRIM)
        return sel if IDENT_PATH_RE.match(sel) else None

    def _path_word_at(self, pos) -> str | None:
        """把光标下的单词左右扩展成点分路径（u_dut.rx_bit），非路径则返回单词本身。"""
        text = self.editor.toPlainText()
        p = self.editor.cursorForPosition(pos).position()
        if not (0 <= p < len(text)):
            return None
        left = p
        while left > 0 and text[left - 1] in PATH_CHARS:
            left -= 1
        right = p
        while right < len(text) and text[right] in PATH_CHARS:
            right += 1
        word = text[left:right].strip(IDENT_TRIM + ".")
        return word if IDENT_PATH_RE.match(word) else None

    def _find_signals_for_word(self, word: str) -> list[str]:
        """Find all VCD signal IDs matching the given word (deduplicated)."""
        wl = word.lower()
        # Direct name match
        if wl in self._name_to_ids:
            return list(dict.fromkeys(self._name_to_ids[wl]))  # dedup
        # Try partial path match (e.g., "dut.state" → "tb_rx_cdr.dut.state")
        seen: set[str] = set()
        matches = []
        for full_path, ids in self._name_to_ids.items():
            if full_path.endswith("." + wl) or ("." + wl + ".") in full_path:
                for vid in ids:
                    if vid not in seen:
                        seen.add(vid)
                        matches.append(vid)
        return matches

    def eventFilter(self, obj, event):
        """捕获编辑器视口事件。
        - Ctrl+Click / Double-click: 把单词当信号加到波形（限定当前模块）
        - 单击模块名: 跳到其定义 / 回到例化处（与双击区分，不抢双击）
        - Right-click: 弹出上下文菜单选择添加
        """
        from PySide6.QtCore import QEvent
        if obj is self.editor.viewport():
            if event.type() == QEvent.MouseButtonPress:
                pos = event.pos()
                word = self._word_under_cursor(pos)

                if event.button() == Qt.LeftButton and \
                        (event.modifiers() & Qt.ControlModifier):
                    # Ctrl+Click → direct add
                    if word:
                        self._add_word_signals(word)
                    self._ignore_next_release = True
                    return True
                elif event.button() == Qt.LeftButton:
                    # fresh normal click → prepare for possible single-click nav
                    self._ignore_next_release = False
                elif event.button() == Qt.RightButton:
                    self._show_signal_menu(event.globalPos(),
                                           self._menu_word_at(event.pos()))
                    return True

            elif event.type() == QEvent.MouseButtonRelease:
                if event.button() == Qt.LeftButton and not (
                        event.modifiers() & (Qt.ControlModifier | Qt.ShiftModifier |
                                             Qt.AltModifier | Qt.MetaModifier)):
                    if self._ignore_next_release:
                        self._ignore_next_release = False
                    # drag-to-select 结束后不触发模块导航
                    elif not self.editor.textCursor().hasSelection():
                        word = self._word_under_cursor(event.pos())
                        if word:
                            line = self.editor.cursorForPosition(event.pos()).block().text()
                            self._schedule_module_nav(word, line)

            elif event.type() == QEvent.MouseButtonDblClick:
                # Double-click → direct add (without Ctrl); cancel pending nav
                self._suppress_nav = True
                self._ignore_next_release = True
                pos = event.pos()
                word = self._word_under_cursor(pos)
                if word:
                    self._add_word_signals(word)
                return True

        return super().eventFilter(obj, event)

    # ---- scoped signal add (bug #1) ----
    def _add_word_signals(self, word: str):
        """双击/Ctrl+Click：只在“当前代码文件对应模块”内找同名信号加波形。

        Restrict matches to the current module's scope subtree so a common leaf
        name (e.g. cyc/bit_cnt in every tb task) no longer floods the wave window.
        Not found in-module → fall back to global; ambiguous → picker menu.
        """
        ids = list(dict.fromkeys(self._name_to_ids.get(word.lower(), [])))
        if not ids:
            self._set_hint(f"✗ '{word}' not found in VCD signals", ok=False)
            return

        def depth(v):
            s = self._id_to_sig.get(v)
            return len(s.scope_path) if s else (1 << 20)

        ctx = self._scope_context or self._derive_context_from_file()
        if ctx:
            pool = [v for v in ids
                    if (s := self._id_to_sig.get(v)) and self._scope_matches(s.scope_path, ctx)]
            if not pool:
                pool = ids[:]      # not in this module → fall back to whole design
        else:
            pool = ids[:]

        pool.sort(key=depth)
        min_d = depth(pool[0])
        chosen = [v for v in pool if depth(v) == min_d]   # 最浅 = 本模块自己的声明
        if len(chosen) == 1:
            self.signal_add_requested.emit(chosen)
            sig = self._id_to_sig.get(chosen[0])
            label = sig.full_path if sig else word
            self._set_hint(f"✓ {word} → {label}")
        else:
            self._show_pick_signal_menu(pool, word)

    def _set_hint(self, text: str, ok: bool = True):
        self.hint_label.setText(text)
        color = "#228B22" if ok else "#CC0000"
        self.hint_label.setStyleSheet(
            f"color: {color}; font-size: 10px; padding: 1px 4px;"
        )

    def _show_pick_signal_menu(self, vcd_ids: list[str], word: str):
        """Ambiguous name → let the user pick one exact signal (never batch-add)."""
        menu = QMenu(self.editor)
        h = menu.addAction(f"'{word}' — {len(vcd_ids)} match(es), pick one:")
        h.setEnabled(False)
        menu.addSeparator()
        for vid in vcd_ids:
            info = self._get_signal_info(vid) or vid
            act = menu.addAction(f"  {info}")
            act.triggered.connect(lambda checked=False, v=vid:
                                  self.signal_add_requested.emit([v]))
        menu.exec(QCursor.pos())

    @staticmethod
    def _scope_matches(scope_path, ctx: str | None) -> bool:
        """True if scope_path is inside the '.'-joined scope context (or no ctx)."""
        if not ctx:
            return True
        parts = ctx.split(".")
        return (len(scope_path) >= len(parts)
                and tuple(scope_path[:len(parts)]) == tuple(parts))

    def _derive_context_from_file(self) -> str | None:
        """Find which VCD module-instance scope owns the currently open file.
        Returns None when ambiguous / unknown; then global matching is used."""
        resolver, cur = self._resolver, self._current_file
        if resolver is None or not cur or not self._scope_paths:
            return None
        abscur = os.path.abspath(cur)
        hits: set[str] = set()
        for sp in self._scope_paths:
            for i in range(1, len(sp) + 1):
                leaf = sp[i - 1]
                fp = resolver.resolve_file(leaf)
                if fp and os.path.abspath(fp) == abscur:
                    hits.add(".".join(sp[:i]))
                    break
        return next(iter(hits)) if len(hits) == 1 else None

    # ---- single-click module navigation (bug #4) ----
    def _schedule_module_nav(self, word: str, line: str):
        self._suppress_nav = False
        self._nav_pending_word = word
        self._nav_pending_line = line
        QTimer.singleShot(QApplication.doubleClickInterval() + 50,
                          self._run_module_nav)

    def _run_module_nav(self):
        if self._suppress_nav:
            self._suppress_nav = False
            return
        word, line = self._nav_pending_word, self._nav_pending_line
        self._nav_pending_word = None
        if not word:
            return
        target = self._resolve_module_nav(word, line)
        if not target:
            return
        kind, mod = target
        if kind == "define":
            self._open_module_definition(mod)
        elif kind == "callers":
            self._jump_to_callers(mod)

    def _resolve_module_nav(self, word: str, line: str):
        """Decide what single-click on a word should navigate to.
        ('callers', mod)  — clicking the module header of the file's own module
        ('define',  mod)  — clicking a module type/instance on an instantiation line
        """
        if self._resolver is None:
            return None
        # module header of the module declared by the CURRENT file → back to callers
        if self._decl_module == word and re.match(r'^\s*(?:module|macromodule)\s+\w+', line):
            return ("callers", word)

        # 例化行的两个 token 按位置区分：type 是模块名、inst 是例化名。
        # 不能靠 resolve_file(word) 判断是否“已知”——它对例化名同样能解析到源文件
        # （instance→module→file），会把例化名误判成模块名。
        modules = self._resolver.all_modules()
        m = re.match(r'^\s*(\w+)\s+(?:#\s*\([^)]*\)\s*)?(\w+)\s*\(', line)
        if m:
            if word == m.group(1):            # 点到模块 type 本身
                if word in modules:
                    return ("define", word)
                return None
            if word == m.group(2):            # 点到例化名 → 跳到它 type 的定义
                mod = m.group(1)
                if mod in modules:
                    return ("define", mod)
                return None
        # 多行带参例化头  <mod> #(    （type 单独在行首）
        if re.match(r'^\s*' + re.escape(word) + r'\s*#', line) and word in modules:
            return ("define", word)
        return None

    def _open_module_definition(self, mod: str):
        resolver = self._resolver
        fp = resolver.resolve_file(mod) if resolver else None
        if not fp or not os.path.isfile(fp):
            self._set_hint(f"✗ module '{mod}' source not found", ok=False)
            return
        if os.path.abspath(fp) == os.path.abspath(self._current_file):
            self._goto_module_header(mod)
            return
        self._scope_context = None
        self._load_file_impl(fp)
        self._goto_module_header(mod)
        self._set_hint(f"→ {mod} ({os.path.basename(fp)})")

    def _goto_module_header(self, mod: str):
        text = self.editor.toPlainText()
        m = re.search(r'(?m)^\s*(?:module|macromodule)\s+' + re.escape(mod) + r'\b', text)
        if m:
            self._goto_line(text[:m.start()].count("\n") + 1)

    def _jump_to_callers(self, mod: str):
        """从一个模块的定义，列出/跳到所有把它例化的位置 (file:line)。"""
        resolver = self._resolver
        if resolver is None:
            return
        module_file = resolver.resolve_file(mod)   # definition file of `mod`
        cands: list[tuple[str, int, str]] = []     # (parent_file, lineno, scope_key)
        for sp in sorted(self._scope_paths):
            if len(sp) < 2:
                continue
            leaf = sp[-1]
            if resolver.resolve_module_name(leaf) != mod:
                continue
            leaf_file = resolver.resolve_file(leaf)
            if module_file and leaf_file and \
                    os.path.abspath(leaf_file) != os.path.abspath(self._current_file):
                continue      # 同名模块但来自别的源文件，跳过
            inst = leaf
            parent_file = resolver.resolve_file(sp[-2]) or resolver.resolve_file(sp[0])
            if not parent_file or not os.path.isfile(parent_file):
                continue
            try:
                with open(parent_file, "r", encoding="utf-8", errors="replace") as f:
                    text = f.read()
            except Exception:
                continue
            lineno = self._find_inst_line(text, mod, inst)
            if lineno:
                cands.append((parent_file, lineno, ".".join(sp)))

        if not cands:
            self._set_hint(f"'{mod}' 未在设计中例化（顶层模块或 VCD 中不存在）", ok=False)
            return
        cands.sort(key=lambda c: (c[0], c[1]))
        if len(cands) == 1:
            f, ln, scope = cands[0]
            self._open_file_at(f, ln)
            self._set_hint(f"↩ {mod} 实例化于 {os.path.basename(f)}:{ln}  ({scope})")
            return
        menu = QMenu(self.editor)
        h = menu.addAction(f"module '{mod}' instantiated at ({len(cands)}):")
        h.setEnabled(False)
        menu.addSeparator()
        for f, ln, scope in cands:
            act = menu.addAction(f"  {scope}  →  {os.path.basename(f)}:{ln}")
            act.triggered.connect(lambda checked=False, ff=f, ll=ln:
                                  self._open_file_at(ff, ll))
        menu.exec(QCursor.pos())

    @staticmethod
    def _skip_paren(text: str, i: int) -> int | None:
        """Return index just past the matching ')' for a '(' at index i."""
        depth = 0
        for j in range(i, len(text)):
            c = text[j]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    return j + 1
        return None

    @staticmethod
    def _find_inst_line(text: str, mod: str, inst: str) -> int | None:
        """Locate '<mod> <inst> (' in source text; return 1-based line of '（'. """
        modre = re.compile(r"\b" + re.escape(mod) + r"\b")
        instre = re.compile(r"\b" + re.escape(inst) + r"\b")
        n = len(text)
        idx = 0
        while True:
            m = modre.search(text, idx)
            if not m:
                return None
            k = m.end()
            while k < n and text[k] in " \t\r\n":
                k += 1
            if k < n and text[k] == "#":
                # skip parameter block  # ( ... )
                while k < n and text[k] in " \t\r\n":
                    k += 1
                if k < n and text[k] == "(":
                    after = CodeViewerPanel._skip_paren(text, k)
                    if after is None:
                        return None
                    k = after
                    while k < n and text[k] in " \t\r\n":
                        k += 1
            im = instre.match(text, k)
            if im:
                k2 = im.end()
                while k2 < n and text[k2] in " \t\r\n":
                    k2 += 1
                if k2 < n and text[k2] == "(":
                    return text[:k2].count("\n") + 1
            idx = m.start() + 1

    def _open_file_at(self, filepath: str, lineno: int | None):
        if not filepath:
            return
        if os.path.abspath(filepath) != os.path.abspath(self._current_file):
            self._scope_context = None
            self._load_file_impl(filepath)
        if lineno:
            self._goto_line(lineno)

    def _goto_line(self, lineno: int):
        block = self.editor.document().findBlockByNumber(lineno - 1)
        if not block.isValid():
            return
        cur = QTextCursor(block)
        cur.movePosition(QTextCursor.StartOfBlock)
        self.editor.setTextCursor(cur)
        self.editor.centerCursor()

    def flash_line(self, lineno: int, ms: int = 900):
        """短暂高亮某一行（日志双击跳转 / trace 定位时给视觉反馈）。"""
        from PySide6.QtGui import QTextFormat
        from PySide6.QtWidgets import QTextEdit
        block = self.editor.document().findBlockByNumber(lineno - 1)
        if not block.isValid():
            return
        sel = QTextEdit.ExtraSelection()
        sel.format.setBackground(QColor("#FFF3B0"))
        sel.format.setProperty(QTextFormat.FullWidthSelection, True)
        sel.cursor = QTextCursor(block)
        self._flash_selections = [sel]
        self.editor.setExtraSelections(self._flash_selections)

        def _clear():
            self._flash_selections = []
            self.editor.setExtraSelections([])
        QTimer.singleShot(ms, _clear)

    def _sig_candidates_for_word(self, word: str) -> list[SignalDef]:
        """按名字/部分路径返回匹配的 SignalDef 列表（按 full_path 去重、稳定排序）。
        优先“名字精确同名”，其次“路径尾匹配”。供右键菜单/trace 使用 ——
        与 _find_signals_for_word(vcd_id) 不同：full_path 才是信号唯一键。"""
        wl = word.lower()
        out: list[SignalDef] = []
        seen: set[str] = set()
        for sig in self._vcd_signals:
            fp = sig.full_path.lower()
            if (sig.name.lower() == wl or fp == wl
                    or fp.endswith("." + wl) or ("." + wl + ".") in fp):
                if sig.full_path not in seen:
                    seen.add(sig.full_path)
                    out.append(sig)
        out.sort(key=lambda s: (s.name.lower() != wl))   # 精确同名排前面
        return out

    def _preferred_sig_for_word(self, word: str,
                                sigs: list[SignalDef] | None = None) -> SignalDef | None:
        """在候选信号里按当前代码作用域挑一条唯一的（与双击加波形同一套作用域规则）。
        唯一 → 返回该 SignalDef；仍有多条同深度候选 → 返回 None（调用方改列子菜单）。"""
        pool = sigs if sigs is not None else self._sig_candidates_for_word(word)
        if not pool:
            return None
        ctx = self._scope_context or self._derive_context_from_file()
        if ctx:
            # 本模块作用域内没有 → 保持全局候选
            scoped = [s for s in pool if self._scope_matches(s.scope_path, ctx)]
            if scoped:
                pool = scoped
        pool = sorted(pool, key=lambda s: len(s.scope_path))
        min_d = len(pool[0].scope_path)
        top = [s for s in pool if len(s.scope_path) == min_d]
        return top[0] if len(top) == 1 else None

    def _show_signal_menu(self, global_pos, word: str | None):
        """Show right-click context menu for signal adding / trace."""
        menu = self._build_signal_menu(word)
        if menu is not None:
            menu.exec(global_pos)
            return
        noop_menu = QMenu(self.editor)              # 光标下没东西 / 没有同名信号
        noop_menu.addAction("(no signal identifier under cursor)"
                            if not word else f"(no VCD signal matches '{word}')").setEnabled(False)
        noop_menu.exec(global_pos)

    def _build_signal_menu(self, word: str | None) -> QMenu | None:
        """构造代码窗口的右键菜单，**不弹出**（同 `_build_color_menu`：`QMenu.exec` 在
        Python 侧 patch 不掉）。取不到候选 → None，由 `_show_signal_menu` 弹提示。"""
        if not word:
            return None

        sigs = self._sig_candidates_for_word(word)
        if not sigs:
            return None

        # Show matched signals
        menu = QMenu(self.editor)
        header = menu.addAction(f"Signals matching '{word}' ({len(sigs)}):")
        header.setEnabled(False)
        menu.addSeparator()
        for sig in sigs:
            label = f"{sig.full_path} ({sig.type}, {sig.width}bit)"
            action = menu.addAction(f"  {label}")
            action.triggered.connect(
                lambda checked=False, s=sig: self.signal_add_requested.emit([s.vcd_id])
            )

        # ➕ 显示某一位 / 位段（见 bug.md B13）—— 候选先按**当前代码所在模块作用域**收窄
        # （与下面 Trace 用的是同一个 `_preferred_sig_for_word`）：同名多路但能定到唯一一条时
        # 照样给菜单，比如 `rx_bit` 在本仓库 3 个作用域都叫这个名字，用"len(sigs)==1"当闸门
        # 就永远拿不到位菜单 —— 那正是最想切位子的那类信号。
        preferred = self._preferred_sig_for_word(word, sigs)
        if preferred is not None and preferred.width > 1:
            sig0 = preferred
            bits_menu = menu.addMenu("➕ 显示位 ▸")
            if sig0.width <= 32:
                for b in range(sig0.width - 1, -1, -1):
                    act = bits_menu.addAction(f"{sig0.name}[{b}]")
                    act.triggered.connect(
                        lambda checked=False, s=sig0, bb=b:
                            self.bit_slice_add_requested.emit(s.vcd_id, bb, bb))
            bits_menu.addSeparator()
            ask = bits_menu.addAction("指定位 / 位段…")
            ask.triggered.connect(lambda checked=False, s=sig0: self._prompt_bit_spec_by_sig(s))
        # Trace Driver / Uses：恒可用 —— 同名信号有多条时用子菜单逐条列出，
        # 绝不因为“有歧义”就把追溯入口整块藏掉（trace 键一律用唯一 full_path）。
        menu.addSeparator()
        if preferred is not None:      # 上面"显示位"那块已经算过，同一个判据
            _fp = preferred.full_path
            act_tr = menu.addAction(f"🔍 Trace Driver（追溯驱动源码）→ {_fp}")
            act_tr.triggered.connect(
                lambda checked=False, v=_fp: self.trace_driver_requested.emit(v))
            act_tu = menu.addAction("📖 Trace Uses（在日志列出使用它的行）")
            act_tu.triggered.connect(
                lambda checked=False, v=_fp: self.trace_uses_requested.emit(v))
        else:
            head_tr = menu.addMenu(f"🔍 Trace Driver ▸ 选信号（{len(sigs)} 条同名）")
            for sig in sigs:
                act = head_tr.addAction(f"{sig.full_path} ({sig.type}, {sig.width}bit)")
                act.triggered.connect(
                    lambda checked=False, s=sig:
                        self.trace_driver_requested.emit(s.full_path))
            head_tu = menu.addMenu(f"📖 Trace Uses ▸ 选信号（{len(sigs)} 条同名）")
            for sig in sigs:
                act = head_tu.addAction(f"{sig.full_path} ({sig.type}, {sig.width}bit)")
                act.triggered.connect(
                    lambda checked=False, s=sig:
                        self.trace_uses_requested.emit(s.full_path))
        if len(sigs) > 1:
            menu.addSeparator()
            add_all = menu.addAction(f"  ▸ Add ALL ({len(sigs)} signals)")
            all_vids = [s.vcd_id for s in sigs]
            add_all.triggered.connect(
                lambda: self.signal_add_requested.emit(all_vids)
            )
        return menu

    def _ask_bit_text(self, title: str, prompt: str) -> tuple[str, bool]:
        """模态输入框的唯一出口 —— 单列出来是为了**可被自查块替换**（函数内 import 的
        QInputDialog 没法从外面 patch，无头跑会永久阻塞在模态框上，见 bug.md B13/B11-GUI）。"""
        from PySide6.QtWidgets import QInputDialog
        return QInputDialog.getText(self.editor, title, prompt)

    def _prompt_bit_spec_by_sig(self, sig: SignalDef):
        """问出 (msb, lsb) 后交给波形面板去加（宽度校验 / 报错都在那边做，本面板没有 cache）。"""
        text, ok = self._ask_bit_text(
            "显示位 / 位段",
            f"{sig.name}（{sig.width} 位）：要显示哪一位 / 哪几位？（单个位写 1，位段写 7:4）")
        if not ok:
            return
        spec = parse_bit_spec(text)
        if spec is None:
            QMessageBox.warning(self.editor, "显示位",
                                f"看不懂「{text}」。请输入 1（单个位）或 7:4（位段）。")
            return
        self.bit_slice_add_requested.emit(sig.vcd_id, spec[0], spec[1])

    def _get_signal_info(self, vcd_id: str) -> str | None:
        """Get a short description for a signal VCD ID."""
        for sig in self._vcd_signals:
            if sig.vcd_id == vcd_id:
                return f"{sig.full_path} ({sig.type}, {sig.width}bit)"
        return None

    def highlight_signal(self, signal_def: SignalDef | None):
        """在源码中高亮信号声明行 / Highlight signal declaration in source."""
        # Clear previous highlights
        cursor = self.editor.textCursor()
        cursor.select(QTextCursor.Document)
        fmt = QTextCharFormat()
        fmt.setBackground(QColor("#FFFFFF"))
        cursor.mergeCharFormat(fmt)

        if signal_def is None:
            return

        # Search for signal name in declaration context
        text = self.editor.toPlainText()
        name = re.escape(signal_def.name)
        pattern = re.compile(
            rf'^\s*(?:input|output|inout|wire|reg|integer|real|parameter|localparam)\b.*\b{name}\b',
            re.MULTILINE
        )
        match = pattern.search(text)
        if not match:
            # Fallback: just search for the name anywhere
            pattern = re.compile(rf'\b{name}\b')
            match = pattern.search(text)

        if match:
            line_num = text[:match.start()].count('\n') + 1
            block = self.editor.document().findBlockByNumber(line_num - 1)
            if block.isValid():
                cursor = QTextCursor(block)
                cursor.movePosition(QTextCursor.StartOfBlock)
                cursor.movePosition(QTextCursor.EndOfBlock, QTextCursor.KeepAnchor)
                fmt = QTextCharFormat()
                fmt.setBackground(QColor("#FFFF99"))
                cursor.mergeCharFormat(fmt)
                self.editor.setTextCursor(cursor)
                self.editor.centerCursor()


#============================================================================
# WaveformScene — 波形渲染场景 / waveform rendering scene
#============================================================================

class WaveformScene(QGraphicsScene):
    """QGraphicsScene 子类，绘制波形轨迹、时间轴、光标。

    Scene rect 覆盖全时间范围，view_start/end 由视口位置计算。
    Supports rubber-band drag-to-zoom and per-signal color customization.
    """

    cursor_moved = Signal(int)  # emits time value in ps

    # Marker colors — cycled by rank; names are unbounded (A…Z, AA, AB, …), so
    # markers past the 5th reuse this palette.
    MARKER_COLORS = [
        QColor("#FF0000"),  # A: red
        QColor("#0066FF"),  # B: blue
        QColor("#FF8800"),  # C: orange
        QColor("#8800CC"),  # D: purple
        QColor("#008866"),  # E: teal
    ]

    # Radix modes for bus signal display
    RADIX_HEX = "hex"
    RADIX_BIN = "bin"
    RADIX_DEC = "dec"
    RADIX_OCT = "oct"
    RADIX_UNSIGNED = "unsigned"

    # 结构变更（增删信号 / 分组 / 折叠 / 隐藏）后发一次，供工具栏菜单与计数标签刷新
    groups_changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._cache: WaveformDataCache | None = None
        # 顶层序列：str(vcd_id) 或 SignalGroup，见 tools/wave_groups.py 与 bug.md B11
        self._order: list = []
        self._displayed: list[str | SignalGroup] = []   # _order 的派生展开（渲染行序列）
        self._signal_color: dict[str, QColor] = {}
        self._signal_radix: dict[str, str] = {}  # vcd_id → radix mode
        self._signal_state_map: dict[str, dict[int, str]] = {}  # vcd_id → {value: name}
        self._use_state_names: dict[str, bool] = {}  # vcd_id → whether to show state names
        self._color_index = 0

        self.pixels_per_ps = 0.0005    # zoom level: pixels per picosecond
        self.cursor_time: int | None = None
        self._view_width = 1200        # cached viewport width

        # Visible time range (set by panel from view scroll position)
        self.visible_start = 0
        self.visible_end = self._total_time()

        # Rubber-band zoom state
        self._rubber_active = False
        self._rubber_start_x: float = 0.0
        self._rubber_end_x: float = 0.0

        # Markers: ordered list of (name, time_ps)
        self._markers: list[tuple[str, int]] = []
        self._selected_marker: str | None = None
        self._dragging_marker: str | None = None

        # Font size for waveform labels/values
        self.wave_font_size = 11

        self.setBackgroundBrush(QBrush(COLOR_BG))
        self._update_scene_rect()  # ensure proper initial scene rect

    # ---- Public API ----

    def set_cache(self, cache: WaveformDataCache):
        self._cache = cache

    def set_signal_color(self, vcd_id: str, color: QColor):
        """设置信号波形颜色 / Set the trace color for a signal."""
        self._signal_color[vcd_id] = color
        self._redraw()

    def set_signal_radix(self, vcd_id: str, radix: str):
        """设置多bit信号的显示进制 / Set radix mode for a bus signal."""
        self._signal_radix[vcd_id] = radix
        self._redraw()

    def get_signal_radix(self, vcd_id: str) -> str:
        """获取信号的显示进制 / Get radix mode for a signal (default 'bin')."""
        return self._signal_radix.get(vcd_id, self.RADIX_BIN)

    def set_state_map(self, vcd_id: str, state_map: dict[int, str]):
        """设置信号的状态名映射 / Set state name mapping for a signal."""
        self._signal_state_map[vcd_id] = state_map
        if state_map:
            self._use_state_names[vcd_id] = True
        self._redraw()

    def get_state_map(self, vcd_id: str) -> dict[int, str]:
        """获取信号的状态名映射 / Get state name mapping."""
        return self._signal_state_map.get(vcd_id, {})

    def toggle_state_names(self, vcd_id: str):
        """切换是否显示状态名 / Toggle state name display for a signal."""
        if vcd_id in self._signal_state_map and self._signal_state_map[vcd_id]:
            self._use_state_names[vcd_id] = not self._use_state_names.get(vcd_id, False)
        self._redraw()

    def get_use_state_names(self, vcd_id: str) -> bool:
        return self._use_state_names.get(vcd_id, False)

    # ---- State name parser from RTL ----

    def store_state_map(self, vcd_id: str, state_map: dict[int, str]):
        """存储某信号的状态名映射，但【不】自动开启状态名显示。
        Store a state map without enabling state-name display (bug #2 default
        is plain binary; the user opts in per-signal via the right-click menu)."""
        if state_map:
            self._signal_state_map[vcd_id] = state_map

    # ---- Marker API / Mark 线操作 ----

    @staticmethod
    def _marker_name(index: int) -> str:
        """0-based time-rank → marker label, unbounded: A, B, …, Z, AA, AB, …
        (spreadsheet-column style). Markers are always renamed by rank, so the
        i-th earliest marker keeps the i-th name."""
        s = ""
        i = index + 1
        while i > 0:
            i, rem = divmod(i - 1, 26)
            s = chr(ord("A") + rem) + s
        return s

    def _marker_color(self, index: int) -> QColor:
        """Color of the marker at the given time-rank; cycles through MARKER_COLORS."""
        return self.MARKER_COLORS[index % len(self.MARKER_COLORS)]

    def _renumber(self):
        """Sort markers by time and assign names A, B, …, Z, AA, … by rank."""
        self._markers.sort(key=lambda x: x[1])
        self._markers = [
            (self._marker_name(i), t) for i, (_n, t) in enumerate(self._markers)
        ]

    def add_marker(self, time_ps: int) -> str:
        """Add a marker at the given time and return its name.
        Markers are kept sorted by time; names are assigned by rank
        (A=earliest, then B…Z, AA…), so the count is not limited."""
        # Insert in time order (after any marker already at the same time)
        insert_idx = len(self._markers)
        for i, (_n, t) in enumerate(self._markers):
            if time_ps < t:
                insert_idx = i
                break
        self._markers.insert(insert_idx, ("", time_ps))
        self._renumber()
        added_name = self._markers[insert_idx][0]
        self._redraw()
        return added_name

    def remove_marker(self, name: str):
        """Remove a marker by name. Remaining markers are renamed by rank in time order."""
        self._markers = [(n, t) for n, t in self._markers if n != name]
        self._renumber()
        self._redraw()

    def clear_markers(self):
        """Remove all markers."""
        self._markers.clear()
        self._redraw()

    def get_marker_time(self, name: str) -> int | None:
        """Get the time value for a marker."""
        for n, t in self._markers:
            if n == name:
                return t
        return None

    def marker_at_x(self, scene_x: float, tolerance_px: int = 8) -> str | None:
        """Find a marker near a given scene X position. Returns name or None."""
        best = None
        best_dist = tolerance_px + 1
        for name, t in self._markers:
            px = self._time_to_x(t)
            dist = abs(scene_x - px)
            if dist < best_dist:
                best_dist = dist
                best = name
        return best if best_dist <= tolerance_px else None

    @property
    def markers(self) -> list[tuple[str, int]]:
        return list(self._markers)

    @property
    def selected_marker(self) -> str | None:
        return self._selected_marker

    def select_marker(self, name: str | None):
        """Select a marker (or deselect). / 选中或取消选中一个 Mark 线."""
        self._selected_marker = name
        self._redraw()

    def move_marker(self, name: str, time_ps: int):
        """Move a marker to a new time and re-sort. / 移动 Mark 线到新位置并重新排序."""
        for i, (n, t) in enumerate(self._markers):
            if n == name:
                self._markers[i] = (n, time_ps)
                break
        self._renumber()
        self._redraw()

    def find_nearest_edge(self, time_ps: int, tolerance_px: int = 20) -> int | None:
        """Find the nearest transition edge among displayed signals.
        Returns the transition time_ps if within tolerance, else None.
        在所有显示信号中搜索最近的跳变边沿，用于 Mark 吸附对齐。"""
        if not self._cache or not self._displayed:
            return None
        best_t = None
        best_dist_px = tolerance_px + 1
        for vcd_id in self._displayed:
            if not isinstance(vcd_id, str):     # 组头行没有波形，跳过（见 bug.md B11）
                continue
            trans = self._cache.get_transitions(vcd_id)
            if not trans:
                continue
            times = [ev[0] for ev in trans]
            # Binary search for nearest transition
            idx = bisect.bisect_left(times, time_ps)
            # Check transition at idx
            for i in (idx, idx - 1):
                if 0 <= i < len(times):
                    t_edge = times[i]
                    dist_px = abs(self._time_to_x(t_edge) - self._time_to_x(time_ps))
                    if dist_px < best_dist_px:
                        best_dist_px = dist_px
                        best_t = t_edge
        return best_t if best_t is not None and best_dist_px <= tolerance_px else None

    def add_signal(self, vcd_id: str, notify: bool = True, at_row: int | None = None):
        """添加信号到波形显示 / Add a signal to the waveform display.
        允许同一信号多次添加 / Allows adding the same signal multiple times.

        at_row=None → 追加为**顶层信号**（不会落进末尾的分组里）；
        at_row=N   → 插到**渲染行 N** 之前（N=行数即末尾），落点决定归属 —— 插在某条组内
                     成员后面就自动成为该组成员（同一套规则见 wave_groups.insert_rows）。
        notify=False 供批量添加用，由调用方最后统一发一次通知。"""
        if at_row is None:
            self._order.append(vcd_id)
        else:
            wave_groups.insert_rows(self._order, [vcd_id], at_row)
        if vcd_id not in self._signal_color:
            self._signal_color[vcd_id] = SIGNAL_COLORS[
                self._color_index % len(SIGNAL_COLORS)
            ]
            self._color_index += 1
        if notify:
            self._commit_order()
        else:
            self._rebuild_displayed()

    def add_signals(self, vcd_ids: list, at_row: int | None = None):
        """批量加信号（一次收尾）。at_row=None → 全部追加到末尾，否则从该渲染行起**按序**插入。

        逐条按 at_row+i 插入而不是一次性插整批：这样第二批、第三批跟着同一个锚点走时
        仍然保持"新的一批排在旧的一批下面"的顺序（一次性插会把后一批排到前一批上面）。"""
        vals = [v for v in vcd_ids if isinstance(v, str)]
        if not vals:
            return
        for i, vid in enumerate(vals):
            self.add_signal(vid, notify=False,
                            at_row=None if at_row is None else at_row + i)
        self.notify_changed()

    def notify_changed(self):
        """批量变更后手动发一次刷新通知（配合 notify=False）。"""
        self._commit_order()

    def remove_signal(self, vcd_id: str):
        """从波形中移除信号（移除第一个匹配项）/ Remove a signal from waveform (first match)."""
        if wave_groups.remove_signal(self._order, vcd_id):
            self._commit_order()

    def remove_signal_at(self, idx: int):
        """按渲染行号移除 / Remove the row at a given display index.

        组头行 → **整组连信号一起移除**（与组头菜单里的"移除整组"一致）。"""
        item = self.item_at_row(idx)
        if item is None:
            return
        if is_group(item):
            self.remove_group_with_signals(item)
            return
        self.remove_signal(item)

    def has_signal(self, vcd_id: str) -> bool:
        """是否已在波形里（含被折叠 / 隐藏组内的成员）。"""
        if vcd_id in self._order:
            return True
        return any(vcd_id in g.members for g in self.groups())

    # ---- 分组：_order 是主序，_displayed 是它的派生视图（见 wave_groups.py） ----

    def _rebuild_displayed(self):
        """按 _order 重算渲染行。**必须原地改**：标签列在 sync_from 里别名了这个 list 对象，
        一旦整体重新赋值，标签列的别名就断了（两列行数不一致 → 滚动错位），见 bug.md B11。"""
        self._displayed[:] = wave_groups.visible_rows(self._order)

    def _commit_order(self):
        """结构变更后的统一收尾：派生视图 → 场景高度 → 重绘 → 通知外部。"""
        self._rebuild_displayed()
        self._update_scene_rect()
        self._redraw()
        self.groups_changed.emit()

    def set_order(self, order: list):
        """整体换掉主序（会话加载 / VCD 重载用），走与其它结构变更相同的收尾。"""
        self._order[:] = order          # 原地改：标签列别名了这个 list 对象（见 bug.md B11）
        self._commit_order()

    @property
    def signal_count(self) -> int:
        """信号条数（含被折叠 / 隐藏组里的成员）。"""
        return wave_groups.counts(self._order)[0]

    @property
    def group_count(self) -> int:
        return wave_groups.counts(self._order)[1]

    def count_text(self) -> str:
        """工具栏计数文案。"""
        n, m = wave_groups.counts(self._order)
        return f"{n} signals · {m} groups" if m else f"{n} signals"

    def item_at_row(self, row: int):
        """渲染行 row 处的元素（vcd_id 或 SignalGroup）；越界返回 None。"""
        if 0 <= row < len(self._displayed):
            return self._displayed[row]
        return None

    def group_at_row(self, row: int) -> SignalGroup | None:
        """渲染行 row 所属的组（组头行返回它自己，顶层信号行返回 None）。"""
        return wave_groups.group_at_row(self._order, row)

    def groups(self) -> list[SignalGroup]:
        return wave_groups.groups_in_order(self._order)

    def rows_of_group(self, group: SignalGroup) -> list[int]:
        """组在**渲染序列**里占用的行号（折叠时只有组头那一行）。"""
        return wave_groups.rows_of_group(self._order, group)

    def set_group_collapsed(self, group: SignalGroup, collapsed: bool):
        # 必须 is_group 先判：传进来一条 vcd_id 字符串时 `in self._order` 也成立，
        # 会往 str 上挂属性直接抛异常（`toggle_group_collapsed` 还要读 .collapsed）
        if is_group(group) and group in self._order:
            group.collapsed = bool(collapsed)
            self._commit_order()

    def toggle_group_collapsed(self, group: SignalGroup):
        if not is_group(group):
            return
        self.set_group_collapsed(group, not group.collapsed)

    def set_group_hidden(self, group: SignalGroup, hidden: bool):
        if is_group(group) and group in self._order:
            group.hidden = bool(hidden)
            self._commit_order()

    def set_all_groups_hidden(self, hidden: bool = False):
        hit = False
        for g in wave_groups.groups_in_order(self._order):
            if g.hidden != bool(hidden):
                g.hidden = bool(hidden)
                hit = True
        if hit:
            self._commit_order()

    def set_all_groups_collapsed(self, collapsed: bool = True):
        hit = False
        for g in wave_groups.groups_in_order(self._order):
            if g.collapsed != bool(collapsed):
                g.collapsed = bool(collapsed)
                hit = True
        if hit:
            self._commit_order()

    def rename_group(self, group: SignalGroup, name: str):
        if group in self._order and name:
            group.name = name
            self._commit_order()

    def create_group_from_rows(self, rows, name: str) -> SignalGroup | None:
        """用选中的渲染行建组；一个信号都没选中则返回 None（不建空组）。"""
        g = wave_groups.group_from_rows(self._order, name, list(rows))
        if g not in self._order:
            return None
        self._commit_order()
        return g

    def add_rows_to_group(self, rows, group: SignalGroup):
        if group not in self._order:
            return
        wave_groups.add_to_group(self._order, list(rows), group)
        self._commit_order()

    def remove_rows_from_group(self, rows):
        wave_groups.remove_from_group(self._order, list(rows))
        self._commit_order()

    def ungroup(self, group: SignalGroup):
        """取消分组：组头删掉，成员原地变顶层信号。"""
        wave_groups.remove_group(self._order, group, keep_signals=True)
        self._commit_order()

    def remove_group_with_signals(self, group: SignalGroup):
        """移除整组（含组内信号）。"""
        wave_groups.remove_group(self._order, group, keep_signals=False)
        self._commit_order()

    def move_rows_by_visible_indices(self, moves: list[tuple[int, int]]):
        """按 (源行号, 落点) 批量拖拽。落点以"摘除被拖行之后"的序列为准，
        与 SignalLabelScene.end_drag 的返回值一致；落点决定归属（Verdi 风格）。"""
        if not moves:
            return
        srcs = [src for src, _tgt in moves]
        dest = min(tgt for _src, tgt in moves)
        wave_groups.move_rows(self._order, srcs, dest)
        self._commit_order()

    def move_group_by_visible_rows(self, rows, dest_row: int):
        """拖动整组：rows 是组在渲染序列里占的行（含组头与成员行）。"""
        owners = wave_groups.row_owners(self._order)
        for i in sorted(set(rows)):
            if 0 <= i < len(owners) and owners[i] is not None:
                wave_groups.move_group_to_row(self._order, owners[i], dest_row)
                self._commit_order()
                return

    def clear_signals(self):
        # 必须原地 clear()：标签列别名了这个 list（sync_from），重新赋值会断别名
        self._order.clear()
        self._displayed.clear()
        self._update_scene_rect()
        self._redraw()
        self.groups_changed.emit()

    def move_selected_rows_by(self, rows, delta: int) -> int:
        """把选中的渲染行整体上移 / 下移 delta 行（工具栏 ▲▼ 用），返回实际位移。

        走与拖拽同一套 move_rows：按住整块平移，不会像以前那样把重复项挪错行。"""
        rows = sorted(r for r in set(rows) if 0 <= r < len(self._displayed))
        if not rows:
            return 0
        moved = set(rows)
        survivors = [i for i in range(len(self._displayed)) if i not in moved]
        # 目标：整块在剩余序列里的插入位。上移看最上面那行上方还剩几行，下移看最下面那行。
        if delta < 0:
            base = sum(1 for i in survivors if i < rows[0])
        else:
            base = sum(1 for i in survivors if i < rows[-1] + 1)
        dest = max(0, min(base + delta, len(survivors)))
        shift = dest - base
        if not shift:
            return 0
        wave_groups.move_rows(self._order, rows, dest)
        self._commit_order()
        return shift

    def set_view_width(self, w: int):
        """Set viewport width for scroll fraction calculations."""
        self._view_width = max(w, 200)

    # ---- Time range properties ----

    @property
    def view_start_time(self) -> int:
        """First visible time (deprecated - use visible_start)."""
        return self.visible_start

    @property
    def view_end_time(self) -> int:
        """Last visible time (deprecated - use visible_end)."""
        return self.visible_end

    def zoom(self, factor: float, center_time: int | None = None):
        """缩放 / Zoom by changing pixels_per_ps."""
        old_pps = self.pixels_per_ps
        self.pixels_per_ps = max(5e-7, min(0.1, old_pps * factor))
        self._update_scene_rect()
        self._redraw()

    def zoom_fit(self):
        """缩放以显示全部时间范围 / Zoom to fit entire time range."""
        total = self._total_time()
        if total > 0 and self._view_width > 0:
            self.pixels_per_ps = max(5e-7, self._view_width / total)
        self._update_scene_rect()
        self._redraw()

    # ---- Coordinate helpers ----

    def _total_time(self) -> int:
        if self._cache and self._cache.total_end > 0:
            return self._cache.total_end
        return 10_000_000  # default 10us

    def _time_to_x(self, t: int) -> float:
        """Absolute scene X for a given time."""
        return t * self.pixels_per_ps

    def _x_to_time(self, x: float) -> int:
        """Time at a given absolute scene X."""
        return int(x / max(self.pixels_per_ps, 1e-12))

    def _row_y(self, idx: int) -> float:
        return RULER_HEIGHT + idx * ROW_HEIGHT

    def _signal_y_center(self, idx: int) -> float:
        return self._row_y(idx) + ROW_HEIGHT / 2

    def _update_scene_rect(self, min_height: int = 200):
        """更新场景矩形 / Update scene rect to cover full time range.
        min_height: ensure scene is at least this tall for vertical scrollability."""
        total = self._total_time()
        width = total * self.pixels_per_ps
        height = RULER_HEIGHT + len(self._displayed) * ROW_HEIGHT + 10
        self.setSceneRect(0, 0, max(width, 200), max(height, min_height))

    def _nice_tick_interval(self, time_span_ps: int) -> int:
        """计算"好看"的时间刻度间隔 / Compute a nice tick interval."""
        # Target: ~8-15 ticks across visible range
        target_ticks = 10
        raw = time_span_ps / target_ticks
        # Snap to 1/2/5 * 10^n
        exp = 10 ** max(0, len(str(int(raw))) - 1)
        frac = raw / exp
        if frac <= 1:
            nice = exp
        elif frac <= 2:
            nice = 2 * exp
        elif frac <= 5:
            nice = 5 * exp
        else:
            nice = 10 * exp
        return max(1, int(nice))

    def _format_time(self, ps: int) -> str:
        """格式化时间值 / Format time value with appropriate unit.

        小数位取"去掉尾零后仍然够用"：固定一位时，亚微秒窗口的刻度会挤成同一个
        标签（200ns 窗口里连印 '3.7us'），看不出间隔。见 tools/bug.md B15。
        """
        if abs(ps) >= 1_000_000_000_000:
            return self._trim_time(ps / 1_000_000_000_000, "s")
        elif abs(ps) >= 1_000_000_000:
            return self._trim_time(ps / 1_000_000_000, "ms")
        elif abs(ps) >= 1_000_000:
            return self._trim_time(ps / 1_000_000, "us")
        elif abs(ps) >= 1_000:
            return self._trim_time(ps / 1_000, "ns")
        else:
            return f"{ps}ps"

    @staticmethod
    def _trim_time(v: float, unit: str) -> str:
        """定单位后的数值转标签：最多 6 位小数，再去掉尾零（不凑无谓的精度）。"""
        return f"{v:.6f}".rstrip("0").rstrip(".") + unit

    def _lookup_state_name(self, formatted: str, vcd_id: str) -> str | None:
        """从格式化值中提取整数值并查找状态名 / Extract integer from value and look up state name."""
        state_map = self._signal_state_map.get(vcd_id, {})
        if not state_map:
            return None
        val = self._parse_int_from_formatted(formatted)
        if val is not None and val in state_map:
            return state_map[val]
        return None

    def _parse_int_from_formatted(self, formatted: str) -> int | None:
        """从格式化 VCD 值中提取整数值 / Extract integer from formatted VCD value."""
        if not formatted or formatted in ('x', 'X', 'z', 'Z', '?', '-'):
            return None
        if "'h" in formatted:
            try:
                return int(formatted.split("'h", 1)[1], 16)
            except ValueError:
                pass
        elif "'b" in formatted:
            try:
                return int(formatted.split("'b", 1)[1], 2)
            except ValueError:
                pass
        elif "'d" in formatted:
            try:
                return int(formatted.split("'d", 1)[1], 10)
            except ValueError:
                pass
        elif "'o" in formatted:
            try:
                return int(formatted.split("'o", 1)[1], 8)
            except ValueError:
                pass
        else:
            try:
                return int(formatted)
            except ValueError:
                pass
        return None

    def _format_value_for_display(self, raw: str, width: int) -> str:
        """格式化值用于波形显示 / Format value for waveform display."""
        if raw in ('x', 'X'):
            return 'x'
        if raw in ('z', 'Z'):
            return 'z'
        if raw.startswith('b'):
            try:
                val = int(raw[1:], 2)
                return f"{width}'h{val:X}"
            except ValueError:
                return raw
        if raw.startswith('r'):
            return raw[1:]
        return raw

    def _format_value_radix(self, formatted: str, width: int, radix: str) -> str:
        """Reformat a formatted VCD value (e.g. '4\\'hA') to the target radix.
        Handles 'x', 'z', and other special values unchanged."""
        if not formatted or formatted in ('x', 'X', 'z', 'Z', '?', '-'):
            return formatted
        # Try to extract integer from formatted hex like "4'hA" or binary "8'b1010"
        val = None
        if formatted.startswith("b") and not formatted.startswith("b'"):
            # Raw binary value from VCD, e.g. "b1010"
            try:
                val = int(formatted[1:], 2)
            except ValueError:
                pass
        elif "'h" in formatted:
            try:
                val = int(formatted.split("'h", 1)[1], 16)
            except ValueError:
                pass
        elif "'b" in formatted:
            try:
                val = int(formatted.split("'b", 1)[1], 2)
            except ValueError:
                pass
        elif "'o" in formatted:
            try:
                val = int(formatted.split("'o", 1)[1], 8)
            except ValueError:
                pass
        elif "'d" in formatted:
            try:
                val = int(formatted.split("'d", 1)[1], 10)
            except ValueError:
                pass
        else:
            # Try as plain decimal integer
            try:
                val = int(formatted)
            except ValueError:
                pass

        if val is None:
            return formatted

        if radix == self.RADIX_HEX:
            return f"{width}'h{val:X}"
        elif radix == self.RADIX_BIN:
            return f"{width}'b{val:0{width}b}"
        elif radix == self.RADIX_DEC:
            # Signed decimal (two's complement for MSB=1)
            if val & (1 << (width - 1)):
                val = val - (1 << width)
            return f"{val}"
        elif radix == self.RADIX_OCT:
            return f"{width}'o{val:o}"
        elif radix == self.RADIX_UNSIGNED:
            return f"{val}"
        return formatted

    # ---- Rendering ----

    def _redraw(self):
        """完全重绘 / Full redraw of all visible items."""
        self.clear()
        self._draw_grid_and_ruler()
        for idx, item in enumerate(self._displayed):
            if is_group(item):
                self._draw_group_header_row(idx, item)
            else:
                self._draw_signal_row(idx, item)
        if self.cursor_time is not None:
            self._draw_cursor()
        self._draw_markers()
        if self._rubber_active:
            self._draw_rubber_band()

    def _draw_group_header_row(self, idx: int, group):
        """绘制组头行 / Draw a group header band（恰好占一个 ROW_HEIGHT）。"""
        y_top = self._row_y(idx)
        width = self.sceneRect().width()
        self.addRect(QRectF(0, y_top, width, ROW_HEIGHT),
                     QPen(Qt.NoPen), QBrush(COLOR_GROUP_BG))
        # 左侧色条 + 上下分隔线：一眼能看出这是一段分组的起点
        self.addRect(QRectF(0, y_top, 3, ROW_HEIGHT),
                     QPen(Qt.NoPen), QBrush(COLOR_GROUP_ACCENT))
        self.addLine(QLineF(0, y_top, width, y_top), QPen(COLOR_GROUP_ACCENT, 1))
        self.addLine(QLineF(0, y_top + ROW_HEIGHT, width, y_top + ROW_HEIGHT),
                     QPen(COLOR_GROUP_ACCENT, 1))
        # 波形侧不重复画组名（名字在标签列），画个居中虚线示意"这里没有波形"
        self.addLine(QLineF(0, self._signal_y_center(idx), width, self._signal_y_center(idx)),
                     QPen(QColor("#B9CBE4"), 1, Qt.DashLine))

    def _draw_grid_and_ruler(self):
        """绘制时间轴和网格线 / Draw time ruler and vertical grid lines."""
        x0, y0, x1, y1 = self.sceneRect().getCoords()
        full_h = y1

        # Ruler background
        self.addRect(QRectF(x0, 0, x1 - x0, RULER_HEIGHT),
                     QPen(Qt.NoPen), QBrush(COLOR_RULER_BG))

        # Ruler bottom line
        self.addLine(QLineF(x0, RULER_HEIGHT, x1, RULER_HEIGHT),
                     QPen(QColor("#CCCCCC"), 1))

        # Compute tick interval
        tick_interval = self._nice_tick_interval(
            self.visible_end - self.visible_start
        )
        first_tick = (self.visible_start // tick_interval) * tick_interval
        if first_tick < self.visible_start:
            first_tick += tick_interval

        ruler_font_size = max(6, self.wave_font_size - 1)
        font = QFont("Helvetica", ruler_font_size)
        t = first_tick
        while t <= self.visible_end:
            px = self._time_to_x(t)
            # Grid line
            self.addLine(QLineF(px, RULER_HEIGHT, px, full_h),
                         QPen(COLOR_GRID, 1, Qt.DotLine))
            # Ruler tick
            self.addLine(QLineF(px, RULER_HEIGHT - 8, px, RULER_HEIGHT),
                         QPen(COLOR_RULER_TEXT, 1))
            # Ruler label
            text = self.addText(self._format_time(t), font)
            text.setDefaultTextColor(COLOR_RULER_TEXT)
            text.setPos(px + 2, 4)
            t += tick_interval

    def _draw_signal_row(self, idx: int, vcd_id: str):
        """绘制一行信号 / Draw one signal row."""
        if not self._cache:
            return

        sig = self._cache.get_signal(vcd_id)
        if not sig:
            return

        y_center = self._signal_y_center(idx)
        y_top = self._row_y(idx)

        # Row background (alternating)
        row_color = COLOR_ROW_BG_EVEN if idx % 2 == 0 else COLOR_ROW_BG_ODD
        self.addRect(
            QRectF(0, y_top, self.sceneRect().width(), ROW_HEIGHT),
            QPen(Qt.NoPen), QBrush(row_color)
        )

        # Get visible transitions
        t0 = self.visible_start
        t1 = self.visible_end
        trans = self._cache.get_visible(vcd_id, max(0, t0 - 1000), t1 + 1000)

        if not trans:
            # Draw unknown
            self._draw_unknown_row(y_center, y_top, t0, t1)
            return

        color = self._signal_color.get(vcd_id, QColor("#2196F3"))

        if sig.width == 1:
            self._draw_scalar_trace(y_center, y_top, trans, color, t0, t1)
        else:
            self._draw_bus_trace(y_center, y_top, trans, sig.width, t0, t1, vcd_id)

    def _draw_scalar_trace(self, y_center, y_top, trans, color, t0, t1):
        """绘制单bit信号波形 / Draw single-bit scalar trace."""
        high_y = y_top + 5
        low_y = y_top + ROW_HEIGHT - 5

        if not trans:
            return

        # Determine initial value before t0
        # Find the last transition at or before t0
        initial_val = 'x'
        initial_fmt = 'x'
        for ev_time, ev_raw, ev_fmt in trans:
            if ev_time <= t0:
                initial_val = ev_raw
                initial_fmt = ev_fmt
            else:
                break

        prev_val = initial_val
        prev_fmt = initial_fmt
        prev_is_high = (prev_val == '1')
        prev_x = self._time_to_x(t0)

        for ev_time, ev_raw, ev_fmt in trans:
            if ev_time < t0:
                prev_val = ev_raw
                prev_is_high = (prev_val == '1')
                continue
            if ev_time > t1:
                break

            curr_x = self._time_to_x(ev_time)
            curr_is_high = (ev_raw == '1')

            # Horizontal line from prev_x to curr_x at prev level
            level_y = high_y if prev_is_high else low_y
            pen = QPen(color, 1.5)
            pen.setCapStyle(Qt.FlatCap)
            self.addLine(QLineF(prev_x, level_y, curr_x, level_y), pen)

            # Vertical transition line
            if prev_is_high != curr_is_high or ev_raw in ('x', 'z'):
                edge_color = color
                if ev_raw == 'x':
                    edge_color = COLOR_TRACE_X
                elif ev_raw == 'z':
                    edge_color = COLOR_TRACE_Z
                self.addLine(
                    QLineF(curr_x, high_y, curr_x, low_y),
                    QPen(edge_color, 1)
                )

            # Value label — 标的是刚画完的这段 (prev_x..curr_x) 的电平, 故用 prev_fmt。
            # 用 ev_fmt (新段的值) 会把标签写早一格, 读者会把两段看反。
            gap = curr_x - prev_x
            if gap > 40:
                label = self.addText(
                    self._format_value_for_display(prev_fmt, 1),
                    QFont("Menlo", max(6, self.wave_font_size - 1))
                )
                label.setDefaultTextColor(QColor("#333333"))
                label.setPos(prev_x + 2, y_top + 2)

            prev_x = curr_x
            prev_is_high = curr_is_high
            prev_val = ev_raw
            prev_fmt = ev_fmt

        # Draw remaining segment to t1
        level_y = high_y if prev_is_high else low_y
        end_x = self._time_to_x(t1)
        pen = QPen(color, 1.5)
        self.addLine(QLineF(prev_x, level_y, end_x, level_y), pen)
        if end_x - prev_x > 40:
            label = self.addText(
                self._format_value_for_display(prev_fmt, 1),
                QFont("Menlo", max(6, self.wave_font_size - 1))
            )
            label.setDefaultTextColor(QColor("#333333"))
            label.setPos(prev_x + 2, y_top + 2)

    def _draw_bus_trace(self, y_center, y_top, trans, width, t0, t1, vcd_id: str = ""):
        """绘制多bit总线波形 / Draw multi-bit bus trace.
        Uses per-signal radix setting to format displayed values."""
        if not trans:
            return

        radix = self.get_signal_radix(vcd_id)

        # Determine initial value before t0
        initial_val = 'x'
        initial_fmt = 'x'
        for ev_time, ev_raw, ev_fmt in trans:
            if ev_time <= t0:
                initial_val = ev_raw
                initial_fmt = ev_fmt
            else:
                break

        prev_val = initial_val
        prev_fmt = initial_fmt
        prev_x = self._time_to_x(t0)

        for ev_time, ev_raw, ev_fmt in trans:
            if ev_time < t0:
                prev_val = ev_raw
                prev_fmt = ev_fmt
                continue
            if ev_time > t1:
                break

            curr_x = self._time_to_x(ev_time)

            # Draw value segment from prev_x to curr_x
            if prev_val != 'x':
                self.addRect(
                    QRectF(prev_x, y_top + 3, curr_x - prev_x, ROW_HEIGHT - 6),
                    QPen(COLOR_BUS_BORDER, 0.5), QBrush(COLOR_BUS_BG)
                )
            else:
                self.addRect(
                    QRectF(prev_x, y_top + 3, curr_x - prev_x, ROW_HEIGHT - 6),
                    QPen(QColor("#CC0000"), 0.5, Qt.DashLine), QBrush(Qt.NoBrush)
                )

            # Value label with radix-aware formatting, switchable to state names
            gap = curr_x - prev_x
            if gap > 50 and prev_fmt != 'x':
                # Check if state name display is enabled and value matches a state
                state_name = None
                if self._use_state_names.get(vcd_id) and vcd_id in self._signal_state_map:
                    state_name = self._lookup_state_name(prev_fmt, vcd_id)
                if state_name:
                    display = state_name
                else:
                    display = self._format_value_radix(prev_fmt, width, radix)
                label = self.addText(display, QFont("Menlo", self.wave_font_size))
                label.setDefaultTextColor(COLOR_BUS_TEXT)
                mid_x = prev_x + (gap - label.boundingRect().width()) / 2
                label.setPos(max(prev_x + 2, mid_x), y_top + 6)

            prev_x = curr_x
            prev_val = ev_raw
            prev_fmt = ev_fmt

        # Last segment to t1
        end_x = self._time_to_x(t1)
        if prev_val != 'x':
            self.addRect(
                QRectF(prev_x, y_top + 3, end_x - prev_x, ROW_HEIGHT - 6),
                QPen(COLOR_BUS_BORDER, 0.5), QBrush(COLOR_BUS_BG)
            )
            if end_x - prev_x > 50:
                # Check if state name display is enabled and value matches a state
                state_name = None
                if self._use_state_names.get(vcd_id) and vcd_id in self._signal_state_map:
                    state_name = self._lookup_state_name(prev_fmt, vcd_id)
                if state_name:
                    display = state_name
                else:
                    display = self._format_value_radix(prev_fmt, width, radix)
                label = self.addText(display, QFont("Menlo", self.wave_font_size))
                label.setDefaultTextColor(COLOR_BUS_TEXT)
                label.setPos(prev_x + 4, y_top + 6)

    def _draw_unknown_row(self, y_center, y_top, t0, t1):
        """画未知信号行 / Draw row for unknown/missing signal data."""
        x0 = self._time_to_x(t0)
        x1 = self._time_to_x(t1)
        self.addRect(
            QRectF(x0, y_top + 4, x1 - x0, ROW_HEIGHT - 8),
            QPen(QColor("#CC0000"), 1, Qt.DashLine), QBrush(Qt.NoBrush)
        )
        label = self.addText("no data", QFont("Menlo", max(6, self.wave_font_size - 1)))
        label.setDefaultTextColor(QColor("#CC0000"))
        label.setPos(x0 + 8, y_top + 6)

    def _draw_cursor(self):
        """画光标线 / Draw cursor marker line."""
        if self.cursor_time is None:
            return
        px = self._time_to_x(self.cursor_time)
        self.addLine(
            QLineF(px, 0, px, self.sceneRect().height()),
            QPen(COLOR_CURSOR, 1.5, Qt.DashLine)
        )

    def _draw_markers(self):
        """画所有 Mark 线 + 相邻 Mark 间的时间差 / Draw marker lines + deltas.
        Selected marker is drawn with a thicker, highlighted line and draggable handle."""
        if not self._markers:
            return
        h = self.sceneRect().height()
        marker_font_size = max(6, self.wave_font_size - 1)
        font = QFont("Helvetica", marker_font_size)

        for i, (name, t) in enumerate(self._markers):
            color = self._marker_color(i)
            px = self._time_to_x(t)

            # Selected marker: thicker, brighter line + glow
            if name == self._selected_marker:
                # Glow / outer highlight
                self.addLine(QLineF(px, 0, px, h), QPen(color.lighter(150), 4, Qt.DashLine))
                # Main line
                self.addLine(QLineF(px, 0, px, h), QPen(color, 2.5, Qt.DashLine))
            else:
                self.addLine(QLineF(px, 0, px, h), QPen(color, 1.5, Qt.DashLine))

        # Draw delta arrows between adjacent markers
        if len(self._markers) >= 2:
            for i in range(len(self._markers) - 1):
                n1, t1 = self._markers[i]
                n2, t2 = self._markers[i + 1]
                c1 = self._marker_color(i)
                c2 = self._marker_color(i + 1)

                x1 = self._time_to_x(t1)
                x2 = self._time_to_x(t2)
                delta_t = t2 - t1
                mid_x = (x1 + x2) / 2
                arrow_y = RULER_HEIGHT + 4

                # Horizontal line connecting markers
                self.addLine(QLineF(x1, arrow_y, x2, arrow_y), QPen(QColor("#FF6600"), 1))
                # Small vertical ticks
                self.addLine(QLineF(x1, arrow_y - 4, x1, arrow_y + 4), QPen(c1, 1.5))
                self.addLine(QLineF(x2, arrow_y - 4, x2, arrow_y + 4), QPen(c2, 1.5))

                # Delta label
                delta_label = self.addText(f"Δ={self._format_time(delta_t)}", font)
                delta_label.setDefaultTextColor(QColor("#FF6600"))
                tw = delta_label.boundingRect().width()
                delta_label.setPos(mid_x - tw / 2, arrow_y - 2)

        # Draw marker name labels at top (draggable handles)
        for i, (name, t) in enumerate(self._markers):
            color = self._marker_color(i)
            px = self._time_to_x(t)
            is_selected = (name == self._selected_marker)

            # Label background — highlighted if selected
            bg_color = color.lighter(130) if is_selected else color
            font_size = 10 if is_selected else 9
            label_text = self.addText(f" {name} ", QFont("Helvetica", font_size, QFont.Bold))
            label_text.setDefaultTextColor(QColor("#FFFFFF"))
            tw = label_text.boundingRect().width()
            th = label_text.boundingRect().height()
            # Extend background below ruler for click target
            bg_h = RULER_HEIGHT + (4 if is_selected else 0)
            if is_selected:
                self.addRect(QRectF(px - tw / 2, 0, tw, bg_h),
                            QPen(color.darker(120), 1), QBrush(bg_color))
            else:
                self.addRect(QRectF(px - tw / 2, 0, tw, bg_h),
                            QPen(Qt.NoPen), QBrush(bg_color))
            # Re-add text on top
            label_text2 = self.addText(f" {name} ", QFont("Helvetica", font_size, QFont.Bold))
            label_text2.setDefaultTextColor(QColor("#FFFFFF"))
            label_text2.setPos(px - tw / 2, 2)
            # Drag hint for selected marker
            if is_selected:
                hint = self.addText("↕", QFont("Helvetica", max(6, self.wave_font_size - 2)))
                hint.setDefaultTextColor(QColor("#FFFFFF"))
                hint.setPos(px + tw / 2 + 1, 2)

    def _draw_rubber_band(self):
        """画拖拽缩放选择框 / Draw rubber-band zoom selection rectangle."""
        x0 = min(self._rubber_start_x, self._rubber_end_x)
        x1 = max(self._rubber_start_x, self._rubber_end_x)
        w = x1 - x0
        if w < 2:
            return
        h = self.sceneRect().height()
        # Semi-transparent blue fill
        color = QColor(0, 120, 215, 60)
        self.addRect(QRectF(x0, 0, w, h), QPen(QColor(0, 120, 215), 1), QBrush(color))

    def zoom_from_rubberband(self) -> bool:
        """从拖拽框计算缩放 / Zoom to the time region selected by rubber band.
        Returns True if zoom was applied."""
        x0 = min(self._rubber_start_x, self._rubber_end_x)
        x1 = max(self._rubber_start_x, self._rubber_end_x)
        if x1 - x0 < 10:  # minimum 10 pixels
            return False
        t0 = self._x_to_time(x0)
        t1 = self._x_to_time(x1)
        if t1 - t0 < 100:  # minimum 100ps
            return False

        # Calculate new zoom to fit [t0, t1] into the viewport
        span = t1 - t0
        if self._view_width > 0 and span > 0:
            self.pixels_per_ps = max(5e-7, min(0.1, self._view_width / span))
        self._update_scene_rect()
        self.visible_start = t0
        self.visible_end = t1
        self._redraw()
        return True

    # ---- Mouse interaction for cursor ----

    def mouse_press_in_view(self, pos_in_view: QPointF):
        """Handle mouse press from view: set cursor time (called on short click)."""
        t = self._x_to_time(pos_in_view.x())
        if 0 <= t <= self._total_time():
            self.cursor_time = t
            self.cursor_moved.emit(t)
            self._redraw()


#============================================================================
# SignalLabelScene — 信号名标签场景 / signal name labels (fixed, no h-scroll)
#============================================================================

class SignalLabelScene(QGraphicsScene):
    """固定左侧信号名标签 / Fixed signal name label column.

    - Click → select a row (blue highlight)
    - Drag → reorder signal by moving it to a new row position
    """

    signal_selected = Signal(str)         # emits vcd_id of selected signal
    signal_reorder_requested = Signal(str, int)  # vcd_id, target_index

    def __init__(self, parent=None):
        super().__init__(parent)
        self._cache: WaveformDataCache | None = None
        self._displayed: list = []      # 渲染行序列（str 或 SignalGroup），波形侧的别名
        self._order: list = []          # 顶层序列，波形侧的别名（拖动分组要用）
        self._signal_color: dict[str, QColor] = {}
        self._selected_indices: set[int] = set()  # multi-select by index (supports duplicates)
        self._selection_anchor: int | None = None  # for Shift+Click range select

        self.label_font_size = 11  # synced from WaveformScene
        self.label_width = 170     # synced from label_view width
        self.extra_height = 0      # 底部补偿高度，见 WaveformPanel._sync_label_padding

        # Drag state
        self._drag_indices: list[int] = []   # indices of signals being dragged
        self._drag_start_y: float = 0.0
        self._drag_source_indices: list[int] = []  # original indices of dragged signals
        self._is_dragging = False

        self.setBackgroundBrush(QBrush(COLOR_BG))
        self._redraw()  # ensure proper initial scene

    def sync_from(self, waveform_scene: WaveformScene):
        """从 WaveformScene 同步信号列表 / Sync signal list from WaveformScene.

        `_displayed` 是**别名**（同一个 list 对象），所以波形侧的过滤必须原地切片赋值，
        不能整体重新赋值（见 bug.md B11）；`_order` 同理，拖动分组时要用。"""
        self._cache = waveform_scene._cache
        self._displayed = waveform_scene._displayed
        self._order = waveform_scene._order
        self._signal_color = waveform_scene._signal_color
        self.label_font_size = waveform_scene.wave_font_size
        self._redraw()

    def _redraw(self, drag_target_idx: int = -1):
        """Redraw with optional drag-drop indicator line."""
        self.clear()
        # 高度与波形场景一致（含同样的 200 下限），再补上视口高度差：
        # 两列场景高度一致 + 视口高度差补偿 → 滚动范围一致、居中偏移也一致。
        h = RULER_HEIGHT + len(self._displayed) * ROW_HEIGHT + 10
        self.setSceneRect(0, 0, self.label_width, max(h, 200) + self.extra_height)

        # 逐行归属（成员行缩进用）；_order 未同步时退化为"都没有分组"
        owners = wave_groups.row_owners(self._order)
        if len(owners) != len(self._displayed):
            owners = [None] * len(self._displayed)

        # Ruler area filler
        self.addRect(QRectF(0, 0, self.label_width, RULER_HEIGHT),
                     QPen(Qt.NoPen), QBrush(COLOR_RULER_BG))
        self.addLine(QLineF(0, RULER_HEIGHT, self.label_width, RULER_HEIGHT),
                     QPen(QColor("#CCCCCC"), 1))

        for idx, vcd_id in enumerate(self._displayed):
            # Skip rendering dragged rows (they follow the cursor visually)
            if idx in self._drag_indices:
                continue

            y_top = RULER_HEIGHT + idx * ROW_HEIGHT
            is_selected = (idx in self._selected_indices)

            if is_selected:
                bg_color = QColor("#0078D4")
                text_color = QColor("#FFFFFF")
                info_color = QColor("#CCDDFF")
            elif is_group(vcd_id):
                bg_color = COLOR_GROUP_BG
                text_color = QColor("#1F4E79")
                info_color = QColor("#7F7F7F")
            else:
                bg_color = COLOR_LABEL_BG_EVEN if idx % 2 == 0 else COLOR_LABEL_BG_ODD
                text_color = QColor("#333333")
                info_color = QColor("#999999")

            self.addRect(QRectF(0, y_top, self.label_width, ROW_HEIGHT),
                         QPen(Qt.NoPen), QBrush(bg_color))

            # ---- 组头行：折叠三角 + 组名 + 成员数 ----
            if is_group(vcd_id):
                self._draw_group_label(idx, vcd_id, y_top, is_selected)
                self.addLine(
                    QLineF(0, y_top + ROW_HEIGHT, self.label_width, y_top + ROW_HEIGHT),
                    QPen(QColor("#C7D6E8"), 1)
                )
                continue

            sig = None
            if self._cache and isinstance(vcd_id, str):
                sig = self._cache.get_signal(vcd_id)

            # 组内成员行整体右移一点，层级关系一眼可见
            indent = GROUP_INDENT_PX if (idx < len(owners) and owners[idx] is not None) else 0

            if sig:
                color = self._signal_color.get(vcd_id, QColor("#333"))
                if not is_selected:
                    self.addRect(QRectF(4 + indent, y_top + 9, 10, ROW_HEIGHT - 18),
                                 QPen(Qt.NoPen), QBrush(color))

                # Signal name with bit-width suffix, e.g. "state[3:0]"
                # 派生位切片的 full_path 里已经带了 [msb:lsb]，再加后缀会渲染成 rx_data[7:4][3:0]
                if sig.width > 1 and not (self._cache and self._cache.is_derived(vcd_id)):
                    name_suffix = f"[{sig.width - 1}:0]"
                else:
                    name_suffix = ""
                max_name_len = 35 - (indent // 4)
                base = sig.full_path if len(sig.full_path) < max_name_len else "..." + sig.full_path[-(max_name_len - 3):]
                display_name = base + name_suffix
                text = self.addText(display_name, QFont("Menlo", self.label_font_size))
                text.setDefaultTextColor(text_color)
                # Right-align within the label column
                text_w = text.boundingRect().width()
                text.setPos(self.label_width - text_w - 6 - indent, y_top + 5)

            self.addLine(
                QLineF(0, y_top + ROW_HEIGHT, self.label_width, y_top + ROW_HEIGHT),
                QPen(QColor("#E8E8E8"), 1)
            )

        # Draw drag target indicator line
        if drag_target_idx >= 0:
            indicator_y = RULER_HEIGHT + drag_target_idx * ROW_HEIGHT
            pen = QPen(QColor("#0078D4"), 2)
            self.addLine(QLineF(0, indicator_y, self.label_width, indicator_y), pen)
            # Small arrow triangle
            self.addLine(QLineF(0, indicator_y, 6, indicator_y - 4), pen)
            self.addLine(QLineF(0, indicator_y, 6, indicator_y + 4), pen)

    def _draw_group_label(self, idx: int, group, y_top: float, is_selected: bool):
        """组头行：折叠三角（▾/▸）+ 组名 + 成员数。三角区 = 最左 FOLD_ZONE_W 像素。"""
        tri_color = QColor("#FFFFFF") if is_selected else QColor("#1F4E79")
        cx, cy = 5.0 + FOLD_ZONE_W / 2, y_top + ROW_HEIGHT / 2
        if group.collapsed:
            # ▸ 收起：向右的三角
            shape = QPolygonF([QPointF(cx - 3, cy - 5), QPointF(cx - 3, cy + 5),
                               QPointF(cx + 4, cy)])
        else:
            # ▾ 展开：向下的三角
            shape = QPolygonF([QPointF(cx - 5, cy - 3), QPointF(cx + 5, cy - 3),
                               QPointF(cx, cy + 4)])
        self.addPolygon(shape, QPen(Qt.NoPen), QBrush(tri_color))

        name_font = QFont("Menlo", self.label_font_size)
        name_font.setBold(True)
        text = self.addText(group.name, name_font)
        text.setDefaultTextColor(tri_color)
        text.setPos(FOLD_ZONE_W + 4, y_top + 5)

        # 成员数：跟在组名右边（收起时标注一下，免得不知道里面有几条）
        count_font = QFont("Menlo", max(8, self.label_font_size - 2))
        cnt = self.addText(f"({len(group.members)})", count_font)
        cnt.setDefaultTextColor(QColor("#FFFFFF") if is_selected else QColor("#7F7F7F"))
        cnt.setPos(FOLD_ZONE_W + 8 + text.boundingRect().width(), y_top + 7)

    def select_signal(self, vcd_id: str | None):
        """选中一个信号行 / Select a single signal row by vcd_id (first match).
        Pass None to deselect all."""
        if vcd_id is None:
            self._selected_indices = set()
            self._selection_anchor = None
        else:
            # Find first occurrence
            try:
                idx = self._displayed.index(vcd_id)
            except ValueError:
                return
            self._selected_indices = {idx}
            self._selection_anchor = idx
        self._redraw()
        if vcd_id:
            self.signal_selected.emit(vcd_id)

    def select_at_index(self, idx: int | None):
        """选中指定索引的信号行 / Select signal row at given index (None = deselect all)."""
        if idx is None:
            self._selected_indices = set()
            self._selection_anchor = None
        else:
            self._selected_indices = {idx}
            self._selection_anchor = idx
        self._redraw()
        # signal_selected 是 Signal(str)：组头行不能往这儿发，否则 PySide6 直接抛 TypeError
        if idx is not None and 0 <= idx < len(self._displayed):
            item = self._displayed[idx]
            if isinstance(item, str):
                self.signal_selected.emit(item)

    def signal_at_y(self, y: float) -> str | SignalGroup | None:
        """返回指定 Y 坐标处的行元素 / Return the row item at given Y position.

        组头行返回 SignalGroup 对象，信号行返回 vcd_id（字符串）。"""
        idx = int((y - RULER_HEIGHT) / ROW_HEIGHT)
        if 0 <= idx < len(self._displayed):
            return self._displayed[idx]
        return None

    def signal_index_at_y(self, y: float) -> int | None:
        """返回指定 Y 坐标处的信号索引 / Return signal index at given Y position."""
        idx = int((y - RULER_HEIGHT) / ROW_HEIGHT)
        if 0 <= idx < len(self._displayed):
            return idx
        return None

    def group_at_y(self, y: float) -> SignalGroup | None:
        """该 Y 位置所属的组（组头行返回它自己，顶层信号行返回 None）。"""
        idx = self.signal_index_at_y(y)
        return None if idx is None else wave_groups.group_at_row(self._order, idx)

    def fold_hit_at(self, x: float, y: float) -> int | None:
        """命中了组头行的折叠三角区就返回该行号 / Fold triangle hit test.

        命中区只有组头行最左侧 FOLD_ZONE_W 像素宽，不会和"点整行选中/拖动"打架。"""
        idx = self.signal_index_at_y(y)
        if idx is None or x > FOLD_ZONE_W:
            return None
        return idx if is_group(self._displayed[idx]) else None

    def _target_index_at_y(self, y: float) -> int:
        """Return the insertion index for a given Y coordinate (clamped)."""
        idx = int((y - RULER_HEIGHT + ROW_HEIGHT / 2) / ROW_HEIGHT)
        return max(0, min(idx, len(self._displayed)))

    def _drop_index(self, y: float) -> int:
        """落点 = **摘除被拖走的行之后**，落点上方还剩多少行（0..剩余行数）。

        这个坐标系和 wave_groups.move_rows 的 dest_row 一致 —— 落点上方那些随块一起
        被拖走的行不算数，否则整块拖到下方时每个落点都会差 len(_drag_indices) 行。"""
        n = self._target_index_at_y(y)
        moved = set(self._drag_indices)
        return sum(1 for i in range(n) if i not in moved)

    # ---- Multi-select helpers ----

    @property
    def selected_vcd_ids(self) -> set[str]:
        """Return unique vcd_ids of selected rows (for backward compat).

        组头行不是信号，跳过 —— 否则下游会把 SignalGroup 当 vcd_id 用。"""
        return {self._displayed[i] for i in self._selected_indices
                if 0 <= i < len(self._displayed) and isinstance(self._displayed[i], str)}

    def selected_rows(self) -> list[int]:
        """选中的渲染行号（升序）。"""
        return sorted(i for i in self._selected_indices if 0 <= i < len(self._displayed))

    def clear_selection(self):
        self._selected_indices = set()
        self._selection_anchor = None

    def drag_block_has_group(self) -> bool:
        """当前拖动块里是否含组头行 —— 决定"搬整组"还是"搬信号"。"""
        return any(is_group(self._displayed[i]) for i in self._drag_indices
                   if 0 <= i < len(self._displayed))

    @property
    def selected_indices(self) -> set[int]:
        """Return selected indices (preferred for duplicate-aware operations)."""
        return self._selected_indices.copy()

    def _select_range(self, from_idx: int, to_idx: int):
        """Select all signals between from_idx and to_idx in display order."""
        if not (0 <= from_idx < len(self._displayed) and 0 <= to_idx < len(self._displayed)):
            return
        lo, hi = min(from_idx, to_idx), max(from_idx, to_idx)
        for i in range(lo, hi + 1):
            self._selected_indices.add(i)
        self._redraw()

    # ---- Drag handling (called from WaveformPanel eventFilter) ----

    def start_drag(self, y: float, ctrl: bool = False, shift: bool = False) -> str | None:
        """Begin dragging. Supports Ctrl+Click (toggle) and Shift+Click (range select).
        Returns the vcd_id at the clicked position, or None."""
        idx = self.signal_index_at_y(y)
        if idx is None:
            return None
        vcd_id = self._displayed[idx]

        if ctrl:
            # Ctrl+Click: toggle selection at this index — cancel any pending drag
            self._drag_indices = []
            self._is_dragging = False
            if idx in self._selected_indices:
                self._selected_indices.discard(idx)
            else:
                self._selected_indices.add(idx)
            self._selection_anchor = idx
            self._redraw()
            return None  # Ctrl+Click doesn't start a drag
        elif shift and self._selection_anchor is not None:
            # Shift+Click: range select — cancel any pending drag
            self._drag_indices = []
            self._is_dragging = False
            saved_anchor = self._selection_anchor
            self._selected_indices = {saved_anchor}
            self._select_range(saved_anchor, idx)
            self._redraw()
            return None  # Shift+Click doesn't start a drag

        # Plain click
        if idx in self._selected_indices:
            # Click on already-selected signal → drag the whole selection
            self._drag_indices = sorted(self._selected_indices)
        else:
            # Click on unselected signal → select only it and drag
            self._selected_indices = {idx}
            self._selection_anchor = idx
            self._drag_indices = [idx]

        # 拖组头 = 搬整块：把该组在渲染序列里占的行（组头 + 成员）全部算进来，
        # 否则落点换算按"只拖了一行"来算，整块会掉错位置（少算的正是成员行数）。
        block = set()
        for r in list(self._drag_indices):
            if not (0 <= r < len(self._displayed)):
                continue
            item = self._displayed[r]
            if is_group(item):
                block.update(wave_groups.rows_of_group(self._order, item))
        if block:
            self._drag_indices = sorted(set(self._drag_indices) | block)

        self._drag_source_indices = list(self._drag_indices)
        self._drag_start_y = y
        self._is_dragging = False
        self._redraw()
        return vcd_id

    def update_drag(self, y: float) -> int:
        """Update drag position. Returns current target insertion index (for the drop line)."""
        if not self._drag_indices:
            return -1
        if abs(y - self._drag_start_y) > 5:
            self._is_dragging = True
        target = self._drop_index(y)
        self._redraw(target)
        return target

    def end_drag(self, y: float) -> list[tuple[int, int]] | None:
        """Finish dragging. Returns list of (source_idx, target_idx) for reorder, or None.

        target 以"摘除被拖行之后"的序列为准（见 _drop_index）。"""
        if not self._drag_indices:
            return None
        target = self._drop_index(y)        # 必须在清空 _drag_indices 之前算
        dragged_indices = list(self._drag_indices)
        self._drag_indices = []
        was_dragging = self._is_dragging
        self._is_dragging = False

        # Filter out stale indices that are no longer valid
        dragged_indices = [i for i in dragged_indices if 0 <= i < len(self._displayed)]
        if not dragged_indices:
            self._redraw()
            return None

        if not was_dragging:
            self._redraw()
            return None

        self._redraw()
        # Return (source_idx, target_idx) for each dragged signal
        return [(src, target + offset) for offset, src in enumerate(dragged_indices)]


#============================================================================
# WaveformPanel — 波形面板 / waveform panel (combines labels + traces)
#============================================================================

class WaveformPanel(QWidget):
    """下方面板：波形显示区。
    Bottom panel: waveform display area with labels and traces.
    """

    cursor_moved = Signal(int)
    trace_driver_requested = Signal(str)    # vcd_id → Trace Driver
    trace_uses_requested = Signal(str)      # vcd_id → Trace Uses
    signal_locate_requested = Signal(str)   # 波形标签双击 → 代码定位

    def __init__(self, parent=None):
        super().__init__(parent)
        self._cache: WaveformDataCache | None = None
        self._clipboard: list[str] = []  # copied signal vcd_ids
        self._rtl_provider = None   # callable(vcd_id)->module RTL text, set by main window

        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # Toolbar
        toolbar = QHBoxLayout()
        toolbar.setSpacing(4)

        self.btn_zoom_in = QPushButton("+")
        self.btn_zoom_in.setFixedSize(28, 28)
        self.btn_zoom_in.setToolTip("Zoom In (Ctrl+Scroll Up)")
        toolbar.addWidget(self.btn_zoom_in)

        self.btn_zoom_out = QPushButton("−")
        self.btn_zoom_out.setFixedSize(28, 28)
        self.btn_zoom_out.setToolTip("Zoom Out (Ctrl+Scroll Down)")
        toolbar.addWidget(self.btn_zoom_out)

        self.btn_zoom_fit = QPushButton("Fit")
        self.btn_zoom_fit.setToolTip("Zoom to Fit")
        toolbar.addWidget(self.btn_zoom_fit)

        toolbar.addSpacing(12)

        # Reorder buttons
        self.btn_move_up = QPushButton("▲")
        self.btn_move_up.setFixedSize(28, 28)
        self.btn_move_up.setToolTip("Move selected signal up")
        self.btn_move_up.setEnabled(False)
        toolbar.addWidget(self.btn_move_up)

        self.btn_move_down = QPushButton("▼")
        self.btn_move_down.setFixedSize(28, 28)
        self.btn_move_down.setToolTip("Move selected signal down")
        self.btn_move_down.setEnabled(False)
        toolbar.addWidget(self.btn_move_down)

        self.btn_remove_signal = QPushButton("✕")
        self.btn_remove_signal.setFixedSize(28, 28)
        self.btn_remove_signal.setToolTip("Remove selected signal from waveform")
        self.btn_remove_signal.setEnabled(False)
        toolbar.addWidget(self.btn_remove_signal)

        toolbar.addSpacing(12)

        # 分组菜单：这是**隐藏分组唯一的恢复入口**，所以常驻工具栏（见 bug.md B11）。
        # 用 clicked → menu.exec() 而不是 setMenu/InstantPopup —— 全文件菜单都是 exec() 这一套，
        # bug.md 的自查块把 QMenu 换成合成菜单，setMenu 会拿到非 QMenu 直接 TypeError（B7/B8 自查）。
        self.btn_groups = QToolButton()
        self.btn_groups.setText("📁 分组")
        self.btn_groups.setToolTip("信号分组：显示/隐藏、折叠、重命名、取消分组")
        self.btn_groups.setEnabled(False)          # 还没有分组时置灰
        self._group_menu = QMenu(self)
        self.btn_groups.clicked.connect(self._popup_group_menu)
        toolbar.addWidget(self.btn_groups)

        toolbar.addSpacing(12)

        self.cursor_label = QLabel("Cursor: —")
        self.cursor_label.setStyleSheet("color: #CC0000; font-weight: bold;")
        toolbar.addWidget(self.cursor_label)

        toolbar.addSpacing(8)

        self.marker_label = QLabel("")
        self.marker_label.setStyleSheet("font-size: 10px;")
        toolbar.addWidget(self.marker_label)

        toolbar.addSpacing(8)

        zoom_hint = QLabel("Drag left→zoom | Click marker→drag | Right-click wave→marker(snap▼)")
        zoom_hint.setStyleSheet("color: #888; font-size: 10px;")
        toolbar.addWidget(zoom_hint)

        toolbar.addStretch()

        self.signal_count_label = QLabel("0 signals")
        toolbar.addWidget(self.signal_count_label)

        layout.addLayout(toolbar)

        # Main area: labels + traces with synced vertical scroll
        # Label scene + view
        self.label_scene = SignalLabelScene()
        self.label_view = QGraphicsView(self.label_scene)
        self.label_view.setMinimumWidth(80)
        self.label_view.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.label_view.setVerticalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.label_view.setFrameShape(QFrame.NoFrame)
        self.label_view.setRenderHint(QPainter.Antialiasing)

        # Waveform scene + view
        self.wave_scene = WaveformScene()
        self.wave_view = QGraphicsView(self.wave_scene)
        self.wave_view.setFrameShape(QFrame.NoFrame)
        self.wave_view.setRenderHint(QPainter.Antialiasing)
        self.wave_view.setDragMode(QGraphicsView.NoDrag)
        self.wave_view.setTransformationAnchor(QGraphicsView.NoAnchor)
        self.wave_view.setResizeAnchor(QGraphicsView.NoAnchor)
        self.wave_view.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOn)
        self.wave_view.setVerticalScrollBarPolicy(Qt.ScrollBarAsNeeded)

        # Splitter for resizable signal label column
        self._label_splitter = QSplitter(Qt.Horizontal)
        self._label_splitter.addWidget(self.label_view)
        self._label_splitter.addWidget(self.wave_view)
        self._label_splitter.setSizes([LABEL_WIDTH_DEFAULT, 600])
        self._label_splitter.setHandleWidth(3)
        self._label_splitter.splitterMoved.connect(self._on_label_width_changed)

        layout.addWidget(self._label_splitter, 1)

        # Time scrollbar
        self.time_scroll = QScrollBar(Qt.Horizontal)
        self.time_scroll.setMinimum(0)
        self.time_scroll.setMaximum(1000)
        layout.addWidget(self.time_scroll)

        # Connections
        self.btn_zoom_in.clicked.connect(lambda: self._zoom(2.0))
        self.btn_zoom_out.clicked.connect(lambda: self._zoom(0.5))
        self.btn_zoom_fit.clicked.connect(self._zoom_fit)
        self.btn_move_up.clicked.connect(self._move_selected_up)
        self.btn_move_down.clicked.connect(self._move_selected_down)
        self.btn_remove_signal.clicked.connect(self._remove_selected_signal)

        # Sync time scrollbar with view horizontal scroll
        h_sb = self.wave_view.horizontalScrollBar()
        h_sb.valueChanged.connect(self._on_view_h_scroll)
        self.time_scroll.valueChanged.connect(self._on_time_scroll)

        # View resize → update visible range
        self.wave_view.viewport().installEventFilter(self)
        self.wave_view.setMouseTracking(True)

        # Label view click → select signal for reorder
        self.label_view.viewport().installEventFilter(self)

        # Sync label view vertical scroll with waveform view
        v_sb = self.wave_view.verticalScrollBar()
        v_sb.valueChanged.connect(self._sync_v_scroll)

        # Cursor signal forwarding
        self.wave_scene.cursor_moved.connect(self._on_cursor_moved)

        # Label selection → enable/disable reorder buttons
        self.label_scene.signal_selected.connect(self._on_label_selection_changed)

        # 分组结构变更 → 刷新工具栏分组菜单 + 计数文案 + 标签列重新取别名。
        # 这是结构变更后的**唯一刷新入口**，别处不用再手动 sync_from（会重复重绘）。
        self.wave_scene.groups_changed.connect(self._refresh_group_menu)
        self.wave_scene.groups_changed.connect(self._update_count_label)
        self.wave_scene.groups_changed.connect(self._on_wave_structure_changed)
        self._refresh_group_menu()

        # Deferred label width sync — QSplitter.splitterMoved may not fire
        # during initial layout, so sync after the event loop starts.
        from PySide6.QtCore import QTimer
        QTimer.singleShot(0, self._sync_label_width)
        # 视口高度差（波形列的水平滚动条）也要等布局完成才知道
        QTimer.singleShot(0, self._sync_label_padding)

        # Keyboard shortcuts for copy/paste (work when this panel has focus)
        self._shortcut_copy = QShortcut(QKeySequence("Ctrl+C"), self)
        self._shortcut_copy.activated.connect(self._copy_selected)
        self._shortcut_paste = QShortcut(QKeySequence("Ctrl+V"), self)
        self._shortcut_paste.activated.connect(self._paste_signals)

    def _sync_label_width(self):
        """Sync label scene width from actual view width after layout."""
        w = self.label_view.width()
        if w > 0:
            self.label_scene.label_width = w
            self.label_scene._redraw()

    def _update_visible_range(self):
        """更新场景可见时间范围 / Update scene visible time range."""
        rect = self.wave_view.mapToScene(
            self.wave_view.viewport().rect()
        ).boundingRect()
        t0 = self.wave_scene._x_to_time(rect.left())
        t1 = self.wave_scene._x_to_time(rect.right())
        self.wave_scene.visible_start = max(0, t0)
        self.wave_scene.visible_end = max(t0 + 1, t1)
        self.wave_scene.set_view_width(self.wave_view.viewport().width())

    def eventFilter(self, obj, event):
        """处理波形视图的鼠标事件 / Handle mouse events on waveform view.
        - Left-click on marker → select + drag marker
        - Left-click drag → rubber-band zoom
        - Short left-click → place cursor
        - Ctrl+Wheel → zoom; Shift+Wheel → h-scroll; Wheel → v-scroll
        - Right-click on waveform → marker menu
        - Right-click on label → color/radix menu
        """
        from PySide6.QtCore import QEvent
        if obj is self.wave_view.viewport():
            if event.type() == QEvent.Resize:
                self._update_visible_range()
                self.wave_scene._redraw()
                self._update_scrollbars()
                self._sync_label_padding()   # 波形列滚动条出现/消失会改变视口高度
                return False
            elif event.type() == QEvent.MouseButtonPress:
                if event.button() == Qt.LeftButton:
                    pos = self.wave_view.mapToScene(event.pos())
                    # Check if clicking on a marker → select + start drag
                    marker = self.wave_scene.marker_at_x(pos.x(), tolerance_px=12)
                    if marker:
                        self.wave_scene._selected_marker = marker
                        self.wave_scene._dragging_marker = marker
                        self.wave_scene._redraw()
                        self._update_marker_info()
                        return True
                    # Otherwise start rubber-band zoom
                    self.wave_scene._rubber_active = True
                    self.wave_scene._rubber_start_x = pos.x()
                    self.wave_scene._rubber_end_x = pos.x()
                    # Deselect marker on click elsewhere
                    if self.wave_scene._selected_marker:
                        self.wave_scene._selected_marker = None
                        self.wave_scene._redraw()
                    return True
                elif event.button() == Qt.RightButton:
                    pos = self.wave_view.mapToScene(event.pos())
                    self._show_marker_menu(event.globalPos(), pos)
                    return True
            elif event.type() == QEvent.MouseMove:
                if self.wave_scene._dragging_marker:
                    pos = self.wave_view.mapToScene(event.pos())
                    time_ps = self.wave_scene._x_to_time(pos.x())
                    # Snap to nearest edge if within tolerance
                    snap_t = self.wave_scene.find_nearest_edge(time_ps, tolerance_px=20)
                    if snap_t is not None:
                        time_ps = snap_t
                    self.wave_scene.move_marker(self.wave_scene._dragging_marker, time_ps)
                    self._update_marker_info()
                    self.label_scene.sync_from(self.wave_scene)
                    return True
                elif self.wave_scene._rubber_active:
                    pos = self.wave_view.mapToScene(event.pos())
                    self.wave_scene._rubber_end_x = pos.x()
                    self.wave_scene._redraw()
                    return True
            elif event.type() == QEvent.MouseButtonRelease:
                if event.button() == Qt.LeftButton:
                    if self.wave_scene._dragging_marker:
                        # Finalize marker drag position
                        pos = self.wave_view.mapToScene(event.pos())
                        time_ps = self.wave_scene._x_to_time(pos.x())
                        snap_t = self.wave_scene.find_nearest_edge(time_ps, tolerance_px=20)
                        if snap_t is not None:
                            time_ps = snap_t
                        self.wave_scene.move_marker(self.wave_scene._dragging_marker, time_ps)
                        self.wave_scene._dragging_marker = None
                        self.wave_scene._redraw()
                        self._update_marker_info()
                        self.label_scene.sync_from(self.wave_scene)
                        return True
                    elif self.wave_scene._rubber_active:
                        self.wave_scene._rubber_active = False
                        dx = abs(self.wave_scene._rubber_end_x - self.wave_scene._rubber_start_x)
                        if dx < 5:
                            # Short click → place cursor
                            pos = self.wave_view.mapToScene(event.pos())
                            self.wave_scene.mouse_press_in_view(pos)
                        else:
                            # Drag → rubber-band zoom
                            if self.wave_scene.zoom_from_rubberband():
                                t0 = self.wave_scene.visible_start
                                new_x = t0 * self.wave_scene.pixels_per_ps
                                self.wave_view.horizontalScrollBar().setValue(int(new_x))
                                self._update_visible_range()
                                self._update_scrollbars()
                        self.wave_scene._rubber_active = False
                        self.wave_scene._redraw()
                        self.label_scene.sync_from(self.wave_scene)
                        return True
                elif event.button() == Qt.RightButton:
                    return True  # Already handled in press
            elif event.type() == QEvent.Wheel:
                return self._handle_wheel(event, self.wave_view)
            elif event.type() == QEvent.KeyPress:
                if event.key() == Qt.Key_Escape:
                    if self.wave_scene._dragging_marker:
                        self.wave_scene._dragging_marker = None
                        self.wave_scene._redraw()
                        self._update_marker_info()
                        return True
                    if self.wave_scene._selected_marker:
                        self.wave_scene._selected_marker = None
                        self.wave_scene._redraw()
                        return True
                elif event.key() == Qt.Key_F:
                    # F key → zoom to fit full waveform
                    self._zoom_fit()
                    return True
        elif obj is self.label_view.viewport():
            if event.type() == QEvent.Resize:
                # Update label scene width and redraw when view resizes
                w = self.label_view.width()
                if w > 0 and w != self.label_scene.label_width:
                    self.label_scene.label_width = w
                    self.label_scene._redraw()
                    # Also sync waveform scene rect to match
                    self.wave_scene.set_view_width(self.wave_view.viewport().width())
                    self.wave_scene._redraw()
                self._sync_label_padding()
                return False
            elif event.type() == QEvent.MouseButtonDblClick:
                # 双击组头 → 折叠/展开；双击波形信号名 → 代码窗口快速定位该信号
                if event.button() == Qt.LeftButton:
                    pos = self.label_view.mapToScene(event.pos())
                    item = self.label_scene.signal_at_y(pos.y())
                    if is_group(item):
                        self.wave_scene.toggle_group_collapsed(item)
                        self.label_scene.clear_selection()
                        self.label_scene.sync_from(self.wave_scene)
                        return True
                    fp = self._fp_of_vcd(item)
                    if fp:
                        self.signal_locate_requested.emit(fp)
                    return True
            elif event.type() == QEvent.Wheel:
                # 标签列上的滚轮也走同一套处理（垂直滚动只由波形视图承担），
                # 否则只有标签列自己滚、右侧波形不跟随。
                return self._handle_wheel(event, self.label_view)
            elif event.type() == QEvent.MouseButtonPress:
                if event.button() == Qt.LeftButton:
                    # Ensure label view has focus for keyboard shortcuts
                    self.label_view.viewport().setFocus()
                    pos = self.label_view.mapToScene(event.pos())
                    # 折叠三角命中 → 只切折叠，绝不进入拖动（免得留下悬空的 _drag_indices）
                    fold_idx = self.label_scene.fold_hit_at(pos.x(), pos.y())
                    if fold_idx is not None:
                        self.wave_scene.toggle_group_collapsed(
                            self.wave_scene.item_at_row(fold_idx))
                        self.label_scene.clear_selection()
                        return True
                    # Left-click → select / start drag (with multi-select support)
                    ctrl = bool(event.modifiers() & Qt.ControlModifier)
                    shift = bool(event.modifiers() & Qt.ShiftModifier)
                    result = self.label_scene.start_drag(pos.y(), ctrl=ctrl, shift=shift)
                    # Enable/disable buttons based on whether anything is selected
                    self._on_label_selection_changed(result)
                    return True
                elif event.button() == Qt.RightButton:
                    # 右键组头 → 分组菜单；右键信号 → 颜色/进制菜单（带分组段）
                    pos = self.label_view.mapToScene(event.pos())
                    item = self.label_scene.signal_at_y(pos.y())
                    idx = self.label_scene.signal_index_at_y(pos.y())
                    if is_group(item):
                        self._show_group_menu(event.globalPos(), item)
                    elif item and idx is not None:
                        self._show_color_menu(event.globalPos(), item, idx)
                    return True
            elif event.type() == QEvent.MouseMove:
                pos = self.label_view.mapToScene(event.pos())
                self.label_scene.update_drag(pos.y())
                return True
            elif event.type() == QEvent.MouseButtonRelease:
                pos = self.label_view.mapToScene(event.pos())
                dragged_rows = list(self.label_scene._drag_indices)
                has_group = self.label_scene.drag_block_has_group()
                results = self.label_scene.end_drag(pos.y())
                if results:
                    dest = min(t for _s, t in results)
                    if has_group:
                        # 拖的是组头 → 整块搬（组头 + 成员一起走）
                        self.wave_scene.move_group_by_visible_rows(dragged_rows, dest)
                    else:
                        self.wave_scene.move_rows_by_visible_indices(results)
                    self.label_scene.sync_from(self.wave_scene)
                    # 选中落位后的这一块（整块在最终序列里是连续的）
                    self._reselect_rows(range(dest, dest + len(results)))
                return True
        return super().eventFilter(obj, event)

    def _copy_selected(self):
        """Copy selected signal vcd_ids to internal clipboard.（组头行不进剪贴板）"""
        if not self.label_scene._selected_indices:
            return
        indices = sorted(self.label_scene._selected_indices)
        self._clipboard = [self.wave_scene._displayed[i]
                          for i in indices
                          if 0 <= i < len(self.wave_scene._displayed)
                          and isinstance(self.wave_scene._displayed[i], str)]
        self.cursor_label.setText(f"📋 Copied {len(self._clipboard)} signal(s)")

    def _reselect_rows(self, rows):
        """选中给定的一批渲染行（拖动落位后保持选中）。"""
        rows = [r for r in sorted(set(rows)) if 0 <= r < len(self.wave_scene._displayed)]
        self.label_scene._selected_indices = set(rows)
        self.label_scene._selection_anchor = rows[0] if rows else None
        self.label_scene._redraw()
        head = self.wave_scene._displayed[rows[0]] if rows else None
        # 组头行没有 vcd_id，别把 SignalGroup 喂给下游（下游按字符串拼路径）
        self._on_label_selection_changed(head if isinstance(head, str) else None)

    def _paste_signals(self):
        """Paste copied signals as new instances in the waveform."""
        if not self._clipboard or not self._cache:
            return
        # 报**实际**加进去的条数：换过 VCD 之后剪贴板里可能有查不到的 id（会被丢掉，
        # 见 bug.md B13），照抄剪贴板长度会显示"粘了 3 条"而实际一行没加
        n = self.add_signals(self._clipboard) or 0
        self.cursor_label.setText(f"📋 Pasted {n} signal(s)")

    def _fp_of_vcd(self, vcd_id: str | None) -> str | None:
        """把波形行存的 vcd_id 解析成唯一 full_path（trace / 定位用）。
        VCD 可能给不同作用域的同名信号复用同一 id，所以一律回落到 full_path。
        注意：波形行里还可能有组头对象，`if not vcd_id` 挡不住它，必须显式判类型。
        派生位切片（`父id[7:4]`）要回到**父信号**的 full_path —— 切片不是 VCD 里真实存在的信号，
        Trace / 双击跳代码都得找它的父（见 bug.md B13）。"""
        if not isinstance(vcd_id, str) or not vcd_id:
            return None
        if self._cache:
            real = self._cache.slice_parent(vcd_id) or vcd_id
            s = self._cache.get_signal(real)
            if s:
                return s.full_path
        return vcd_id

    def _show_color_menu(self, global_pos, vcd_id: str, idx: int | None = None):
        """弹出信号标签列的右键菜单（构造见 `_build_color_menu`）。"""
        menu = self._build_color_menu(vcd_id, idx)
        menu.exec(global_pos)

    def _build_color_menu(self, vcd_id: str, idx: int | None = None) -> QMenu:
        """构造信号标签列的右键菜单，**不弹出**（`QMenu.exec` 是纯 C++ 非虚函数，
        Python 侧 patch 不掉，无头自查只能拿到菜单对象查 `actions()`，见 bug.md B13）。

        idx: display index for precise removal (supports duplicate signals)."""
        from PySide6.QtWidgets import QColorDialog
        sig = None
        if self._cache:
            sig = self._cache.get_signal(vcd_id)

        menu = QMenu(self)
        label = sig.name if sig else vcd_id
        menu.addAction(f"Signal: {label}").setEnabled(False)
        menu.addSeparator()

        # Trace Driver / Trace Uses（trace 一律按唯一 full_path 追溯）
        # 派生位切片追的是**它的父信号**（切片不是 RTL 里真实存在的信号），文案里点明，
        # 免得用户以为在追这一位（见 bug.md B13）。
        _spec = self._cache.slice_spec(vcd_id) if self._cache else None
        _owner = self._cache.get_signal(_spec[0]) if _spec else None
        _suffix = f"（父信号 {_owner.name}）" if _owner is not None else ""
        fp = self._fp_of_vcd(vcd_id)
        act_tr = menu.addAction(f"🔍 Trace Driver（追溯驱动源码）{_suffix}")
        act_tr.triggered.connect(lambda: self.trace_driver_requested.emit(fp))
        act_tu = menu.addAction(f"📖 Trace Uses（在日志列出使用它的行）{_suffix}")
        act_tu.triggered.connect(lambda: self.trace_uses_requested.emit(fp))
        menu.addSeparator()

        # ---- Radix submenu for multi-bit signals ----
        if sig and sig.width > 1:
            radix_menu = menu.addMenu("🔢 Radix")
            current_radix = self.wave_scene.get_signal_radix(vcd_id)
            radix_options = [
                ("Hex (4'hA)", WaveformScene.RADIX_HEX),
                ("Binary (8'b...)", WaveformScene.RADIX_BIN),
                ("Decimal (signed)", WaveformScene.RADIX_DEC),
                ("Octal", WaveformScene.RADIX_OCT),
                ("Unsigned", WaveformScene.RADIX_UNSIGNED),
            ]
            for text, mode in radix_options:
                action = radix_menu.addAction(text)
                action.setCheckable(True)
                action.setChecked(mode == current_radix)
                action.triggered.connect(
                    lambda checked, m=mode, v=vcd_id: self.wave_scene.set_signal_radix(v, m)
                )

            # ---- State Names toggle (for signals with state maps) ----
            # 派生位切片**不给**状态名：切片之后数值下标变了（rx_data[7:4] 的值不再等于父的编码），
            # 沿用父信号的状态映射只会张冠李戴，所以整块藏掉（Radix 保留，位段照样能切进制）。
            if not self._cache.is_derived(vcd_id):
                state_map = self.wave_scene.get_state_map(vcd_id)
                if state_map:
                    radix_menu.addSeparator()
                    state_action = radix_menu.addAction("🔤 State Names")
                    state_action.setCheckable(True)
                    state_action.setChecked(self.wave_scene.get_use_state_names(vcd_id))
                    state_action.triggered.connect(
                        lambda checked, v=vcd_id: self._toggle_state_names(v)
                    )
                else:
                    # no map yet → offer on-demand per-FSM auto-detect for this signal
                    detect_action = radix_menu.addAction("🔤 Show State Names (auto-detect)")
                    detect_action.triggered.connect(
                        lambda checked=False, v=vcd_id: self._detect_show_state_names(v)
                    )

                # Edit State Names option
                radix_menu.addSeparator()
                edit_states_action = radix_menu.addAction("📝 Edit State Names...")
                edit_states_action.triggered.connect(
                    lambda checked, v=vcd_id: self._edit_state_names(v)
                )

            menu.addSeparator()

        # ---- ➕ 显示位 / 位段（派生位切片，见 bug.md B13）----
        if sig and self._cache:
            if self._cache.is_derived(vcd_id):
                # 已经是切片了 → 给一条回父信号的路（想看回整条总线时不用去别处找）
                spec = self._cache.slice_spec(vcd_id)
                parent = self._cache.get_signal(spec[0]) if spec else None
                if parent is not None:
                    bits_menu = menu.addMenu("➕ 显示位 ▸")
                    act_full = bits_menu.addAction(
                        f"↩ 显示完整信号 {parent.name}（{parent.width} 位）")
                    act_full.triggered.connect(
                        lambda checked=False, p=parent.vcd_id: self.add_signals([p]))
                    menu.addSeparator()
            elif sig.width > 1:
                bits_menu = menu.addMenu("➕ 显示位 ▸")
                # 位宽大的（如 256 位 case_name）不逐位列，只留下面的手输入口
                if sig.width <= 32:
                    for b in range(sig.width - 1, -1, -1):
                        act = bits_menu.addAction(f"{sig.name}[{b}]")
                        act.triggered.connect(
                            lambda checked=False, p=vcd_id, bb=b:
                                self.add_bit_slice(p, bb, bb))
                bits_menu.addSeparator()
                ask = bits_menu.addAction("指定位 / 位段…")
                ask.triggered.connect(lambda checked=False, p=vcd_id: self._prompt_bit_spec_by_id(p))
                menu.addSeparator()

        # ---- 分组 / Grouping ----
        # 右键落在"当前多选之外"的行时，先把选择收敛到这一行（与拖动的语义一致），
        # 这样"多选 → 右键 → 新建分组"才成立。
        if idx is not None and idx not in self.label_scene._selected_indices:
            self.label_scene.select_at_index(idx)
        sel = self.label_scene.selected_rows()
        cur_group = self.wave_scene.group_at_row(sel[0]) if sel else None

        grp = menu.addMenu("📁 分组")
        act_new = grp.addAction("新建分组…")
        act_new.setEnabled(bool(sel))
        act_new.triggered.connect(self._create_group_from_selection)
        act_add = grp.addMenu("加入分组 ▸")
        groups = self.wave_scene.groups()
        if groups:
            for g in groups:
                a = act_add.addAction(f"{g.name}  ({len(g.members)})")
                a.triggered.connect(lambda checked=False, gg=g: self._add_selection_to_group(gg))
        else:
            act_add.setEnabled(False)
        act_out = grp.addAction("移出分组")
        act_out.setEnabled(cur_group is not None)
        act_out.triggered.connect(self._remove_selection_from_group)

        menu.addSeparator()

        # Quick color presets
        preset_colors = [
            ("🔵 Blue", QColor("#2196F3")),
            ("🟢 Green", QColor("#4CAF50")),
            ("🟠 Orange", QColor("#FF9800")),
            ("🟣 Purple", QColor("#9C27B0")),
            ("🔴 Red", QColor("#E91E63")),
            ("🟤 Brown", QColor("#795548")),
            ("⚫ Dark", QColor("#333333")),
            ("🩵 Cyan", QColor("#00BCD4")),
            ("🟡 Yellow", QColor("#CDDC39")),
        ]
        for label, color in preset_colors:
            action = menu.addAction(label)
            action.triggered.connect(
                lambda checked, c=color, v=vcd_id: self.wave_scene.set_signal_color(v, c)
            )

        menu.addSeparator()
        custom_action = menu.addAction("🎨 Custom Color...")
        custom_action.triggered.connect(
            lambda: self._pick_custom_color(vcd_id)
        )

        menu.addSeparator()

        # Copy / Paste
        copy_action = menu.addAction("📋 Copy Selected\tCtrl+C")
        copy_action.triggered.connect(lambda: self._copy_selected())
        copy_action.setEnabled(bool(self.label_scene._selected_indices))

        paste_action = menu.addAction("📋 Paste\tCtrl+V")
        paste_action.triggered.connect(lambda: self._paste_signals())
        paste_action.setEnabled(bool(self._clipboard))

        menu.addSeparator()
        remove_action = menu.addAction("✕ Remove from Waveform")
        if idx is not None:
            remove_action.triggered.connect(
                lambda: self._remove_at_index(idx)
            )
        else:
            remove_action.triggered.connect(
                lambda: self.remove_selected(vcd_id)
            )

        return menu

    # ---- 分组：菜单与动作 / grouping menus & actions ----

    def _on_wave_structure_changed(self):
        """波形结构变更后，标签列重新取别名并重绘（唯一入口）。"""
        self.label_scene.sync_from(self.wave_scene)

    def _update_count_label(self):
        self.signal_count_label.setText(self.wave_scene.count_text())

    def _popup_group_menu(self):
        """工具栏 📁 分组 → 在按钮左下角弹出菜单（先重建，内容永远是最新的）。"""
        self._refresh_group_menu()
        if not self.btn_groups.isEnabled():
            return
        anchor = self.btn_groups.mapToGlobal(self.btn_groups.rect().bottomLeft())
        self._group_menu.exec(anchor)

    def _refresh_group_menu(self):
        """重建工具栏 📁 分组菜单。**隐藏的分组也列在这里 —— 这是它们唯一的恢复入口。**"""
        m = self._group_menu
        m.clear()
        groups = self.wave_scene.groups()
        n_hidden = sum(1 for g in groups if g.hidden)
        self.btn_groups.setText(
            f"📁 分组 ({len(groups)}"
            + (f" · {n_hidden} 隐藏)" if n_hidden else ")"))
        self.btn_groups.setEnabled(bool(groups))
        if not groups:
            m.addAction("（还没有分组：在标签列多选后右键 → 📁 分组 → 新建分组…）").setEnabled(False)
            return

        a_show_all = m.addAction("👁 显示全部隐藏分组")
        a_show_all.setEnabled(n_hidden > 0)
        a_show_all.triggered.connect(lambda: self.wave_scene.set_all_groups_hidden(False))
        m.addAction("▾ 全部展开").triggered.connect(
            lambda: self.wave_scene.set_all_groups_collapsed(False))
        m.addAction("▸ 全部折叠").triggered.connect(
            lambda: self.wave_scene.set_all_groups_collapsed(True))
        m.addSeparator()

        for g in groups:
            title = f"{g.name}  ({len(g.members)})"
            if g.hidden:
                title += "  [已隐藏]"
            elif g.collapsed:
                title += "  [已折叠]"
            sub = m.addMenu(title)
            sub.addAction("▾ 展开" if g.collapsed else "▸ 折叠").triggered.connect(
                lambda checked=False, gg=g: self.wave_scene.toggle_group_collapsed(gg))
            sub.addAction("👁 显示分组" if g.hidden else "👁 隐藏分组").triggered.connect(
                lambda checked=False, gg=g: self.wave_scene.set_group_hidden(gg, not gg.hidden))
            sub.addSeparator()
            sub.addAction("✏ 重命名…").triggered.connect(
                lambda checked=False, gg=g: self._rename_group(gg))
            sub.addAction("☑ 选中组内全部信号").triggered.connect(
                lambda checked=False, gg=g: self._select_group_rows(gg))
            sub.addSeparator()
            sub.addAction("✂ 取消分组（保留信号）").triggered.connect(
                lambda checked=False, gg=g: self.wave_scene.ungroup(gg))
            sub.addAction("✕ 移除整组（含信号）").triggered.connect(
                lambda checked=False, gg=g: self.wave_scene.remove_group_with_signals(gg))

    def _show_group_menu(self, global_pos, group: SignalGroup):
        """右键组头行的菜单。"""
        menu = QMenu(self)
        menu.addAction(f"📁 分组: {group.name}  ({len(group.members)} 个信号)").setEnabled(False)
        menu.addSeparator()

        menu.addAction("▾ 展开分组" if group.collapsed else "▸ 折叠分组").triggered.connect(
            lambda checked=False, gg=group: self.wave_scene.toggle_group_collapsed(gg))
        menu.addAction("👁 显示分组" if group.hidden else "👁 隐藏分组").triggered.connect(
            lambda checked=False, gg=group: self.wave_scene.set_group_hidden(gg, not gg.hidden))
        menu.addSeparator()

        menu.addAction("✏ 重命名分组…").triggered.connect(
            lambda checked=False, gg=group: self._rename_group(gg))
        menu.addAction("☑ 选中组内全部信号").triggered.connect(
            lambda checked=False, gg=group: self._select_group_rows(gg))
        menu.addSeparator()

        # 把当前选中的信号（或右键那一行）移出本组
        act_out = menu.addAction("➖ 移出分组（变顶层信号）")
        act_out.setEnabled(bool(self.label_scene.selected_rows()))
        act_out.triggered.connect(self._remove_selection_from_group)
        menu.addSeparator()

        menu.addAction("✂ 取消分组（保留信号）").triggered.connect(
            lambda checked=False, gg=group: self.wave_scene.ungroup(gg))
        menu.addAction("✕ 移除整组（含信号）").triggered.connect(
            lambda checked=False, gg=group: self.wave_scene.remove_group_with_signals(gg))

        menu.exec(global_pos)

    def _next_group_name(self) -> str:
        used = {g.name for g in self.wave_scene.groups()}
        i = 1
        while f"分组 {i}" in used:
            i += 1
        return f"分组 {i}"

    def _ask_group_name(self, title: str, default: str) -> str | None:
        from PySide6.QtWidgets import QInputDialog
        name, ok = QInputDialog.getText(self, title, "分组名：", QLineEdit.Normal, default)
        return name.strip() if (ok and name.strip()) else None

    def _create_group_from_selection(self):
        """把当前多选的行收成一个新分组。"""
        rows = self.label_scene.selected_rows()
        if not rows:
            self.cursor_label.setText("📁 先选中要分组的信号（Ctrl/Shift 多选）")
            return
        name = self._ask_group_name("新建分组", self._next_group_name())
        if not name:
            return
        g = self.wave_scene.create_group_from_rows(rows, name)
        if g is None:
            return
        self._reselect_rows(self.wave_scene.rows_of_group(g))
        self.cursor_label.setText(f"📁 已新建分组「{name}」（{len(g.members)} 个信号）")

    def _add_selection_to_group(self, group: SignalGroup):
        rows = self.label_scene.selected_rows()
        if not rows:
            return
        self.wave_scene.add_rows_to_group(rows, group)
        self._reselect_rows(self.wave_scene.rows_of_group(group))
        self.cursor_label.setText(f"📁 已加入分组「{group.name}」")

    def _remove_selection_from_group(self):
        rows = self.label_scene.selected_rows()
        if not rows:
            return
        self.wave_scene.remove_rows_from_group(rows)
        self.cursor_label.setText("📁 已移出分组（变为顶层信号）")

    def _rename_group(self, group: SignalGroup):
        name = self._ask_group_name("重命名分组", group.name)
        if name:
            self.wave_scene.rename_group(group, name)

    def _select_group_rows(self, group: SignalGroup):
        """选中该组的所有成员行（组折叠着也先展开，否则行号无从谈起）。"""
        if group.collapsed:
            self.wave_scene.set_group_collapsed(group, False)
        rows = self.wave_scene.rows_of_group(group)
        self._reselect_rows(rows[1:] if rows else [])   # rows[0] 是组头行本身

    def _pick_custom_color(self, vcd_id: str):
        """Open QColorDialog to pick a custom color for a signal."""
        from PySide6.QtWidgets import QColorDialog
        current = self.wave_scene._signal_color.get(vcd_id, QColor("#2196F3"))
        color = QColorDialog.getColor(current, self, "Select Signal Color")
        if color.isValid():
            self.wave_scene.set_signal_color(vcd_id, color)
            self.label_scene.sync_from(self.wave_scene)

    def _toggle_state_names(self, vcd_id: str):
        """Toggle state name display for this signal."""
        self.wave_scene.toggle_state_names(vcd_id)
        self.wave_scene._redraw()

    def _detect_show_state_names(self, vcd_id: str):
        """On-demand per-FSM auto-detect for one signal, then show its state names."""
        sig = self._cache.get_signal(vcd_id) if self._cache else None
        if not sig:
            return
        rtl_text = self._rtl_provider(vcd_id) if self._rtl_provider else None
        mp = detect_fsm_state_map(sig.name, rtl_text, sig.width) if rtl_text else {}
        if mp:
            self.wave_scene.store_state_map(vcd_id, mp)
            self.wave_scene._use_state_names[vcd_id] = True
            self.wave_scene._redraw()
        else:
            QMessageBox.information(
                self, "State Names",
                f"未从模块源码识别到与 {sig.name} 一起使用的状态常量。\n"
                f"请用 “📝 Edit State Names...” 手动填写值→名字映射。"
            )

    def _edit_state_names(self, vcd_id: str):
        """Open a dialog to manually edit state name mappings for a signal.
        打开对话框手动编辑信号的状态名映射。"""
        sig = self._cache.get_signal(vcd_id) if self._cache else None
        sig_name = sig.name if sig else vcd_id
        sig_width = sig.width if sig else 4

        # Get current state map
        current_map = self.wave_scene.get_state_map(vcd_id)
        entries = sorted(current_map.items()) if current_map else []

        # Build dialog
        dlg = QDialog(self)
        dlg.setWindowTitle(f"Edit State Names — {sig_name}")
        dlg.setMinimumSize(380, 300)
        dlg_layout = QVBoxLayout(dlg)

        info = QLabel(f"Signal: {sig_name}  ({sig_width}-bit)\n"
                       f"Define value → name mappings for state machine display.\n"
                       f"Tip: Use auto-detect first, then edit manually.")
        info.setStyleSheet("color: #666; font-size: 10px; padding: 4px;")
        dlg_layout.addWidget(info)

        # Table
        from PySide6.QtWidgets import QTableWidget, QTableWidgetItem, QHeaderView
        table = QTableWidget(0, 2)
        table.setHorizontalHeaderLabels(["Value", "State Name"])
        table.horizontalHeader().setStretchLastSection(True)
        table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeToContents)
        table.setAlternatingRowColors(True)

        for val, name in entries:
            row = table.rowCount()
            table.insertRow(row)
            table.setItem(row, 0, QTableWidgetItem(str(val)))
            table.setItem(row, 1, QTableWidgetItem(name))

        dlg_layout.addWidget(table)

        # Buttons row
        btn_layout = QHBoxLayout()

        add_btn = QPushButton("+ Add Row")
        add_btn.clicked.connect(lambda: (
            table.insertRow(table.rowCount()),
            table.setItem(table.rowCount() - 1, 0, QTableWidgetItem("")),
            table.setItem(table.rowCount() - 1, 1, QTableWidgetItem("")),
        ))
        btn_layout.addWidget(add_btn)

        del_btn = QPushButton("− Delete Row")
        del_btn.clicked.connect(lambda: (
            table.removeRow(table.currentRow()) if table.currentRow() >= 0 else None
        ))
        btn_layout.addWidget(del_btn)

        btn_layout.addStretch()

        # Auto-detect button
        auto_btn = QPushButton("🔄 Re-detect from RTL")
        auto_btn.setToolTip("Re-parse state definitions from the currently loaded RTL file")
        auto_btn.clicked.connect(
            lambda: self._auto_detect_from_rtl(vcd_id, table)
        )
        btn_layout.addWidget(auto_btn)

        dlg_layout.addLayout(btn_layout)

        # Dialog buttons
        dlg_btns = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        dlg_btns.accepted.connect(lambda: self._apply_state_names_edit(vcd_id, table, dlg))
        dlg_btns.rejected.connect(dlg.reject)
        dlg_layout.addWidget(dlg_btns)

        dlg.exec()

    def _auto_detect_from_rtl(self, vcd_id: str, table):
        """Re-detect per-FSM state names for THIS signal and populate the table.
        优先用该信号所属模块的源码（rtl_provider）；否则退回代码窗口当前文件。"""
        sig = self._cache.get_signal(vcd_id) if self._cache else None
        if not sig:
            return
        rtl_text = None
        if self._rtl_provider:
            rtl_text = self._rtl_provider(vcd_id)
        if not rtl_text:
            w = self.window()
            if hasattr(w, 'code_panel') and w.code_panel._current_file:
                rtl_text = w.code_panel.editor.toPlainText()
        if rtl_text:
            new_map = detect_fsm_state_map(sig.name, rtl_text, sig.width)
            self.wave_scene.store_state_map(vcd_id, new_map)
        # Reload table
        current_map = self.wave_scene.get_state_map(vcd_id)
        table.setRowCount(0)
        for val, name in sorted(current_map.items()):
            row = table.rowCount()
            table.insertRow(row)
            table.setItem(row, 0, QTableWidgetItem(str(val)))
            table.setItem(row, 1, QTableWidgetItem(name))

    def _apply_state_names_edit(self, vcd_id: str, table, dlg):
        """Apply edited state names from the table dialog."""
        new_map: dict[int, str] = {}
        for row in range(table.rowCount()):
            val_item = table.item(row, 0)
            name_item = table.item(row, 1)
            if val_item and name_item:
                val_text = val_item.text().strip()
                name_text = name_item.text().strip()
                if val_text and name_text:
                    try:
                        val = int(val_text, 0)
                        new_map[val] = name_text
                    except ValueError:
                        pass  # skip invalid rows
        if new_map:
            self.wave_scene.set_state_map(vcd_id, new_map)
        dlg.accept()

    def _show_marker_menu(self, global_pos, scene_pos):
        """Show right-click context menu for marker operations on waveform area.
        Includes snap-to-edge info when a transition edge is nearby."""
        time_ps = self.wave_scene._x_to_time(scene_pos.x())

        # Find nearest transition edge for snap-to-edge
        snap_t = self.wave_scene.find_nearest_edge(time_ps, tolerance_px=20)

        menu = QMenu(self)
        menu.addAction(f"Time: {self.wave_scene._format_time(time_ps)}").setEnabled(False)
        if snap_t is not None:
            menu.addAction(f"  ⑆ Nearest edge: {self.wave_scene._format_time(snap_t)}").setEnabled(False)
        menu.addSeparator()

        # Check if clicked near an existing marker
        near_marker = self.wave_scene.marker_at_x(scene_pos.x())
        if near_marker:
            remove_action = menu.addAction(f"✕ Remove Marker {near_marker}")
            remove_action.triggered.connect(
                lambda: self._remove_marker_and_update(near_marker)
            )

        # Add marker action — snap to edge by default (marker count is unlimited)
        add_time = snap_t if snap_t is not None else time_ps
        label = f"📍 Add Marker at {self.wave_scene._format_time(add_time)}"
        if snap_t is not None:
            label += " (snapped ▼)"
        add_action = menu.addAction(label)
        add_action.triggered.connect(
            lambda: self._add_marker_and_update(add_time)
        )
        # If snapped, also offer exact position option
        if snap_t is not None:
            exact_action = menu.addAction(
                f"📍 Add Marker at {self.wave_scene._format_time(time_ps)} (exact)"
            )
            exact_action.triggered.connect(
                lambda: self._add_marker_and_update(time_ps)
            )

        menu.addSeparator()

        # Remove specific markers
        if self.wave_scene._markers:
            for name, t in self.wave_scene._markers:
                rm_action = menu.addAction(f"Remove Marker {name} ({self.wave_scene._format_time(t)})")
                rm_action.triggered.connect(
                    lambda checked, n=name: self._remove_marker_and_update(n)
                )
            menu.addSeparator()
            clear_action = menu.addAction("Clear All Markers")
            clear_action.triggered.connect(self._clear_markers_and_update)

        menu.exec(global_pos)

    def _add_marker_and_update(self, time_ps: int):
        name = self.wave_scene.add_marker(time_ps)
        if name:
            self._update_marker_info()
            self.label_scene.sync_from(self.wave_scene)

    def _remove_marker_and_update(self, name: str):
        self.wave_scene.remove_marker(name)
        self._update_marker_info()
        self.label_scene.sync_from(self.wave_scene)

    def _clear_markers_and_update(self):
        self.wave_scene.clear_markers()
        self._update_marker_info()
        self.label_scene.sync_from(self.wave_scene)

    def _update_marker_info(self):
        """Update the marker info label in toolbar."""
        markers = self.wave_scene.markers
        if not markers:
            self.marker_label.setText("")
            return
        parts = []
        sel = self.wave_scene._selected_marker
        for i, (name, t) in enumerate(markers):
            color = self.wave_scene._marker_color(i)
            if name == sel:
                # Highlight selected marker
                parts.append(
                    f"<span style='background-color:{color.name()};color:#fff;padding:1px 4px;"
                    f"font-weight:bold;border-radius:2px;'>{name}:{self.wave_scene._format_time(t)} ↕</span>"
                )
            else:
                parts.append(
                    f"<span style='color:{color.name()};"
                    f"font-weight:bold;'>{name}:{self.wave_scene._format_time(t)}</span>"
                )
        # Add deltas
        if len(markers) >= 2:
            for i in range(len(markers) - 1):
                n1, t1 = markers[i]
                n2, t2 = markers[i + 1]
                delta = t2 - t1
                parts.append(
                    f"<span style='color:#FF6600;'>Δ{n1}→{n2}={self.wave_scene._format_time(delta)}</span>"
                )
        self.marker_label.setText(" | ".join(parts))

    def set_cache(self, cache: WaveformDataCache):
        self._cache = cache
        self.wave_scene.set_cache(cache)
        self.label_scene._cache = cache

    def set_rtl_provider(self, provider):
        """provider(vcd_id) → 该信号所属模块的 RTL 源码文本（用于逐FSM识别状态名）。"""
        self._rtl_provider = provider

    def _insert_row_for_new_signals(self) -> int | None:
        """新波形插到哪一行：**选中块最下面那一行的下面**；没有选中 → None（追加到末尾）。

        行号是渲染行（含组头行），落点决定归属 —— 插在组内成员下面会自动成为该组成员，
        与拖拽同一套规则（wave_groups.insert_rows）。选中折叠的组头行时，插到它下面 =
        成为该组首个成员。"""
        rows = self.label_scene.selected_rows()
        return (rows[-1] + 1) if rows else None

    def preload_ids(self, ids):
        """确保这些行（含派生位切片）的跳变数据在缓存里。

        切片 key 由缓存自己展开成父信号去取数。**会话加载 / VCD 重载也必须走这里** ——
        它们只 `set_order()` 不 preload 的话，所有行都会画成红框 "no data"（bug.md B13）。"""
        if not self._cache:
            return
        want = [i for i in ids if isinstance(i, str) and i]
        if want:
            self._cache.preload(want)

    def add_signals(self, vcd_ids: list[str]):
        """批量添加信号 / Add multiple signals (允许重复添加).
        单次调用内相同 vcd_id 只添加一次，避免重复；
        跨调用相同 vcd_id 正常添加新实例。

        插入位置 = 当前选中行的下面（没选中则仍是追加到末尾），加完把新行设为选中，
        这样**连续添加会按顺序一路往下排**（不然每次都插回同一个锚点，顺序会倒过来）。"""
        if not self._cache:
            return
        # Dedup within a single call to prevent accidental duplicates
        # （只收 str：万一传进来组头对象，绝不能把它塞进 _order —— 见 bug.md B11）
        seen: set[str] = set()
        unique_ids = []
        for vid in vcd_ids:
            if isinstance(vid, str) and vid not in seen:
                seen.add(vid)
                unique_ids.append(vid)
        # 换 VCD 后再粘贴旧内容时，剪贴板里可能有**已经不认识**的 id（含派生切片 key）：
        # 这种 id 画不出来也查不到，直接丢掉，别留一行幽灵（见 bug.md B13）
        unique_ids = [vid for vid in unique_ids if self._cache.get_signal(vid) is not None]
        if not unique_ids:
            return 0
        self.preload_ids(unique_ids)
        at = self._insert_row_for_new_signals()
        if at is not None:
            # 落点会进一个**折叠**的组时先展开：成员行收着，加完看不见，用户会以为"点了没反应"
            container, _off = wave_groups.anchor_at(self.wave_scene._order, at)
            if wave_groups.is_group(container) and container.collapsed:
                self.wave_scene.set_group_collapsed(container, False)
        # 没选中 → 落在末尾，也就是"插入前那批行的行数"这个位置（两种写法同值，合并成一个）
        start = len(self.wave_scene._displayed) if at is None else at
        # 批量添加时先不发通知，加完一次性提交（免得每条信号都重建一次分组菜单）
        self.wave_scene.add_signals(unique_ids, at_row=at)
        self._reselect_rows(range(start, start + len(unique_ids)))
        return len(unique_ids)          # 实际加进去的条数（调用方报数要用真实值）

    def remove_selected(self, vcd_id: str):
        self.wave_scene.remove_signal(vcd_id)

    # ---- 位切片：显示某一条信号的其中一位 / 一个位段（见 bug.md B13）----

    def add_bit_slice(self, parent_vcd_id: str, msb: int, lsb: int) -> bool:
        """把 `父信号[msb:lsb]` 作为一条派生波形加进来。

        单 bit 画成 1-bit 折线（高低电平），位段画成多 bit 总线（可切 Hex/Bin/Dec/Oct）；
        插入位置沿用 `add_signals` 的"插在选中行下面"（见 B12），颜色 / 进制继承父信号，
        一眼能看出它属于哪条总线。位段非法（父信号不存在 / 超出位宽 / 不是位向量）→
        弹窗说明并返回 False。
        """
        if not self._cache:
            return False
        # 对"已经是切片"的行再切，就在它的父信号上切（父 id 由缓存解析回来）
        parent_id = self._cache.slice_parent(parent_vcd_id) or parent_vcd_id
        sig = self._cache.get_signal(parent_id)
        if sig is None:
            QMessageBox.warning(self, "显示位 / 位段", f"找不到信号：{parent_vcd_id}")
            return False
        if not (0 <= lsb <= msb < sig.width):
            QMessageBox.warning(
                self, "显示位 / 位段",
                f"{sig.name} 只有 {sig.width} 位（[0:{max(0, sig.width - 1)}]），"
                f"取不到 [{msb}:{lsb}]。")
            return False
        key = self._cache.add_slice(sig.vcd_id, msb, lsb)
        if key is None:
            QMessageBox.warning(self, "显示位 / 位段",
                                f"{sig.name} 不是位向量（{sig.type}），无法按位显示。")
            return False
        # 父信号还没取过数 → 先取：切片是父信号切出来的，父没有数据就画不出来
        if not self._cache.has(sig.vcd_id):
            self.preload_ids([sig.vcd_id])
        # 颜色 / 进制**先摆好再 add_signals**：add_signal 只在"还没有颜色"时才自动配色，
        # 这样切片与父信号同色、也不会把配色序号往后推（见 bug.md B13）
        ws = self.wave_scene
        if key not in ws._signal_color:
            ws._signal_color[key] = ws._signal_color.get(sig.vcd_id, QColor("#2196F3"))
        if key not in ws._signal_radix:
            ws._signal_radix[key] = ws.get_signal_radix(sig.vcd_id)
        self.add_signals([key])
        return True

    def _ask_bit_text(self, title: str, prompt: str) -> tuple[str, bool]:
        """模态输入框的唯一出口 —— 单列出来是为了**可被自查块替换**（函数内 import 的
        QInputDialog 没法从外面 patch，无头跑会永久阻塞在模态框上，见 bug.md B13）。"""
        from PySide6.QtWidgets import QInputDialog
        return QInputDialog.getText(self, title, prompt)

    def _prompt_bit_spec_by_id(self, parent_vcd_id: str) -> bool:
        """弹框手输"指定位 / 位段"（`1` 或 `7:4`），确定后加进来。"""
        sig = self._cache.get_signal(parent_vcd_id) if self._cache else None
        if sig is None:
            return False
        text, ok = self._ask_bit_text(
            "显示位 / 位段",
            f"{sig.name}（{sig.width} 位）：要显示哪一位 / 哪几位？（单个位写 1，位段写 7:4）")
        if not ok:
            return False
        spec = parse_bit_spec(text)
        if spec is None:
            QMessageBox.warning(self, "显示位 / 位段",
                                f"看不懂「{text}」。请输入 1（单个位）或 7:4（位段）。")
            return False
        return self.add_bit_slice(parent_vcd_id, spec[0], spec[1])

    def _remove_at_index(self, idx: int):
        """按索引移除信号（支持重复信号的精确删除）."""
        self.label_scene._selected_indices.clear()
        self.wave_scene.remove_signal_at(idx)

    def _on_label_selection_changed(self, vcd_id: str | None):
        """Enable/disable reorder/remove buttons based on selection."""
        has_sel = bool(self.label_scene._selected_indices)
        self.btn_move_up.setEnabled(has_sel)
        self.btn_move_down.setEnabled(has_sel)
        self.btn_remove_signal.setEnabled(has_sel)

    def _move_selected_up(self):
        """把选中的行整体上移一行（走统一的重排，重复信号也不会挪错行）。"""
        rows = self.label_scene.selected_rows()
        if not rows:
            return
        shift = self.wave_scene.move_selected_rows_by(rows, -1)
        if shift:
            self._reselect_rows({r + shift for r in rows})

    def _move_selected_down(self):
        """把选中的行整体下移一行。"""
        rows = self.label_scene.selected_rows()
        if not rows:
            return
        shift = self.wave_scene.move_selected_rows_by(rows, 1)
        if shift:
            self._reselect_rows({r + shift for r in rows})

    def _remove_selected_signal(self):
        """移除选中的行（组头行 = 整组连信号一起移除）。"""
        rows = self.label_scene.selected_rows()
        if not rows:
            return
        self.label_scene.clear_selection()
        # 从下往上删，避免行号漂移
        for idx in sorted(rows, reverse=True):
            self.wave_scene.remove_signal_at(idx)

    def _zoom(self, factor: float, center_time: int | None = None):
        """Zoom waveform: multiply pixels_per_ps by factor."""
        old_pps = self.wave_scene.pixels_per_ps
        new_pps = max(5e-7, min(0.1, old_pps * factor))
        if center_time is None:
            center_time = (self.wave_scene.visible_start + self.wave_scene.visible_end) // 2

        self.wave_scene.pixels_per_ps = new_pps
        self.wave_scene._update_scene_rect()
        self.label_scene.sync_from(self.wave_scene)

        # Scroll to keep center_time at viewport center
        new_center_x = center_time * new_pps
        h_sb = self.wave_view.horizontalScrollBar()
        viewport_w = self.wave_view.viewport().width()
        h_sb.setValue(int(new_center_x - viewport_w // 2))

        self._update_visible_range()
        self.wave_scene._redraw()
        self._update_scrollbars()

    def _zoom_fit(self):
        """Zoom to fit entire time range in view."""
        self.wave_scene.set_view_width(self.wave_view.viewport().width())
        self.wave_scene.zoom_fit()
        self.label_scene.sync_from(self.wave_scene)
        self._update_visible_range()
        self.wave_scene._redraw()
        self._update_scrollbars()

    def _on_label_width_changed(self, pos: int, index: int):
        """Label column resized via splitter → update scene width and redraw."""
        w = self.label_view.width()
        self.label_scene.label_width = w
        self.label_scene._redraw()

    def _handle_wheel(self, wheel, source_view) -> bool:
        """滚轮统一入口（波形区与标签列共用，保证左右两列同步）。
        Ctrl+滚 = 缩放；Shift+滚 = 水平滚；普通滚 = 垂直滚（只驱动波形视图，
        标签视图由 _sync_v_scroll 跟随）。
        """
        if wheel.modifiers() & Qt.ControlModifier:
            delta = wheel.angleDelta().y()
            factor = 1.3 if delta > 0 else 1.0 / 1.3
            if source_view is self.wave_view:
                center_pos = self.wave_view.mapToScene(wheel.position().toPoint())
            else:
                # 标签列没有时间轴语义 → 以波形视口中心为缩放中心
                center_pos = self.wave_view.mapToScene(
                    self.wave_view.viewport().rect().center())
            self._zoom(factor, self.wave_scene._x_to_time(center_pos.x()))
            return True

        if wheel.modifiers() & Qt.ShiftModifier:
            # Shift+scroll → horizontal scroll
            # Use pixelDelta first (trackpad), fall back to angleDelta (mouse wheel)
            px_delta = wheel.pixelDelta()
            if px_delta.x() != 0 or px_delta.y() != 0:
                scroll_delta = px_delta.x() if abs(px_delta.x()) > abs(px_delta.y()) else px_delta.y()
            else:
                ang = wheel.angleDelta()
                scroll_delta = ang.x() if abs(ang.x()) > abs(ang.y()) else ang.y()
            sb = self.wave_view.horizontalScrollBar()
            sb.setValue(sb.value() - scroll_delta)
            return True

        # Normal vertical scroll (always on the waveform view — single source of truth)
        px_delta = wheel.pixelDelta()
        if px_delta.y() != 0:
            scroll_delta = px_delta.y()
        else:
            scroll_delta = wheel.angleDelta().y()
        sb = self.wave_view.verticalScrollBar()
        sb.setValue(sb.value() - scroll_delta)
        return True

    def _sync_v_scroll(self, value):
        """波形视图垂直滚动 → 标签列对齐同一段场景 Y（左右两列同行对齐）。
        不直接搬 scrollbar 数值：波形视图常驻水平滚动条 → 视口比标签列矮，
        两者 range 差一个滚动条高度，直接 setValue 到两端会错位半行。
        改成对齐“视口左上角对应的场景 Y”后，两端也不会漂。
        """
        lab = self.label_view.verticalScrollBar()
        dy = self.wave_view.mapToScene(0, 0).y() - self.label_view.mapToScene(0, 0).y()
        if dy:
            lab.setValue(lab.value() + int(round(dy)))

    def _sync_label_padding(self):
        """标签场景底部补一段 = 两视图视口高度差，使两列垂直滚动范围一致。
        仅当高度差变化时才重绘。"""
        pad = max(0, self.label_view.viewport().height()
                  - self.wave_view.viewport().height())
        if pad != self.label_scene.extra_height:
            self.label_scene.extra_height = pad
            self.label_scene._redraw()

    # (removed _on_v_scroll — label view synced from wave_view directly)

    def _on_view_h_scroll(self, value):
        """View horizontal scroll → update visible range and time scrollbar."""
        self._update_visible_range()
        self.wave_scene._redraw()
        total = self.wave_scene._total_time()
        span = self.wave_scene.visible_end - self.wave_scene.visible_start
        if total > span:
            fraction = self.wave_scene.visible_start / max(1, total - span)
            self.time_scroll.blockSignals(True)
            self.time_scroll.setValue(int(fraction * 1000))
            self.time_scroll.blockSignals(False)

    def _on_time_scroll(self, value):
        """Time scrollbar dragged → scroll view to that position."""
        total = self.wave_scene._total_time()
        span = self.wave_scene.visible_end - self.wave_scene.visible_start
        if total <= span:
            return
        fraction = value / 1000.0
        new_start = int(fraction * (total - span))
        new_x = new_start * self.wave_scene.pixels_per_ps
        self.wave_view.horizontalScrollBar().setValue(int(new_x))

    def _update_scrollbars(self):
        """Update time scrollbar range."""
        total = self.wave_scene._total_time()
        span = self.wave_scene.visible_end - self.wave_scene.visible_start
        self.time_scroll.blockSignals(True)
        self.time_scroll.setMaximum(1000 if total > span else 0)
        self.time_scroll.blockSignals(False)

    def _on_cursor_moved(self, t: int):
        self.cursor_label.setText(f"Cursor: {self.wave_scene._format_time(t)}")
        self.cursor_moved.emit(t)


#============================================================================
# LogPanel — 日志子窗口 / Log sub-window (switchable with the waveform)
#============================================================================

class LogPanel(QWidget):
    """日志子窗口：与波形共享底部区域，用标签页切换。

    既显示纯文本运行信息，也显示带 (文件,行号) 的 trace 行 —— 双击任意
    trace 行即跳到代码窗口对应源码处 (jump_requested)。"""

    jump_requested = Signal(str, int)          # (filepath, lineno)

    def __init__(self, parent=None):
        super().__init__(parent)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(2, 2, 2, 2)
        lay.setSpacing(2)

        bar = QHBoxLayout()
        bar.setSpacing(8)
        self.btn_clear = QPushButton("🗑 清空 Clear")
        self.btn_clear.setFixedHeight(24)
        self.btn_clear.clicked.connect(self.clear_log)
        bar.addWidget(self.btn_clear)
        self.cb_autoscroll = QCheckBox("Auto-scroll")
        self.cb_autoscroll.setChecked(True)
        bar.addWidget(self.cb_autoscroll)
        self.hint = QLabel("双击带路径行可跳转源码 / double-click a path row to jump")
        self.hint.setStyleSheet("color:#999;")
        bar.addWidget(self.hint)
        bar.addStretch(1)
        self.count_label = QLabel("0 条")
        self.count_label.setStyleSheet("color:#555;")
        bar.addWidget(self.count_label)
        lay.addLayout(bar)

        self.list = QListWidget()
        self.list.setWordWrap(True)
        self.list.setAlternatingRowColors(True)
        self.list.itemDoubleClicked.connect(self._on_double_click)
        lay.addWidget(self.list, 1)

    def _on_double_click(self, item):
        fp = item.data(Qt.UserRole)
        if fp:
            ln = item.data(Qt.UserRole + 1) or 1
            self.jump_requested.emit(fp, int(ln))

    def clear_log(self):
        self.list.clear()
        self.count_label.setText("0 条")

    def _update_count(self):
        self.count_label.setText(f"{self.list.count()} 条")

    def add(self, text: str, filepath=None, lineno=None,
            color="#333333", bold=False, italic=False):
        """追加一行。filepath 非空则该行双击可跳转源码。"""
        it = QListWidgetItem(text)
        if filepath:
            it.setData(Qt.UserRole, filepath)
            it.setData(Qt.UserRole + 1, lineno)
            it.setToolTip(f"双击跳转 {os.path.basename(filepath)}:{lineno}")
        it.setForeground(QColor(color))
        f = it.font()
        f.setBold(bold)
        f.setItalic(italic)
        it.setFont(f)
        self.list.addItem(it)
        self._update_count()
        if self.cb_autoscroll.isChecked():
            self.list.scrollToBottom()

    def section(self, text: str, color="#8a5a00"):
        """分隔/标题行：加粗 + 深棕，不支持跳转。"""
        it = QListWidgetItem("▪ " + text)
        it.setForeground(QColor(color))
        f = it.font()
        f.setBold(True)
        it.setFont(f)
        self.list.addItem(it)
        self._update_count()
        if self.cb_autoscroll.isChecked():
            self.list.scrollToBottom()


#============================================================================
# WaveDebuggerMain — 主窗口 / Main Window
#============================================================================

class WaveDebuggerMain(QMainWindow):
    """波形调试器主窗口。
    Waveform Debugger main window with tree, source viewer, and waveform panels.
    """

    def __init__(self, vcd_path: str | None = None):
        super().__init__()
        self.setWindowTitle("APB USB Waveform Debugger — vcd_analyzer GUI")
        self.resize(1500, 950)
        self.setMinimumSize(900, 600)

        self._analyzer: VcdAnalyzer | None = None
        self._cache: WaveformDataCache | None = None
        self._project_root: str = ""
        self._vcd_auto_path = vcd_path
        self._current_vcd_path: str = ""       # 尚未打开 VCD 时为空（_open_vcd 会再设）
        self._module_resolver = None           # _open_vcd 时构建
        self._rtl_cache: dict[str, str] = {}   # abs file path → text (state detection)

        # Font sizes for each panel (can be adjusted via Settings menu)
        self._tree_font_size = 14
        self._signal_font_size = 13
        self._code_font_size = 15
        self._wave_font_size = 11   # base font size for waveform labels/values

        self._apply_style()
        self._build_menu()
        self._build_toolbar()
        self._build_layout()
        self._build_status_bar()

        # Apply each panel's default font now that all widgets exist.  The global
        # QSS no longer hard-codes px font sizes for these widgets, so the QFont
        # (pt) set here is what actually renders.
        for _t in ("tree", "signal", "code", "wave"):
            self._apply_font_size(_t, getattr(self, f"_{_t}_font_size"))

        # Try to find project root
        self._detect_project_root()

    def _apply_style(self):
        """Apply QSS stylesheet for a clean, Verdi-like appearance."""
        self.setStyleSheet("""
            /* ---- Global ---- */
            QMainWindow {
                background-color: #ECECEC;
            }
            QSplitter::handle {
                background-color: #C8C8C8;
            }
            QSplitter::handle:horizontal {
                width: 2px;
            }
            QSplitter::handle:vertical {
                height: 2px;
            }

            /* ---- Menu Bar ---- */
            QMenuBar {
                background-color: #E8E8E8;
                border-bottom: 1px solid #CCCCCC;
                padding: 1px 0px;
            }
            QMenuBar::item {
                padding: 3px 10px;
                background: transparent;
            }
            QMenuBar::item:selected {
                background-color: #D0D0D0;
                border-radius: 3px;
            }
            QMenu {
                background-color: #FFFFFF;
                border: 1px solid #BBBBBB;
                padding: 3px;
            }
            QMenu::item {
                padding: 4px 28px 4px 12px;
            }
            QMenu::item:selected {
                background-color: #0078D4;
                color: white;
            }

            /* ---- Toolbar ---- */
            QToolBar {
                background-color: #F0F0F0;
                border-bottom: 1px solid #D0D0D0;
                spacing: 4px;
                padding: 2px 4px;
            }
            QToolBar QToolButton {
                background: transparent;
                border: 1px solid transparent;
                border-radius: 3px;
                padding: 3px 8px;
                font-size: 12px;
            }
            QToolBar QToolButton:hover {
                background-color: #E0E0E0;
                border: 1px solid #CCCCCC;
            }
            QToolBar QToolButton:pressed {
                background-color: #D0D0D0;
            }

            /* ---- Tree View (Signal Panel) ----
               NOTE: no font-family/font-size here — trees get their font from
               QFont (pt) applied per-panel via _apply_font_size, so the Settings
               font controls actually take effect.  An ancestor QSS font rule
               would override the widget's own setFont(). */
            QTreeView {
                background-color: #FFFFFF;
                border: none;
                outline: none;
            }
            QTreeView::item {
                padding: 2px 4px;
                border-bottom: 1px solid #F5F5F5;
            }
            QTreeView::item:selected {
                background-color: #0078D4;
                color: white;
            }
            QTreeView::item:hover {
                background-color: #E8F0FE;
            }
            QTreeView::branch:has-children:!has-siblings:closed,
            QTreeView::branch:closed:has-children:has-siblings {
                border-image: none;
            }
            QHeaderView::section {
                background-color: #F5F5F5;
                border: none;
                border-bottom: 1px solid #D0D0D0;
                border-right: 1px solid #E0E0E0;
                padding: 3px 6px;
                font-size: 10px;
                font-weight: bold;
                color: #555;
            }

            /* ---- Line Edit (Search box) ---- */
            QLineEdit {
                border: 1px solid #CCCCCC;
                border-radius: 3px;
                padding: 3px 6px;
                background-color: #FFFFFF;
                font-size: 11px;
            }
            QLineEdit:focus {
                border-color: #0078D4;
            }

            /* ---- Combo Box ---- */
            QComboBox {
                border: 1px solid #CCCCCC;
                border-radius: 3px;
                padding: 2px 6px;
                background-color: #FFFFFF;
                font-size: 11px;
            }
            QComboBox:hover {
                border-color: #AAAAAA;
            }
            QComboBox::drop-down {
                border: none;
                width: 20px;
            }

            /* ---- Plain Text Edit (Code Viewer) ----
               NOTE: no font-family/font-size here either — the code editor's
               font (Menlo, pt) is set via QFont in CodeViewerPanel / _apply_font_size,
               so per-window font adjustments render at the requested size. */
            QPlainTextEdit {
                background-color: #FAFBFC;
                border: none;
                selection-background-color: #0078D4;
                selection-color: white;
            }

            /* ---- Graphics View (Waveform) ---- */
            QGraphicsView {
                background-color: #FFFFFF;
                border: none;
            }

            /* ---- Scrollbars ---- */
            QScrollBar:horizontal {
                border: none;
                background: #F0F0F0;
                height: 10px;
                margin: 0px;
            }
            QScrollBar::handle:horizontal {
                background: #C0C0C0;
                min-width: 30px;
                border-radius: 4px;
            }
            QScrollBar::handle:horizontal:hover {
                background: #A0A0A0;
            }
            QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal {
                width: 0px;
            }
            QScrollBar:vertical {
                border: none;
                background: #F0F0F0;
                width: 10px;
                margin: 0px;
            }
            QScrollBar::handle:vertical {
                background: #C0C0C0;
                min-height: 30px;
                border-radius: 4px;
            }
            QScrollBar::handle:vertical:hover {
                background: #A0A0A0;
            }
            QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
                height: 0px;
            }

            /* ---- Push Buttons ---- */
            QPushButton {
                background-color: #F5F5F5;
                border: 1px solid #CCCCCC;
                border-radius: 3px;
                padding: 3px 10px;
                font-size: 11px;
                color: #333;
            }
            QPushButton:hover {
                background-color: #E8E8E8;
                border-color: #AAAAAA;
            }
            QPushButton:pressed {
                background-color: #D0D0D0;
            }

            /* ---- Status Bar ---- */
            QStatusBar {
                background-color: #007ACC;
                color: white;
                font-size: 11px;
                padding: 2px 8px;
                border-top: 1px solid #005A9E;
            }
            QStatusBar QLabel {
                color: white;
            }

            /* ---- Labels ---- */
            QLabel {
                color: #444;
                font-size: 11px;
            }

            /* ---- Frames / Separators ---- */
            QFrame[frameShape="5"] {  /* VLine */
                color: #CCCCCC;
            }
        """)

    def showEvent(self, event):
        """Called when window is first shown — deferred VCD load."""
        super().showEvent(event)
        if self._vcd_auto_path:
            path = self._vcd_auto_path
            self._vcd_auto_path = None
            self._open_vcd(path)

    # ---- Menu / 菜单栏 ----

    def _build_menu(self):
        menubar = self.menuBar()

        # File
        file_menu = menubar.addMenu("&File")
        act_open = QAction("Open &VCD...", self)
        act_open.setShortcut(QKeySequence("Ctrl+O"))
        act_open.triggered.connect(self._on_open_vcd)
        file_menu.addAction(act_open)

        self.act_reload = QAction("&Reload VCD", self)
        self.act_reload.setShortcut(QKeySequence("Ctrl+R"))
        self.act_reload.triggered.connect(self._on_reload_vcd)
        self.act_reload.setEnabled(False)
        file_menu.addAction(self.act_reload)

        act_open_src = QAction("Open Source &Folder...", self)
        act_open_src.triggered.connect(self._on_open_src_folder)
        file_menu.addAction(act_open_src)

        file_menu.addSeparator()

        act_save_session = QAction("Save Session &As...", self)
        act_save_session.setShortcut(QKeySequence("Ctrl+S"))
        act_save_session.triggered.connect(self._on_save_session)
        file_menu.addAction(act_save_session)

        act_load_session = QAction("Load Session...", self)
        act_load_session.setShortcut(QKeySequence("Ctrl+L"))
        act_load_session.triggered.connect(self._on_load_session)
        file_menu.addAction(act_load_session)

        file_menu.addSeparator()

        act_exit = QAction("E&xit", self)
        act_exit.setShortcut(QKeySequence("Ctrl+Q"))
        act_exit.triggered.connect(self.close)
        file_menu.addAction(act_exit)

        # View
        view_menu = menubar.addMenu("&View")
        act_zoom_in = QAction("Zoom &In", self)
        act_zoom_in.setShortcut(QKeySequence("Ctrl++"))
        act_zoom_in.triggered.connect(lambda: self._zoom(2.0))
        view_menu.addAction(act_zoom_in)

        act_zoom_out = QAction("Zoom &Out", self)
        act_zoom_out.setShortcut(QKeySequence("Ctrl+-"))
        act_zoom_out.triggered.connect(lambda: self._zoom(0.5))
        view_menu.addAction(act_zoom_out)

        act_zoom_fit = QAction("Zoom &Fit", self)
        act_zoom_fit.setShortcut(QKeySequence("Ctrl+0"))
        act_zoom_fit.triggered.connect(self._zoom_fit)
        view_menu.addAction(act_zoom_fit)

        view_menu.addSeparator()

        act_remove = QAction("Remove Selected Signal", self)
        act_remove.setShortcut(QKeySequence("Delete"))
        act_remove.triggered.connect(self._remove_selected)
        view_menu.addAction(act_remove)

        view_menu.addSeparator()

        act_check = QAction("🔍 Check VCD↔RTL Compatibility", self)
        act_check.setToolTip("Verify that the loaded VCD matches the RTL source files")
        act_check.triggered.connect(self._on_check_compatibility)
        view_menu.addAction(act_check)

        view_menu.addSeparator()

        # 底部区域: 波形 / 日志 标签页切换
        act_show_wave = QAction("📊 波形标签 Show Waveform", self)
        act_show_wave.triggered.connect(lambda: self._activate_bottom_tab(0))
        view_menu.addAction(act_show_wave)

        act_show_log = QAction("🧾 日志标签 Show Log", self)
        act_show_log.triggered.connect(lambda: self._activate_bottom_tab(1))
        view_menu.addAction(act_show_log)

        # Settings
        settings_menu = menubar.addMenu("&Settings")

        # 统一的字体设置对话框：每个子窗口字号单独可调
        act_fonts = QAction("字体大小 Fonts…", self)
        act_fonts.setToolTip("Adjust font size of each sub-window (Design Tree / Signal List / Code Viewer / Waveform)")
        act_fonts.triggered.connect(self._show_fonts_dialog)
        settings_menu.addAction(act_fonts)
        settings_menu.addSeparator()

        # Tree font
        tree_font_menu = settings_menu.addMenu("Design Tree Font")
        for label, delta, target in [
            ("Larger (+)", +1, "tree"), ("Smaller (-)", -1, "tree"), ("Reset (14pt)", 0, "tree")
        ]:
            act = QAction(label, self)
            act.triggered.connect(lambda checked, d=delta, t=target: self._adjust_font(t, d))
            tree_font_menu.addAction(act)

        # Signal panel font
        sig_font_menu = settings_menu.addMenu("Signal Panel Font")
        for label, delta, target in [
            ("Larger (+)", +1, "signal"), ("Smaller (-)", -1, "signal"), ("Reset (13pt)", 0, "signal")
        ]:
            act = QAction(label, self)
            act.triggered.connect(lambda checked, d=delta, t=target: self._adjust_font(t, d))
            sig_font_menu.addAction(act)

        # Code font
        code_font_menu = settings_menu.addMenu("Code Viewer Font")
        for label, delta, target in [
            ("Larger (+)", +1, "code"), ("Smaller (-)", -1, "code"), ("Reset (15pt)", 0, "code")
        ]:
            act = QAction(label, self)
            act.triggered.connect(lambda checked, d=delta, t=target: self._adjust_font(t, d))
            code_font_menu.addAction(act)

        # Waveform font
        wave_font_menu = settings_menu.addMenu("Waveform Font")
        for label, delta, target in [
            ("Larger (+)", +1, "wave"), ("Smaller (-)", -1, "wave"), ("Reset (11pt)", 0, "wave")
        ]:
            act = QAction(label, self)
            act.triggered.connect(lambda checked, d=delta, t=target: self._adjust_font(t, d))
            wave_font_menu.addAction(act)

    # ---- Toolbar / 工具栏 ----

    def _build_toolbar(self):
        toolbar = QToolBar("Main")
        toolbar.setMovable(False)
        self.addToolBar(toolbar)

        act_open = QAction("📂 VCD", self)
        act_open.setToolTip("Open VCD file (Ctrl+O)")
        act_open.triggered.connect(self._on_open_vcd)
        toolbar.addAction(act_open)

        self.act_reload_tb = QAction("🔄 Reload", self)
        self.act_reload_tb.setToolTip("Reload VCD (Ctrl+R) — keeps waveform signals")
        self.act_reload_tb.triggered.connect(self._on_reload_vcd)
        self.act_reload_tb.setEnabled(False)
        toolbar.addAction(self.act_reload_tb)

        toolbar.addSeparator()

        act_zin = QAction("🔍+", self)
        act_zin.setToolTip("Zoom In")
        act_zin.triggered.connect(lambda: self._zoom(2.0))
        toolbar.addAction(act_zin)

        act_zout = QAction("🔍-", self)
        act_zout.setToolTip("Zoom Out")
        act_zout.triggered.connect(lambda: self._zoom(0.5))
        toolbar.addAction(act_zout)

        act_zfit = QAction("Fit", self)
        act_zfit.setToolTip("Zoom to Fit (Ctrl+0)")
        act_zfit.triggered.connect(self._zoom_fit)
        toolbar.addAction(act_zfit)

    # ---- Layout / 布局 ----

    def _build_layout(self):
        # Outer vertical splitter
        self.v_splitter = QSplitter(Qt.Vertical)

        # Inner horizontal splitter (tree | signals | code) — 3 panels
        self.h_splitter = QSplitter(Qt.Horizontal)

        # Panel 1: Design module hierarchy tree
        self.tree_panel = DesignTreePanel()
        self.tree_panel.setToolTip("Design module hierarchy — double-click to open source")
        self.h_splitter.addWidget(self.tree_panel)

        # Panel 2: Signals in selected module
        self.signal_panel = ModuleSignalPanel()
        self.signal_panel.setToolTip("Signals in selected module — double-click to add to waveform")
        self.h_splitter.addWidget(self.signal_panel)

        # Panel 3: RTL source code viewer
        self.code_panel = CodeViewerPanel()
        self.code_panel.setToolTip("RTL source code — Ctrl+Click signal name to add to waveform")
        self.h_splitter.addWidget(self.code_panel)

        self.h_splitter.setSizes([280, 300, 920])

        self.v_splitter.addWidget(self.h_splitter)

        # Waveform panel (bottom) + Log panel — share the bottom area as tabs
        self.wave_panel = WaveformPanel()
        self.log_panel = LogPanel()
        self.log_panel.jump_requested.connect(self._open_code_at_line)
        self.bottom_tabs = QTabWidget()
        self.bottom_tabs.setDocumentMode(True)
        self.bottom_tabs.addTab(self.wave_panel, "📊 波形 Waveform")
        self.bottom_tabs.addTab(self.log_panel, "🧾 日志 Log")
        self.v_splitter.addWidget(self.bottom_tabs)

        self.v_splitter.setSizes([480, 470])

        # Trace (Driver / Uses) requests from every right-click menu
        for _p in (self.signal_panel, self.wave_panel, self.code_panel):
            if hasattr(_p, "trace_driver_requested"):
                _p.trace_driver_requested.connect(self._on_trace_driver)
            if hasattr(_p, "trace_uses_requested"):
                _p.trace_uses_requested.connect(self._on_trace_uses)
            if hasattr(_p, "signal_locate_requested"):
                _p.signal_locate_requested.connect(self._on_wave_locate)

        self.setCentralWidget(self.v_splitter)

        # ---- Connect signals / 信号连接 ----

        # Design tree → signal panel (show module signals)
        self.tree_panel.scope_selected.connect(self.signal_panel.show_scope)

        # Design tree → code panel (load module source)
        self.tree_panel.module_selected.connect(self.code_panel.open_module_source)

        # Signal panel → waveform (add signals)
        self.signal_panel.signal_add_requested.connect(self._on_add_signals)

        # Signal panel → code panel (highlight signal in source)
        self.signal_panel.signal_selected.connect(self._on_signal_selected)

        # Code viewer → waveform (Ctrl+Click / right-click)
        self.code_panel.signal_add_requested.connect(self._on_add_signals)

        # Code viewer → waveform (➕ 显示位：把某一条信号的 [msb:lsb] 加成一条派生波形)
        # 宽度校验与报错在波形面板里做（只有它持有 cache），代码面板负责问出位段。
        self.code_panel.bit_slice_add_requested.connect(self.wave_panel.add_bit_slice)

        # Waveform cursor
        self.wave_panel.cursor_moved.connect(self._on_cursor_update)

    def _build_status_bar(self):
        self.status_bar = QStatusBar()
        self.setStatusBar(self.status_bar)
        self.status_label = QLabel("Ready — Open a VCD file to start (Ctrl+O)")
        self.status_bar.addWidget(self.status_label, 1)
        # Compatibility indicator (right side)
        self.compat_label = QLabel("")
        self.compat_label.setStyleSheet("padding: 0 8px;")
        self.status_bar.addPermanentWidget(self.compat_label)

    # ---- Project detection / 项目目录检测 ----

    def _detect_project_root(self):
        """Detect project root based on script location."""
        script_dir = os.path.dirname(os.path.abspath(__file__))
        # tools/ is inside the project root
        self._project_root = os.path.dirname(script_dir)

    # ---- Actions / 操作 ----

    def _on_open_vcd(self):
        default_dir = os.path.join(self._project_root, "sim") if self._project_root else ""
        path, _ = QFileDialog.getOpenFileName(
            self, "Open VCD File", default_dir,
            "VCD Files (*.vcd);;All Files (*)"
        )
        if path:
            self._open_vcd(path)

    def _open_vcd(self, path: str):
        """加载 VCD 文件 / Load a VCD file."""
        try:
            self._analyzer = VcdAnalyzer(path)
        except Exception as e:
            QMessageBox.critical(self, "Error", f"Failed to parse VCD:\n{e}")
            return

        self._current_vcd_path = path
        self.act_reload.setEnabled(True)
        self.act_reload_tb.setEnabled(True)

        self._cache = WaveformDataCache(self._analyzer)

        # Scan RTL files and build module resolver
        self._module_resolver = ModuleResolver()
        src_dir = os.path.join(self._project_root, "src")
        tests_dir = os.path.join(self._project_root, "tests")
        # VCD 所在目录也要扫: testbench 常与 VCD 同目录 (如 sim/cdr/tb_cdr.v),
        # 不扫的话顶层模块 tb_cdr 解析不到源码, 顶层代码会回退到 src/ 下的错误文件
        vcd_dir = os.path.dirname(os.path.abspath(path))
        for d in [src_dir, tests_dir, vcd_dir]:
            if os.path.isdir(d):
                self._module_resolver.scan(d)

        # Per-VCD source pairing sidecar: <vcd>.src.json {"module_files": {mod: abs_path}}
        # 记录本 VCD 实际编译自哪些源文件 (同名模块歧义时用), 覆盖扫描先到先得的结果。
        sidecar = path + ".src.json"
        if os.path.isfile(sidecar):
            try:
                with open(sidecar, "r", encoding="utf-8") as f:
                    data = json.load(f)
                self._module_resolver.apply_overrides(data.get("module_files", {}))
            except Exception as e:
                print(f"wave_debugger: ignore bad sidecar {sidecar}: {e}")

        # Design tree (module hierarchy only)
        self.tree_panel.set_resolver(self._module_resolver)
        self.tree_panel.load_vcd(self._analyzer)

        # Signal panel (index all signals by scope)
        self.signal_panel.load_vcd(self._analyzer)

        # Code panel
        signals = self._analyzer.header.get("signals", [])
        self.code_panel.set_signal_index(signals)
        self.code_panel.set_resolver(self._module_resolver)
        self._rtl_cache.clear()
        if os.path.isdir(src_dir):
            self.code_panel.find_rtl_files(src_dir)
        if os.path.isdir(tests_dir):
            self.code_panel.find_rtl_files(tests_dir)
        if os.path.isdir(vcd_dir):
            self.code_panel.find_rtl_files(vcd_dir)
        # Auto-load DUT source file if resolvable (remember its scope)
        top_scope = signals[0].scope_path[0] if signals else ""
        if top_scope:
            # Try loading the top-level module file
            top_file = self._module_resolver.resolve_file(top_scope)
            if top_file:
                self.code_panel.open_module_source(top_scope, top_file)
            elif self.code_panel._rtl_files:
                self.code_panel.load_file(self.code_panel._rtl_files[0])

        # Waveform panel
        self.wave_panel.set_cache(self._cache)
        self.wave_panel.set_rtl_provider(self._rtl_text_for_signal)
        self.wave_panel.wave_scene.clear_signals()
        self.wave_panel.label_scene.sync_from(self.wave_panel.wave_scene)

        # Set window title
        info = self._analyzer.get_info()
        self.setWindowTitle(
            f"Waveform Debugger — {os.path.basename(path)} "
            f"({info.get('num_signals', 0)} signals, "
            f"{info.get('first_time', 0)}–{info.get('last_time', 0)} ps)"
        )
        self.status_label.setText(
            f"Loaded: {path}  |  {info.get('num_signals', 0)} signals  |  "
            f"timescale: {info.get('timescale', '?')}  |  "
            f"Select a module → see signals → double-click to add to waveform"
        )

        # Auto-select first tree node to populate signal panel
        root_idx = self.tree_panel._model.index(0, 0)
        if root_idx.isValid():
            self.tree_panel.tree.setCurrentIndex(root_idx)
            # Show signals for the first child scope (typically the DUT module)
            child_count = self.tree_panel._model.rowCount(root_idx)
            if child_count > 0:
                first_child = self.tree_panel._model.index(0, 0, root_idx)
                scope_key = self.tree_panel._get_scope_key(first_child)
                if scope_key:
                    self.signal_panel.show_scope(scope_key)

        # Auto zoom-fit after VCD load
        self._zoom_fit()

        # ---- VCD ↔ RTL compatibility check ----
        self._check_vcd_rtl_compatibility(signals)

    def _check_vcd_rtl_compatibility(self, signals: list[SignalDef]):
        """检查 VCD 信号与 RTL 源码的匹配度。
        Verify VCD signals match the loaded RTL source files.
        Reports match status via status bar with color coding.
        """
        if not self._module_resolver:
            return

        # Collect unique scope names from VCD
        vcd_scopes: set[str] = set()
        for sig in signals:
            vcd_scopes.add(".".join(sig.scope_path))

        # Also collect unique scope-level names (e.g., "dut", "crc5")
        scope_names: set[str] = set()
        for scope in vcd_scopes:
            for part in scope.split("."):
                scope_names.add(part)

        # Try to resolve each scope-level name to an RTL module
        resolved = 0
        unresolved = []
        for name in sorted(scope_names):
            if self._module_resolver.resolve_file(name):
                resolved += 1
            else:
                unresolved.append(name)

        # Count signal names that appear in loaded RTL files
        # (heuristic: check against the currently loaded code file)
        rtl_text = self.code_panel.editor.toPlainText() if self.code_panel._current_file else ""
        sigs_in_rtl = 0
        total_signal_names = len(set(s.name.lower() for s in signals))
        if rtl_text:
            for sig in signals:
                if re.search(r'\b' + re.escape(sig.name) + r'\b', rtl_text):
                    sigs_in_rtl += 1

        # Determine status
        total_scopes = len(scope_names)
        match_rate = resolved / max(total_scopes, 1)

        if match_rate >= 0.5 and sigs_in_rtl > 0:
            # Good match
            self._compat_status = "✅"
            self._compat_detail = (
                f"VCD↔RTL: {resolved}/{total_scopes} scopes matched, "
                f"{sigs_in_rtl} signal names found in source"
            )
        elif resolved > 0 or sigs_in_rtl > 0:
            # Partial match
            self._compat_status = "⚠️"
            self._compat_detail = (
                f"VCD↔RTL: only {resolved}/{total_scopes} scopes matched"
                + (f", {sigs_in_rtl} signals in source" if sigs_in_rtl else "")
                + (" — unresolved: " + ", ".join(unresolved[:5]) if unresolved else "")
            )
        else:
            # No match
            self._compat_status = "❌"
            self._compat_detail = (
                "VCD↔RTL MISMATCH: no VCD scopes match any RTL module. "
                "Open the correct source folder (File → Open Source Folder)."
            )

        # Update status bar
        self._update_compat_status()

    def _update_compat_status(self):
        """Refresh the compatibility status label in the status bar."""
        if hasattr(self, '_compat_status') and hasattr(self, '_compat_detail'):
            styles = {
                "✅": "color: #90EE90; font-weight: bold;",
                "⚠️": "color: #FFD700; font-weight: bold;",
                "❌": "color: #FF6666; font-weight: bold;",
            }
            style = styles.get(self._compat_status, "")
            self.compat_label.setText(f"{self._compat_status} {self._compat_detail}")
            self.compat_label.setStyleSheet(style)

    def _on_reload_vcd(self):
        """重新加载 VCD 文件，保留所有面板的完整状态（缩放、颜色、进制、光标、
        Marker、树展开状态、信号面板过滤、代码文件及滚动位置等）。
        Reload VCD — re-parse file, preserve ALL panel state.
        """
        if not self._current_vcd_path:
            return

        ws = self.wave_panel.wave_scene

        # ---- Save waveform state ----
        # 信号表 + 分组结构统一走 .wvs 的打包格式（槽位编号），重载后按同一套
        # records↔order 算法重建 —— 不然"分组"在这里会丢，两套恢复逻辑也迟早走岔。
        saved_session = self._session_dict()
        saved_colors = dict(ws._signal_color)
        saved_radix = dict(ws._signal_radix)
        saved_state_maps = {k: dict(v) for k, v in ws._signal_state_map.items()}
        saved_use_state = dict(ws._use_state_names)
        saved_zoom = ws.pixels_per_ps
        saved_cursor = ws.cursor_time
        saved_markers = list(ws._markers)
        saved_color_idx = ws._color_index

        h_sb = self.wave_panel.wave_view.horizontalScrollBar()
        saved_h_scroll_frac = (
            h_sb.value() / max(1, h_sb.maximum())
        ) if h_sb.maximum() > 0 else 0.0

        # ---- Save tree panel expanded state ----
        saved_expanded_scopes: list[str] = []
        def _collect_expanded(index, model):
            for row in range(model.rowCount(index)):
                child = model.index(row, 0, index)
                if self.tree_panel.tree.isExpanded(child):
                    scope = self.tree_panel._get_scope_key(child)
                    if scope:
                        saved_expanded_scopes.append(scope)
                _collect_expanded(child, model)
        _collect_expanded(self.tree_panel.tree.rootIndex(),
                         self.tree_panel.tree.model())

        # ---- Save signal panel scope ----
        saved_signal_scope = self.signal_panel._current_scope

        # ---- Save code panel state ----
        saved_code_file = self.code_panel._current_file
        editor = self.code_panel.editor
        saved_code_v_scroll = editor.verticalScrollBar().value()
        saved_code_cursor = editor.textCursor().position()

        # ---- Reload VCD ----
        self._open_vcd(self._current_vcd_path)

        # ---- Restore waveform state ----
        ws = self.wave_panel.wave_scene
        ws._signal_color = saved_colors
        ws._signal_radix = saved_radix
        ws._signal_state_map = saved_state_maps
        ws._use_state_names = saved_use_state
        ws._color_index = saved_color_idx

        # 重新解析出来的 VCD 里按 full_path 对回信号，再按槽位算法重建 _order（分组一起回来）
        results, _summary = resolve_session_signals(
            saved_session.get("signals", []),
            self._analyzer.header.get("signals", []),
            self._module_resolver,
        )
        slots = self._slots_from_results(results, _summary)   # 派生位切片在这里按 bits 重新派生
        order, _restored_groups, _dropped = wave_groups.records_to_order(
            slots, saved_session.get("groups"))
        ws.set_order(order)
        # 重载后必须重新取数：缓存是新建的，不 preload 就全是 "no data"（见 bug.md B13）
        self.wave_panel.preload_ids(slots)

        if saved_zoom > 0:
            ws.pixels_per_ps = saved_zoom
            ws._update_scene_rect()
            from PySide6.QtCore import QTimer
            QTimer.singleShot(50, lambda: self._restore_scroll(saved_h_scroll_frac))

        ws.cursor_time = saved_cursor
        ws._markers = saved_markers

        self.wave_panel.label_scene.sync_from(ws)
        self.wave_panel._update_visible_range()
        self.wave_panel._update_scrollbars()
        self.wave_panel._update_marker_info()
        ws._redraw()

        # ---- Restore tree panel expanded state ----
        def _re_expand(index, model):
            for row in range(model.rowCount(index)):
                child = model.index(row, 0, index)
                scope = self.tree_panel._get_scope_key(child)
                if scope and scope in saved_expanded_scopes:
                    self.tree_panel.tree.expand(child)
                _re_expand(child, model)
        _re_expand(self.tree_panel.tree.rootIndex(),
                   self.tree_panel.tree.model())

        # ---- Restore signal panel scope ----
        if saved_signal_scope:
            self.signal_panel.show_scope(saved_signal_scope)

        # ---- Restore code panel state ----
        if saved_code_file and os.path.isfile(saved_code_file):
            self.code_panel.load_file(saved_code_file)
            # Restore cursor and scroll (deferred — needs layout)
            from PySide6.QtCore import QTimer
            QTimer.singleShot(100, lambda: self._restore_code_state(
                saved_code_cursor, saved_code_v_scroll))

        self.status_label.setText(
            f"🔄 Reloaded: {self._current_vcd_path}  |  "
            f"{ws.count_text()} restored  |  all state preserved"
        )

    def _restore_scroll(self, frac: float):
        """Restore horizontal scroll position from saved fraction."""
        h_sb = self.wave_panel.wave_view.horizontalScrollBar()
        target = int(frac * h_sb.maximum())
        h_sb.setValue(target)

    def _restore_code_state(self, cursor_pos: int, v_scroll: int):
        """Restore code editor cursor and scroll position."""
        editor = self.code_panel.editor
        cursor = editor.textCursor()
        cursor.setPosition(min(cursor_pos, len(editor.toPlainText())))
        editor.setTextCursor(cursor)
        editor.verticalScrollBar().setValue(v_scroll)

    def _on_open_src_folder(self):
        default = os.path.join(self._project_root, "src") if self._project_root else ""
        folder = QFileDialog.getExistingDirectory(
            self, "Open Source Folder", default
        )
        if folder:
            self.code_panel.find_rtl_files(folder)
            self._module_resolver.scan(folder)
            self.tree_panel.set_resolver(self._module_resolver)
            if self.code_panel._rtl_files:
                self.code_panel.load_file(self.code_panel._rtl_files[0])
            # Re-check compatibility with new source files
            if self._analyzer:
                self._check_vcd_rtl_compatibility(
                    self._analyzer.header.get("signals", [])
                )

    def _on_check_compatibility(self):
        """Show a detailed VCD↔RTL compatibility report dialog."""
        if not self._analyzer or not self._module_resolver:
            QMessageBox.information(self, "Compatibility Check",
                                    "Please open a VCD file and source folder first.")
            return

        signals = self._analyzer.header.get("signals", [])
        vcd_scopes: set[str] = set()
        for sig in signals:
            vcd_scopes.add(".".join(sig.scope_path))

        scope_names: set[str] = set()
        for scope in vcd_scopes:
            for part in scope.split("."):
                scope_names.add(part)

        # Build detailed report
        lines = []
        lines.append("═══ VCD ↔ RTL Compatibility Report ═══\n")

        # Module mapping
        lines.append("── VCD scopes → RTL modules ──")
        matched = 0
        for name in sorted(scope_names):
            mod = self._module_resolver.resolve_module_name(name)
            f = self._module_resolver.resolve_file(name)
            if f:
                lines.append(f"  ✅ {name} → {mod}  ({f})")
                matched += 1
            else:
                lines.append(f"  ❓ {name} — not found in RTL sources")

        lines.append("")
        lines.append(f"Matched: {matched}/{len(scope_names)} scope names")

        # Signal cross-reference with currently loaded file
        if self.code_panel._current_file:
            rtl_text = self.code_panel.editor.toPlainText()
            lines.append("")
            lines.append(f"── Signal names in current file: {os.path.basename(self.code_panel._current_file)} ──")
            found = 0
            for sig in signals[:30]:  # check first 30
                if re.search(r'\b' + re.escape(sig.name) + r'\b', rtl_text):
                    found += 1
            lines.append(f"  {found}/{min(len(signals), 30)} signal names recognized in source")

        # Summary
        lines.append("")
        info = self._analyzer.get_info()
        lines.append(f"VCD: {os.path.basename(self._current_vcd_path)}")
        lines.append(f"  Timescale: {info.get('timescale', '?')}")
        lines.append(f"  Signals: {info.get('num_signals', 0)}")
        lines.append(f"  Time range: {info.get('first_time', 0)} – {info.get('last_time', 0)} ps")

        QMessageBox.information(self, "VCD ↔ RTL Compatibility", "\n".join(lines))

    def _on_add_signals(self, vcd_ids: list[str]):
        """从信号树添加信号到波形 / Add signals from tree to waveform."""
        if not self._cache:
            self.status_label.setText("Please open a VCD file first.")
            return

        # 注意：只有组头行的波形不算"空"（signal_count 不含组头行）
        was_empty = self.wave_panel.wave_scene.signal_count == 0
        self.wave_panel.add_signals(vcd_ids)

        # 后台逐FSM识别状态名（只存映射、不自动显示——默认仍是二进制）。
        # Per-signal background state-map detection against the signal's own module.
        for vid in vcd_ids:
            ws = self.wave_panel.wave_scene
            if not ws.has_signal(vid):
                continue
            # 派生位切片跳过：它不是 RTL 里的信号（名字带 [msb:lsb]），
            # 识别出来的空映射会把右键菜单从"自动识别"降级成"空的 State Names"（见 bug.md B13）
            if self._cache.is_derived(vid):
                continue
            sig = self._cache.get_signal(vid)
            if not sig or sig.width <= 1:
                continue
            rtl_text = self._rtl_text_for_signal(vid)
            if rtl_text:
                mp = detect_fsm_state_map(sig.name, rtl_text, sig.width)
                ws.store_state_map(vid, mp)

        # Only zoom to fit when adding the very first signal(s); preserve
        # the user's current zoom level for all subsequent additions.
        if was_empty:
            self._zoom_fit()
        self.status_label.setText(
            f"Waveform: {self.wave_panel.wave_scene.count_text()} displayed"
        )

    def _rtl_text_for_signal(self, vcd_id: str) -> str | None:
        """返回 vcd_id 信号所在模块（module 体）的 RTL 源码文本，用于逐FSM识别。
        Module instance resolved through the resolver so it is the signal's OWN
        module source, not whatever file happens to be open in the code panel."""
        if not self._cache or not hasattr(self, "_module_resolver"):
            return None
        sig = self._cache.get_signal(vcd_id)
        if not sig or not sig.scope_path:
            return None
        resolver = self._module_resolver
        leaf = sig.scope_path[-1]
        mod = resolver.resolve_module_name(leaf)
        fp = resolver.resolve_file(leaf)
        if not fp:
            fp = resolver.resolve_file(mod)
        if not fp or not os.path.isfile(fp):
            return None
        return self._module_text(fp, mod)

    # ------------------------------------------------------------------
    # Trace (Driver / Uses) 与日志跳转 —— 主窗口处理器
    # ------------------------------------------------------------------

    def _read_text(self, filepath: str) -> str:
        """带缓存的整文件读取（供静态分析 / 状态名 / trace 共用）。"""
        absf = os.path.abspath(filepath)
        if absf not in self._rtl_cache:
            try:
                with open(filepath, "r", encoding="utf-8", errors="replace") as f:
                    self._rtl_cache[absf] = f.read()
            except Exception:
                self._rtl_cache[absf] = ""
        return self._rtl_cache[absf]

    def _module_text(self, filepath: str, mod_name: str) -> str | None:
        """Read (cached) file and return the text of `module <mod_name>` body."""
        text = self._read_text(filepath)
        if not text:
            return None
        m = re.search(r'(?m)^\s*(?:module|macromodule)\s+' + re.escape(mod_name) + r'\b', text)
        if not m:
            return text
        start = m.start()
        em = re.search(r'(?m)^\s*endmodule\b', text[m.end():])
        end = m.end() + em.start() if em else len(text)
        return text[start:end]

    def _sig_source(self, sig: SignalDef | None) -> tuple[str | None, str | None]:
        """返回信号所属模块的 (源码文件, 模块名)。resolver 不可用时 (None,None)。"""
        if not sig or not sig.scope_path or not self._module_resolver:
            return (None, None)
        resolver = self._module_resolver
        leaf = sig.scope_path[-1]
        mod = resolver.resolve_module_name(leaf)
        fp = resolver.resolve_file(leaf)
        if not fp:
            fp = resolver.resolve_file(mod)
        if not fp or not os.path.isfile(fp):
            return (None, mod)
        return (fp, mod)

    def _file_line(self, fp: str, lineno: int) -> str:
        lines = self._read_text(fp).splitlines()
        return lines[lineno - 1].strip() if 0 < lineno <= len(lines) else ""

    def _activate_bottom_tab(self, index: int):
        """程序化切换底部标签页（0=波形, 1=日志）。"""
        if hasattr(self, "bottom_tabs") and 0 <= index < self.bottom_tabs.count():
            self.bottom_tabs.setCurrentIndex(index)

    def _open_code_at_line(self, filepath: str, lineno: int):
        """日志双击 / trace 跳转：加载文件 → 跳到行 → 短暂高亮。"""
        if not filepath or not os.path.isfile(filepath) or not lineno:
            return
        self.code_panel._open_file_at(filepath, int(lineno))
        self.code_panel.flash_line(int(lineno))

    _ROLE_META = {
        "driver:assign":  ("驱动 · assign",      "#b00020"),
        "driver:netinit": ("驱动 · 声明赋值",     "#b00020"),
        "driver:proc":    ("驱动 · always 赋值", "#d84315"),
        "driver:inst":    ("驱动 · 实例输出",     "#ad1457"),
        "use:sens":       ("使用 · 敏感列表",     "#6a1b9a"),
        "use:portlink":   ("使用 · 端口名连接",   "#00838f"),
        "use:inst":       ("使用 · 实参连线",     "#00695c"),
        "use:logic":      ("使用 · 逻辑引用",     "#37474f"),
        "decl":           ("声明",               "#757575"),
    }

    def _log_trace_row(self, row: dict):
        """把一行 trace 结果写进日志面板，带 (文件,行号) 双击跳源码。"""
        kind = row.get("kind") or "use:logic"
        label, color = self._ROLE_META.get(kind, (kind, "#555555"))
        note = row.get("note") or ""
        fname = os.path.basename(row["fp"])
        snip = (row.get("text") or "").strip().replace("\t", " ")
        if len(snip) > 220:
            snip = snip[:220] + " …"
        prefix = f"[{label}] {fname}:{row['line']}"
        text = prefix + (f"  {note}" if note else "") + (f"  {snip}" if snip else "")
        self.log_panel.add(text, filepath=row["fp"], lineno=row["line"], color=color)

    def _driver_chain_rows(self, sig: SignalDef) -> tuple[list[dict], str]:
        """自信号所属模块向上追溯驱动，返回 (rows, 结束说明)。

        row = {fp, line, text, role, kind[, note]}
          role 'driver' 真正驱动行; 'link' 上层的端口连线; 'cand' 未定候选。
        规则（用户拍板: 自身模块 + 上层连接）:
          · 本模块内 assign/always 赋值到它 → 那就是驱动；
          · 它是本模块 input/inout 端口 → 沿实例端口映射爬到上层实例化的
            实际网再追（链接行记在上层文件）；
          · 否则若是子实例的输出端口实参接了它 → 该实例输出即驱动；
          · 都不行 → 列出本模块内的引用行作候选。
        """
        if not self._module_resolver or not sig or not sig.scope_path:
            return [], "模块解析器不可用（需先打开 VCD）"
        resolver = self._module_resolver
        scopes = list(sig.scope_path)
        name = sig.name
        rows: list[dict] = []
        # 从叶子模块逐级向上
        for level in range(len(scopes) - 1, -1, -1):
            inst = scopes[level]
            mod = resolver.resolve_module_name(inst)
            fp = resolver.resolve_file(inst) or resolver.resolve_file(mod)
            if not fp or not os.path.isfile(fp):
                return rows, f"模块 {mod} 找不到源码文件"
            text = self._read_text(fp)
            region, base = module_region_of(text, mod)

            # 1) 本模块内部驱动（assign / always 赋值）
            refs = analyze_signal_refs(region, name)
            drivers = [r for r in refs if r["role"].startswith("driver")]
            if drivers:
                for r in drivers:
                    rows.append({"fp": fp, "line": base + r["line"],
                                 "text": r["text"], "role": "driver",
                                 "kind": r["role"]})
                return rows, f"由模块 {mod} 内部驱动"

            # 2) 它是本模块输入端口 → 爬上层实例的实际连接网
            pdirs = module_port_directions(region)
            if pdirs.get(name) in ("input", "inout"):
                if level == 0:
                    return rows, f"顶层模块 {mod} 的输入端口 {name}，无上级驱动"
                parent_inst = scopes[level - 1]
                parent_mod = resolver.resolve_module_name(parent_inst)
                pfp = (resolver.resolve_file(parent_inst)
                       or resolver.resolve_file(parent_mod))
                if not pfp or not os.path.isfile(pfp):
                    return rows, f"{mod}.{name} 为输入端口，但上层 {parent_inst} 源码不可得"
                ptext = self._read_text(pfp)
                # 在上层文本里找子实例 `mod inst (...)`，端口实参即本输入端的驱动来源。
                # 注意匹配的模块类型是子实例的模块名 mod，不是父模块 parent_mod。
                conns = find_instance_connects(ptext, mod, inst, name)
                if not conns:
                    return rows, (f"{mod}.{name} 为输入端口，但上层 {parent_inst} "
                                  f"实例未发现 .{name}(…) 连接")
                for c in conns:
                    rows.append({"fp": pfp, "line": c["line"],
                                 "text": self._file_line(pfp, c["line"]),
                                 "role": "link", "kind": "use:inst",
                                 "note": f"上层 {inst}.{name} 实参 → {c['net']}"})
                nets = {c["net"] for c in conns}
                if len(nets) == 1:
                    nn = next(iter(nets))
                    if nn != name:
                        name = nn        # 端口改名：在上层追实际网名
                continue                 # 升一级，在父模块里继续追

            # 3) 本模块内子实例的输出端口实参接了它
            inst_dr = self._inst_output_rows(fp, region, base, mod, name)
            if inst_dr:
                rows.extend(inst_dr)
                return rows, f"由模块 {mod} 内子实例输出端口驱动"

            # 4) 兜底：把本模块内相关引用列成候选
            cands = [r for r in refs
                     if r["role"] not in ("decl",) and not r["role"].startswith("driver")]
            if cands:
                for r in cands:
                    rows.append({"fp": fp, "line": base + r["line"],
                                 "text": r["text"], "role": "cand",
                                 "kind": r["role"]})
                return rows, f"模块 {mod} 内未见明确驱动，下列为相关引用（候选）"
            return rows, f"模块 {mod} 内未找到 {name} 的任何引用"
        return rows, ""

    def _inst_output_rows(self, fp: str, region: str, base: int,
                          self_mod: str, net: str) -> list[dict]:
        """找 region(本模块体) 里把 `net` 接到子实例输出/双向端口的行。"""
        rows: list[dict] = []
        for blk in iter_instance_blocks(region):
            child_mod = blk["mod"]
            if child_mod == self_mod:
                continue
            dirs = self._child_port_dirs(child_mod, fp)
            for (pname, cnet, line) in blk["ports"]:
                if cnet != net or dirs.get(pname) not in ("output", "inout"):
                    continue
                rows.append({"fp": fp, "line": base + line,
                             "text": self._file_line(fp, base + line),
                             "role": "driver", "kind": "driver:inst",
                             "note": f"{blk['inst']} 的 {pname} 端口输出"})
        return rows

    def _child_port_dirs(self, child_mod: str, fallback_fp: str) -> dict[str, str]:
        """取子模块端口的 input/output/inout 方向（跨文件、自身兜底）。"""
        fp = self._module_resolver.resolve_file(child_mod) if child_mod else None
        if not fp:
            fp = fallback_fp
        if not fp or not os.path.isfile(fp):
            return {}
        ctext = self._read_text(fp)
        cregion, _base = module_region_of(ctext, child_mod)
        if not cregion:
            return {}
        return module_port_directions(cregion)

    def _sig_from_key(self, key: str | None) -> SignalDef | None:
        """把 (唯一) full_path 解析成 SignalDef。

        VCD 可能给不同作用域的同名信号复用同一 id（如 Icarus 的 '$'），
        所以 trace/定位一律以 full_path 为键：先查 engine.by_path，再回退。
        """
        if not self._analyzer or not key:
            return None
        eng = getattr(self._analyzer, "engine", None)
        if eng is not None:
            bp = getattr(eng, "by_path", None)
            if isinstance(bp, dict):
                s = bp.get(key)
                if s:
                    return s
            sm = getattr(eng, "signals", None)
            if isinstance(sm, dict) and key in sm:
                return sm[key]
        for s in self._analyzer.header.get("signals", []):
            if s.full_path == key:
                return s
        return None

    def _on_trace_driver(self, key: str):
        """右键 'Trace Driver'：日志列出驱动链并跳到真正的驱动行。"""
        sig = self._sig_from_key(key)
        if not sig:
            self.log_panel.add(f"[trace] 未知信号 {key}", color="#b00020")
            self._activate_bottom_tab(1)
            return
        self.log_panel.section(f"🔍 Trace Driver — {sig.full_path} "
                               f"({sig.width}bit {sig.type})")
        rows, note = self._driver_chain_rows(sig)
        if not rows:
            self.log_panel.add(f"⚠ 未找到驱动：{note or '无'}", color="#b00020")
        else:
            for row in rows:
                self._log_trace_row(row)
            drv = [r for r in rows if r["role"] == "driver"]
            target = drv[-1] if drv else rows[-1]
            self._open_code_at_line(target["fp"], target["line"])
        if note:
            self.log_panel.add("· " + note, color="#777777", italic=True)
        self.log_panel.add("（双击任一 [文件:行] 可跳转源码）",
                           color="#888888", italic=True)
        self._activate_bottom_tab(1)
        self.status_label.setText(
            f"Trace Driver: {sig.full_path} → {note or 'ok'}")

    def _on_trace_uses(self, key: str):
        """右键 'Trace Uses'：在日志列出本模块内引用该信号的每一行。"""
        sig = self._sig_from_key(key)
        if not sig:
            self.log_panel.add(f"[trace] 未知信号 {key}", color="#b00020")
            self._activate_bottom_tab(1)
            return
        fp, mod = self._sig_source(sig)
        self.log_panel.section(f"📖 Trace Uses — {sig.full_path} "
                               f"({sig.width}bit {sig.type})")
        if not fp:
            self.log_panel.add(f"⚠ 找不到 {mod or sig.name} 的源码", color="#b00020")
            self._activate_bottom_tab(1)
            return
        text = self._read_text(fp)
        region, base = module_region_of(text, mod or sig.name)
        refs = analyze_signal_refs(region, sig.name)
        uses = [r for r in refs if r["role"] != "decl"]
        if not uses:
            self.log_panel.add(f"（{mod}）模块内没有任何引用 {sig.name} 的行",
                               color="#888888")
        else:
            for r in uses:
                self._log_trace_row({"fp": fp, "line": base + r["line"],
                                     "text": r["text"], "role": "cand",
                                     "kind": r["role"]})
            self._open_code_at_line(fp, base + uses[0]["line"])
        self.log_panel.add(f"（共 {len(uses)} 行；双击任意行跳转源码）",
                           color="#888888", italic=True)
        self._activate_bottom_tab(1)
        self.status_label.setText(
            f"Trace Uses: {sig.full_path} → 本模块 {len(uses)} 行引用")

    def _on_wave_locate(self, key: str):
        """波形信号标签双击 → 代码窗口定位到声明处。"""
        sig = self._sig_from_key(key)
        if not sig:
            return
        fp, _mod = self._sig_source(sig)
        if fp:
            self.code_panel._open_file_at(fp, None)
        self.code_panel.highlight_signal(sig)
        self.status_label.setText(f"Locate in code: {sig.full_path}")

    def _on_signal_selected(self, sig: SignalDef | None):
        """树中选中信号 → 代码联动 / Signal selected in tree → highlight in code."""
        self.code_panel.highlight_signal(sig)
        if sig:
            self.status_label.setText(
                f"Selected: {sig.full_path} ({sig.type}, {sig.width}bit)"
            )

    def _on_cursor_update(self, t: int):
        self.status_label.setText(f"Cursor: {self.wave_panel.wave_scene._format_time(t)}")

    def _adjust_font(self, target: str, delta: int):
        """Adjust font size for a specific panel. / 调整指定面板的字体大小。
        target: 'tree', 'signal', 'code', 'wave'
        delta: +1 (larger), -1 (smaller), 0 (reset)
        """
        defaults = {"tree": 14, "signal": 13, "code": 15, "wave": 11}
        mins = {"tree": 8, "signal": 8, "code": 8, "wave": 6}
        maxs = {"tree": 24, "signal": 24, "code": 30, "wave": 20}

        if delta == 0:
            new_size = defaults[target]
        else:
            current = getattr(self, f"_{target}_font_size")
            new_size = max(mins[target], min(maxs[target], current + delta))

        self._apply_font_size(target, new_size)

    def _apply_font_size(self, target: str, size: int):
        """把某个子窗口的字号真正应用上去 / Apply a font size to one sub-window."""
        setattr(self, f"_{target}_font_size", size)
        if target == "tree":
            self.tree_panel.tree.setFont(QFont("Helvetica", size))
        elif target == "signal":
            self.signal_panel.tree.setFont(QFont("Helvetica", size))
        elif target == "code":
            self.code_panel.editor.setFont(QFont("Menlo", size))
        elif target == "wave":
            # Update font size and trigger redraw
            self.wave_panel.wave_scene.wave_font_size = size
            self.wave_panel.label_scene.label_font_size = size
            self.wave_panel.wave_scene._redraw()
            self.wave_panel.label_scene._redraw()

    def _show_fonts_dialog(self):
        """设置菜单 → 字体大小：每个子窗口各自可精确调字号（带实时预览）。"""
        from PySide6.QtWidgets import QSpinBox

        titles = [
            ("tree", "模块树 / Design Tree"),
            ("signal", "信号列表 / Signal List"),
            ("code", "代码窗口 / Code Viewer"),
            ("wave", "波形 / Waveform"),
        ]
        defaults = {"tree": 14, "signal": 13, "code": 15, "wave": 11}
        ranges = {"tree": (8, 24), "signal": (8, 24), "code": (8, 30), "wave": (6, 24)}

        dlg = QDialog(self)
        dlg.setWindowTitle("字体大小 / Font Sizes")
        dlg.setMinimumWidth(560)
        lay = QVBoxLayout(dlg)

        tip = QLabel("分别调整各子窗口的字体大小，拖动即预览，点“应用”生效。")
        tip.setStyleSheet("color: #666;")
        lay.addWidget(tip)

        spins: dict[str, QSpinBox] = {}
        for target, label in titles:
            row = QHBoxLayout()
            name = QLabel(label)
            name.setFixedWidth(190)
            sp = QSpinBox()
            lo, hi = ranges[target]
            sp.setRange(lo, hi)
            sp.setValue(getattr(self, f"_{target}_font_size"))
            sp.setSuffix(" pt")
            pv = QLabel("示例 Sample Aa 01 状态 ST_IDLE")
            pv.setStyleSheet("color: #888;")

            def _preview(val: int, t: str = target):
                fam = "Menlo" if t == "code" else "Helvetica"
                pv.setFont(QFont(fam, val))

            sp.valueChanged.connect(_preview)
            _preview(sp.value())
            row.addWidget(name)
            row.addWidget(sp)
            row.addSpacing(8)
            row.addWidget(pv)
            row.addStretch()
            spins[target] = sp
            lay.addLayout(row)

        def _reset_defaults():
            for t, _ in titles:
                spins[t].setValue(defaults[t])

        btns = QHBoxLayout()
        reset_btn = QPushButton("恢复默认")
        reset_btn.clicked.connect(_reset_defaults)
        btns.addWidget(reset_btn)
        btns.addStretch()
        box = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        ok_btn = box.button(QDialogButtonBox.Ok)
        ok_btn.setText("应用")
        cancel_btn = box.button(QDialogButtonBox.Cancel)
        cancel_btn.setText("取消")

        def _apply():
            for t, _ in titles:
                self._apply_font_size(t, spins[t].value())
            self.status_label.setText(
                "字体已更新 — " + ", ".join(f"{t}={spins[t].value()}pt" for t, _ in titles)
            )

        box.accepted.connect(_apply)
        box.accepted.connect(dlg.accept)
        box.rejected.connect(dlg.reject)
        btns.addWidget(box)
        lay.addLayout(btns)

        dlg.exec()

    def _zoom(self, factor: float):
        self.wave_panel._zoom(factor)

    def _zoom_fit(self):
        self.wave_panel._zoom_fit()

    def _remove_selected(self):
        """移除选中信号 / Remove selected signals from waveform."""
        # Remove from the signal panel selection (or waveform panel label selection)
        selected = self.signal_panel.get_selected_vcd_ids()
        if not selected:
            # Try waveform label selected signals (by index)
            # 倒序删：低行号不受高行号删除的影响（组头行 = 整个组，也照样成立）
            selected_indices = sorted(self.wave_panel.label_scene._selected_indices, reverse=True)
            if selected_indices:
                for idx in selected_indices:
                    self.wave_panel.wave_scene.remove_signal_at(idx)
                self.wave_panel.label_scene._selected_indices.clear()
                # 计数标签与标签列都由 groups_changed → _update_count_label /
                # _on_wave_structure_changed 自动刷新，这里不重复设
                self.status_label.setText(
                    f"Waveform: {self.wave_panel.wave_scene.count_text()} displayed"
                )
                return
        if not selected:
            return
        for vid in selected:
            self.wave_panel.wave_scene.remove_signal(vid)
        self.wave_panel.label_scene._selected_indices.clear()
        self.status_label.setText(
            f"Waveform: {self.wave_panel.wave_scene.count_text()} displayed"
        )

    # ---- Session save / restore / 会话保存与恢复 ----

    def _on_save_session(self):
        """Save current waveform session to a .wvs JSON file."""
        if not self._cache:
            QMessageBox.warning(self, "No Data", "No VCD loaded. Open a VCD first.")
            return
        path, _ = QFileDialog.getSaveFileName(
            self, "Save Waveform Session",
            os.path.splitext(self._current_vcd_path)[0] + ".wvs" if self._current_vcd_path else "session.wvs",
            "Waveform Session (*.wvs);;All Files (*)"
        )
        if not path:
            return
        try:
            self._save_session(path)
            self.status_label.setText(f"Session saved: {path}")
        except Exception as e:
            QMessageBox.critical(self, "Error", f"Failed to save session:\n{e}")

    def _on_load_session(self):
        """Load a waveform session from a .wvs JSON file."""
        path, _ = QFileDialog.getOpenFileName(
            self, "Load Waveform Session", "",
            "Waveform Session (*.wvs);;All Files (*)"
        )
        if not path:
            return
        try:
            self._load_session(path)
            self.status_label.setText(f"Session loaded: {path}")
        except Exception as e:
            QMessageBox.critical(self, "Error", f"Failed to load session:\n{e}")

    def _session_dict(self) -> dict:
        """把当前波形会话打包成 .wvs 的字典。

        **保存（`_save_session`）与重新加载 VCD（`_on_reload_vcd`）共用这一份打包**：
        两边都走"signals[] 槽位 + groups[].members 槽位下标"，分组结构才不会在重载时丢，
        也不会演变成两套各写各的恢复逻辑。
        """
        ws = self.wave_panel.wave_scene
        resolver = getattr(self, "_module_resolver", None)

        def _entry(vcd_id):
            """一条信号记录（version 3 起带跨 case 映射所需的身份信息）。

            **派生位切片（version 5）**：身份信息一律写**父信号**的（full_path / leaf / width /
            scope…），另加 `"bits": [msb, lsb]` 标明取的是哪几位。这样 `resolve_session_signals`
            一行都不用改就能精确命中父信号、跨 case 改名也照样适配；加载时再按 `bits` 重新派生出
            切片 key（见 bug.md B13）。
            """
            sig = self._cache.get_signal(vcd_id) if self._cache else None
            spec = self._cache.slice_spec(vcd_id) if self._cache else None
            if spec is not None:
                sig = self._cache.get_signal(spec[0])     # 换成父信号的身份
            full_path = sig.full_path if sig else vcd_id
            state_map = ws.get_state_map(vcd_id)
            entry = {
                "full_path": full_path,
                "color": ws._signal_color.get(vcd_id, QColor("#2196F3")).name(),
                "radix": ws.get_signal_radix(vcd_id),
                "state_map": {str(k): v for k, v in state_map.items()} if state_map else None,
                "use_state_names": ws.get_use_state_names(vcd_id),
            }
            if sig is not None:
                # leaf/width/type + 完整作用域 + 每级作用域 resolve 出的模块名
                entry["leaf"] = sig.name
                entry["width"] = sig.width
                entry["type"] = sig.type
                entry["scope"] = list(sig.scope_path)
                if resolver is not None:
                    entry["scope_modules"] = [
                        resolver.resolve_module_name(s0) for s0 in sig.scope_path
                    ]
                else:
                    entry["scope_modules"] = list(sig.scope_path)
            if spec is not None:
                entry["bits"] = [spec[1], spec[2]]
            return entry

        # 走**完整逻辑序列**（含折叠 / 隐藏组的成员）—— 收起的分组也要存下来。
        # signals[] 的写入顺序 == wave_groups 的槽位编号，groups[].members 用的就是这个下标
        # （不用 full_path：同一 full_path 可以出现多次，下标才唯一且精确）。
        sig_rows, group_recs = wave_groups.order_to_records(ws._order)
        logical = wave_groups.all_rows(ws._order)[0]
        return {
            # version 5：signals[] 里多了 "bits"（派生位切片，见 _entry）。旧版本照样读得懂。
            "version": 5,
            "vcd_file": self._current_vcd_path,
            "pixels_per_ps": ws.pixels_per_ps,
            "visible_start": ws.visible_start,
            "markers": [(n, t) for n, t in ws.markers],
            "signals": [_entry(logical[r]) for r in sig_rows],
            "groups": group_recs,
        }

    def _save_session(self, path: str):
        """Export waveform session to JSON. / 导出波形会话到 JSON 文件."""
        import json
        with open(path, "w") as f:
            json.dump(self._session_dict(), f, indent=2)

    def _slots_from_results(self, results, summary=None) -> list:
        """把 `resolve_session_signals` 的结果转成"槽位"：第 i 槽 = 第 i 条 entry 对应的行键。

        普通信号 = 解析出的 vcd_id；带 `"bits"` 的派生位切片 = 在**父信号**上按位段重新派生出来的
        切片 key（父可能是跨 case 适配过来的另一条信号，所以必须重新派生、不能拿旧 key）。
        位段超出新 VCD 的位宽 → 槽位 None，并把这条改判成 FAIL_BITS、计数从 exact/adapt 挪到 fail：
        **掉了就报，绝不静默丢一行**（与分组掉成员同一条原则，见 bug.md B11/B13）。
        """
        slots = []
        for r in results:
            sig, entry = r["sig"], r["entry"]
            if sig is None:
                slots.append(None)
                continue
            bits = entry.get("bits")
            if not bits:
                slots.append(sig.vcd_id)
                continue
            # 手改过 / 将来版本写坏的 bits 也只能让**这一行**掉，不能把整个会话加载搞崩
            ok_pair = (isinstance(bits, (list, tuple)) and len(bits) == 2
                       and all(isinstance(b, int) for b in bits)
                       and 0 <= bits[1] <= bits[0])
            msb, lsb = (bits[0], bits[1]) if ok_pair else (0, 1)   # 非法时 msb<lsb → add_slice 必拒
            key = self._cache.add_slice(sig.vcd_id, msb, lsb) if self._cache else None
            if key is None:
                if summary is not None:
                    if r["status"] == "OK_EXACT" and summary.get("exact"):
                        summary["exact"] -= 1
                    elif r["status"] == "OK_ADAPT" and summary.get("adapt"):
                        summary["adapt"] -= 1
                    summary["fail"] = summary.get("fail", 0) + 1
                r["status"] = "FAIL_BITS"
                r["note"] = (
                    f"{sig.full_path} 只有 {sig.width} 位，取不到 [{msb}:{lsb}]。"
                    if ok_pair else
                    f"存盘的位段 {bits!r} 不合法（{sig.full_path} 共 {sig.width} 位）。")
                slots.append(None)
                continue
            slots.append(key)
        return slots

    def _load_session(self, path: str):
        """Import waveform session from JSON. / 从 JSON 文件恢复波形会话。

        跨 case 语义（用户已确认"总是映射当前 VCD"）：
        - 未打开任何 VCD → 自动打开会话自带的 VCD（保持原有便捷）。
        - 已打开且与会话记录的 VCD 相同 → 完整恢复（信号 + marker + 缩放/滚动）。
        - 已打开但 VCD 不同 → 只把信号列表【映射到当前 VCD】，不自动切换、不导入
          marker/缩放（时间相关项跨 case 无意义）；显示不出的信号在报告里逐条说明原因。
        """
        import json
        with open(path, "r") as f:
            data = json.load(f)

        vcd_file = data.get("vcd_file", "")
        if not self._current_vcd_path:
            # 未打开任何 VCD → 自动打开会话自带的 VCD
            opened = None
            if vcd_file and os.path.exists(vcd_file):
                opened = vcd_file
            else:
                alt = os.path.join(os.path.dirname(path), os.path.basename(vcd_file))
                if alt and os.path.exists(alt):
                    opened = alt
            if not opened:
                raise FileNotFoundError(f"VCD file not found: {vcd_file}")
            self._open_vcd(opened)

        if not self._cache:
            raise RuntimeError("No VCD loaded — cannot restore signals")

        same_vcd = bool(self._current_vcd_path) and bool(vcd_file) and \
            os.path.abspath(vcd_file) == os.path.abspath(self._current_vcd_path)

        ws = self.wave_panel.wave_scene
        current_sigs = self._analyzer.header.get("signals", [])
        results, summary = resolve_session_signals(
            data.get("signals", []), current_sigs, self._module_resolver
        )

        # Clear the current waveform signal list (markers 仅在完整恢复时清/导)
        ws.clear_signals()
        if same_vcd:
            ws.clear_markers()

        # 槽位重建：第 i 槽 = 第 i 条 entry 解析出的 vcd_id（没解析出来为 None）。
        # 用槽位下标认领组成员 —— 掉信号的成员自动消失、组不散架、重复项也不串
        # （旧文件没有 "groups" 键 → 空组列表 → 行为与分组功能之前完全一致）。
        slots = self._slots_from_results(results, summary)
        order, _restored_groups, dropped_groups = wave_groups.records_to_order(
            slots, data.get("groups"))
        ws.set_order(order)
        # 取跳变数据：**这一步不能少** —— 只 set_order 不 preload，所有行都会画成红框 "no data"；
        # 派生切片更是靠它把父信号的数据切出来（见 bug.md B13）
        self.wave_panel.preload_ids(slots)

        # 颜色 / 进制 / 状态名仍按 vcd_id 记账（派生切片记在它自己的合成 key 上）
        for slot, r in zip(slots, results):
            s = r["entry"]
            if slot is None:
                continue
            vcd_id = slot
            if "color" in s:
                ws._signal_color[vcd_id] = QColor(s["color"])
            if "radix" in s:
                ws._signal_radix[vcd_id] = s["radix"]
            if s.get("state_map"):
                smap = {int(k): v for k, v in s["state_map"].items()}
                ws._signal_state_map[vcd_id] = smap
            if "use_state_names" in s:
                ws._use_state_names[vcd_id] = s["use_state_names"]
            ws._color_index += 1

        # marker / zoom / 滚动：仅在“完整恢复”模式（同 VCD）导入
        if same_vcd:
            for name, t in data.get("markers", []):
                ws._markers.append((name, int(t)))
            if ws._markers:
                ws._markers.sort(key=lambda x: x[1])
            if "pixels_per_ps" in data:
                ws.pixels_per_ps = float(data["pixels_per_ps"])

        ws._update_scene_rect()
        ws._redraw()
        self.wave_panel.label_scene.sync_from(ws)
        self.wave_panel._update_marker_info()
        self.wave_panel._update_count_label()
        self.wave_panel._update_scrollbars()

        if same_vcd and "visible_start" in data:
            vs = int(data["visible_start"])
            new_x = vs * ws.pixels_per_ps
            self.wave_panel.wave_view.horizontalScrollBar().setValue(int(new_x))

        n_ok = summary["exact"] + summary["adapt"]
        msg = f"Session loaded: {n_ok}/{summary['saved']} signals"
        parts = []
        if summary["adapt"]:
            parts.append(f"{summary['adapt']} adapted")
        if summary["fail"]:
            parts.append(f"{summary['fail']} missing")
        if dropped_groups:
            parts.append(f"{len(dropped_groups)} groups dropped")
        if parts:
            msg += " (" + ", ".join(parts) + ")"
        self.status_label.setText(msg)

        if summary["fail"] or summary["adapt"] or dropped_groups:
            self._show_load_report(summary, results, dropped_groups)

    def _show_load_report(self, summary, results, dropped_groups=()):
        """弹窗逐条报告跨 case 加载时无法显示 / 已适配的信号及原因，以及整组丢弃的分组。"""
        from PySide6.QtWidgets import QTableWidget, QTableWidgetItem

        n_ok = summary["exact"] + summary["adapt"]
        summary_text = f"已恢复 {n_ok}/{summary['saved']} 个信号"
        if summary["adapt"]:
            summary_text += f"，其中 {summary['adapt']} 个按模块结构适配了改名"
        if summary["fail"]:
            summary_text += f"；{summary['fail']} 个无法显示："
        elif dropped_groups:
            summary_text += "；"
        else:
            summary_text += "。"
        if dropped_groups:
            summary_text += (f"{len(dropped_groups)} 个分组因成员全部无法显示而丢弃："
                             if summary["fail"] else
                             f"{len(dropped_groups)} 个分组因成员全部无法显示而丢弃。")

        dlg = QDialog(self)
        dlg.setWindowTitle("Load Session 报告")
        dlg.resize(780, 430)
        lay = QVBoxLayout(dlg)

        head = QLabel(summary_text)
        head.setWordWrap(True)
        lay.addWidget(head)

        table = QTableWidget(0, 3)
        table.setHorizontalHeaderLabels(["保存的信号", "结果", "说明"])
        table.horizontalHeader().setStretchLastSection(True)
        table.setColumnWidth(0, 260)
        table.setColumnWidth(1, 100)
        table.setAlternatingRowColors(True)
        table.setEditTriggers(QAbstractItemView.NoEditTriggers)

        status_txt = {
            "OK_EXACT": "✓",
            "OK_ADAPT": "✓ 已适配",
            "FAIL_NO_SUCH": "✗ 无法显示",
            "FAIL_SCOPE": "✗ 无法显示",
            "FAIL_AMBIG": "✗ 无法显示（有歧义）",
            "FAIL_BITS": "✗ 位段超出范围",
        }
        red = QColor("#C62828")
        green = QColor("#2E7D32")

        rows = []
        for rec in dropped_groups:
            members = rec.get("members") or []
            rows.append((f"📁 {rec.get('name') or 'Group'}（整组）", "✗ 整组丢弃",
                         f"{len(members)} 个成员在当前 VCD 里一个都没解析出来"))
        for r in results:
            entry = r["entry"]
            bits = entry.get("bits")
            # 精确命中不打扰（本报告只在"有失败 / 有适配 / 有整组丢弃"时才弹，
            # 一切正常的会话根本走不到这里 —— 所以这里按老规矩跳过 OK_EXACT 即可）
            if r["status"] == "OK_EXACT":
                continue
            name = entry.get("full_path") or ""
            if bits:
                name += (f"[{bits[0]}]" if bits[0] == bits[1]
                         else f"[{bits[0]}:{bits[1]}]")
            st = status_txt.get(r["status"], r["status"])
            rows.append((name, st, r["note"]))

        for i, (fp, st, note) in enumerate(rows):
            table.insertRow(i)
            for col, txt in enumerate((fp, st, note)):
                item = QTableWidgetItem(txt)
                if col == 1:
                    item.setForeground(red if st.startswith("✗") else green)
                table.setItem(i, col, item)
        lay.addWidget(table)

        btns = QHBoxLayout()
        btns.addStretch()

        def _copy():
            lines = ["保存的信号\t结果\t说明"]
            for fp, st, note in rows:
                lines.append(f"{fp}\t{st}\t{note}")
            QApplication.clipboard().setText("\n".join(lines))

        copy_btn = QPushButton("复制到剪贴板")
        copy_btn.clicked.connect(_copy)
        btns.addWidget(copy_btn)

        ok_btn = QPushButton("确定")
        ok_btn.clicked.connect(dlg.accept)
        btns.addWidget(ok_btn)
        lay.addLayout(btns)

        dlg.exec()


#============================================================================
# Entry Point / 入口
#============================================================================

def main():
    import sys
    app = QApplication(sys.argv)
    app.setApplicationName("Waveform Debugger")
    app.setStyle(QStyleFactory.create("Fusion"))

    # Set global font
    font = QFont("Helvetica", 13)
    app.setFont(font)

    vcd_path = sys.argv[1] if len(sys.argv) > 1 else None
    window = WaveDebuggerMain(vcd_path)
    window.show()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
