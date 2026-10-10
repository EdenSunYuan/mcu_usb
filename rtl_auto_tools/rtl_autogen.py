#!/usr/bin/env python3
#============================================================================
# rtl_autogen.py — Verilog RTL 自动化: 端口解析 / 信号检查 / 顶层实例化生成
#
# 三个子命令 (对应三项需求):
#   ports : 解析 module 端口列表 (ANSI / 非 ANSI 两种风格),
#           输出 方向/类型/位宽/端口名/注释 表格, 可选 --json
#   lint  : 提取内部 wire/reg 定义, 报告
#           [未驱动] (无任何驱动源) 与 [未使用] (从未被读取) 的信号/端口
#   gen   : 扫描顶层文件注释中的子模块引用 (// INST: <路径>.v [实例名]),
#           解析被引用模块端口, 自动生成 连线 wire 声明 + 命名端口实例化,
#           并检查 未驱动(输入无来源)/未使用(输出无人消费) 的连线
#
# INST 注释约定 (写在顶层模块体内, 按依赖顺序排列):
#   // INST: ../../src/common/usb_crc5.v               → 实例名默认 u_<模块名>
#   // INST: ../../src/common/usb_crc16.v  u_crc16_chk  → 显式指定实例名
#
# 依赖: 仅 Python3 标准库
#============================================================================

import argparse
import bisect
import json
import os
import re
import sys
from dataclasses import dataclass, field

# Verilog-2001 关键字表 (标识符提取时排除)
KEYWORDS = frozenset('''
    always and assign automatic begin buf bufif0 bufif1 case casex casez cell
    cmos config deassign default defparam design disable edge else end endcase
    endconfig endfunction endgenerate endmodule endprimitive endspecify
    endtable endtask event for force forever fork function generate genvar
    highz0 highz1 if ifnone incdir include initial inout input instance
    integer join large liblist library localparam macromodule medium module
    nand negedge nmos nor noshowcancelled not notif0 notif1 or output parameter
    pmos posedge primitive pull0 pull1 pulldown pullup pulsestyle_onevent
    pulsestyle_ondetect rcmos real realtime reg release repeat rnmos rpmos
    rtran rtranif0 rtranif1 scalared showcancelled signed small specify specparam
    strong0 strong1 supply0 supply1 table task time tran tranif0 tranif1 tri
    tri0 tri1 triand trior trireg unsigned use vectored wait wand weak0 weak1
    while wire wor xnor xor
'''.split())

NET_TYPES = ('wire', 'tri', 'tri0', 'tri1', 'triand', 'trior', 'trireg',
             'wand', 'wor')
VAR_TYPES = ('reg', 'logic', 'integer', 'time', 'real', 'realtime')
ALL_TYPES = NET_TYPES + VAR_TYPES

TYPE_ALT = '|'.join(ALL_TYPES)


# ----------------------------------------------------------------------------
# 基础工具: 注释剥离 / 括号匹配 / 常量求值 / 标识符提取
# ----------------------------------------------------------------------------

def strip_comments(text):
    """删除 // 与 /* */ 注释, 保留字符串字面量.

    输出与原文等长 (注释替换为空格、保留换行), 偏移量在原文/处理后文本
    之间一一对应, 便于回原文抓端口尾注释.
    """
    out = []
    i, n = 0, len(text)
    NORMAL, LINEC, BLOCKC, STR = 0, 1, 2, 3
    mode = NORMAL
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ''
        if mode == NORMAL:
            if c == '/' and nxt == '/':
                mode, out, i = LINEC, out + [' ', ' '], i + 2
            elif c == '/' and nxt == '*':
                mode, out, i = BLOCKC, out + [' ', ' '], i + 2
            elif c == '"':
                mode, out, i = STR, out + [c], i + 1
            else:
                out.append(c)
                i += 1
        elif mode == LINEC:
            if c == '\n':
                mode, out = NORMAL, out + ['\n']
            else:
                out.append(' ')
            i += 1
        elif mode == BLOCKC:
            if c == '*' and nxt == '/':
                mode, out, i = NORMAL, out + [' ', ' '], i + 2
            else:
                out.append('\n' if c == '\n' else ' ')
                i += 1
        else:                                  # 字符串字面量
            if c == '\\' and i + 1 < n:
                out.extend(text[i:i + 2])
                i += 2
            else:
                if c == '"':
                    mode = NORMAL
                out.append(c)
                i += 1
    return ''.join(out)


def matching_paren(text, open_idx):
    """返回与 text[open_idx]=='(' 配对的 ')' 下标, 找不到返回 -1."""
    depth = 0
    for i in range(open_idx, len(text)):
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
            if depth == 0:
                return i
    return -1


def split_top_commas(text):
    """按括号/方括号深度为 0 的逗号切分, 返回 [(片段, 起, 止偏移)]."""
    items, depth, start = [], 0, 0
    for i, c in enumerate(text):
        if c in '([':
            depth += 1
        elif c in ')]':
            depth -= 1
        elif c == ',' and depth == 0:
            items.append((text[start:i], start, i))
            start = i + 1
    items.append((text[start:], start, len(text)))
    return items


def eval_const(expr, params=None):
    """对 [msb:lsb] / 参数表达式做受限整数求值, 失败返回 None."""
    if expr is None:
        return None
    params = params or {}
    s = expr.strip()

    def repl(m):
        name = m.group(0)
        if name not in params:
            raise KeyError(name)
        v = str(params[name]).strip()
        if re.fullmatch(r'-?\d+', v):
            return v
        inner = eval_const(v, params)          # 参数引用参数, 递归解析
        if inner is None:
            raise KeyError(name)
        return str(inner)

    try:
        s = re.sub(r'[a-zA-Z_]\w*', repl, s)
    except KeyError:
        return None
    if not re.fullmatch(r'[\d+\-*/() ]+', s):
        return None
    try:
        # 已消毒: 只含数字与四则运算符
        val = eval(s, {'__builtins__': {}}, {})
    except Exception:
        return None
    if isinstance(val, float):
        val = int(val) if val.is_integer() else None
    return val if isinstance(val, int) else None


def _clean_expr(t):
    """去掉系统任务/宏/进制字面量, 只留可提取标识符的文本.

    全部替换为等长空格 — 保证结果中的偏移与输入一致 (lint 依赖坐标对齐).
    """
    def pad(m):
        return ' ' * len(m.group(0))

    t = re.sub(r'\$\w+', pad, t)
    t = re.sub(r'`\w+', pad, t)
    t = re.sub(r"\d*\s*'\s*[bodhBODH][0-9a-fA-FxXzZ_?]+", pad, t)
    t = re.sub(r"'\s*[01xXzZ?]", pad, t)
    return t


def idents_in(text):
    """提取文本中的标识符 (排除关键字), 返回 [(名字, (起,止))]."""
    return [(m.group(0), m.span())
            for m in re.finditer(r'[a-zA-Z_]\w*', _clean_expr(text))
            if m.group(0) not in KEYWORDS]


def _parse_range(s):
    """'[7:0]' → ('7','0'); 无效/不存在 → (None, None)."""
    if s:
        m = re.match(r'\[\s*([^:]+?)\s*:\s*(.+?)\s*\]$', s.strip())
        if m:
            return m.group(1), m.group(2)
    return None, None


# ----------------------------------------------------------------------------
# 数据模型
# ----------------------------------------------------------------------------

@dataclass
class Port:
    name: str
    direction: str = ''          # input / output / inout
    vtype: str = 'wire'
    msb: str = None              # None = 标量端口
    lsb: str = None
    signed: bool = False
    comment: str = ''            # 端口尾注释 (回原文抓取)
    line: int = 0

    def width(self, params=None):
        if self.msb is None:
            return 1
        hi = eval_const(self.msb, params)
        lo = eval_const(self.lsb, params)
        return abs(hi - lo) + 1 if hi is not None and lo is not None else None

    def range_text(self):
        return '[%s:%s]' % (self.msb, self.lsb) if self.msb is not None else ''


@dataclass
class Signal:
    name: str
    kind: str                     # wire / reg / logic / integer ...
    msb: str = None
    lsb: str = None
    mem: str = None               # 存储器维度原文, 如 '[0:15]'
    has_init: bool = False        # 声明即赋值: wire x = expr;
    line: int = 0
    comment: str = ''

    def width(self, params=None):
        if self.msb is None:
            return 1
        hi = eval_const(self.msb, params)
        lo = eval_const(self.lsb, params)
        return abs(hi - lo) + 1 if hi is not None and lo is not None else None


@dataclass
class Conn:
    """实例的一处命名端口连接 .port(expr)."""
    port: str
    expr: str
    span: tuple                   # expr 在模块体中的 (起,止) 偏移


@dataclass
class Instance:
    module: str
    name: str
    conns: list = field(default_factory=list)   # [Conn]
    line: int = 0


@dataclass
class Module:
    name: str
    ports: list = field(default_factory=list)   # [Port]
    params: dict = field(default_factory=dict)  # 参数名 -> 默认值文本
    signals: list = field(default_factory=list) # 内部信号 [Signal]
    instances: list = field(default_factory=list)
    genvars: set = field(default_factory=set)   # genvar 名
    funcs: set = field(default_factory=set)     # function/task 名
    include_names: set = field(default_factory=set)  # `include 链上的已知名
    include_text: str = ''        # `include 链上各文件的剥离文本拼接
    file: str = ''
    line: int = 0
    body: str = ''                # 注释已剥离的模块体 (header ';' 之后)
    stripped: str = ''            # 注释已剥离的全文
    base_off: int = 0             # body 在 stripped 中的起始偏移
    # 以下均为 body 内偏移区间, lint 阶段使用:
    mask_spans: list = field(default_factory=list)   # 不计为"读取"的位置


