#!/usr/bin/env python3
#============================================================================
# vcd_analyzer.py — VCD 波形分析工具 / VCD Waveform Analyzer
#
# 用于 AI 辅助 RTL 调试时提取 VCD 波形关键信息，减少 token 消耗。
# Extract key waveform info from VCD files for AI-assisted RTL debugging
# with minimal token usage.
#
# 用法 / Usage:
#   python3 tools/vcd_analyzer.py info sim/cdr.vcd [--tree]
#   python3 tools/vcd_analyzer.py list sim/cdr.vcd [--glob PATTERN] [--tree]
#   python3 tools/vcd_analyzer.py show sim/cdr.vcd --signals GLOB [--start T] [--end T]
#   python3 tools/vcd_analyzer.py search sim/cdr.vcd --cond EXPR
#   python3 tools/vcd_analyzer.py stats sim/cdr.vcd --signals GLOB
#   python3 tools/vcd_analyzer.py snapshot sim/cdr.vcd --at TIME
#
# 纯 Python 标准库，无第三方依赖 / No third-party dependencies.
#============================================================================

import sys
import os
import re
import argparse
import fnmatch
import json
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Optional, Generator, Any

# ============================================================================
# Section 1: Data Classes
# ============================================================================

@dataclass
class SignalDef:
    """单个信号定义 / a single signal definition."""
    vcd_id: str          # VCD 标识符 (如 '!', '"') / VCD identifier code
    name: str            # 叶子名 (如 'clk') / leaf name
    full_path: str       # 完整层级路径 / full hierarchical path
    type: str            # wire, reg, integer, real, parameter
    width: int           # 位宽 / bit width
    scope_path: list = field(default_factory=list)  # scope 层级列表


@dataclass
class TransitionEvent:
    """一次信号值跳变 / a single signal value transition."""
    time: int
    vcd_id: str
    signal_path: str
    old_value: str
    new_value: str


@dataclass
class SignalStats:
    """信号统计信息 / per-signal statistics."""
    full_path: str
    width: int
    toggles: int           # 翻转次数 (0↔1 for scalar)
    transitions: int        # 值变化总次数
    first_time: int         # 首次变化时间
    last_time: int          # 末次变化时间
    high_time: int = 0      # 高电平持续时间 (仅 1-bit)
    low_time: int = 0       # 低电平持续时间 (仅 1-bit)


# ============================================================================
# Section 2: VcdParser — 流式 VCD 解析器 / Streaming VCD Parser
# ============================================================================

class VcdParser:
    """流式解析 VCD 文件，逐行产出事件。

    Streaming VCD parser — reads line-by-line, yields typed events.
    Does NOT accumulate all value changes in memory.
    """

    def __init__(self, filepath: str):
        self.filepath = filepath
        self._known_ids: set = set()   # collected during header parsing

    # ---- public API ----

    def parse_header(self) -> dict:
        """解析 VCD 头部，返回元信息和信号列表。

        Parse VCD header; return metadata dict and populate signal list.
        Stops at $enddefinitions.
        """
        header = {
            "date": "", "version": "", "timescale": "1ps",
            "timescale_magnitude": "", "timescale_unit": "",
        }
        signals: list[SignalDef] = []
        scope_stack: list[tuple[str, str]] = []  # [(name, kind)]

        with open(self.filepath, "r", encoding="utf-8", errors="replace") as f:
            for raw in f:
                line = raw.rstrip("\n").rstrip("\r").strip()

                if not line:
                    continue

                # ---- $date / $version / $timescale ----
                if line.startswith("$date"):
                    header["date"] = self._read_until(f, "$end", raw, line)
                elif line.startswith("$version"):
                    header["version"] = self._read_until(f, "$end", raw, line)
                elif line.startswith("$timescale"):
                    ts_text = self._read_until(f, "$end", raw, line)
                    header["timescale"] = ts_text
                    header["timescale_magnitude"], header["timescale_unit"] = \
                        self._parse_timescale(ts_text)

                # ---- $scope ----
                elif line.startswith("$scope"):
                    m = re.match(r'\$scope\s+(\S+)\s+(.+?)\s*\$end', line)
                    if not m:
                        # multi-line: read until $end
                        full = line
                        if not full.endswith("$end"):
                            full = self._read_until_line(f, "$end", raw, line)
                        m = re.match(r'\$scope\s+(\S+)\s+(.+?)\s*\$end', full)
                    if m:
                        scope_stack.append((m.group(2), m.group(1)))

                # ---- $upscope ----
                elif line.startswith("$upscope"):
                    if scope_stack:
                        scope_stack.pop()

                # ---- $var ----
                elif line.startswith("$var"):
                    var_text = self._read_until(f, "$end", raw, line)
                    sig = self._parse_var(var_text, scope_stack)
                    if sig:
                        signals.append(sig)
                        self._known_ids.add(sig.vcd_id)

                # ---- $enddefinitions -> done ----
                elif line.startswith("$enddefinitions"):
                    break

        # 构建层级路径 / build full paths
        self._build_full_paths(signals)

        header["signals"] = signals
        header["scope_stack"] = scope_stack
        return header

    def iter_values(self, signal_ids: Optional[set] = None,
                    start_time: int = 0, end_time: int = None,
                    stop_after: int = None) -> Generator[tuple, None, None]:
        """流式遍历值变化事件。

        Yields (time, vcd_id, value_str) tuples.
        Filters by signal_ids if provided.
        Stops at end_time or after stop_after matching changes.

        Args:
            signal_ids: 关注的 VCD ID 集合，None = 全部
            start_time: 起始时间 (inclusive)
            end_time: 结束时间 (inclusive), None = 无限制
            stop_after: 最大匹配跳变数, None = 无限制
        """
        current_time = 0
        match_count = 0
        in_dump_block = False

        with open(self.filepath, "r", encoding="utf-8", errors="replace") as f:
            # 跳过头部到 $enddefinitions
            for raw in f:
                if raw.strip().startswith("$enddefinitions"):
                    break

            # 读取值变化
            for raw in f:
                line = raw.rstrip("\n").rstrip("\r").strip()

                if not line:
                    continue

                # ---- 时间戳 / timestamp ----
                if line.startswith("#"):
                    try:
                        current_time = int(line[1:])
                    except ValueError:
                        continue
                    if end_time is not None and current_time > end_time:
                        break
                    continue

                # ---- $comment 块 / skip comments ----
                if line.startswith("$comment"):
                    if not line.endswith("$end"):
                        for skipline in f:
                            if skipline.strip() == "$end":
                                break
                    continue

                # ---- $dumpvars / $dumpall -> treat as regular values ----
                if line.startswith("$dumpvars") or line.startswith("$dumpall"):
                    continue
                if line == "$end":
                    continue

                # ---- 值变化 / value change ----
                # 格式: 0! 或 b1010" 或 r3.14#
                value_str, vid = self._split_value_line(line)

                if vid is None:
                    continue

                if signal_ids is not None and vid not in signal_ids:
                    continue

                if current_time < start_time:
                    continue

                match_count += 1
                yield (current_time, vid, value_str)

                if stop_after is not None and match_count >= stop_after:
                    break

    # ---- internal helpers ----

    @staticmethod
    def _read_until(f, end_marker: str, raw_first: str, line_first: str) -> str:
        """读取直到 $end 的多行值。"""
        if line_first.endswith(end_marker):
            return line_first.split(None, 1)[1].rsplit(end_marker, 1)[0].strip()
        parts = [line_first]
        for raw in f:
            line = raw.rstrip("\n").rstrip("\r").strip()
            if line == end_marker:
                break
            parts.append(line)
        # 取第一行 keyword 后的内容 + 后续行
        text = " ".join(parts)
        # 去掉开头的 keyword (如 $timescale)
        if " " in text:
            text = text.split(" ", 1)[1]
        return text.strip()

    @staticmethod
    def _read_until_line(f, end_marker: str, raw_first: str, line_first: str) -> str:
        """读取直到 $end，返回完整单行（用于 $scope 等可能折行的）。"""
        if line_first.endswith(end_marker):
            return line_first
        combined = line_first
        for raw in f:
            line = raw.rstrip("\n").rstrip("\r").strip()
            combined += " " + line
            if line == end_marker:
                break
        return combined

    @staticmethod
    def _parse_timescale(ts_text: str) -> tuple:
        """解析 timescale 字符串如 '1ps', '10ns' -> (magnitude, unit)."""
        m = re.match(r'(\d+)\s*(s|ms|us|ns|ps|fs)', ts_text)
        if m:
            return (m.group(1), m.group(2))
        return ("1", "ps")

    @staticmethod
    def _parse_var(var_text: str, scope_stack: list) -> Optional[SignalDef]:
        """解析 $var 定义行。

        Format: $var <type> <width> <id> <name> [<lsb>:<msb>] $end
        Example: $var wire 1 ! clk $end
                 $var reg 4 = state [3:0] $end
        """
        # 去掉 $var 前缀和 $end 后缀
        inner = var_text
        if inner.startswith("$var"):
            inner = inner[4:].strip()
        if inner.endswith("$end"):
            inner = inner[:-4].strip()

        # 按空格拆分: type width id name [range]
        parts = inner.split()
        if len(parts) < 4:
            return None

        vtype = parts[0]
        try:
            width = int(parts[1])
        except ValueError:
            width = 1
        vid = parts[2]
        # name 可能是剩余的所有部分（含空格），但通常就是 parts[3]
        name = parts[3]
        # 去掉可能跟在名字后面的 range 如 [3:0]
        name = re.sub(r'\s*\[.*\]', '', name)

        # 构建 scope_path
        scope_path = [s[0] for s in scope_stack]
        full_path = ".".join(scope_path + [name]) if scope_path else name

        return SignalDef(
            vcd_id=vid, name=name, full_path=full_path,
            type=vtype, width=width, scope_path=list(scope_path)
        )

    @staticmethod
    def _build_full_paths(signals: list[SignalDef]):
        """为所有信号构建完整的 full_path（去重处理）。"""
        # 先在 parse_var 中已经设置了初步路径，这里做去重
        seen: dict[str, int] = {}
        for sig in signals:
            path = sig.full_path
            if path in seen:
                seen[path] += 1
                # 加 scope 前缀消歧义
                if sig.scope_path:
                    sig.full_path = ".".join(sig.scope_path[-2:] + [sig.name]) \
                        if len(sig.scope_path) >= 2 else sig.full_path
            else:
                seen[path] = 1

    def _split_value_line(self, line: str) -> tuple:
        """拆分值行: '1!' -> ('1', '!'), 'b1010\"' -> ('b1010', '\"')."""
        if not line:
            return ("", None)

        # 对已知 ID 从长到短尝试匹配后缀
        for vid in sorted(self._known_ids, key=len, reverse=True):
            if line.endswith(vid):
                value = line[:-len(vid)]
                # 验证 value 部分合法
                if value and (
                    value[0] in "01xXzZuUwWlLhH-" or  # scalar
                    value[0] in "bBrR"                  # vector/real
                ):
                    return (value, vid)
                # 如果 value 为空（不太可能），继续尝试更短的 ID

        # Fallback: 单字符值 + 单字符 ID（最简情况）
        if len(line) >= 2:
            return (line[:-1], line[-1])
        return ("", None)


