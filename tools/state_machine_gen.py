#!/usr/bin/env python3
#============================================================================
# state_machine_gen.py — 状态机图生成器
# State machine diagram generator
#
# 基于 Graphviz dot（二进制），无 Python 第三方依赖（subprocess 调用 dot）。
# 用于设计报告生成美观的状态机跳转图。
#
# 用法 / Usage:
#   from state_machine_gen import FSM
#   fsm = FSM(title="DPLL 状态机", init="C")
#   fsm.state("C", label="C")
#   fsm.edge("C", "D", "b=0")
#   fsm.cluster("左环", ["1","3","2","0"])
#   fsm.render("dpll")          # -> doc/fig/dpll.png (+ .dot)
#
# 依赖 / Dependency: graphviz (brew install graphviz)
#============================================================================

import os
import subprocess

__all__ = ["FSM"]


def _esc(s):
    """转义 dot 字符串 / escape a string for dot."""
    return str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


class FSM:
    """状态机图构建器 / state machine diagram builder."""

    def __init__(self, title="", init=None, rankdir="TB"):
        self.title = title
        self.init = init                  # 初始态（双圈）/ initial state (double circle)
        self.rankdir = rankdir            # TB / LR
        self.states = {}                  # name -> (label, attrs)
        self.edges = []                   # (from, to, label, attrs)
        self.clusters = []                # (name, [states], attrs)
        self.ranks = []                   # 同行约束 / same-rank groups

    # ---- 构建 API / building API ----
    def state(self, name, label=None, **attrs):
        """加一个状态 / add a state. attrs 直接传给 dot（fillcolor 等）。"""
        self.states[name] = (label if label is not None else name, attrs)
        return self

    def edge(self, src, dst, label="", **attrs):
        """加一条跳转 / add a transition. label 为条件。"""
        self.edges.append((src, dst, label, attrs))
        return self

    def cluster(self, name, states, **attrs):
        """把若干状态分组（虚线框）/ group states into a cluster."""
        self.clusters.append((name, states, attrs))
        return self

    def rank(self, *states):
        """把这些状态放在同一行 / force states onto the same rank."""
        self.ranks.append(list(states))
        return self

    # ---- 生成 dot 源码 / generate dot source ----
    def to_dot(self):
        L = []
        L.append("digraph FSM {")
        L.append('  graph [labelloc="t", labeljust="c", '
                 'fontname="Helvetica", fontsize=13];')
        if self.title:
            L.append(f'  label="{_esc(self.title)}";')
        L.append(f'  rankdir={self.rankdir};')
        # 默认节点/边样式 / default node & edge style
        L.append('  node [shape=box, style="rounded,filled", '
                 'fontname="Helvetica", fontsize=11, fillcolor="#EEF2F7", '
                 'color="#444444", penwidth=1.2, margin="0.15,0.06"];')
        L.append('  edge [fontname="Helvetica", fontsize=10, '
                 'color="#555555", arrowsize=0.8];')

        # 已归组状态 / clustered states
        grouped = set()
        for ci, (cname, cstates, cattrs) in enumerate(self.clusters):
            # subgraph 标识符只能用安全字符 / safe id for subgraph
            cid = "".join(ch for ch in cname if ch.isalnum() or ch == "_") or "c"
            L.append(f'  subgraph cluster_{ci}_{_esc(cid)} {{')
            L.append(f'    label="{_esc(cname)}";')
            L.append('    style="rounded,dashed"; color="#999999"; penwidth=1;')
            for k, v in cattrs.items():
                L.append(f'    {k}="{_esc(v)}";')
            for s in cstates:
                grouped.add(s)
                self._emit_state(L, s)
            L.append("  }")

        # 未归组状态 / standalone states
        for name in self.states:
            if name not in grouped:
                self._emit_state(L, name)

        # 同行约束 / same-rank groups
        for grp in self.ranks:
            names = "; ".join(f'"{_esc(s)}"' for s in grp)
            L.append(f"  {{ rank=same; {names}; }}")

        # 跳转 / transitions
        for (src, dst, label, attrs) in self.edges:
            parts = []
            if label:
                parts.append(f'label="{_esc(label)}"')
            for k, v in attrs.items():
                parts.append(f'{k}="{_esc(v)}"')
            tail = ""
            if parts:
                tail = " [" + ", ".join(parts) + "]"
            L.append(f'  "{_esc(src)}" -> "{_esc(dst)}"{tail};')

        L.append("}")
        return "\n".join(L) + "\n"

    def _emit_state(self, L, name):
        label, attrs = self.states[name]
        a = dict(attrs)
        # 这里放原文，转义统一由下面的 f-string 做一次（label 里可以有 \n 换行）
        a.setdefault("label", label)
        if name == self.init:
            a["peripheries"] = "2"       # 双圈 = 初始态 / double circle
        parts = [f'"{_esc(name)}"']
        if a:
            parts.append("[" + ", ".join(f'{k}="{_esc(v)}"' for k, v in a.items()) + "]")
        L.append("  " + " ".join(parts) + ";")

    # ---- 渲染 / render ----
    def save_dot(self, path):
        with open(path, "w") as f:
            f.write(self.to_dot())
        return path

    def render(self, name, outdir="doc/fig", fmt="png"):
        """生成 .dot 与图片 / write .dot and render image."""
        os.makedirs(outdir, exist_ok=True)
        dotpath = os.path.join(outdir, name + ".dot")
        imgpath = os.path.join(outdir, name + "." + fmt)
        self.save_dot(dotpath)
        r = subprocess.run(["dot", f"-T{fmt}", dotpath, "-o", imgpath],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"dot render failed:\n{r.stderr}")
        print(f"  -> {imgpath}")
        return imgpath


if __name__ == "__main__":
    # 简单自测 / self-test: 画一个示例状态机
    fsm = FSM(title="示例状态机 / Example FSM", init="IDLE")
    fsm.state("IDLE", fillcolor="#FFF3CD")
    fsm.state("RUN", fillcolor="#D6F5D6")
    fsm.state("DONE", fillcolor="#D6E4F5")
    fsm.edge("IDLE", "RUN", "start")
    fsm.edge("RUN", "RUN", "busy")
    fsm.edge("RUN", "DONE", "finish")
    fsm.edge("DONE", "IDLE", "reset")
    fsm.render("_example")
    print("self-test OK")