# ----------------------------------------------------------------------------
# 解析: 文件 → [Module]
# ----------------------------------------------------------------------------

def _trailing_comment(raw, item_end):
    """回原文抓端口/声明条目的尾注释 (同 // 后内容, 截到行尾)."""
    nl = raw.find('\n', item_end)
    seg = raw[item_end:nl if nl >= 0 else len(raw)]
    m = re.search(r'//(.*)', seg)
    return m.group(1).strip() if m else ''


def parse_params(param_text):
    """'#(parameter W = 8, ...)' → {名: 默认值文本}."""
    params = {}
    for item, _, _ in split_top_commas(param_text or ''):
        m = re.match(r'\s*(?:parameter\s+)?(?:signed\s+)?(?:\[[^\]]*\]\s*)?'
                     r'([a-zA-Z_]\w*)\s*=\s*(.+?)\s*$', item)
        if m:
            params[m.group(1)] = m.group(2)
    return params


def _parse_ansi_port_item(item, carry):
    """解析单个 ANSI 端口条目; 无方向的条目 (如 ', b') 继承上一条 carry."""
    m = re.match(r'\s*(?:(input|output|inout)\b)?\s*'
                 r'(?:(%s)\b)?\s*(signed\b)?\s*(\[[^\]=]*\])?\s*'
                 r'([a-zA-Z_]\w*)\s*$' % TYPE_ALT, item)
    if m and m.group(1):
        direction, vtype, signed, rng, name = m.groups()
        carry = {'direction': direction, 'vtype': vtype or 'wire',
                 'signed': bool(signed), 'rng': rng}
        msb, lsb = _parse_range(rng)
        return Port(name=name, direction=direction, vtype=vtype or 'wire',
                    msb=msb, lsb=lsb, signed=bool(signed)), carry
    if m:                                    # ', b' 形式: 继承方向/类型/位宽
        _, vtype, signed, rng, name = m.groups()
        c = carry or {'direction': '', 'vtype': 'wire', 'rng': None,
                      'signed': False}
        rng = rng or c['rng']
        msb, lsb = _parse_range(rng)
        return Port(name=name, direction=c['direction'] or 'input',
                    vtype=vtype or c['vtype'], msb=msb, lsb=lsb,
                    signed=bool(signed) or c['signed']), carry
    return None, carry


def _resolve_include(inc, including_path, inc_dirs):
    """`include 文件解析: 包含文件目录 → inc_dirs → CWD."""
    cands = [os.path.join(os.path.dirname(os.path.abspath(including_path)),
                          inc)]
    for d in (inc_dirs or []):
        cands.append(os.path.join(d, inc))
    cands.append(inc)
    for c in cands:
        if os.path.isfile(c):
            return c
    return None


def _collect_include_names(path, inc_dirs, visited, depth=0, texts=None):
    """轻量收集 `include 链上的已知名: 宏/参数/任务/函数/信号声明.

    只取名字进已知集合 (消除 TB 文件 include 公共任务/宏造成的
    [未声明] 误报), 不展开内容到解析流程.
    texts: 传入 list 时, 顺带收集各 include 文件的剥离文本
           (TB 的信号常在 include 的任务中使用, 读取/驱动分析需要).
    """
    names = set()
    if depth > 5 or path in visited:
        return names
    visited.add(path)
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as f:
            text = strip_comments(f.read())
    except OSError:
        return names
    if texts is not None:
        texts.append(text)
    for m in re.finditer(r'`\s*define\s+([a-zA-Z_]\w*)', text):
        names.add(m.group(1))
    for m in re.finditer(r'\b(?:task|function)\b(?:\s+(?:automatic|signed))?'
                         r'(?:\s*\[[^\]=]*\])?\s*([a-zA-Z_]\w*)', text):
        names.add(m.group(1))
    for m in re.finditer(r'\b(?:parameter|localparam)\b\s*(?:signed\s+)?'
                         r'(?:\[[^\]=]*\]\s*)?([^;]+);', text):
        for item, _, _ in split_top_commas(m.group(1)):
            nm = re.match(r'\s*([a-zA-Z_]\w*)\s*=', item)
            if nm:
                names.add(nm.group(1))
    for m in re.finditer(r'\b(?:wire|reg|logic|integer|genvar)\b[^;]*;',
                         text):
        for name, _ in idents_in(m.group(0)):
            names.add(name)
    for m in re.finditer(r'`\s*include\s+"([^"]+)"', text):
        ip = _resolve_include(m.group(1), path, inc_dirs)
        if ip:
            names |= _collect_include_names(ip, inc_dirs, visited, depth + 1)
    return names


def parse_file(path, inc_dirs=None):
    """解析一个 Verilog 文件, 返回其中的模块列表."""
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        raw = f.read()
    stripped = strip_comments(raw)
    nl = [i for i, c in enumerate(stripped) if c == '\n']

    def line_of(off):                        # stripped 偏移 → 行号
        return bisect.bisect_right(nl, off) + 1

    modules = []
    for m in re.finditer(r'\bmodule\s+([a-zA-Z_]\w*)', stripped):
        end = stripped.find('endmodule', m.end())
        end = len(stripped) if end < 0 else end
        mod = Module(name=m.group(1), file=path, line=line_of(m.start()))
        zone = stripped[m.end():end]         # module 名之后到 endmodule

        # ---- header: 可选 #(参数), 可选 (端口表), 到首个 ';' ----
        pos = re.match(r'\s*', zone).end()
        params_txt = ''
        if zone[pos:pos + 1] == '#':
            po = zone.find('(', pos)
            pc = matching_paren(zone, po)
            params_txt = zone[po + 1:pc] if pc >= 0 else ''
            pos = pc + 1 if pc >= 0 else pos
        ports_txt, ports_off, body_start = '', -1, pos
        if zone[pos:pos + 1] == '(':
            po = zone.find('(', pos)
            pc = matching_paren(zone, po)
            if pc >= 0:
                ports_txt = zone[po + 1:pc]
                ports_off = m.end() + po + 1  # 端口表在 stripped 中的偏移
                body_start = pc + 1           # zone 内坐标
        semi = zone.find(';', body_start)     # header 结束的 ';'
        semi = semi if semi >= 0 else body_start - 1
        mod.stripped = stripped
        mod.body = zone[semi + 1:]
        mod.base_off = m.end() + semi + 1     # body 在 stripped 中的偏移
        mod.params = parse_params(params_txt)

        # ---- 端口表 (ANSI / 非 ANSI 自适应) ----
        ansi = any(re.search(r'\b(input|output|inout)\b', it)
                   for it, _, _ in split_top_commas(ports_txt) if it.strip())
        carry = None
        for item, s, e in split_top_commas(ports_txt):
            if not item.strip():
                continue
            if ansi:
                port, carry = _parse_ansi_port_item(item, carry)
                if port:
                    port.line = line_of(ports_off + s)
                    port.comment = _trailing_comment(raw, ports_off + e)
                    mod.ports.append(port)
            else:
                nm = re.match(r'\s*([a-zA-Z_]\w*)\s*$', item)
                if nm:                       # 非 ANSI: 先收名字, 方向在体内
                    mod.ports.append(Port(name=nm.group(1),
                                          line=line_of(ports_off + s)))

        _parse_body(mod, raw, line_of)
        modules.append(mod)
    if modules:
        texts = []
        inc_names = _collect_include_names(path, inc_dirs, set(),
                                           texts=texts)
        inc_names |= {m.group(1) for m in
                      re.finditer(r'`\s*define\s+([a-zA-Z_]\w*)', stripped)}
        inc_text = '\n'.join(texts)
        for mod in modules:
            mod.include_names = inc_names
            mod.include_text = inc_text
            # `ifdef/ifndef/elsif 的宏名: 可能由编译命令行 -D 提供,
            # 不属于信号 — 加掩码 (body 内的部分)
            for mm in re.finditer(r'`\s*(?:ifdef|ifndef|elsif)\s+'
                                  r'([a-zA-Z_]\w*)', stripped):
                a, b = mm.span(1)
                if mod.base_off <= a < mod.base_off + len(mod.body):
                    mod.mask_spans.append((a - mod.base_off,
                                           b - mod.base_off))
    return modules


# 匹配 function...endfunction / task...endtask 体内区域 (其中声明不算模块级信号)
_FT_RE = re.compile(r'\b(function|task)\b')
_FTBODY_END_RE = r'\bend(function|task)\b'


def _ft_spans(body):
    spans = []
    for m in _FT_RE.finditer(body):
        e = re.search(_FTBODY_END_RE, body[m.start():])
        spans.append((m.start(), m.start() + e.end() if e else len(body)))
    return spans


def _in_spans(off, spans):
    return any(s <= off < e for s, e in spans)