# ============================================================================
# Section 3: VcdQueryEngine — 信号查询引擎
# ============================================================================

class VcdQueryEngine:
    """信号索引、glob 匹配、值格式化。"""

    def __init__(self, signals: list[SignalDef]):
        self.signals: dict[str, SignalDef] = {}   # vcd_id -> SignalDef
        self.by_path: dict[str, SignalDef] = {}   # full_path -> SignalDef
        for s in signals:
            self.signals[s.vcd_id] = s
            self.by_path[s.full_path] = s

    def match_signals(self, pattern: str) -> list[SignalDef]:
        """按 glob 模式匹配信号。

        段分隔符为 '.'，支持: * (单段), ** (递归多段), ? (单字符).
        自动支持部分路径匹配 — 'dut.*' 可匹配 'tb.dut.clk'.

        Supports shell-style globs on dot-separated signal paths.
        Patterns without dots (e.g. '*state*') match against full paths
        using fnmatch directly (dot-agnostic).
        """
        if not pattern or pattern == "*":
            return list(self.by_path.values())

        # 无点号 → 直接全文 fnmatch 匹配（跨段）
        if "." not in pattern:
            return [s for s in self.by_path.values()
                    if fnmatch.fnmatch(s.full_path, "*" + pattern + "*")
                    or fnmatch.fnmatch(s.name, pattern)]

        parts = pattern.split(".")
        regex_parts = []
        for p in parts:
            if p == "**":
                regex_parts.append(r".+")
            elif "*" in p or "?" in p or "[" in p:
                seg = fnmatch.translate(p)
                seg = seg[4:-3] if seg.startswith("(?s:") else seg
                seg = seg.replace(".*", r"[^.]*")
                seg = seg.replace(".?", r"[^.]")
                regex_parts.append(seg)
            else:
                regex_parts.append(re.escape(p))
        regex_body = r"\." .join(regex_parts)

        # 允许部分路径匹配: 'dut.*' 可匹配 'tb.dut.clk'
        if parts[0] != "**" and not parts[0].startswith("*"):
            regex = r"(^|.*\.)" + regex_body + r"$"
        else:
            regex = r"^" + regex_body + r"$"

        try:
            pat = re.compile(regex)
        except re.error:
            return [s for s in self.by_path.values()
                    if fnmatch.fnmatch(s.full_path, pattern)]

        return [s for s in self.by_path.values()
                if pat.search(s.full_path)]

    def match_signals_multi(self, patterns: str) -> list[SignalDef]:
        """按逗号分隔的多模式匹配信号。

        支持: 'dut.state' (单路径), 'dut.*' (glob), 'a,b,c' (逗号分隔).
        """
        if not patterns or patterns == "*":
            return list(self.by_path.values())

        seen: set[str] = set()
        result = []
        for pat in patterns.split(","):
            pat = pat.strip()
            if not pat:
                continue
            for sig in self.match_signals(pat):
                if sig.full_path not in seen:
                    seen.add(sig.full_path)
                    result.append(sig)
        return result
        """按 glob 模式匹配信号。

        段分隔符为 '.'，支持: * (单段), ** (递归多段), ? (单字符).
        自动支持部分路径匹配 — 'dut.*' 可匹配 'tb.dut.clk'.

        Supports shell-style globs on dot-separated signal paths.
        'dut.*' matches paths ending with 'dut.<something>'.
        '**' matches any number of segments recursively.
        """
        if not pattern or pattern == "*":
            return list(self.by_path.values())

        parts = pattern.split(".")
        regex_parts = []
        for p in parts:
            if p == "**":
                regex_parts.append(r".+")  # match one or more segments
            elif "*" in p or "?" in p or "[" in p:
                # 单段内: * → [^.]*, ? → [^.], 其余保留
                # fnmatch.translate('*') → '(?s:.*)\\z', extract content
                seg = fnmatch.translate(p)
                # format: '(?s:CONTENT)\\z' → extract CONTENT
                seg = seg[4:-3] if seg.startswith("(?s:") else seg
                # fnmatch 把 * 翻成 .*, 我们要 [^.]* (单段匹配)
                seg = seg.replace(".*", r"[^.]*")
                seg = seg.replace(".?", r"[^.]")
                regex_parts.append(seg)
            else:
                # 字面量段
                regex_parts.append(re.escape(p))
        regex_body = r"\." .join(regex_parts)

        # 允许部分路径匹配：如 'dut.*' 应匹配 'tb.dut.clk'
        # 在开头加可选的任意前缀 (^|.*\.) 或 (\.|^)
        if parts[0] != "**" and not parts[0].startswith("*"):
            # 模式不以通配符开头 → 允许任意层级前缀
            regex = r"(^|.*\.)" + regex_body + r"$"
        else:
            regex = r"^" + regex_body + r"$"

        try:
            pat = re.compile(regex)
        except re.error:
            return [s for s in self.by_path.values()
                    if fnmatch.fnmatch(s.full_path, pattern)]

        return [s for s in self.by_path.values()
                if pat.search(s.full_path)]

    def resolve(self, name: str) -> Optional[str]:
        """根据完整路径或叶子名查找 vcd_id。

        Given 'dut.clk' or leaf 'clk', return vcd_id or None.
        """
        if name in self.by_path:
            return self.by_path[name].vcd_id
        for sig in self.signals.values():
            if sig.name == name:
                return sig.vcd_id
        # 按路径后缀匹配
        for sig in self.signals.values():
            if sig.full_path.endswith("." + name) or sig.full_path == name:
                return sig.vcd_id
        return None

    def get_signal(self, vcd_id: str) -> Optional[SignalDef]:
        """通过 vcd_id 获取信号定义。"""
        return self.signals.get(vcd_id)

    def all_signal_ids(self) -> set:
        """返回所有 VCD ID 的集合。"""
        return set(self.signals.keys())

    @staticmethod
    def format_value(raw: str, width: int) -> str:
        """将 VCD 原始值格式化为可读字符串。使用信号定义宽度。

        '0'       -> "0"       (1-bit)
        '1'       -> "1"
        'b1010'   -> "4'hA"    (binary -> hex for width>1)
        'b1100'   -> "4'hC"
        'r3.14'   -> "3.14"    (real)
        'x'       -> "x"
        'z'       -> "z"
        """
        if not raw:
            return "?"

        ch = raw[0].lower()
        if ch in "01xzuhwl-":
            return raw
        elif ch == "b":
            bits = raw[1:]
            if width <= 1:
                return bits if bits else "0"
            try:
                val = int(bits, 2)
                return f"{width}'h{val:X}"
            except ValueError:
                return raw
        elif ch == "r":
            try:
                return f"{float(raw[1:]):.4g}"
            except ValueError:
                return raw
        return raw


