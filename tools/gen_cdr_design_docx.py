#!/usr/bin/env python3
"""
gen_cdr_design_docx.py — 从 CDR 设计内容生成 Word 版设计报告 (doc/CDR设计报告.docx)

内容与 doc/02_cdr_design.md 保持一致，按「模块设计报告编写规范」4 节结构组织，
并内嵌 doc/fig/ 下的状态机图 + 4 张波形截图。

用法:
    cd <项目根目录>
    python3 tools/gen_cdr_design_docx.py
"""

import os
import re

from docx import Document
from docx.shared import Pt, Inches, RGBColor
from docx.oxml import OxmlElement
from docx.oxml.ns import qn

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIG = os.path.join(ROOT, "doc", "fig")
OUT = os.path.join(ROOT, "doc", "CDR设计报告.docx")

BODY_FONT = "宋体"
MONO_FONT = "Consolas"
BODY_SIZE = 10.5
CODE_SIZE = 9.5
CODE_BG = "F2F2F2"


def set_run(run, size=BODY_SIZE, bold=False, mono=False, color=None):
    run.font.name = MONO_FONT if mono else BODY_FONT
    run.font.size = Pt(size)
    run.bold = bold
    if color:
        run.font.color.rgb = RGBColor.from_string(color)
    rPr = run._element.get_or_add_rPr()
    rFonts = rPr.find(qn("w:rFonts"))
    if rFonts is None:
        rFonts = OxmlElement("w:rFonts")
        rPr.append(rFonts)
    if mono:
        rFonts.set(qn("w:ascii"), MONO_FONT)
        rFonts.set(qn("w:hAnsi"), MONO_FONT)
    rFonts.set(qn("w:eastAsia"), BODY_FONT)


def add_rich(p, text, size=BODY_SIZE, bold=False, color=None):
    for tok in re.split(r"(\*\*.*?\*\*|`[^`]*`)", text):
        if not tok:
            continue
        if tok.startswith("**") and tok.endswith("**"):
            set_run(p.add_run(tok[2:-2]), size=size, bold=True, color=color)
        elif tok.startswith("`") and tok.endswith("`"):
            set_run(p.add_run(tok[1:-1]), size=size, mono=True, color=color)
        else:
            set_run(p.add_run(tok), size=size, bold=bold, color=color)


def add_para(doc, text="", size=BODY_SIZE, bold=False, space_after=4, indent=None, color=None):
    p = doc.add_paragraph()
    p.paragraph_format.space_after = Pt(space_after)
    if indent:
        p.paragraph_format.left_indent = Pt(indent)
    add_rich(p, text, size=size, bold=bold, color=color)
    return p


def add_heading(doc, text, level=1):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(12 if level == 1 else 8)
    p.paragraph_format.space_after = Pt(6)
    sizes = {1: 16, 2: 13, 3: 11.5}
    set_run(p.add_run(text), size=sizes.get(level, 11), bold=True,
            color={1: "1F3864", 2: "2E5395", 3: "404040"}.get(level))
    return p


def add_code_block(doc, text):
    p = doc.add_paragraph()
    p.paragraph_format.space_after = Pt(6)
    p.paragraph_format.left_indent = Pt(12)
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:fill"), CODE_BG)
    p._p.get_or_add_pPr().append(shd)
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if i:
            p.add_run().add_break()
        set_run(p.add_run(line), size=CODE_SIZE, mono=True)
    return p


def add_table(doc, header, rows, widths=None):
    t = doc.add_table(rows=1, cols=len(header))
    t.style = "Table Grid"
    hdr = t.rows[0].cells
    for i, h in enumerate(header):
        hdr[i].text = ""
        set_run(hdr[i].paragraphs[0].add_run(h), size=BODY_SIZE, bold=True)
        shd = OxmlElement("w:shd")
        shd.set(qn("w:val"), "clear")
        shd.set(qn("w:fill"), "DEEAF6")
        hdr[i]._tc.get_or_add_tcPr().append(shd)
    for row in rows:
        cells = t.add_row().cells
        for i, c in enumerate(row):
            cells[i].text = ""
            add_rich(cells[i].paragraphs[0], c, size=BODY_SIZE)
    if widths:
        for i, w in enumerate(widths):
            for row in t.rows:
                row.cells[i].width = Inches(w)
    doc.add_paragraph().paragraph_format.space_after = Pt(2)
    return t