def _parse_body(mod, raw, line_of):
    body = mod.body
    base = mod.base_off                       # body→stripped 偏移换算基址
    masks = mod.mask_spans                    # body 内坐标
    ft = _ft_spans(body)

    # 1) 体内 input/output/inout 声明 (非 ANSI 端口方向补全)
    for m in re.finditer(r'\b(input|output|inout)\b\s*(%s\b)?\s*(signed\b)?'
                         r'\s*(\[[^\]]*\])?\s*([^;]+);' % TYPE_ALT, body):
        if _in_spans(m.start(), ft):
            continue
        direction, vtype, signed, rng, names = m.groups()
        masks.append((m.start(), m.start(5)))  # 方向..名字表头部不计读取
        for part, ps, _ in split_top_commas(names):
            nm = re.match(r'\s*([a-zA-Z_]\w*)\s*$', part)
            if not nm:
                continue
            name = nm.group(1)
            # ps 含逗号后的前导空白, 名字真实起点要加 nm.start(1)
            ns = m.start(5) + ps + nm.start(1)
            masks.append((ns, ns + len(name)))
            msb, lsb = _parse_range(rng)
            for p in mod.ports:
                if p.name == name:
                    p.direction = direction
                    if vtype:
                        p.vtype = vtype
                    if msb is not None:
                        p.msb, p.lsb = msb, lsb
                    if signed:
                        p.signed = True
                    break

    # 2) 内部信号声明 wire/reg/logic/integer ...
    decl_re = re.compile(r'\b(%s)\b\s*(signed\b)?\s*(\[[^\]=]*\])?\s*([^;]+);'
                         % TYPE_ALT)
    for m in decl_re.finditer(body):
        if _in_spans(m.start(), ft):
            continue
        kind, signed, rng, names = m.groups()
        msb, lsb = _parse_range(rng)
        masks.append((m.start(), m.start(4)))  # 类型..名字表头部不计读取
        for part, ps, _ in split_top_commas(names):
            nm = re.match(r'\s*([a-zA-Z_]\w*)\s*(\[[^\]]*\])?\s*(=\s*(.+))?\s*$',
                          part)
            if not nm:
                continue
            name, mem, _, init = nm.groups()
            # ps 含逗号后的前导空白, 名字真实起点要加 nm.start(1)
            ns = m.start(4) + ps + nm.start(1)
            masks.append((ns, ns + len(name)))
            if name in (p.name for p in mod.ports):
                continue                       # 非 ANSI 端口的体内声明
            mod.signals.append(Signal(
                name=name, kind=kind, msb=msb, lsb=lsb,
                mem=mem.strip() if mem else None,
                has_init=init is not None,
                line=line_of(base + m.start()),
                comment=_trailing_comment(raw, base + m.end())))

    # 3) 参数/localparam/genvar: 整句不计读取, localparam 并入参数表
    for m in re.finditer(r'\blocalparam\b\s*(?:signed\s+)?(?:\[[^\]=]*\]\s*)?'
                         r'([^;]+);', body):
        for item, _, _ in split_top_commas(m.group(1)):
            nm = re.match(r'\s*([a-zA-Z_]\w*)\s*=\s*(.+?)\s*$', item)
            if nm:
                mod.params[nm.group(1)] = nm.group(2)
    for m in re.finditer(r'\b(parameter|localparam|genvar)\b[^;]*;', body):
        masks.append(m.span())
    for m in re.finditer(r'\bgenvar\b([^;]+);', body):
        for name, _ in idents_in(m.group(1)):
            mod.genvars.add(name)

    # 4) function/task 名: 定义处抹掉, 调用处归入 funcs 集合 (不算未声明)
    for m in re.finditer(r'\b(?:function|task)\b(?:\s+(?:automatic|signed))?'
                         r'(?:\s*\[[^\]=]*\])?\s*([a-zA-Z_]\w*)', body):
        masks.append(m.span(1))
        mod.funcs.add(m.group(1))
    # function/task 体内声明的 形参/局部变量 也归入 funcs 集合 (不参与
    # 模块级信号分析, 但名字是已知的, 不报 [未声明])
    for fs, fe in ft:
        for dm in re.finditer(r'\b(?:input|output|inout|integer|reg|real)\b'
                              r'[^;]*;', body[fs:fe]):
            for name, _ in idents_in(dm.group(0)):
                mod.funcs.add(name)
    # generate 块标签 (begin : name) — 标签不是信号
    for m in re.finditer(r'\bbegin\s*:\s*([a-zA-Z_]\w*)', body):
        masks.append(m.span(1))
        mod.funcs.add(m.group(1))
    for m in re.finditer(r'\bend\s*:\s*([a-zA-Z_]\w*)', body):
        masks.append(m.span(1))

    # 5) 实例: 模块名 实例名 #(参数)? ( 命名连接表 );
    inst_re = re.compile(r'\b([a-zA-Z_]\w*)\s+([a-zA-Z_]\w*)\s*'
                         r'(#\s*\((?:[^()]|\([^()]*\))*\))?\s*\(')
    for m in inst_re.finditer(body):
        modname, instname = m.group(1), m.group(2)
        if modname in KEYWORDS or instname in KEYWORDS:
            continue
        po = m.end() - 1                       # 命名连接表 '(' 位置
        pc = matching_paren(body, po)
        if pc < 0:
            continue
        masks.append(m.span(1))                # 模块名
        masks.append(m.span(2))                # 实例名
        conns = []
        for cm in re.finditer(r'\.\s*([a-zA-Z_]\w*)\s*\(([^()]*)\)',
                              body[po:pc]):
            # 端口标签 (.port 的 port) 不算信号读取
            masks.append((po + cm.start(1), po + cm.end(1)))
            # expr 保留原文不 strip — span 坐标依赖其与 body 的偏移一致
            conns.append(Conn(port=cm.group(1), expr=cm.group(2),
                              span=(po + cm.start(2), po + cm.end(2))))
        mod.instances.append(Instance(module=modname, name=instname,
                                      conns=conns,
                                      line=line_of(base + m.start())))


# ----------------------------------------------------------------------------
# lint: 驱动 / 使用分析
# ----------------------------------------------------------------------------