# ============================================================================
# Section 4: ConditionParser — 条件表达式解析器
# ============================================================================

class ConditionNode:
    """条件 AST 节点基类。"""
    def evaluate(self, values: dict, prev_values: dict) -> bool:
        raise NotImplementedError

    def needed_signals(self) -> set:
        """返回此条件依赖的信号 vcd_id 集合。"""
        raise NotImplementedError


class ValueCompare(ConditionNode):
    """signal OP value"""
    def __init__(self, signal_id: str, op: str, target: int, width: int):
        self.signal_id = signal_id
        self.op = op
        self.target = target
        self.width = width

    def evaluate(self, values: dict, prev_values: dict) -> bool:
        raw = values.get(self.signal_id, "x")
        try:
            curr = self._to_int(raw)
        except ValueError:
            return False
        if self.op == "==": return curr == self.target
        if self.op == "!=": return curr != self.target
        if self.op == ">":  return curr > self.target
        if self.op == "<":  return curr < self.target
        if self.op == ">=": return curr >= self.target
        if self.op == "<=": return curr <= self.target
        return False

    def _to_int(self, raw: str) -> int:
        ch = raw[0].lower() if raw else 'x'
        if ch == 'b':
            return int(raw[1:], 2) if raw[1:] else 0
        if ch in 'xzu':
            return -1  # unknown 不匹配任何值
        if ch in '01':
            return int(ch)
        return int(raw, 0) if raw else 0

    def needed_signals(self) -> set:
        return {self.signal_id}


class EdgeDetect(ConditionNode):
    """posedge / negedge signal"""
    def __init__(self, signal_id: str, edge: str):
        self.signal_id = signal_id
        self.edge = edge  # "posedge" or "negedge"

    def evaluate(self, values: dict, prev_values: dict) -> bool:
        raw = values.get(self.signal_id, "x")
        prev_raw = prev_values.get(self.signal_id, "x")
        curr = self._to_bit(raw)
        prev_ = self._to_bit(prev_raw)
        if self.edge == "posedge":
            return prev_ == 0 and curr == 1
        else:  # negedge
            return prev_ == 1 and curr == 0

    def _to_bit(self, raw: str) -> int:
        if not raw:
            return -1
        ch = raw[0].lower()
        if ch == '1':
            return 1
        if ch == '0':
            return 0
        return -1

    def needed_signals(self) -> set:
        return {self.signal_id}


class AndCondition(ConditionNode):
    def __init__(self, left: ConditionNode, right: ConditionNode):
        self.left = left
        self.right = right

    def evaluate(self, values: dict, prev_values: dict) -> bool:
        return self.left.evaluate(values, prev_values) and \
               self.right.evaluate(values, prev_values)

    def needed_signals(self) -> set:
        return self.left.needed_signals() | self.right.needed_signals()


class OrCondition(ConditionNode):
    def __init__(self, left: ConditionNode, right: ConditionNode):
        self.left = left
        self.right = right

    def evaluate(self, values: dict, prev_values: dict) -> bool:
        return self.left.evaluate(values, prev_values) or \
               self.right.evaluate(values, prev_values)

    def needed_signals(self) -> set:
        return self.left.needed_signals() | self.right.needed_signals()


class ConditionParser:
    """将条件表达式字符串解析为 ConditionNode AST。"""

    def __init__(self, engine: VcdQueryEngine):
        self.engine = engine
        self.tokens: list = []
        self.pos = 0

    def parse(self, cond_str: str) -> Optional[ConditionNode]:
        """解析条件表达式字符串。"""
        self.tokens = self._tokenize(cond_str)
        self.pos = 0
        if not self.tokens:
            return None
        return self._parse_or()

    def _tokenize(self, s: str) -> list:
        """词法分析 / tokenizer."""
        tokens = []
        i = 0
        while i < len(s):
            ch = s[i]
            if ch.isspace():
                i += 1
                continue
            if ch == "(":
                tokens.append(("LPAREN", "("))
                i += 1
            elif ch == ")":
                tokens.append(("RPAREN", ")"))
                i += 1
            elif s[i:i+2] in ("&&", "||", "==", "!=", "<=", ">="):
                tokens.append(("OP", s[i:i+2]))
                i += 2
            elif ch in (">", "<", "="):
                tokens.append(("OP", ch))
                i += 1
            elif s[i:i+7] == "posedge":
                tokens.append(("EDGE", "posedge"))
                i += 7
            elif s[i:i+7] == "negedge":
                tokens.append(("EDGE", "negedge"))
                i += 7
            elif ch.isalpha() or ch == "_":
                # 信号名 / signal name
                j = i
                while j < len(s) and (s[j].isalnum() or s[j] in "_.[]"):
                    j += 1
                tokens.append(("SIGNAL", s[i:j]))
                i = j
            elif ch.isdigit():
                # 数值 / value literal: 123 或 4'hA 或 8'b1010
                j = i
                while j < len(s) and (s[j].isalnum() or s[j] in "'_hHbBxXzZ"):
                    j += 1
                tokens.append(("VALUE", s[i:j]))
                i = j
            else:
                i += 1
        tokens.append(("EOF", None))
        return tokens

    def _peek(self):
        return self.tokens[self.pos] if self.pos < len(self.tokens) else ("EOF", None)

    def _advance(self):
        tok = self._peek()
        self.pos += 1
        return tok

    def _parse_or(self) -> Optional[ConditionNode]:
        left = self._parse_and()
        if left is None:
            return None
        while self._peek()[1] == "||":
            self._advance()
            right = self._parse_and()
            if right:
                left = OrCondition(left, right)
        return left

    def _parse_and(self) -> Optional[ConditionNode]:
        left = self._parse_atom()
        if left is None:
            return None
        while self._peek()[1] == "&&":
            self._advance()
            right = self._parse_atom()
            if right:
                left = AndCondition(left, right)
        return left

    def _parse_atom(self) -> Optional[ConditionNode]:
        tok = self._peek()

        # LPAREN
        if tok[0] == "LPAREN":
            self._advance()
            node = self._parse_or()
            if self._peek()[0] == "RPAREN":
                self._advance()
            return node

        # posedge / negedge
        if tok[0] == "EDGE":
            edge_type = tok[1]
            self._advance()
            sig_tok = self._advance()
            if sig_tok[0] != "SIGNAL":
                return None
            sig_id = self.engine.resolve(sig_tok[1])
            if sig_id is None:
                print(f"Warning: signal '{sig_tok[1]}' not found")
                return None
            return EdgeDetect(sig_id, edge_type)

        # signal OP value
        if tok[0] == "SIGNAL":
            sig_name = tok[1]
            self._advance()
            op_tok = self._peek()
            if op_tok[0] not in ("OP",):
                # 单一信号名，检测是否为 1
                sig_id = self.engine.resolve(sig_name)
                if sig_id is None:
                    return None
                return ValueCompare(sig_id, "==", 1, 1)
            op = self._advance()[1]
            if op == "=":
                op = "=="  # 允许单等号
            val_tok = self._advance()
            if val_tok[0] != "VALUE":
                return None
            target_val, width = self._parse_value(val_tok[1])
            sig_id = self.engine.resolve(sig_name)
            if sig_id is None:
                print(f"Warning: signal '{sig_name}' not found")
                return None
            return ValueCompare(sig_id, op, target_val, width)

        return None

    def _parse_value(self, text: str) -> tuple:
        """解析值字符串: '123' -> (123, 32), \"4'hA\" -> (10, 4)."""
        text = text.replace("_", "")
        m = re.match(r"(\d+)'([bhBH])(\w+)", text)
        if m:
            width = int(m.group(1))
            base = m.group(2).lower()
            digits = m.group(3)
            try:
                if base == 'b':
                    return (int(digits, 2), width)
                else:
                    return (int(digits, 16), width)
            except ValueError:
                return (0, width)
        try:
            return (int(text), 32)
        except ValueError:
            return (0, 32)