def add_fig(doc, path, caption, width=6.3):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(4)
    p.paragraph_format.space_after = Pt(2)
    p.alignment = 1
    p.add_run().add_picture(os.path.join(FIG, path), width=Inches(width))
    cap = doc.add_paragraph()
    cap.paragraph_format.space_after = Pt(8)
    cap.alignment = 1
    set_run(cap.add_run(caption), size=9, color="595959")


def main():
    doc = Document()
    for s in doc.sections:
        s.left_margin = Inches(0.9)
        s.right_margin = Inches(0.9)
        s.top_margin = Inches(0.8)
        s.bottom_margin = Inches(0.8)

    normal = doc.styles["Normal"]
    normal.font.name = BODY_FONT
    normal.font.size = Pt(BODY_SIZE)
    normal.element.rPr.rFonts.set(qn("w:eastAsia"), BODY_FONT)

    # ===== 标题 =====
    title = doc.add_paragraph()
    title.alignment = 1
    set_run(title.add_run("CDR 模块设计报告"), size=20, bold=True, color="1F3864")
    sub = doc.add_paragraph()
    sub.alignment = 1
    set_run(sub.add_run("usb_rx_cdr — 时钟数据恢复（Intel SIE DPLL）"), size=12, bold=True)
    meta = doc.add_paragraph()
    meta.alignment = 1
    meta.paragraph_format.space_after = Pt(12)
    set_run(meta.add_run("源码：src/phy/usb_rx_cdr.v   参考：Intel SIE 白皮书   验证：sim/cdr/"),
            size=9.5, color="595959")

    # ===== 1. 模块介绍 =====
    add_heading(doc, "1. 模块介绍", 1)
    add_para(doc, "`usb_rx_cdr` 是 USB 1.1 数字收发器（`usb_dpll_phy`）中最贴近物理线的第一个子模块，"
                  "位于 `ref_clk`(48MHz) 时钟域，负责从 D+/D- 差分线**同时恢复出**两样东西：")
    add_para(doc, "**数据位流** `d_out`：NRZI 电平（state[2]，K=0 / J=1）；", indent=12)
    add_para(doc, "**位时钟** `clk_12m`：12MHz 恢复时钟。", indent=12)
    add_para(doc, "它只做“从边沿里抠出时钟和数据”这一件事，不识别 SYNC、不做 NRZI 解码、不解位填充"
                  "（这些属于下游 `usb_rx_deserial`）。")
    add_table(doc, ["属性", "说明"],
              [["工作频率", "ref_clk = 48MHz，Full-Speed 位率 12MHz → 4× 过采样（每 bit = 4 ref_clk）"],
               ["核心思想", "Intel SIE 16 态 DPLL 数字锁相环：状态机模拟锁相环，从数据跳变中提取相位/频率"],
               ["无派生时钟", "恢复时钟用状态位（state[1]）经寄存器打一拍输出，可综合、无 STA 问题"]],
              widths=[1.3, 5.0])

    # ===== 2. 设计理论和原理及方法 =====
    add_heading(doc, "2. 模块设计理论和原理及方法", 1)

    add_heading(doc, "2.1 设计动机：为什么需要 CDR", 2)
    add_para(doc, "USB 是**异步串行**总线：主机与设备的 12MHz 晶振相互独立，容差各 ±0.25%，接收端没有"
                  "发送端时钟，必须从数据流里**逐位恢复**数据位和位时钟。NRZI + 位填充规则（数据 0 翻转电平、"
                  "数据 1 保持电平，连续 6 个 1 后强制插 0）保证线上**无跳变最长只有 6 bit**，使自由运行相位误差"
                  "有界（6 × 0.25% × 4 ≈ 0.06 ref_clk），CDR 才能稳定工作——这是整个设计的前提。")

    add_heading(doc, "2.2 4× 过采样", 2)
    add_para(doc, "`ref_clk = 48MHz = 12MHz × 4`，一个位周期内 4 个采样点，位边界分辨率 = 1/4 bit。"
                  "过采样的本质是用更多采样点换取更细的相位量化。")

    add_heading(doc, "2.3 a/b 双沿采样（等效 8×）", 2)
    add_code_block(doc,
        "diff = rxdp ^ rxdn\n"
        "       ┌──► [D] posedge ──► a   （48MHz 上升沿采样）\n"
        "diff ──┤\n"
        "       └──► [D] negedge ──► b   （48MHz 下降沿采样）")
    add_para(doc, "一个 ref_clk 内得 a、b 两个采样，一个 bit（4 ref_clk）内共 8 个采样点 = 等效 8× 过采样。"
                  "位边界检测分辨率达 1/8 bit，能精确判断跳变落点相位从而决定频率调整方向。状态机在 48MHz 上升沿"
                  "运行，同时读 `a`（本拍）和 `b`（上一拍已锁存）。")

    add_heading(doc, "2.4 DPLL 状态机（16 态）", 2)
    add_para(doc, "状态编码采用**位编码**，4-bit 状态里直接嵌入了要恢复的信息：")
    add_table(doc, ["状态位", "含义"],
              [["state[1]", "恢复时钟（0=低，1=高）"],
               ["state[2]", "NRZI 数据电平（0=K，1=J）"]],
              widths=[1.3, 5.0])
    add_fig(doc, "dpll_state_machine.png", "图 1 DPLL 状态机（tools/gen_fsm_diagrams.py 生成）")
    add_table(doc, ["状态", "恢复时钟", "所属", "说明"],
              [["1,3,2,0", "外低内高", "左环·数据0", "数据 0 位周期；内两态(3,2)=clk高，外两态(1,0)=clk低"],
               ["5,7,6,4", "外低内高", "右环·数据1", "数据 1 位周期；内两态(7,6)=clk高，外两态(5,4)=clk低"],
               ["C(12)", "—", "锁存", "初始/未锁定态"],
               ["D(13)", "—", "锁存", "预锁态（检测到第 1 个边沿）"],
               ["F(15),B(11)", "—", "长bit绕行", "位宽偏长时多耗一拍"]],
              widths=[1.2, 1.0, 1.0, 3.1])
    add_para(doc, "**状态跳转表**：")
    add_table(doc, ["当前", "条件", "下一", "说明"],
              [["C", "b≠0", "C", "等待首个边沿"],
               ["C", "b=0", "D", "检测到数据 0"],
               ["D", "b=0", "D", "等待第二个边沿"],
               ["D", "b=1", "5", "锁定，进右环"],
               ["1", "无条件", "3", "左环前进"],
               ["3", "a=0", "2", "左环前进"],
               ["3", "a=1", "F", "长 bit 绕行"],
               ["2", "b=0", "0", "左环前进"],
               ["2", "b=1", "5", "短 bit/边沿，切右环"],
               ["0", "b=0", "1", "左环回环"],
               ["0", "b=1", "5", "边沿，切右环"],
               ["5", "无条件", "7", "右环前进"],
               ["7", "a=1", "6", "右环前进"],
               ["7", "a=0", "B", "长 bit 绕行"],
               ["6", "b=1", "4", "右环前进"],
               ["6", "b=0", "1", "边沿，切左环"],
               ["4", "b=1", "5", "右环回环"],
               ["4", "b=0", "1", "边沿，切左环"],
               ["F", "无条件", "6", "长 bit 绕行结束"],
               ["B", "无条件", "2", "长 bit 绕行结束"],
               ["（默认）", "—", "C", "兜底，回锁存态"]],
              widths=[0.9, 0.9, 0.7, 2.6])

    add_heading(doc, "2.5 NRZI 规则与跳变检测", 2)
    add_para(doc, "状态机每条环 4 态 = 1 bit，核心是**在位边界判决态用 a/b 检测边界处电平是否跳变**："
                  "数据 0 在位起点翻转电平（有跳变），数据 1 保持电平（无跳变）。因此边界有跳变 → 新 bit 是 0"
                  "（进/留左环），无跳变 → 新 bit 是 1（进/留右环）。状态机在环尾判决态采样 a/b 判断跳变并切环/"
                  "绕行；跳变出现相位反映主机位率，驱动频率自适应。")

    add_heading(doc, "2.6 频率自适应", 2)
    add_table(doc, ["主机位率", "跳变出现相位", "状态机行为", "恢复时钟"],
              [["与标称同步", "状态 0/4", "正常切环", "不变"],
               ["偏快（短 bit）", "提前到状态 2/6", "从 2/6 直接切环", "低电平缩短 1 个 4× 周期"],
               ["偏慢（长 bit）", "推迟", "从 3/7 经 F/B 绕行再切环", "高电平加 1 个 4× 周期"]],
              widths=[1.2, 1.4, 1.8, 1.9])

    add_heading(doc, "2.7 实现方法小结", 2)
    add_para(doc, "组合逻辑 `always @*` 的 `case(state)` 生成 `nxt_state`；时序逻辑在 `posedge ref_clk` 把 "
                  "`nxt_state` 打进 `state`；`state[1]` 打一拍去毛刺得 `clk_12m`；`state[2]` 组合输出 `d_out`。"
                  "全模块**单时钟、可综合**，无 `#`/`initial`/`$display`，复位回 idle J。")

    # ===== 3. 信号列表 =====
    add_heading(doc, "3. 模块信号列表", 1)
    add_heading(doc, "3.1 端口信号（对外接口）", 2)
    add_table(doc, ["端口", "方向", "位宽", "说明"],
              [["ref_clk", "in", "1", "48MHz 参考时钟"],
               ["ref_rstn", "in", "1", "异步复位，低有效（复位回 idle J）"],
               ["rxdp", "in", "1", "D+ 单端接收（J=1,K=0），a/b 双沿采样源"],
               ["rxdn", "in", "1", "D- 单端接收（SE0 检测用，本模块内未参与状态跳转）"],
               ["clk_12m", "out", "1", "恢复的 12MHz 位时钟（state[1] 打一拍，无毛刺）"],
               ["d_out", "out", "1", "NRZI 数据电平（= state[2]，0=K / 1=J）"]],
              widths=[1.1, 0.6, 0.5, 4.1])
    add_heading(doc, "3.2 内部关键信号", 2)
    add_table(doc, ["信号", "类型", "位宽", "说明"],
              [["a_reg", "reg", "1", "ref_clk 上升沿采样 rxdp，复位为 1（idle J）"],
               ["b_reg", "reg", "1", "ref_clk 下降沿采样 rxdp，复位为 1（idle J）"],
               ["state", "reg", "4", "DPLL 当前状态"],
               ["nxt_state", "reg", "4", "下一状态（组合逻辑结果）"],
               ["state_clk", "wire", "1", "= state[1]，恢复时钟原始位"],
               ["state_data", "wire", "1", "= state[2]，NRZI 电平"],
               ["nxt_clk", "wire", "1", "= nxt_state[1]（观测用，未参与逻辑）"],
               ["clk_12m_reg", "reg", "1", "state_clk 打一拍后的寄存器输出"]],
              widths=[1.3, 0.7, 0.5, 3.8])
    add_heading(doc, "3.3 状态编码常量（localparam）", 2)
    add_code_block(doc,
        "localparam ST_C = 4'd12;   // 锁存初始态\n"
        "localparam ST_D = 4'd13;   // 锁存预锁态\n"
        "localparam ST_F = 4'd15;   // 长 bit 绕行（J 侧）\n"
        "localparam ST_B = 4'd11;   // 长 bit 绕行（K 侧）")

    # ===== 4. 关键设计点 =====
    add_heading(doc, "4. 关键设计点描述及波形", 1)
    add_para(doc, "波形用 `tools/wave_debugger.py` 显示、`tools/render_waveform.py` 离屏导出。"
                  "信号名 `dut.state` 为 4-bit DPLL 状态（十六进制即状态编码）。", size=9.5, color="595959")

    add_heading(doc, "4.1 锁存过程（C→D→5）", 2)
    add_para(doc, "**问题**：上电/复位后状态机处于 C(12)，必须可靠地从 SYNC 的 `00000001` 识别出边沿并进入右环锁定。")
    add_para(doc, "**设计做法**：两段式锁存——C 态等 `b` 采样到第 1 个边沿（b=0）→ 进 D(13)；D 态等第 2 个边沿（b=1）"
                  "→ 进 5，正式锁定进入右环。不足 2 个边沿无法锁定（如 resume 信号）。")
    add_fig(doc, "cdr_lock.png",
            "图 2 锁存放大（cdr_case_nominal）：state 走 C(12)→D(13)→5，锁定进入右环")

    add_heading(doc, "4.2 左右环循环（数据 0 / 数据 1）", 2)
    add_para(doc, "**问题**：数据 0（K）与数据 1（J）在 NRZI 下分别对应“有跳变/无跳变”，状态机须用两个独立的 4 态环"
                  "分别跑这两种电平，并在位边界正确切环。")
    add_para(doc, "**设计做法**：左环 1→3→2→0 跑数据 0（K），右环 5→7→6→4 跑数据 1（J）。环尾判决态采样 a/b，"
                  "有跳变切左环、无跳变切右环。每环 4 态 = 1 bit = 4 ref_clk = 12MHz。")

    add_heading(doc, "4.3 长 bit → F/B 绕行", 2)
    add_para(doc, "**问题**：主机位率偏慢时某 bit 实际宽度拉长（>4 ref_clk），状态机若按 4 态跑完会提前切环、相位跑飞。")
    add_para(doc, "**设计做法**：环内第 3 态（左环 3、右环 7）判 a/b，若位边界未到就绕行到 F(15)（从 3）或 B(11)（从 7），"
                  "多耗 1 个 ref_clk 再回环，等效把该 bit 高电平拉长 1 个 4× 周期。")
    add_fig(doc, "cdr_f_detour.png",
            "图 3 F 绕行放大（cdr_case_long_bit_f）：state 走 3→F(15)→6→4，恢复时钟高电平比标称多 1 个 48MHz 周期")

    add_heading(doc, "4.4 频率自适应（短 bit / 长 bit）", 2)
    add_para(doc, "**问题**：同 4.3 反向——主机偏快时 bit 缩短（<4 ref_clk），状态机要“少等一拍”。")
    add_para(doc, "**设计做法**：跳变提前到环内第 2 态（2/6）时直接从 2→5（或 6→1）切环，跳过第 3、4 态，等效把低电平"
                  "缩短 1 个 4× 周期。与 4.3 合起来，恢复时钟频率双向跟随主机位率。")

    add_heading(doc, "4.5 恢复时钟去毛刺", 2)
    add_para(doc, "**问题**：`state[1]` 是状态寄存器原始位，切换瞬间组合路径可能产生毛刺。")
    add_para(doc, "**设计做法**：`state_clk` 再经一级触发器打一拍输出 `clk_12m_reg` 作为 `clk_12m`，与 ref_clk 对齐、"
                  "无毛刺。恢复时钟上升沿即下游采样数据的时机。")

    add_heading(doc, "4.6 数据提取", 2)
    add_para(doc, "**问题**：`d_out` 须在正确相位输出 NRZI 电平，并与 `clk_12m` 配对。")
    add_para(doc, "**设计做法**：直接取 `state[2]` 组合输出（左环=0/K，右环=1/J）。状态编码里 bit2 恰好编码了当前数据"
                  "电平所属的环，无需额外解码。数据位在 `clk_12m` 上升沿采样有效。")

    add_heading(doc, "4.7 端到端恢复质量（引用验证）", 2)
    add_para(doc, "综合以上各点，CDR 最终要能连续、正确恢复整包数据。验证报告已用**端到端回环**严格证明：用恢复的 "
                  "`clk_12m` + `d_out` 还原出发送包数据位，逐 bit 对比 **122 数据位 0 差异**。")
    add_fig(doc, "cdr_wave_overview.png",
            "图 4 完整 OUT Token 总览（cdr_case_nominal）：rxdp/rxdn、clk_12m、d_out 三者同步对齐")
    add_fig(doc, "cdr_multi_pkt.png",
            "图 5 多包事务（cdr_case_multi_pkt）：SETUP + DATA0 + ACK，clk_12m 持续恢复 12MHz，d_out 跨包跟踪")
    add_para(doc, "详细验证见 **CDR 模块验证报告**（8 个用例全通过，含端到端回环）。", size=9.5, color="595959")

    doc.save(OUT)
    print(f"OK: {OUT}")


if __name__ == "__main__":
    main()