def analyze_module(mod, known_modules):
    """对单个模块做驱动/使用分析 (参考 Verilator MULTIDRIVEN 等规则).

    返回 (drivers, reads, issues):
      drivers: 名字 -> [(类别, 组id, 来源, 行号, 偏移)]
               类别: cont=assign / proc=过程赋值 / init=声明初始化 / inst=实例输出
               组id: 同组视为同一驱动源 (同一 always 块内多分支只算一组)
      reads:   被读取过的名字集合
      issues:  {'undeclared': [(名字, 行号)],      未声明标识符 (隐式网线?)
                'multidriven':  [(名字, 描述, 行号)],
                'latches':      [(名字, 行号)]}   组合块不完整赋值启发式
    坐标一律使用 body 内偏移.
    """
    body = mod.body
    known = known_modules
    drivers = {}
    write_spans = []          # 写入位置的 (起,止) — 从读取中剔除

    # 过程块归属: 驱动所在块 = 其前方最近的过程关键字.
    # 只有 always 家族是并发驱动 ('proc'); initial/task/function 体内的
    # 写入是调用时序执行 → 归 'init' 类 (TB 的 initial clk=0 +
    # always clk=~clk、case 任务写统计变量都是标准写法, 不构成
    # MULTIDRIVEN 冲突)
    proc_kw = [(m.start(), m.group(0)) for m in
               re.finditer(r'\b(?:always|always_comb|always_ff|always_latch'
                           r'|initial|task|function)\b', body)]
    proc_kw_off = [o for o, _ in proc_kw]

    def block_id(off):
        return bisect.bisect_right(proc_kw_off, off) - 1

    def add_driver(name, cls, gid, src, line, off):
        drivers.setdefault(name, []).append((cls, gid, src, line, off))

    def add_proc_driver(name, src, line, off):
        i = block_id(off)
        if i >= 0 and proc_kw[i][1] in ('initial', 'task', 'function'):
            add_driver(name, 'init', 0, src, line, off)
        else:
            add_driver(name, 'proc', i, src, line, off)

    # 1) 工作副本: 先屏蔽声明头/参数/实例名/端口标签, 再清空字符串字面量
    #    (字符串里的 "x = y" 之类不参与驱动/读取分析)
    work_chars = list(body)
    for s, e in mod.mask_spans:
        for i in range(s, min(e, len(work_chars))):
            if work_chars[i] != '\n':
                work_chars[i] = ' '
    work = _blank_strings(''.join(work_chars))

    # 2) assign 语句: 记录驱动后从工作副本抹掉, 以免 '=' 再扫描一遍
    for m in sorted(re.finditer(r'\bassign\b\s*([^=;]+)=', work),
                    key=lambda x: -x.start()):
        line = _line_of(mod, m.start())
        for name, (s, e) in idents_in(m.group(1)):
            add_driver(name, 'cont', m.start(), 'assign', line, m.start(1) + s)
            write_spans.append((m.start(1) + s, m.start(1) + e))
        work = work[:m.start()] + ' ' * (m.end() - m.start()) + work[m.end():]

    # 2b) 系统任务的输出参数 ($value$plusargs / $fscanf 等) 视为写入
    for m in re.finditer(r'\$(?:value\$plusargs|fscanf|sscanf|fread|'
                         r'sdf_annotate)\b\s*\(([^()]*)\)', work):
        line = _line_of(mod, m.start())
        for name, (s, e) in idents_in(m.group(1)):
            if name in KEYWORDS:
                continue
            add_proc_driver(name, '系统任务输出', line, m.start())
            write_spans.append((m.start(1) + s, m.start(1) + e))

    # 3) 过程赋值 '=' / '<=': 直接形 + 拼接形.
    #    '<=' 有二义性: 语句层是非阻塞赋值, 表达式内(括号深度>0,
    #    如 if (a <= b))是比较运算 — 深度>0 的 '<=' 一律不算驱动.
    #    目标允许嵌套位宽索引, 如 mem[cnt[1:0]] <= ...;
    _IDX = r'(?:\[(?:[^\[\]]|\[[^\[\]]*\])*\])*'
    for m in re.finditer(r'\b([a-zA-Z_]\w*)\s*' + _IDX + r'\s*'
                         r'(<=|=(?![=<>]))', work):
        name = m.group(1)
        if name in KEYWORDS:
            continue
        if m.group(2) == '<=' and _paren_depth_at(work, m.start()) > 0:
            continue                            # 表达式内的比较运算
        add_proc_driver(name,
                        'always' if m.group(2) == '<=' else '阻塞赋值',
                        _line_of(mod, m.start()), m.start())
        write_spans.append((m.start(), m.start() + len(name)))
    for m in re.finditer(r'\{([^{}]*)\}\s*(<=|=(?![=<>]))', work):
        line = _line_of(mod, m.start())
        for name, (s, e) in idents_in(m.group(1)):
            add_proc_driver(name, 'always(拼接)', line, m.start(1) + s)
            write_spans.append((m.start(1) + s, m.start(1) + e))
    for m in re.finditer(r'\b([a-zA-Z_]\w*)\s*\}\s*(<=|=(?![=<>]))', work):
        add_proc_driver(m.group(1), 'always(拼接)',
                        _line_of(mod, m.start()), m.start())
        write_spans.append((m.start(), m.start() + len(m.group(1))))

    # 4) 声明即赋值 wire x = expr;
    for sig in mod.signals:
        if sig.has_init:
            add_driver(sig.name, 'init', 0, '声明初始化', sig.line, 0)

    # 5) 实例连接: 已知模块的 output/inout → 驱动; 未知模块 → 记为
    #    'inst?' 保守驱动 (可消除 [未驱动], 但不参与 [多驱动] 冲突判定,
    #    因为它可能只是输入连接)
    for inst in mod.instances:
        sub = known.get(inst.module)
        for c in inst.conns:
            direction = None
            if sub:
                for p in sub.ports:
                    if p.name == c.port:
                        direction = p.direction
                        break
            if direction == 'input':
                continue                      # 读取, 由出现次数自然覆盖
            if direction in ('output', 'inout'):
                cls, src = 'inst', '实例输出(%s.%s)' % (inst.name, c.port)
            else:
                cls, src = 'inst?', '实例连接(%s.%s)?' % (inst.name, c.port)
            for name, (s, e) in idents_in(c.expr):
                add_driver(name, cls, (inst.name, c.port), src,
                           inst.line, c.span[0] + s)
                write_spans.append((c.span[0] + s, c.span[0] + e))

    # 6) 读取集合 = 屏蔽非信号后的全部标识符出现 − 写入位置
    masked = list(body)
    for s, e in mod.mask_spans:
        for i in range(s, min(e, len(masked))):
            if masked[i] != '\n':
                masked[i] = ' '
    masked_text = _blank_strings(''.join(masked))
    reads = set()
    for name, (s, e) in idents_in(masked_text):
        if not any(ws <= s < we for ws, we in write_spans):
            reads.add(name)
    # include 的任务/宏内容在模块作用域内执行 — 其标识符也计入读取
    if mod.include_text:
        for name, (s, e) in idents_in(_blank_strings(mod.include_text)):
            reads.add(name)

    # 7) 未声明标识符 (implicit net / 拼写错误).
    #    已知名集合 = 端口+信号+参数+genvar+函数/任务; 忽略 '.' 邻接的
    #    标识符 (层次引用 a.b 与参数覆盖标签 .W). 写入位置也参与检查
    #    (assign typo = x; 的 typo 同样是隐式网线).
    known_names = ({p.name for p in mod.ports} | {s.name for s in mod.signals}
                   | set(mod.params) | mod.genvars | mod.funcs
                   | mod.include_names | {mod.name})
    undeclared = {}
    for name, (s, e) in idents_in(masked_text):
        if name in known_names:
            continue
        if _adjacent_dot(masked_text, s, e):
            continue
        if name not in undeclared:
            undeclared[name] = _line_of(mod, s)

    # 7b) include 任务体内对模块信号的赋值也算驱动 (TB case 任务写
    #     统计变量的常见布局); 同为任务调用, 顺序执行 → 同一组, 不互斥
    signal_names = {s.name for s in mod.signals} | {p.name for p in mod.ports}
    if mod.include_text:
        inc_text = _blank_strings(mod.include_text)
        for m in re.finditer(r'\b([a-zA-Z_]\w*)\s*' + _IDX +
                             r'\s*(<=|=(?![=<>]))', inc_text):
            name = m.group(1)
            if name in KEYWORDS or name not in signal_names:
                continue
            if m.group(2) == '<=' and _paren_depth_at(inc_text,
                                                      m.start()) > 0:
                continue
            decl_line = next((s.line for s in mod.signals
                              if s.name == name),
                             next((p.line for p in mod.ports
                                   if p.name == name), mod.line))
            add_driver(name, 'init', 0, 'include(任务内赋值)', decl_line, -1)

    # 8) 多驱动检查 (Verilator MULTIDRIVEN 风格)
    multidriven = []
    for name in sorted(signal_names):
        entries = drivers.get(name, [])
        if name in mod.genvars:
            continue
        groups = {(cls, gid) for cls, gid, _, _, _ in entries}
        cont = {g for g in groups if g[0] == 'cont'}
        proc = {g for g in groups if g[0] == 'proc'}
        inst = {g for g in groups if g[0] == 'inst'}
        init = {g for g in groups if g[0] == 'init'}
        desc = None
        if len(proc) >= 2:
            desc = '在 %d 个 always/initial 块中都被赋值 (竞争)' % len(proc)
        elif proc and (cont or inst):
            desc = '过程赋值与 %s 同时驱动' % (
                'assign' if cont else '实例输出')
        elif len(cont) >= 2:
            desc = '被 %d 条 assign 同时驱动' % len(cont)
        elif cont and inst:
            desc = 'assign 与实例输出同时驱动'
        elif len(inst) >= 2:
            desc = '被 %d 个实例输出同时驱动' % len(inst)
        elif init and (cont or inst):
            # reg 声明初值 + always 驱动是合法写法, 不报
            desc = '声明初始化与 %s 同时驱动' % ('assign' if cont else '实例输出')
        if desc:
            first = min(e[3] for e in entries)
            multidriven.append((name, desc, first))

    # 9) 锁存器启发式: 组合块 (always @* / @(*) / always_comb) 中
    #    有 if 无 else、或有 case 无 default → 块内被赋值的信号可能成锁存器
    #    注意 '@*' 后不能接 \b (* 与空格均非单词字符, 词边界永远不成立)
    latches = []
    for m in re.finditer(r'\balways\s*@\s*\*|\balways\s*@\s*\(\s*\*\s*\)'
                         r'|\balways_comb\b', body):
        nxt = len(body)
        nm = re.search(r'\b(?:always|always_comb|always_ff|always_latch'
                       r'|initial|assign|function|task|endmodule)\b',
                       body[m.end():])
        if nm:
            nxt = m.end() + nm.start()
        has_if = re.search(r'\bif\b', body[m.end():nxt])
        has_else = re.search(r'\belse\b', body[m.end():nxt])
        has_case = re.search(r'\bcase[xz]?\b', body[m.end():nxt])
        has_default = re.search(r'\bdefault\b', body[m.end():nxt])
        if not ((has_if and not has_else) or (has_case and not has_default)):
            continue
        assigned = set()
        for name, entries in drivers.items():
            for cls, gid, src, line, off in entries:
                if cls == 'proc' and m.end() <= off < nxt:
                    assigned.add(name)
        for name in sorted(assigned):
            latches.append((name, _line_of(mod, m.start())))

    issues = {'undeclared': sorted(undeclared.items(), key=lambda kv: kv[1]),
              'multidriven': multidriven,
              'latches': latches}
    return drivers, reads, issues


def _blank_strings(text):
    """把字符串字面量的内容替换为空格 (保留引号与偏移)."""
    out, in_str = list(text), False
    i = 0
    while i < len(out):
        c = out[i]
        if in_str:
            if c == '\\' and i + 1 < len(out):
                out[i] = out[i + 1] = ' '
                i += 2
                continue
            if c == '"':
                in_str = False
            elif c != '\n':
                out[i] = ' '
        elif c == '"':
            in_str = True
        i += 1
    return ''.join(out)


def _paren_depth_at(text, pos):
    """text[pos] 之前的括号深度 (用于区分语句层 '<=' 与比较运算)."""
    d = 0
    for i in range(pos):
        if text[i] == '(':
            d += 1
        elif text[i] == ')':
            d -= 1
    return d


def _adjacent_dot(text, s, e):
    """标识符 [s,e) 前或后紧邻 '.' (跳过空白) → 层次引用/标签, 不算信号."""
    i = s - 1
    while i >= 0 and text[i] in ' \t\n\r':
        i -= 1
    if i >= 0 and text[i] == '.':
        return True
    j = e
    while j < len(text) and text[j] in ' \t\n\r':
        j += 1
    return j < len(text) and text[j] == '.'


def _line_of(mod, off):
    """body 偏移 → 行号 (以全文行号计)."""
    if not hasattr(mod, '_nl'):
        return mod.line
    return bisect.bisect_right(mod._nl, mod.base_off + off) + 1


# ----------------------------------------------------------------------------
# 文件收集: 参数可以是文件或目录 (目录递归收集 *.v / *.sv)
# ----------------------------------------------------------------------------

def collect_files(paths):
    """把 命令行路径参数 展开为去重后的 Verilog 文件列表.

    目录递归收集 .v/.sv (排序保证输出稳定); 返回 (文件列表, 错误消息列表).
    """
    files, errors, seen, walked = [], [], set(), []
    for p in paths:
        if os.path.isdir(p):
            found = []
            for root, dirs, names in os.walk(p):
                dirs[:] = sorted(d for d in dirs if d not in
                                 ('.git', '.svn', '.DS_Store'))
                walked.append(root)
                for n in sorted(names):
                    if n.endswith(('.v', '.sv')):
                        found.append(os.path.join(root, n))
            if not found:
                errors.append('目录 %s 下未找到 .v/.sv 文件' % p)
            for f in found:
                if f not in seen:
                    seen.add(f)
                    files.append(f)
        elif os.path.isfile(p):
            if p not in seen:
                seen.add(p)
                files.append(p)
        else:
            errors.append('路径不存在: %s' % p)
    return files, errors, walked