# ============================================================================
# Section 5: VcdAnalyzer — 高层分析器
# ============================================================================

class VcdAnalyzer:
    """组合 Parser + QueryEngine 的高层分析接口。"""

    def __init__(self, filepath: str):
        self.filepath = filepath
        self.parser = VcdParser(filepath)
        header = self.parser.parse_header()
        self.header = header
        self.engine = VcdQueryEngine(header["signals"])
        self._timescale_to_ps = self._calc_scale_factor(
            header.get("timescale_magnitude", "1"),
            header.get("timescale_unit", "ps"),
        )

    # ---- info ----

    def get_info(self) -> dict:
        """返回文件元信息。"""
        sigs = self.header["signals"]
        types = {}
        for s in sigs:
            types[s.type] = types.get(s.type, 0) + 1

        # 找时间范围 (扫描开头和结尾)
        first_time = 0
        last_time = 0
        try:
            for t, vid, val in self.parser.iter_values(start_time=0):
                if first_time == 0:
                    first_time = t
                last_time = t
        except Exception:
            pass

        return {
            "file": self.filepath,
            "date": self.header.get("date", ""),
            "version": self.header.get("version", ""),
            "timescale": self.header.get("timescale", "1ps"),
            "num_signals": len(sigs),
            "type_counts": types,
            "first_time": first_time,
            "last_time": last_time,
        }

    def get_hierarchy_tree(self, glob_pattern: str = None) -> str:
        """生成 ASCII 层级树。"""
        sigs = self.header["signals"]
        if glob_pattern:
            matched = self.engine.match_signals_multi(glob_pattern)
            matched_paths = {s.full_path for s in matched}
        else:
            matched_paths = None

        # 构建树结构
        class Node:
            def __init__(self, name):
                self.name = name
                self.children: dict[str, Node] = OrderedDict()
                self.signals: list[SignalDef] = []

        root = Node("")
        for sig in sigs:
            if matched_paths is not None and sig.full_path not in matched_paths:
                continue
            # 路径段
            parts = sig.full_path.split(".")
            curr = root
            for part in parts[:-1]:
                if part not in curr.children:
                    curr.children[part] = Node(part)
                curr = curr.children[part]
            curr.signals.append(sig)

        lines = []
        def _walk(node: Node, prefix: str, is_last: bool, depth: int):
            if node.name:
                connector = "└── " if is_last else "├── "
                lines.append(prefix + connector + node.name + "/")
            new_prefix = prefix + ("    " if is_last else "│   ")
            items = list(node.children.items()) + \
                    [(f"({s.type} {s.width}bit) {s.name}", s) for s in node.signals]
            for i, item in enumerate(items):
                is_item_last = (i == len(items) - 1)
                if isinstance(item[1], Node):
                    _walk(item[1], new_prefix if node.name else prefix,
                          is_item_last, depth + 1)
                else:
                    sig = item[1]
                    connector = "└── " if is_item_last else "├── "
                    id_str = f" [{sig.vcd_id}]" if sig.vcd_id.isprintable() else ""
                    lines.append(
                        (new_prefix if node.name else prefix) + connector +
                        f"{sig.name} ({sig.type}, {sig.width}bit){id_str}"
                    )

        _walk(root, "", False, 0)
        return "\n".join(lines)

    # ---- show: waveform extraction ----

    def extract_transitions(self, signal_glob: str,
                            start_time: int = 0,
                            end_time: Optional[int] = None,
                            max_changes: int = 500) -> list[TransitionEvent]:
        """提取指定信号的波形跳变（仅值变化时刻）。

        总以 start_time 处的初始状态作为首条记录，保证输出可独立还原完整波形。
        Always includes initial state at start_time so the output is self-contained
        and can reconstruct the full waveform without the original VCD.
        """
        signals = self.engine.match_signals_multi(signal_glob)
        if not signals:
            return []
        target_ids = {s.vcd_id for s in signals}

        # ---- 第一遍扫描: 捕获 start_time 之前的最终状态 ----
        states: dict[str, str] = {}      # vcd_id -> raw value string
        for t, vid, raw_val in self.parser.iter_values(
            signal_ids=target_ids,
            start_time=0,
            end_time=start_time,
        ):
            if vid in target_ids:
                states[vid] = raw_val

        # ---- 用 start_time 处的状态构建初始记录 ----
        transitions: list[TransitionEvent] = []
        for sig in signals:
            raw = states.get(sig.vcd_id, "x")
            transitions.append(TransitionEvent(
                time=start_time, vcd_id=sig.vcd_id,
                signal_path=sig.full_path,
                old_value="x",
                new_value=self.engine.format_value(raw, sig.width),
            ))
            states[sig.vcd_id] = raw

        transition_count = len(signals)  # count initial entries
        if transition_count >= max_changes:
            return transitions

        # ---- 第二遍扫描: start_time 之后的跳变 ----
        for t, vid, raw_val in self.parser.iter_values(
            signal_ids=target_ids,
            start_time=start_time,
            end_time=end_time,
        ):
            if vid not in target_ids:
                continue

            sig = self.engine.get_signal(vid)
            if not sig:
                continue

            old_val = states.get(vid, "x")
            new_val = self.engine.format_value(raw_val, sig.width)

            if old_val != raw_val:  # 比较原始值，避免格式化差异
                transitions.append(TransitionEvent(
                    time=t, vcd_id=vid,
                    signal_path=sig.full_path,
                    old_value=self.engine.format_value(old_val, sig.width),
                    new_value=new_val,
                ))
                states[vid] = raw_val
                transition_count += 1

                if transition_count >= max_changes:
                    break

        return transitions

        return transitions

    # ---- sample: clock-synchronized sampling ----

    def sample_clock(self, clock_glob: str, signal_glob: str = "*",
                     edges: str = "both",
                     start_time: int = 0,
                     end_time: Optional[int] = None,
                     max_edges: int = 200) -> list[dict]:
        """以时钟为参考，提取每个沿和中点时刻的信号值。

        输出包含: 时钟沿 (↑ posedge, ↓ negedge) 和相邻沿之间的中点 (~)。
        可用于从 compact 输出进一步整理成时序数据表。

        Args:
            clock_glob: 时钟信号 glob (必须是 1-bit)
            signal_glob: 待采样数据信号 glob
            edges: 'both' | 'posedge' | 'negedge'
            start_time/end_time: 时间范围
            max_edges: 最多收集的沿数
        Returns:
            [{time, edge, signal_path: value, ...}, ...]
        """
        # 1. 解析时钟信号
        clock_sigs = self.engine.match_signals_multi(clock_glob)
        if not clock_sigs:
            return []
        clock_vid = clock_sigs[0].vcd_id
        clock_name = clock_sigs[0].full_path

        # 2. 解析数据信号
        data_sigs = self.engine.match_signals_multi(signal_glob)
        all_ids = {clock_vid} | {s.vcd_id for s in data_sigs}

        # 3. 第一遍: 收集时钟沿
        edge_events = []  # [(time, edge_type)]
        prev = None
        for t, vid, raw in self.parser.iter_values(
            signal_ids={clock_vid},
            start_time=start_time,
            end_time=end_time,
        ):
            curr = raw[0] if raw else 'x'
            if prev == '0' and curr == '1':
                if edges in ("both", "posedge"):
                    edge_events.append((t, "↑"))
            elif prev == '1' and curr == '0':
                if edges in ("both", "negedge"):
                    edge_events.append((t, "↓"))
            prev = curr
            if len(edge_events) >= max_edges:
                break

        if not edge_events:
            return []

        # 4. 计算中点并构建目标时间列表
        targets = []  # [(time, edge_type)]
        for i, (t, e) in enumerate(edge_events):
            targets.append((t, e))
            if i + 1 < len(edge_events):
                mid_t = (t + edge_events[i+1][0]) // 2
                targets.append((mid_t, "~"))
        targets.sort(key=lambda x: x[0])

        # 5. 第二遍: 扫描并采样
        current: dict[str, str] = {}  # vcd_id -> raw
        ti = 0  # target index
        samples = []
        sample_idx = 1

        for t, vid, raw in self.parser.iter_values(
            signal_ids=all_ids,
            start_time=start_time,
            end_time=end_time,
        ):
            # 在到达目标时间之前，更新当前值
            if vid in all_ids:
                current[vid] = raw

            # 检查是否到达目标时间
            while ti < len(targets) and t >= targets[ti][0]:
                target_t, edge = targets[ti]
                sample = {"time": target_t, "edge": edge, "_clock_name": clock_name}
                for sig in data_sigs:
                    raw_val = current.get(sig.vcd_id, "x")
                    sample[sig.full_path] = self.engine.format_value(
                        raw_val, sig.width)
                samples.append(sample)
                ti += 1

        # 处理剩余目标（在最后跳变之后的目标，使用最终值）
        while ti < len(targets):
            target_t, edge = targets[ti]
            sample = {"time": target_t, "edge": edge, "_clock_name": clock_name}
            for sig in data_sigs:
                raw_val = current.get(sig.vcd_id, "x")
                sample[sig.full_path] = self.engine.format_value(
                    raw_val, sig.width)
            samples.append(sample)
            ti += 1

        return samples

    # ---- search ----

    def search_condition(self, cond_str: str,
                         start_time: int = 0,
                         end_time: Optional[int] = None,
                         limit: int = 100) -> list[dict]:
        """搜索条件匹配的时刻。"""
        cp = ConditionParser(self.engine)
        ast = cp.parse(cond_str)
        if ast is None:
            return []

        needed_ids = ast.needed_signals()
        if not needed_ids:
            return []

        matches: list[dict] = []
        states: dict[str, str] = {}       # current values
        prev_states: dict[str, str] = {}  # previous values
        current_time = 0

        for t, vid, raw_val in self.parser.iter_values(
            signal_ids=needed_ids,
            start_time=start_time,
            end_time=end_time,
        ):
            current_time = t

            # 更新状态 (store raw VCD values for condition evaluation)
            prev_states = dict(states)
            states[vid] = raw_val

            # 检查条件
            if ast.evaluate(states, prev_states):
                match_info = {"time": t}
                for nid in needed_ids:
                    sig = self.engine.get_signal(nid)
                    if sig:
                        match_info[sig.full_path] = self.engine.format_value(
                            states.get(nid, "x"), sig.width)
                matches.append(match_info)
                if len(matches) >= limit:
                    break

        return matches

    # ---- stats ----

    def compute_stats(self, signal_glob: str,
                      start_time: int = 0,
                      end_time: Optional[int] = None) -> list[SignalStats]:
        """计算信号翻转统计。"""
        signals = self.engine.match_signals_multi(signal_glob)
        target_ids = {s.vcd_id for s in signals}
        acc: dict[str, dict] = {}
        for sig in signals:
            acc[sig.vcd_id] = {
                "sig": sig, "toggles": 0, "transitions": 0,
                "first_time": 0, "last_time": 0,
                "prev_val": None, "prev_time": 0,
                "high_time": 0, "low_time": 0,
                "last_non_x": None,
            }

        for t, vid, raw_val in self.parser.iter_values(
            signal_ids=target_ids,
            start_time=start_time,
            end_time=end_time,
        ):
            if vid not in acc:
                continue

            a = acc[vid]
            sig = a["sig"]
            new_val = self.engine.format_value(raw_val, sig.width)

            if a["prev_val"] is not None and a["prev_val"] != new_val:
                a["transitions"] += 1
                # 1-bit toggle
                if sig.width == 1:
                    prev_bit = a["prev_val"] if a["prev_val"] in "01" else None
                    new_bit = new_val if new_val in "01" else None
                    if prev_bit and new_bit and prev_bit != new_bit:
                        a["toggles"] += 1
                    # 累加电平时间
                    if a["last_non_x"] is not None:
                        duration = t - a["last_non_x"]
                        if a["prev_val"] == "1":
                            a["high_time"] += duration
                        elif a["prev_val"] == "0":
                            a["low_time"] += duration

            # 跟踪电平时间
            if sig.width == 1 and new_val in "01":
                a["last_non_x"] = t

            a["prev_val"] = new_val
            a["prev_time"] = t
            if a["first_time"] == 0:
                a["first_time"] = t
            a["last_time"] = t

        results = []
        for a in acc.values():
            sig = a["sig"]
            results.append(SignalStats(
                full_path=sig.full_path,
                width=sig.width,
                toggles=a["toggles"],
                transitions=a["transitions"],
                first_time=a["first_time"],
                last_time=a["last_time"],
                high_time=a["high_time"],
                low_time=a["low_time"],
            ))
        return results

    # ---- snapshot ----

    def get_snapshot(self, target_time: int,
                     signal_glob: str = "*") -> dict:
        """获取指定时刻各信号的值快照。"""
        signals = self.engine.match_signals_multi(signal_glob)
        if not signals:
            return {}

        # 需要从 $dumpvars 获取初始值，这里简化处理：
        # 扫描到 target_time，记录最后的值
        target_ids = {s.vcd_id for s in signals}
        states: dict[str, str] = {}
        last_time = 0

        for t, vid, raw_val in self.parser.iter_values(
            signal_ids=target_ids,
            start_time=0,
            end_time=target_time,
        ):
            last_time = t
            sig = self.engine.get_signal(vid)
            if sig:
                states[vid] = self.engine.format_value(raw_val, sig.width)

        # 构建结果
        result = {}
        for sig in signals:
            result[sig.full_path] = states.get(sig.vcd_id, "x")
        return result

    @staticmethod
    def _calc_scale_factor(magnitude: str, unit: str) -> float:
        """计算时间单位到 ps 的换算因子。"""
        scales = {"s": 1e12, "ms": 1e9, "us": 1e6, "ns": 1e3, "ps": 1, "fs": 1e-3}
        try:
            return float(magnitude) * scales.get(unit, 1)
        except ValueError:
            return 1.0

    def time_str(self, t: int) -> str:
        """格式化时间值。"""
        ts_unit = self.header.get("timescale_unit", "ps")
        return f"{t}{ts_unit}"


# ============================================================================
# Section 6: Output Formatters
# ============================================================================

def format_info_human(info: dict, tree: str = None) -> str:
    """人类可读的 info 输出。"""
    lines = [
        f"VCD File:      {info['file']}",
        f"Date:          {info.get('date', 'N/A')}",
        f"Version:       {info.get('version', 'N/A')}",
        f"Timescale:     {info.get('timescale', 'N/A')}",
        f"Time Range:    {info.get('first_time', 0)} - {info.get('last_time', 0)}",
        f"Total Signals: {info.get('num_signals', 0)}",
    ]
    for t, n in sorted(info.get("type_counts", {}).items()):
        lines.append(f"  {t}: {n}")
    if tree:
        lines.append("")
        lines.append(tree)
    return "\n".join(lines)


def format_info_compact(info: dict) -> str:
    """紧凑的 info 输出 — 键值对格式，便于脚本解析。"""
    return (f"# vcd: {info['file']}\n"
            f"# timescale: {info.get('timescale','?')}\n"
            f"# signals: {info.get('num_signals',0)}\n"
            f"# time_range: {info.get('first_time',0)} - {info.get('last_time',0)}")


def format_list_human(signals: list[SignalDef], tree: str = None) -> str:
    """人类可读的信号列表。"""
    if tree:
        return tree
    lines = [f"{'type':<10} {'width':>5}  {'vcd_id':<6}  path"]
    lines.append("-" * 60)
    for s in signals:
        lines.append(f"{s.type:<10} {s.width:>5}  {s.vcd_id:<6}  {s.full_path}")
    return "\n".join(lines)