def parse_filelist(path):
    """解析工业界 .f 文件列表 (VCS/Verilator 通用格式).

    行内 '#...' 与 '//' 为注释; '+incdir+DIR' 收集为 include 搜索目录;
    其余每行一个文件路径, 相对 .f 文件所在目录解析; 支持嵌套 -f/-F.
    返回 (文件列表, incdir 列表, 错误消息列表).
    """
    files, incdirs, errors = [], [], []
    base = os.path.dirname(os.path.abspath(path))
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as f:
            lines = f.read().split('\n')
    except OSError as e:
        return [], [], ['无法读取 filelist %s: %s' % (path, e)]
    for ln, line in enumerate(lines, 1):
        s = line.split('#')[0].split('//')[0].strip()
        if not s:
            continue
        if s.startswith('+incdir+'):
            d = s[len('+incdir+'):]
            incdirs.append(d if os.path.isabs(d) else os.path.join(base, d))
            continue
        if s.startswith('-f ') or s.startswith('-F '):
            sub = os.path.join(base, s[3:].strip())
            sub_files, sub_incdirs, sub_errors = parse_filelist(sub)
            files += sub_files
            incdirs += sub_incdirs
            errors += sub_errors
            continue
        p = s if os.path.isabs(s) else os.path.join(base, s)
        if os.path.isfile(p):
            files.append(p)
        else:
            errors.append('filelist %s 第 %d 行: 文件不存在 %s'
                          % (path, ln, s))
    return files, incdirs, errors


# ----------------------------------------------------------------------------
# 子命令: ports
# ----------------------------------------------------------------------------

def cmd_ports(args):
    paths = list(args.files)
    if not paths and not getattr(args, 'filelist', []):
        print('错误: 需要提供文件/目录参数或 -f filelist', file=sys.stderr)
        return 1
    inc_dirs = []
    for fl in getattr(args, 'filelist', []) or []:
        fl_files, fl_incdirs, fl_errors = parse_filelist(fl)
        for e in fl_errors:
            print('错误: %s' % e, file=sys.stderr)
        paths += fl_files
        inc_dirs.extend(fl_incdirs)
    files, errors, _walked = collect_files(paths)
    for e in errors:
        print('错误: %s' % e, file=sys.stderr)
    ok = not errors
    for path in files:
        try:
            mods = parse_file(path)
        except OSError as e:
            print('错误: 无法读取 %s: %s' % (path, e), file=sys.stderr)
            ok = False
            continue
        if not mods:
            print('%s: 未找到 module' % path, file=sys.stderr)
            ok = False
            continue
        for mod in mods:
            if args.json:
                print(json.dumps({
                    'file': path, 'module': mod.name, 'params': mod.params,
                    'ports': [{'name': p.name, 'direction': p.direction,
                               'type': p.vtype,
                               'range': p.range_text() or None,
                               'width': p.width(mod.params),
                               'signed': p.signed,
                               'comment': p.comment} for p in mod.ports]},
                    ensure_ascii=False, indent=2))
                continue
            if args.md:
                print('### module %s\n' % mod.name)
                print('文件: `%s:%d` · 端口 %d 个%s\n' % (
                    path, mod.line, len(mod.ports),
                    (' · 参数: %s' % ', '.join(mod.params))
                    if mod.params else ''))
                print('| 方向 | 类型 | 位宽 | 名字 | 注释 |')
                print('|------|------|------|------|------|')
                for p in mod.ports:
                    rng = ('`%s`' % p.range_text()) if p.range_text() \
                        else '1 bit'
                    cmt = p.comment.replace('|', '\\|')
                    print('| %s | %s | %s | `%s` | %s |' % (
                        p.direction, p.vtype, rng, p.name, cmt))
                print()
                continue
            print('module %s  (%s:%d)  — %d 个端口%s' % (
                mod.name, path, mod.line, len(mod.ports),
                (', %d 个参数: %s' % (len(mod.params),
                                      ', '.join(mod.params)))
                if mod.params else ''))
            w_dir = max([len(p.direction) for p in mod.ports] + [6])
            w_typ = max([len(p.vtype) for p in mod.ports] + [4])
            w_rng = max([len(p.range_text()) for p in mod.ports] + [4])
            w_nm = max([len(p.name) for p in mod.ports] + [4])
            hdr = '  %-*s  %-*s  %-*s  %-*s  %s' % (
                w_dir, '方向', w_typ, '类型', w_rng, '位宽', w_nm, '名字', '注释')
            print(hdr)
            print('  ' + '-' * (len(hdr) - 2))
            for p in mod.ports:
                print('  %-*s  %-*s  %-*s  %-*s  %s' % (
                    w_dir, p.direction, w_typ, p.vtype, w_rng,
                    p.range_text() or '-', w_nm, p.name, p.comment))
            print()
    return 0 if ok else 1


# ----------------------------------------------------------------------------
# 子命令: lint
# ----------------------------------------------------------------------------

def cmd_lint(args):
    paths = list(args.files)
    if not paths and not getattr(args, 'filelist', []):
        print('错误: 需要提供文件/目录参数或 -f filelist', file=sys.stderr)
        return 1
    inc_dirs = []
    for fl in getattr(args, 'filelist', []) or []:
        fl_files, fl_incdirs, fl_errors = parse_filelist(fl)
        for e in fl_errors:
            print('错误: %s' % e, file=sys.stderr)
        paths += fl_files
        inc_dirs.extend(fl_incdirs)
    files, errors, walked = collect_files(paths)
    for e in errors:
        print('错误: %s' % e, file=sys.stderr)
    if errors:
        return 1
    # 批内所有目录自动作为 include 搜索目录 (TB include 公共任务的常见布局)
    inc_dirs.extend(walked)
    all_mods = []
    for path in files:
        try:
            all_mods.extend(parse_file(path, inc_dirs))
        except OSError as e:
            print('错误: 无法读取 %s: %s' % (path, e), file=sys.stderr)
            return 1
    if not all_mods:
        print('错误: 未解析到任何 module', file=sys.stderr)
        return 1

    # 预计算行号索引, 供 analyze 中的 _line_of 使用
    for mod in all_mods:
        mod._nl = [i for i, c in enumerate(mod.stripped) if c == '\n']

    known = {}                                # 模块名 → Module (端口方向查询)
    for mod in all_mods:
        known.setdefault(mod.name, mod)

    total = 0
    json_out = []
    style_total = 0
    for mod in all_mods:
        drivers, reads, issues = analyze_module(mod, known)
        probs = _lint_problems(mod, drivers, reads)
        # 未声明 / 多驱动 / 锁存器
        for name, line in issues['undeclared']:
            probs.append(('[未声明]', '-', name, line,
                          '未声明标识符 — 隐式 1bit 网线或拼写错误'))
        for name, desc, line in issues['multidriven']:
            kind = next((s.kind for s in mod.signals if s.name == name),
                        next((p.direction for p in mod.ports
                              if p.name == name), '-'))
            probs.append(('[多驱动]', kind, name, line, desc))
        for name, line in issues['latches']:
            kind = next((s.kind for s in mod.signals if s.name == name), '-')
            probs.append(('[锁存器?]', kind, name, line,
                          '组合 always 有 if 无 else / 有 case 无 default,'
                          ' 可能推断锁存器'))
        total += len(probs)
        style = _style_problems(mod, args.style) if args.style else []
        style_total += len(style)
        if args.json:
            json_out.append({
                'file': mod.file, 'module': mod.name,
                'problems': [{'type': t, 'kind': kind, 'name': name,
                              'line': line, 'message': msg}
                             for t, kind, name, line, msg in probs],
                'style': [{'message': msg} for _, _, _, _, msg in style],
                'signals': [{'name': s.name, 'kind': s.kind,
                             'range': ('[%s:%s]' % (s.msb, s.lsb))
                             if s.msb else None,
                             'line': s.line, 'comment': s.comment}
                            for s in mod.signals]})
            continue
        print('== %s: module %s ==' % (mod.file, mod.name))
        if args.all:
            print('内部信号定义 (%d):' % len(mod.signals))
            for sig in mod.signals:
                w = sig.width(mod.params)
                wtxt = ('%d bit' % w) if w is not None else (
                    '[%s:%s]' % (sig.msb, sig.lsb) if sig.msb else '1 bit')
                extra = (' ' + sig.mem) if sig.mem else ''
                cmt = ('  // ' + sig.comment) if sig.comment else ''
                print('  L%-5d %-8s %-20s %s%s%s' % (
                    sig.line, sig.kind, sig.name, wtxt, extra, cmt))
            if mod.instances:
                print('实例 (%d): %s' % (len(mod.instances),
                      ', '.join('%s(%s)' % (i.name, i.module)
                                for i in mod.instances)))
            print()

        if probs:
            w = max(len(t) for t, *_ in probs)
            for t, kind, name, line, msg in probs:
                print('  %-*s  %-8s %-20s L%-5d  %s' % (w, t, kind, name,
                                                        line, msg))
        else:
            print('  ✓ 无未驱动/未使用信号')
        if style:
            for _, kind, name, line, msg in style:
                print('  [风格] L%-5d %s' % (line, msg))
        print()
    if args.json:
        print(json.dumps(json_out, ensure_ascii=False, indent=2))
        return 0
    if total:
        print('共 %d 个问题' % total, end='')
        if style_total:
            print(' (另有 %d 条风格提示, 不计入退出码)' % style_total)
        else:
            print()
        return 2
    if style_total:
        print('0 个问题 (另有 %d 条风格提示, 不计入退出码)' % style_total)
    return 0