def format_list_compact(signals: list[SignalDef]) -> str:
    """紧凑信号列表 — 每行一个信号，空格分隔字段，便于脚本解析。"""
    lines = [f"# signal_count: {len(signals)}"]
    for s in signals:
        lines.append(f"{s.full_path} {s.type} {s.width}bit")
    return "\n".join(lines)


def format_show_human(transitions: list[TransitionEvent],
                      signals: list[str]) -> str:
    """人类可读的波形输出。"""
    headers = ["Time"] + signals
    col_widths = [max(len(h), 10) for h in headers]

    lines = []
    lines.append("  ".join(f"{h:<{w}}" for h, w in zip(headers, col_widths)))
    lines.append("  ".join("-" * w for w in col_widths))

    # 按时间分组
    groups: dict[int, dict[str, str]] = OrderedDict()
    for ev in transitions:
        if ev.time not in groups:
            groups[ev.time] = {}
        groups[ev.time][ev.signal_path] = ev.new_value

    for t, vals in groups.items():
        row = [f"{t:<{col_widths[0]}}"]
        for i, sig_path in enumerate(signals):
            val = vals.get(sig_path, ".")
            row.append(f"{val:<{col_widths[i+1]}}")
        lines.append("  ".join(row))
    return "\n".join(lines)


def format_show_compact(transitions: list[TransitionEvent],
                        signals: list[str], ts_info: str = "",
                        vcd_file: str = "",
                        signal_meta: list[tuple] = None) -> str:
    """紧凑 VCD 风格波形输出 — 时间 + 空格分隔值，便于脚本解析。

    格式:
      # vcd: <path>  timescale: <ts>  signals: <N>
      # [0] tb.dut.state (reg, 4bit)
      # [1] tb.dut.clk (wire, 1bit)
      0    4'hC  0
      10417  .    1
    """
    lines = [f"# vcd: {vcd_file}  timescale: {ts_info}  signals: {len(signals)}"]

    # 信号索引行: 用 [N] full_path (type, width) 便于脚本识别列顺序
    if signal_meta:
        for i, (path, stype, width) in enumerate(signal_meta):
            lines.append(f"# [{i}] {path} ({stype}, {width}bit)")

    # 数据行: TIME  VAL0  VAL1  ...   (. 表示无变化)
    groups: dict[int, dict[str, str]] = OrderedDict()
    for ev in transitions:
        if ev.time not in groups:
            groups[ev.time] = {}
        groups[ev.time][ev.signal_path] = ev.new_value

    for t, vals in groups.items():
        parts = [str(t)]
        for sig_path in signals:
            parts.append(vals.get(sig_path, "."))
        lines.append("  ".join(parts))
    return "\n".join(lines)


def format_show_json(transitions: list[TransitionEvent],
                     signals: list[str], metadata: dict) -> str:
    """JSON 格式输出。"""
    output = []
    for ev in transitions:
        entry = {"time": ev.time, ev.signal_path: ev.new_value}
        # 其他信号填 null
        output.append(entry)

    # 按时间合并
    merged = OrderedDict()
    for ev in transitions:
        t = ev.time
        if t not in merged:
            merged[t] = {"time": t}
            for s in signals:
                merged[t][s] = None
        merged[t][ev.signal_path] = ev.new_value

    return json.dumps({
        "transitions": list(merged.values()),
        "metadata": metadata,
    }, indent=2, ensure_ascii=False)


def format_stats_human(stats_list: list[SignalStats], ts_unit: str = "ps") -> str:
    """人类可读的统计输出。"""
    lines = [
        f"{'Signal':<40} {'W':>3} {'Toggles':>8} {'Trans':>8} "
        f"{'First':>10} {'Last':>10}"
    ]
    lines.append("-" * 90)
    for s in stats_list:
        lines.append(
            f"{s.full_path:<40} {s.width:>3} {s.toggles:>8} {s.transitions:>8} "
            f"{s.first_time:>10} {s.last_time:>10}"
        )
    # 附加 1-bit 信号的占空比
    for s in stats_list:
        if s.width == 1 and s.high_time + s.low_time > 0:
            total = s.high_time + s.low_time
            duty = s.high_time / total * 100
            lines.append(
                f"  {s.full_path}: duty={duty:.1f}% "
                f"(high={s.high_time}{ts_unit}, low={s.low_time}{ts_unit})"
            )
    return "\n".join(lines)


def format_stats_compact(stats_list: list[SignalStats]) -> str:
    """紧凑统计输出 — 每行一个信号，空格分隔，便于脚本解析。"""
    lines = [f"# signal_count: {len(stats_list)}"]
    for s in stats_list:
        lines.append(
            f"{s.full_path} {s.width}bit toggles={s.toggles} "
            f"transitions={s.transitions} first={s.first_time} last={s.last_time}"
        )
    return "\n".join(lines)


def format_stats_json(stats_list: list[SignalStats]) -> str:
    return json.dumps([{
        "signal": s.full_path, "width": s.width,
        "toggles": s.toggles, "transitions": s.transitions,
        "first_time": s.first_time, "last_time": s.last_time,
        "high_time": s.high_time, "low_time": s.low_time,
    } for s in stats_list], indent=2, ensure_ascii=False)


def format_search_human(matches: list[dict], cond_str: str) -> str:
    """人类可读的搜索结果。"""
    lines = [f"Condition: {cond_str}", f"Found {len(matches)} matches:", ""]
    for m in matches:
        t = m.pop("time")
        ctx = " ".join(f"{k}={v}" for k, v in m.items())
        lines.append(f"  #{t}: {ctx}")
        m["time"] = t
    return "\n".join(lines)


def format_search_compact(matches: list[dict], cond_str: str) -> str:
    """紧凑搜索结果 — 便于脚本解析。"""
    if not matches:
        return f"# search: {cond_str}  matches: 0"
    lines = [f"# search: {cond_str}  matches: {len(matches)}"]
    for m in matches:
        ctx = " ".join(f"{k}={v}" for k, v in m.items() if k != "time")
        lines.append(f"{m['time']} {ctx}")
    return "\n".join(lines)


def format_snapshot_human(snapshot: dict, at_time: int, ts_unit: str) -> str:
    """人类可读的快照。"""
    lines = [f"Snapshot at #{at_time} {ts_unit}:", ""]
    max_name = max((len(k) for k in snapshot), default=20)
    for name, val in sorted(snapshot.items()):
        lines.append(f"  {name:<{max_name}} = {val}")
    return "\n".join(lines)


def format_snapshot_compact(snapshot: dict, at_time: int) -> str:
    """紧凑快照 — key=value 格式，便于脚本解析。"""
    lines = [f"# time: {at_time}"]
    for name, val in sorted(snapshot.items()):
        lines.append(f"{name} {val}")
    return "\n".join(lines)


def format_sample_compact(samples: list[dict], clock_name: str,
                          vcd_file: str, ts_info: str,
                          signal_meta: list[tuple]) -> str:
    """紧凑采样输出 — 每行一个采样点，便于脚本解析。

    ↑ = posedge, ↓ = negedge, ~ = midpoint
    """
    lines = [
        f"# vcd: {vcd_file}  timescale: {ts_info}",
        f"# clock: {clock_name}  samples: {len(samples)}",
        f"# signals: {len(signal_meta)}",
    ]
    for i, (path, stype, width) in enumerate(signal_meta):
        lines.append(f"# [{i}] {path} ({stype}, {width}bit)")

    for s in samples:
        parts = [str(s["time"]), s["edge"]]
        for path, stype, width in signal_meta:
            parts.append(s.get(path, "."))
        lines.append("  ".join(parts))
    return "\n".join(lines)


def format_sample_human(samples: list[dict], clock_name: str,
                        signal_paths: list[str]) -> str:
    """人类可读的采样输出。"""
    headers = ["Time", "Edge"] + signal_paths
    cols = [max(len(h), 12) for h in headers]
    lines = [f"Clock: {clock_name}  Samples: {len(samples)}", ""]
    lines.append("  ".join(f"{h:<{w}}" for h, w in zip(headers, cols)))
    lines.append("  ".join("-" * w for w in cols))
    for s in samples:
        row = [f"{s['time']:<{cols[0]}}", f"{s['edge']:<{cols[1]}}"]
        for path in signal_paths:
            row.append(f"{s.get(path, '.'):<{cols[2+signal_paths.index(path)]}}")
        lines.append("  ".join(row))
    return "\n".join(lines)


# ============================================================================
# Section 7: Time Parsing Utilities
# ============================================================================

def parse_time_arg(s: str, timescale_to_ps: float = 1.0) -> int:
    """解析时间参数: '1000000' 或 '1ms' 或 '1000ns' -> 整数 (ps 等原始单位)."""
    if s is None:
        return 0
    s = s.strip()
    # 带单位: 1ms, 500ns, 3.5us
    m = re.match(r'([\d.]+)\s*(s|ms|us|ns|ps|fs)', s)
    if m:
        val = float(m.group(1))
        unit = m.group(2)
        scales = {"s": 1e12, "ms": 1e9, "us": 1e6, "ns": 1e3, "ps": 1, "fs": 1e-3}
        ps_val = val * scales.get(unit, 1)
        # 转回文件时间单位
        return int(ps_val / timescale_to_ps)
    return int(s)


# ============================================================================
# Section 8: CLI
# ============================================================================

def resolve_vcd_path(explicit: str) -> str:
    """解析 VCD 文件路径（必须显式指定）。"""
    if os.path.exists(explicit):
        return explicit
    cand = os.path.join("sim", explicit)
    if os.path.exists(cand):
        return cand
    raise FileNotFoundError(f"VCD file not found: {explicit}")


def cmd_info(args, analyzer: VcdAnalyzer):
    info = analyzer.get_info()
    tree = None
    if args.tree:
        tree = analyzer.get_hierarchy_tree(args.glob)
    fmt = args.format
    if fmt == "compact":
        print(format_info_compact(info))
        if tree:
            print(tree)
    elif fmt == "json":
        info["tree"] = tree
        print(json.dumps(info, indent=2, ensure_ascii=False, default=str))
    else:
        print(format_info_human(info, tree))


def cmd_list(args, analyzer: VcdAnalyzer):
    pattern = args.glob or "*"
    signals = analyzer.engine.match_signals_multi(pattern)
    if args.type and args.type != "all":
        signals = [s for s in signals if s.type == args.type]
    if args.width is not None:
        signals = [s for s in signals if s.width == args.width]
    tree = None
    if args.tree:
        tree = analyzer.get_hierarchy_tree(pattern)
    fmt = args.format
    if fmt == "compact":
        print(format_list_compact(signals))
    elif fmt == "json":
        print(json.dumps([{
            "vcd_id": s.vcd_id, "name": s.name, "full_path": s.full_path,
            "type": s.type, "width": s.width,
        } for s in signals], indent=2, ensure_ascii=False))
    else:
        print(format_list_human(signals, tree))


def cmd_show(args, analyzer: VcdAnalyzer):
    scale = analyzer._timescale_to_ps
    t0 = parse_time_arg(args.start, scale) if args.start else 0
    t1 = parse_time_arg(args.end, scale) if args.end else None
    max_n = args.max_changes or 500

    transitions = analyzer.extract_transitions(
        signal_glob=args.signals or "*",
        start_time=t0, end_time=t1, max_changes=max_n,
    )

    # 收集信号路径（按出现顺序）
    signal_order = list(OrderedDict.fromkeys(
        ev.signal_path for ev in transitions
    ))
    if not signal_order:
        matched = analyzer.engine.match_signals_multi(args.signals or "*")
        signal_order = [s.full_path for s in matched]

    # 构建信号元数据: [(path, type, width), ...]
    signal_meta = []
    for path in signal_order:
        sig = analyzer.engine.by_path.get(path)
        if sig:
            signal_meta.append((path, sig.type, sig.width))
        else:
            signal_meta.append((path, "?", 1))

    ts_info = analyzer.header.get("timescale", "1ps")

    fmt = args.format
    if fmt == "compact":
        print(format_show_compact(transitions, signal_order, ts_info,
                                   vcd_file=analyzer.filepath,
                                   signal_meta=signal_meta))
    elif fmt == "json":
        print(format_show_json(transitions, signal_order, {
            "vcd_file": analyzer.filepath,
            "timescale": ts_info,
            "range": {"start": t0, "end": t1},
            "total_transitions": len(transitions),
        }))
    else:
        print(format_show_human(transitions, signal_order))


def cmd_search(args, analyzer: VcdAnalyzer):
    scale = analyzer._timescale_to_ps
    t0 = parse_time_arg(args.start, scale) if args.start else 0
    t1 = parse_time_arg(args.end, scale) if args.end else None
    limit = args.limit or 100

    matches = analyzer.search_condition(
        cond_str=args.cond,
        start_time=t0, end_time=t1, limit=limit,
    )

    fmt = args.format
    if fmt == "compact":
        print(format_search_compact(matches, args.cond))
    elif fmt == "json":
        print(json.dumps(matches, indent=2, ensure_ascii=False))
    else:
        print(format_search_human(matches, args.cond))


def cmd_stats(args, analyzer: VcdAnalyzer):
    scale = analyzer._timescale_to_ps
    t0 = parse_time_arg(args.start, scale) if args.start else 0
    t1 = parse_time_arg(args.end, scale) if args.end else None

    stats_list = analyzer.compute_stats(
        signal_glob=args.signals or "*",
        start_time=t0, end_time=t1,
    )

    ts_unit = analyzer.header.get("timescale_unit", "ps")
    fmt = args.format
    if fmt == "compact":
        print(format_stats_compact(stats_list))
    elif fmt == "json":
        print(format_stats_json(stats_list))
    else:
        print(format_stats_human(stats_list, ts_unit))


def cmd_snapshot(args, analyzer: VcdAnalyzer):
    scale = analyzer._timescale_to_ps
    at_time = parse_time_arg(args.at, scale)

    snapshot = analyzer.get_snapshot(
        target_time=at_time,
        signal_glob=args.signals or "*",
    )

    ts_unit = analyzer.header.get("timescale_unit", "ps")
    fmt = args.format
    if fmt == "compact":
        print(format_snapshot_compact(snapshot, at_time))
    elif fmt == "json":
        print(json.dumps(snapshot, indent=2, ensure_ascii=False))
    else:
        print(format_snapshot_human(snapshot, at_time, ts_unit))


def cmd_sample(args, analyzer: VcdAnalyzer):
    """时钟沿采样: 每个沿 + 中点时刻的信号值。"""
    scale = analyzer._timescale_to_ps
    t0 = parse_time_arg(args.start, scale) if args.start else 0
    t1 = parse_time_arg(args.end, scale) if args.end else None
    max_e = args.max_edges or 200

    samples = analyzer.sample_clock(
        clock_glob=args.clock,
        signal_glob=args.signals or "*",
        edges=args.edges or "both",
        start_time=t0, end_time=t1, max_edges=max_e,
    )

    if not samples:
        print(f"# No clock edges found for '{args.clock}' in time range")
        return

    # 收集信号路径（排除内部字段）
    signal_paths = [k for k in samples[0].keys()
                    if k not in ("time", "edge", "_clock_name")]
    signal_meta = []
    for path in signal_paths:
        sig = analyzer.engine.by_path.get(path)
        if sig:
            signal_meta.append((path, sig.type, sig.width))
        else:
            signal_meta.append((path, "?", 1))

    clock_name = samples[0].get("_clock_name", args.clock)
    ts_info = analyzer.header.get("timescale", "1ps")

    fmt = args.format
    if fmt == "compact":
        print(format_sample_compact(samples, clock_name, analyzer.filepath,
                                     ts_info, signal_meta))
    elif fmt == "json":
        print(json.dumps(samples, indent=2, ensure_ascii=False))
    else:
        print(format_sample_human(samples, clock_name, signal_paths))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="VCD Waveform Analyzer — 从 VCD 波形文件中提取、筛选、采样信号数据，"
                    "输出紧凑文本供 AI 或脚本进一步处理。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=r"""