def _lint_problems(mod, drivers, reads):
    """单个模块的 lint 问题列表, 元素: (类型, 类别, 名字, 行号, 说明)."""
    probs = []
    for sig in mod.signals:
        drv = drivers.get(sig.name, [])
        used = sig.name in reads
        if not drv and not used:
            probs.append(('[未驱动且未使用]', sig.kind, sig.name, sig.line,
                          '完全无引用, 可删除'))
        elif not drv:
            probs.append(('[未驱动]', sig.kind, sig.name, sig.line,
                          '无任何驱动源 (缺 assign/always/实例输出?)'))
        elif not used:
            probs.append(('[未使用]', sig.kind, sig.name, sig.line,
                          '有驱动但从未被读取'))
    for p in mod.ports:
        if p.direction == 'input' and p.name not in reads:
            probs.append(('[未使用]', 'input', p.name, p.line,
                          '输入端口在模块内从未被读取'))
        if p.direction in ('output', 'inout') and not drivers.get(p.name):
            probs.append(('[未驱动]', p.direction, p.name, p.line,
                          '输出端口无内部驱动源'))
    return probs


def _style_problems(mod, enabled):
    """风格检查 (参考 Verilator DECLFILENAME / verible module-filename).

    返回 [(类型, 类别, 名字, 行号, 说明)] — 只提示, 不计入退出码.
    """
    probs = []
    stem = os.path.splitext(os.path.basename(mod.file))[0]
    if mod.name != stem:
        probs.append(('[风格]', 'module', mod.name, mod.line,
                      '模块名 %s 与文件名 %s.v 不一致 (DECLFILENAME)'
                      % (mod.name, stem)))
    try:
        with open(mod.file, 'r', encoding='utf-8', errors='replace') as f:
            raw_lines = f.read().split('\n')
    except OSError:
        raw_lines = []
    long_lines = [i + 1 for i, l in enumerate(raw_lines) if len(l) > 100]
    if long_lines:
        probs.append(('[风格]', 'line', '-', long_lines[0],
                      '%d 行超过 100 列 (如 L%d)' % (len(long_lines),
                                                     long_lines[0])))
    tab_lines = [i + 1 for i, l in enumerate(raw_lines)
                 if re.match(r'[ \t]*\t', l)]
    if tab_lines:
        probs.append(('[风格]', 'tab', '-', tab_lines[0],
                      '%d 行使用 Tab 缩进 (如 L%d)' % (len(tab_lines),
                                                       tab_lines[0])))
    if raw_lines and raw_lines[-1] != '':
        probs.append(('[风格]', 'eof', '-', len(raw_lines),
                      '文件末尾缺换行符'))
    return probs


# ----------------------------------------------------------------------------
# 子命令: tree — 模块层次树 + 实例端口核对
# ----------------------------------------------------------------------------

def cmd_tree(args):
    paths = list(args.files)
    if not paths and not getattr(args, 'filelist', []):
        print('错误: 需要提供文件/目录参数或 -f filelist', file=sys.stderr)
        return 1
    inc_dirs = []
    for fl in getattr(args, 'filelist', []) or []:
        fl_files, fl_incdirs, fl_errors = parse_filelist(fl)
        for e in fl_errors:
            print('错误: %s' % e, file=sys.stderr)
        paths += fl_files
        inc_dirs.extend(fl_incdirs)
    files, errors, _walked = collect_files(paths)
    for e in errors:
        print('错误: %s' % e, file=sys.stderr)
    if errors:
        return 1

    order, db, dup = [], {}, []
    for path in files:
        try:
            for mod in parse_file(path, inc_dirs):
                if mod.name in db:
                    dup.append('%s: module %s 与 %s 重名 (以先者为准)'
                               % (path, mod.name, db[mod.name].file))
                else:
                    db[mod.name] = mod
                    order.append(mod)
        except OSError as e:
            print('错误: 无法读取 %s: %s' % (path, e), file=sys.stderr)
            return 1
    for d in dup:
        print('警告: %s' % d, file=sys.stderr)
    if not db:
        print('错误: 未解析到任何 module', file=sys.stderr)
        return 1

    instantiated = {i.module for m in order for i in m.instances}
    tops = [m for m in order if m.name not in instantiated]
    if not tops:
        print('未发现顶层候选 (所有模块都被实例化?)')
        return 0

    problems = 0

    def walk_body(mod, child_base, chain):
        """打印 mod 的各实例 (实例行自带模块定义位置), 递归展开子层."""
        nonlocal problems
        insts = sorted(mod.instances, key=lambda i: i.line)
        for k, inst in enumerate(insts):
            last = k == len(insts) - 1
            branch = '└─ ' if last else '├─ '
            sub = db.get(inst.module)
            if not sub:
                problems += 1
                print('%s%s%s: %s  ⚠ 未找到模块定义'
                      % (child_base, branch, inst.name, inst.module))
                continue
            print('%s%s%s: %s  [%s:%d]'
                  % (child_base, branch, inst.name, inst.module,
                     sub.file, sub.line))
            deep = child_base + ('   ' if last else '│  ')
            if sub.name in chain:
                print('%s   ⚠ 循环实例化?' % deep)
                continue
            if not args.no_check:
                sub_ports = {p.name: p for p in sub.ports}
                conn_names = {c.port for c in inst.conns}
                warnings = ['连接了不存在的端口 .%s' % c.port
                            for c in inst.conns if c.port not in sub_ports]
                missing_in = [p.name for p in sub.ports
                              if p.direction == 'input'
                              and p.name not in conn_names]
                missing_out = [p.name for p in sub.ports
                               if p.direction in ('output', 'inout')
                               and p.name not in conn_names]
                if missing_in:
                    warnings.append('输入端口未连接: %s' % ', '.join(missing_in))
                if missing_out:
                    warnings.append('输出端口未连接: %s' % ', '.join(missing_out))
                for w in warnings:
                    problems += 1
                    print('%s   ⚠ %s' % (deep, w))
            walk_body(sub, deep, chain | {mod.name})

    print('顶层候选 %d 个:' % len(tops))
    for k, top in enumerate(tops):
        top_last = k == len(tops) - 1
        print('%s%s%s (顶层)  [%s:%d]'
              % ('', '└─ ' if top_last else '├─ ', top.name, top.file,
                 top.line))
        walk_body(top, '   ' if top_last else '│  ', frozenset())
    print()
    if problems:
        print('共 %d 处端口连接问题' % problems)
        return 2
    return 0


# ----------------------------------------------------------------------------
# 子命令: tb — 测试台骨架生成
# ----------------------------------------------------------------------------

def _is_clock(name):
    n = name.lower()
    return n == 'clk' or n.endswith('clk') or n.endswith('_clk')


def _is_reset(name):
    n = name.lower()
    return n.startswith('rst') or n.startswith('reset') \
        or '_rst' in n or '_rstn' in n


def cmd_tb(args):
    files, errors, _walked = collect_files([args.dut])
    for e in errors:
        print('错误: %s' % e, file=sys.stderr)
    if errors:
        return 1
    mods = parse_file(files[0])
    if not mods:
        print('错误: %s 中未找到 module' % files[0], file=sys.stderr)
        return 1
    if args.module:
        mod = next((m for m in mods if m.name == args.module), None)
        if not mod:
            print('错误: %s 中没有 module %s (有: %s)'
                  % (files[0], args.module, ', '.join(m.name for m in mods)),
                  file=sys.stderr)
            return 1
    else:
        mod = mods[0]

    tb_name = args.name or ('tb_%s' % mod.name)
    ports = mod.ports
    w_d = max([len(p.direction) for p in ports] + [1])
    w_t = max([len(p.vtype) for p in ports] + [1])
    w_r = max([len(p.range_text()) for p in ports] + [1])
    w_n = max([len(p.name) for p in ports] + [1])

    # ---- 信号分类: 时钟 / 复位 / 普通 ----
    clocks = [p for p in ports if _is_clock(p.name)]
    resets = [p for p in ports if _is_reset(p.name) and not _is_clock(p.name)]
    plain_in = [p for p in ports if p.direction == 'input'
                and p not in clocks and p not in resets]
    outs = [p for p in ports if p.direction in ('output', 'inout')]
    inouts = [p for p in ports if p.direction == 'inout']

    L = []
    L += ['`timescale 1ns/1ps',
          '//============================================================================',
          '// %s.v — %s 测试台骨架 (rtl_autogen.py tb 自动生成)' % (tb_name, mod.name),
          '// DUT: %s  module %s (%d 端口)' % (mod.file, mod.name, len(ports)),
          '// TODO: 在 "激励与自检" 区补充测试向量与结果比对',
          '//============================================================================',
          '',
          'module %s;' % tb_name,
          '']
    if clocks:
        c = clocks[0]
        L += ['    // ---- 时钟 ----',
              '    reg %s = 1\'b0;                    // 初值必须给, 否则 ~X 仍为 X 无沿' % c.name,
              '    parameter CLK_PERIOD = %s;                 // 时钟周期 ns'
              % args.period,
              '    always #(CLK_PERIOD/2.0) %s = ~%s;' % (c.name, c.name),
              '']
    if resets:
        r = resets[0]
        active_low = ('rstn' in r.name.lower()) or ('rst_n' in r.name.lower())
        L += ['    // ---- 复位 (%s) ----'
              % ('低有效' if active_low else '高有效'),
              '    reg %s;' % r.name,
              '']
    if plain_in:
        L += ['    // ---- DUT 输入激励 ----']
        for p in plain_in:
            L.append('    reg  %-*s %-*s;%s'
                     % (w_r, p.range_text(), w_n, p.name,
                        ('   // ' + p.comment) if p.comment else ''))
        L.append('')
    if outs:
        L += ['    // ---- DUT 输出观测 ----']
        for p in outs:
            kind = 'tri' if p.direction == 'inout' else 'wire'
            L.append('    %-4s %-*s %-*s;%s'
                     % (kind, w_r, p.range_text(), w_n, p.name,
                        ('   // ' + p.comment) if p.comment else ''))
        if inouts:
            L.append('    // 注: inout 端口按 tri 声明, 需自行控制三态驱动')
        L.append('')

    # ---- DUT 实例 ----
    L += ['    // ---- DUT 实例 ----',
          '    %s dut (' % mod.name]
    for i, p in enumerate(ports):
        comma = ',' if i < len(ports) - 1 else ''
        L.append('        .%-*s (%s)%s' % (w_n + 1, p.name + ' ', p.name, comma))
    L += ['    );', '']

    # ---- 复位流程 ----
    if resets:
        r = resets[0]
        active_low = ('rstn' in r.name.lower()) or ('rst_n' in r.name.lower())
        init_v = "1'b0" if active_low else "1'b1"
        rel_v = "1'b1" if active_low else "1'b0"
        L += ['    // ---- 复位流程 ----',
              '    initial begin',
              '        %s = %s;' % (r.name, init_v),
              '        repeat (5) @(posedge %s);' % (clocks[0].name
                                                       if clocks else 'clk'),
              '        %s = %s;' % (r.name, rel_v),
              '    end',
              '']

    L += ['    // ---- 波形转储 ----',
          '    initial begin',
          '        $dumpfile("%s.vcd");' % tb_name,
          '        $dumpvars(0, %s);' % tb_name,
          '    end',
          '',
          '    // ---- 激励与自检 (TODO: 手动补充) ----',
          '    initial begin',
          '        // 示例: 喂入向量 → @(posedge clk) → if (out !== expected) $error;'
          if (plain_in or outs) else
          '        // TODO: 测试激励',
          '        repeat (100) @(posedge %s);' % (clocks[0].name
                                                    if clocks else 'clk'),
          '        $display("[%t] %m 仿真结束", $time);',
          '        $finish;',
          '    end',
          '',
          'endmodule']

    text = '\n'.join(L) + '\n'
    if args.output:
        with open(args.output, 'w', encoding='utf-8') as f:
            f.write(text)
        print('已写入 %s' % args.output)
    else:
        print(text)
    return 0