┌──────────────────────────────────────────────────────────┐
│  常用工作流 / Common Workflows                           │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  1. 查看 VCD 中有哪些信号 / Discover signals:             │
│     %(prog)s list sim/cdr.vcd --glob "dut.*state*"        │
│     %(prog)s info sim/cdr.vcd --tree                      │
│                                                          │
│  2. 提取波形跳变 (VCD 风格, 可独立还原) / Extract waves:   │
│     %(prog)s show sim/cdr.vcd                             │
│       -s "top.dut.clk,top.dut.state,top.dut.d_out"        │
│       --start 0 --end 1ms                                 │
│                                                          │
│  3. 以时钟为参考采样 (沿+中点) / Clock-synced sampling:    │
│     %(prog)s sample sim/cdr.vcd                           │
│       --clock "top.dut.clk"                               │
│       -s "top.dut.state,top.dut.d_out,top.dut.a_reg"      │
│                                                          │
│  4. 搜索条件匹配时刻 / Search for conditions:              │
│     %(prog)s search sim/cdr.vcd                           │
│       --cond "state == 4'h6 && posedge clk"               │
│                                                          │
│  5. 查看信号统计 / Signal statistics:                      │
│     %(prog)s stats sim/cdr.vcd -s "dut.*"                 │
│                                                          │
│  6. 某时刻快照 / Snapshot at a time:                       │
│     %(prog)s snapshot sim/cdr.vcd --at 1.5ms              │
│                                                          │
│  输出格式 / Output formats:                                │
│    compact  默认, VCD 风格 key=value, 便于脚本解析         │
│    human    人类可读的表格格式                            │
│    json     JSON, 程序化消费                              │
│                                                          │
│  信号匹配 / Signal patterns:                              │
│    逗号分隔多信号: "a,b,c"                                 │
│    完整路径:     "top.dut.state"                           │
│    Glob 通配:    "dut.*", "*clk*", "**.state"              │
│                                                          │
└──────────────────────────────────────────────────────────┘
        """,
    )
    sub = parser.add_subparsers(dest="command", help="Subcommands")

    # ---- info ----
    p_info = sub.add_parser("info", help="Show VCD file metadata",
        epilog="Examples:\n  %(prog)s sim/cdr.vcd\n  %(prog)s sim/cdr.vcd --tree")
    p_info.add_argument("--format", choices=["human", "compact", "json"],
                        default="compact", help="Output format (default: compact)")
    p_info.add_argument("vcd", help="VCD file path (required)")
    p_info.add_argument("--tree", action="store_true", help="Show hierarchy tree")
    p_info.add_argument("--glob", help="Filter tree by glob pattern")

    # ---- list ----
    p_list = sub.add_parser("list", help="List signals matching pattern",
        epilog="Examples:\n"
               "  %(prog)s sim/cdr.vcd --glob \"dut.*\"\n"
               "  %(prog)s sim/cdr.vcd --glob \"*state*\" --tree\n"
               "  %(prog)s sim/cdr.vcd --glob \"dut.*\" --type reg --width 4")
    p_list.add_argument("--format", choices=["human", "compact", "json"],
                        default="compact", help="Output format")
    p_list.add_argument("vcd", help="VCD file path (required)")
    p_list.add_argument("--glob", help="Glob pattern (e.g. 'dut.*')")
    p_list.add_argument("--type", choices=["wire","reg","integer","real","parameter","all"],
                        help="Filter by signal type")
    p_list.add_argument("--width", type=int, help="Filter by bit width")
    p_list.add_argument("--tree", action="store_true", help="Show as hierarchy tree")

    # ---- show ----
    p_show = sub.add_parser("show", help="Extract waveform transitions (VCD-style, self-contained)",
        epilog="Examples:\n"
               "  %(prog)s sim/cdr.vcd -s \"dut.clk,dut.state,dut.d_out\"\n"
               "  %(prog)s sim/cdr.vcd -s \"dut.state,dut.d_out\" --start 0 --end 1ms\n"
               "  %(prog)s sim/cdr.vcd -s \"dut.*\" --format human --max-changes 100")
    p_show.add_argument("--format", choices=["human", "compact", "json"],
                        default="compact", help="Output format")
    p_show.add_argument("vcd", help="VCD file path (required)")
    p_show.add_argument("-s", "--signals", help="Signal glob pattern (e.g. 'dut.state,dut.clk12m')")
    p_show.add_argument("--start", help="Start time (e.g. '0' or '1ms')")
    p_show.add_argument("--end", help="End time")
    p_show.add_argument("--max-changes", type=int, default=500,
                        help="Max transitions to show (default: 500)")

    # ---- search ----
    p_search = sub.add_parser("search", help="Search for condition matches",
        epilog="Examples:\n"
               "  %(prog)s sim/cdr.vcd --cond \"state == 4'h6\"\n"
               "  %(prog)s sim/cdr.vcd --cond \"state == 4'h6 && posedge clk\"\n"
               "  %(prog)s sim/cdr.vcd --cond \"d_out == 1\" --start 1ms --end 2ms")

    p_search.add_argument("--format", choices=["human", "compact", "json"],
                          default="compact", help="Output format")
    p_search.add_argument("vcd", help="VCD file path (required)")
    p_search.add_argument("--cond", required=True,
                          help="Condition expr (e.g. \"state == 4'h6 && posedge clk\")")
    p_search.add_argument("--start", help="Start time")
    p_search.add_argument("--end", help="End time")
    p_search.add_argument("--limit", type=int, default=100,
                          help="Max matches (default: 100)")

    # ---- stats ----
    p_stats = sub.add_parser("stats", help="Signal statistics")
    p_stats.add_argument("--format", choices=["human", "compact", "json"],
                         default="compact", help="Output format")
    p_stats.add_argument("vcd", help="VCD file path (required)")
    p_stats.add_argument("-s", "--signals", help="Signal glob pattern")
    p_stats.add_argument("--start", help="Start time")
    p_stats.add_argument("--end", help="End time")

    # ---- snapshot ----
    p_snap = sub.add_parser("snapshot", help="Signal values at a specific time")
    p_snap.add_argument("--format", choices=["human", "compact", "json"],
                        default="compact", help="Output format")
    p_snap.add_argument("vcd", help="VCD file path (required)")
    p_snap.add_argument("--at", required=True, help="Target time")
    p_snap.add_argument("-s", "--signals", help="Signal glob pattern")

    # ---- sample ----
    p_sample = sub.add_parser("sample", help="Sample signals at clock edges + midpoints")
    p_sample.add_argument("--format", choices=["human", "compact", "json"],
                          default="compact", help="Output format")
    p_sample.add_argument("vcd", help="VCD file path (required)")
    p_sample.add_argument("--clock", required=True,
                          help="Clock signal (e.g. 'tb.dut.clk12m')")
    p_sample.add_argument("-s", "--signals",
                          help="Data signals to sample (e.g. 'dut.state,dut.d_out')")
    p_sample.add_argument("--edges", choices=["both", "posedge", "negedge"],
                          default="both", help="Which edges to sample (default: both)")
    p_sample.add_argument("--start", help="Start time")
    p_sample.add_argument("--end", help="End time")
    p_sample.add_argument("--max-edges", type=int, default=200,
                          help="Max clock edges (default: 200)")

    return parser


# ============================================================================
# Section 9: Main
# ============================================================================

def main():
    parser = build_parser()
    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    try:
        vcd_file = resolve_vcd_path(args.vcd)
        analyzer = VcdAnalyzer(vcd_file)
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error reading VCD: {e}", file=sys.stderr)
        sys.exit(1)

    dispatch = {
        "info": cmd_info,
        "list": cmd_list,
        "show": cmd_show,
        "search": cmd_search,
        "stats": cmd_stats,
        "snapshot": cmd_snapshot,
        "sample": cmd_sample,
    }
    fn = dispatch.get(args.command)
    if fn:
        fn(args, analyzer)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