# ----------------------------------------------------------------------------
# 子命令: gen
# ----------------------------------------------------------------------------

# INST: <文件>.v [实例名] [.端口=连线 ...]
#   实例名/内联重连必须与文件名同行 (不跨行, 防止吃到下一行的 endmodule 等)
#   内联重连示例: // INST: usb_crc16.v u_crc  .crc_en=bit_valid .d_in=d_out
INST_RE = re.compile(r'//\s*INST\s*:\s*([^\s]+\.(?:v|sv))(?P<tail>[^\n]*)',
                     re.IGNORECASE)


def _parse_inst_tail(tail):
    """INST 行尾部 → (实例名或 None, [(端口, 连接表达式), ...])."""
    tail = tail.strip()
    name = None
    m = re.match(r'([a-zA-Z_]\w*)(?:\s+|$)', tail)
    if m:
        name = m.group(1)
        tail = tail[m.end():]
    overrides = re.findall(r'\.\s*([a-zA-Z_]\w*)\s*=\s*([^\s,]+)', tail)
    return name, overrides


# --inplace 生成的块用标记包裹, 下次 gen 可整段再生成 (verilog-mode
# AUTOINST 式的幂等展开): 
#   //<<< rtl_autogen:begin <ref> <实例名> [.端口=连线 ...]
#   ...生成代码...
#   //>>> rtl_autogen:end
MARK_BEGIN_RE = re.compile(r'^[ \t]*//\s*<<<\s*rtl_autogen:begin\s+([^\n]*)$',
                           re.MULTILINE | re.IGNORECASE)
MARK_END_RE = re.compile(r'^[ \t]*//\s*>>>\s*rtl_autogen:end[ \t]*$',
                         re.MULTILINE | re.IGNORECASE)


def _resolve_module_file(ref, top_path, extra_dirs):
    """按 顶层目录 → CWD → 附加目录(-I) 顺序解析被引用文件路径."""
    cands = [os.path.join(os.path.dirname(os.path.abspath(top_path)), ref),
             ref] + [os.path.join(d, ref) for d in extra_dirs]
    for c in cands:
        if os.path.isfile(c):
            return c
    return None


def cmd_gen(args):
    with open(args.top, 'r', encoding='utf-8', errors='replace') as f:
        raw = f.read()
    mods = parse_file(args.top)
    top = mods[0] if mods else None
    top_ports = {p.name: p for p in top.ports} if top else {}
    # 标记区域内的信号声明是上次 gen 生成的 (不是手写), 排除出去,
    # 再生成时会重新产出, 否则声明会逐次丢失
    marker_lines = set()
    for bm in MARK_BEGIN_RE.finditer(raw):
        em = MARK_END_RE.search(raw, bm.end())
        if em:
            marker_lines.update(
                range(raw[:bm.start()].count('\n'),
                      raw[:em.end()].count('\n') + 1))
    top_sigs = {s.name for s in top.signals
                if (s.line - 1) not in marker_lines} if top else set()
    taken = set(top_ports) | top_sigs

    refs = list(INST_RE.finditer(raw))
    # gen 条目 = INST 注释 + (inplace 时) 已有标记区块
    entries = [('inst', m, None, m.group('tail')) for m in refs]
    if args.inplace:
        for bm in MARK_BEGIN_RE.finditer(raw):
            em = MARK_END_RE.search(raw, bm.end())
            if not em:
                print('警告: begin 标记缺配对的 end, 已忽略: %s'
                      % bm.group(1)[:60], file=sys.stderr)
                continue
            entries.append(('marker', bm, em, bm.group(1)))
    if not entries:
        print('错误: %s 中未找到 "// INST: <file>.v [实例名]" 注释' % args.top,
              file=sys.stderr)
        return 1

    out_blocks = []          # 条目结果 dict 列表
    gen_wires = {}           # 网络名 -> 位宽原文 (生成的连线)
    inst_inputs = []         # (实例名, 端口名, 网络名)
    undriven = []            # 无来源的输入连接
    top_out_connected = set()  # 已被实例输出直连的顶层 output 端口
    errors = 0

    for kind, bm, em, tail in entries:
        if kind == 'inst':
            ref = bm.group(1)
            inst_name, ovr_list = _parse_inst_tail(tail)
        else:
            t = tail.strip()
            fm = re.match(r'(\S+)', t)
            if not fm:
                continue
            ref = fm.group(1)
            inst_name, ovr_list = _parse_inst_tail(t[fm.end():])
        overrides = dict(ovr_list)
        sub_path = _resolve_module_file(ref, args.top, args.include)
        if not sub_path:
            print('错误: INST 引用的文件找不到: %s' % ref, file=sys.stderr)
            errors += 1
            continue
        sub_mods = parse_file(sub_path)
        if not sub_mods:
            print('错误: %s 中未找到 module' % sub_path, file=sys.stderr)
            errors += 1
            continue
        sub = sub_mods[0]
        inst = inst_name or ('u_%s' % sub.name)
        if inst in [b['inst'] for b in out_blocks]:
            print('错误: 实例名重复: %s (同名 INST 注释与生成标记并存?'
                  ' 删掉其一)' % inst, file=sys.stderr)
            errors += 1
            continue

        wire_decls, conns = [], []
        w_p = max([len(p.name) for p in sub.ports] + [1])
        for p in sub.ports:
            ovr = overrides.get(p.name)
            if p.direction == 'input':
                if ovr is not None:
                    net = ovr                 # 内联重连: 用户显式指定, 免查来源
                else:
                    # 输入: 优先连到已有同名网络 (顶层端口/手写信号/已生成连线)
                    net = p.name
                    if p.name not in top_ports and p.name not in top_sigs \
                            and p.name not in gen_wires:
                        undriven.append('%s.%s → %s  (无来源, 需驱动、'
                                        '手写同名信号或行内 .%s=xxx 重连)'
                                        % (inst, p.name, net, p.name))
                inst_inputs.append((inst, p.name, net))
            else:
                if ovr is not None:
                    net = ovr
                    if net in top_ports and top_ports[net].direction != 'input':
                        top_out_connected.add(net)
                elif p.name in top_ports and \
                        top_ports[p.name].direction != 'input':
                    # 输出: 顶层同名 output 端口直接对接
                    net = p.name
                    top_out_connected.add(net)
                elif p.name in top_sigs:
                    net = p.name
                else:
                    # 新建 wire; 名字被占 → <实例名>_<端口名>
                    net = p.name if p.name not in taken else \
                        '%s_%s' % (inst, p.name)
                    gen_wires[net] = p.range_text()
                    taken.add(net)
                    note = ('   // %s.%s 输出' % (inst, p.name)) \
                        if args.comments else ''
                    wire_decls.append('wire %s%s;%s' % (
                        (p.range_text() + ' ') if p.range_text() else '',
                        net, note))
            conns.append((p, net))

        conn_lines = []
        for i, (p, net) in enumerate(conns):
            comma = ',' if i < len(conns) - 1 else ''
            cmt = ''
            if args.comments:
                c0 = p.comment.split('\n')[0] if p.comment else ''
                cmt = ('   // ' + c0) if c0 else ''
            conn_lines.append('    .%-*s (%s)%s%s' % (
                w_p + 1, p.name + ' ', net, comma, cmt))
        head = '%s ' % sub.name
        if sub.params:
            head += '#(\n' + ',\n'.join(
                '    .%-10s (%s)' % (k, v)
                for k, v in sub.params.items()) + '\n) '
        head += '%s (' % inst
        block = head + '\n' + '\n'.join(conn_lines) + '\n);'
        if wire_decls:
            block = '\n'.join(wire_decls) + '\n\n' + block
        out_blocks.append({
            'kind': kind, 'begin': bm, 'end': em, 'inst': inst,
            'block': block, 'ref': ref, 'inst_name': inst or inst_name,
            'overrides': overrides,
            'lineno': raw[:bm.start()].count('\n') + 1})

    # ---- 连通性检查 ----
    checks = []
    for u in undriven:
        checks.append('[未驱动] %s' % u)
    consumed = {net for _, _, net in inst_inputs}
    for net, rng in gen_wires.items():
        if net not in consumed and net not in top_ports:
            checks.append('[未使用] wire %s%s — 无任何实例输入/顶层端口消费'
                          % ((rng + ' ') if rng else '', net))
    if top:
        for tp in top.ports:
            if tp.direction == 'input' and tp.name not in consumed:
                checks.append('[未使用] input %s — 顶层输入未连到任何实例'
                              % tp.name)
            if tp.direction in ('output', 'inout') and \
                    tp.name not in top_out_connected:
                checks.append('[未驱动] %s %s — 顶层输出未由任何实例输出驱动'
                              % (tp.direction, tp.name))

    # ---- 输出 ----
    def indent_block(block, ind):
        return '\n'.join((ind + bl) if bl else '' for bl in block.split('\n'))

    if args.inplace:
        body_lines = raw.split('\n')

        def marker_lines(b, ind):
            """一个实例的标记包裹生成块."""
            ovr = ' '.join('.%s=%s' % (k, v)
                           for k, v in b['overrides'].items())
            head = '%s %s' % (b['ref'], b['inst'])
            if ovr:
                head += ' ' + ovr
            out = ['%s//<<< rtl_autogen:begin %s' % (ind, head)]
            out += indent_block(b['block'], ind).split('\n')
            out.append('%s//>>> rtl_autogen:end' % ind)
            return out

        # 倒序回写, 行号不失效:
        #   inst 条目  → INST 注释行替换为标记包裹块
        #   marker 条目→ begin..end 整段替换为再生成的标记块
        regions = []
        for b in out_blocks:
            li1 = b['lineno'] - 1
            li2 = li1 if b['kind'] == 'inst' \
                else raw[:b['end'].start()].count('\n')
            regions.append((li1, li2, b))
        for li1, li2, b in sorted(regions, key=lambda r: -r[0]):
            ind = re.match(r'[ \t]*', body_lines[li1]).group(0)
            body_lines[li1:li2 + 1] = marker_lines(b, ind)
        with open(args.top + '.bak', 'w', encoding='utf-8') as f:
            f.write(raw)
        with open(args.top, 'w', encoding='utf-8') as f:
            f.write('\n'.join(body_lines))
        n_new = sum(1 for b in out_blocks if b['kind'] == 'inst')
        n_regen = len(out_blocks) - n_new
        msg = '已回写 %s (' % args.top
        if n_new:
            msg += '%d 处 INST 新展开' % n_new
        if n_regen:
            msg += '%s%d 处标记再生成' % (' + ' if n_new else '', n_regen)
        msg += ', 原文件备份为 %s.bak)' % args.top
        print(msg)
    else:
        lines = ['//============================================',
                 '// 由 rtl_autogen.py gen 生成 — 顶层: %s' % args.top,
                 '// %d 个实例, %d 条自动连线' % (len(out_blocks),
                                                len(gen_wires)),
                 '//============================================']
        for b in out_blocks:
            lines += ['',
                      '//---- 实例 %s  (INST 注释在第 %d 行) ----'
                      % (b['inst'], b['lineno']),
                      indent_block(b['block'], '    ')]
        text = '\n'.join(lines) + '\n'
        if args.output:
            with open(args.output, 'w', encoding='utf-8') as f:
                f.write(text)
            print('已写入 %s' % args.output)
        else:
            print(text)

    if checks and not args.no_check:
        print()
        print('//================ 连通性检查 ================')
        for line in checks:
            print('// ' + line)
    return 1 if errors else 0


# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(
        prog='rtl_autogen.py',
        description='Verilog RTL 自动化: 端口解析 / lint / 层次树 / 测试台生成 / 顶层实例化生成',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
文件参数可以是目录 (递归收集 *.v / *.sv), 也可用 -f design.f 读取
工业界 filelist (支持 # 注释 / +incdir+ / 嵌套 -f)。

lint 检查项 (参考 Verilator/verible 规则):
  [未驱动]/[未使用]/[未驱动且未使用]  信号与端口的驱动/使用分析
  [未声明]   未声明标识符 — 隐式 1bit 网线或拼写错误 (default_nettype 隐患)
  [多驱动]   同一信号被 多个 always 块 / assign+always / 多实例输出 驱动
  [锁存器?]  组合 always 有 if 无 else / 有 case 无 default
  [风格]     --style 时: 模块名与文件名不一致 / 超 100 列 / Tab 缩进 (不计退出码)

INST 注释约定 (写在顶层模块体内, 按依赖顺序):
  // INST: ../../src/common/usb_crc5.v                 实例名默认 u_<模块名>
  // INST: ../../src/common/usb_crc16.v  u_crc16_chk   显式指定实例名
  // INST: usb_bit_stuff.v  u_stuff  .d_in=nrzi_bit .d_valid=bit_en
                                                      行内 .端口=连线 显式重连
                                                      (也接受常量, 如 .crc_en=1'b1)
gen --inplace 展开的块由 //<<< rtl_autogen:begin ... //>>> rtl_autogen:end
标记包裹, 修改子模块端口后重跑 gen --inplace 即可整段再生成 (幂等)。

示例:
  rtl_autogen.py ports src/common/usb_crc5.v
  rtl_autogen.py ports src/ --json                     目录递归
  rtl_autogen.py ports src/common/usb_crc5.v --md      Markdown 表格 (贴文档)
  rtl_autogen.py lint  src/ --all                      全工程检查
  rtl_autogen.py lint  src/ --style                    加风格检查
  rtl_autogen.py lint  -f sim/filelist.f               读 filelist
  rtl_autogen.py tree  src/                            层次树 + 端口连接核对
  rtl_autogen.py tb    src/common/usb_crc5.v -o sim/crc5/tb_auto.v
  rtl_autogen.py gen   rtl/top_skeleton.v --inplace    原地回写(标记包裹, 可再生成)
''')
    ap.add_argument('--version', action='version', version='%(prog)s 2.1')
    sub = ap.add_subparsers(dest='cmd', required=True)

    p1 = sub.add_parser('ports', help='解析 module 端口列表')
    p1.add_argument('files', nargs='*', help='Verilog 文件或目录 (或用 -f)')
    p1.add_argument('--json', action='store_true', help='JSON 输出')
    p1.add_argument('--md', action='store_true', help='Markdown 表格输出')
    p1.add_argument('-f', '--filelist', action='append', default=[],
                    help='.f 文件列表 (可多次)')
    p1.set_defaults(func=cmd_ports)

    p2 = sub.add_parser('lint', help='wire/reg 定义 + 未驱动/未使用/未声明/多驱动检查')
    p2.add_argument('files', nargs='*', help='Verilog 文件或目录 (或用 -f)')
    p2.add_argument('--all', action='store_true', help='同时列出全部信号定义')
    p2.add_argument('--json', action='store_true', help='JSON 输出')
    p2.add_argument('--style', action='store_true',
                    help='附加风格检查 (不计入退出码)')
    p2.add_argument('-f', '--filelist', action='append', default=[],
                    help='.f 文件列表 (可多次)')
    p2.set_defaults(func=cmd_lint)

    p2b = sub.add_parser('tree', help='模块层次树 + 实例端口连接核对')
    p2b.add_argument('files', nargs='*', help='Verilog 文件或目录 (或用 -f)')
    p2b.add_argument('--no-check', action='store_true',
                     help='只画树, 不做端口连接核对')
    p2b.add_argument('-f', '--filelist', action='append', default=[],
                     help='.f 文件列表 (可多次)')
    p2b.set_defaults(func=cmd_tree)

    p2c = sub.add_parser('tb', help='按 DUT 端口生成测试台骨架')
    p2c.add_argument('dut', help='DUT 文件 (取其中第一个 module)')
    p2c.add_argument('-m', '--module', help='指定 module 名 (多模块文件)')
    p2c.add_argument('-o', '--output', help='输出文件 (缺省打印到终端)')
    p2c.add_argument('-n', '--name', help='测试台模块名 (默认 tb_<DUT名>)')
    p2c.add_argument('--period', default='10.0',
                     help='时钟周期 ns (默认 10.0)')
    p2c.set_defaults(func=cmd_tb)

    p3 = sub.add_parser('gen', help='按顶层 INST 注释生成实例化')
    p3.add_argument('top', help='顶层文件 (含 // INST: xxx.v 注释)')
    p3.add_argument('-o', '--output', help='输出文件 (缺省打印到终端)')
    p3.add_argument('--inplace', action='store_true',
                    help='把生成代码直接回写到顶层文件 (INST 注释处, 原文件备份 .bak)')
    p3.add_argument('-I', '--include', action='append', default=[],
                    help='子模块搜索目录 (可多次)')
    p3.add_argument('--no-comments', dest='comments', action='store_false',
                    default=True, help='生成代码中不带注释')
    p3.add_argument('--no-check', action='store_true',
                    help='跳过连通性检查报告')
    p3.set_defaults(func=cmd_gen)

    args = ap.parse_args(argv)
    if getattr(args, 'inplace', False) and getattr(args, 'output', None):
        ap.error('--inplace 与 -o 不能同时使用')
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())
