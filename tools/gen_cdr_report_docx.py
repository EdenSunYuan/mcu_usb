#!/usr/bin/env python3
"""
gen_cdr_report_docx.py — 从 CDR 验证内容生成 Word 版报告 (doc/CDR验证报告.docx)

内容与 doc/02_cdr_verification.md 保持一致，并内嵌 doc/fig/ 下的 4 张波形截图。

用法:
    cd <项目根目录>
    python3 tools/gen_cdr_report_docx.py
"""

import os
import re

from docx import Document
from docx.shared import Pt, Inches, RGBColor
from docx.oxml import OxmlElement
from docx.oxml.ns import qn

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIG = os.path.join(ROOT, "doc", "fig")
OUT = os.path.join(ROOT, "doc", "CDR验证报告.docx")

BODY_FONT = "宋体"
MONO_FONT = "Consolas"
BODY_SIZE = 10.5
CODE_SIZE = 9.5
CODE_BG = "F2F2F2"


def set_run(run, size=BODY_SIZE, bold=False, mono=False, color=None):
    """Set font (incl. east-asian) on a run."""
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
    """Add runs (parsing **bold** and `code` inline markers) into existing paragraph p."""
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
    """Add a paragraph, parsing **bold** and `code` inline markers."""
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
    for line in text.split("\n"):
        if line != text.split("\n")[0]:
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


def add_fig(doc, path, caption):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(4)
    p.paragraph_format.space_after = Pt(2)
    p.alignment = 1  # center
    p.add_run().add_picture(os.path.join(FIG, path), width=Inches(6.3))
    cap = doc.add_paragraph()
    cap.paragraph_format.space_after = Pt(8)
    cap.alignment = 1
    set_run(cap.add_run(caption), size=9, color="595959")


def main():
    doc = Document()
    # 页边距
    for s in doc.sections:
        s.left_margin = Inches(0.9)
        s.right_margin = Inches(0.9)
        s.top_margin = Inches(0.8)
        s.bottom_margin = Inches(0.8)

    # 默认 Normal 字体
    normal = doc.styles["Normal"]
    normal.font.name = BODY_FONT
    normal.font.size = Pt(BODY_SIZE)
    normal.element.rPr.rFonts.set(qn("w:eastAsia"), BODY_FONT)

    # ===== 标题 =====
    title = doc.add_paragraph()
    title.alignment = 1
    set_run(title.add_run("CDR 模块验证报告"), size=20, bold=True, color="1F3864")
    sub = doc.add_paragraph()
    sub.alignment = 1
    set_run(sub.add_run("usb_rx_cdr — Intel SIE DPLL 时钟数据恢复"), size=12, bold=True)

    meta = doc.add_paragraph()
    meta.alignment = 1
    meta.paragraph_format.space_after = Pt(12)
    set_run(meta.add_run("日期：2026-08-13   工具：iverilog + vvp   源码：src/phy/usb_rx_cdr.v"),
            size=9.5, color="595959")

    # ===== 1. 概述 =====
    add_heading(doc, "1. 概述", 1)
    add_para(doc, "`usb_rx_cdr` 是 USB 1.1 数字收发器（PHY）中的时钟数据恢复单元，用 48MHz "
                  "`ref_clk` 对 D+/D- 差分线做 4× 过采样，恢复出 12MHz 位时钟 `clk_12m` 和 NRZI "
                  "电平数据 `d_out`。其核心是 Intel SIE 的 16 态 DPLL 状态机：")
    add_para(doc, "**锁存路径**：C(12) → D(13) → 5（进入右环即锁存）", indent=12)
    add_para(doc, "**右环（J 电平）**：5 → 7 → 6 → 4", indent=12)
    add_para(doc, "**左环（K 电平）**：1 → 3 → 2 → 0", indent=12)
    add_para(doc, "**长 bit 绕行**：F(15)、B(11) 各多耗一拍", indent=12)
    add_para(doc, "验证目标：证明 CDR 在标称、长/短 bit、SE0、随机、多包、以及**端到端数据往返**"
                  "等场景下都能正确恢复时钟与数据。")

    # ===== 2. 测试环境 =====
    add_heading(doc, "2. 测试环境", 1)
    add_table(doc,
              ["项目", "说明"],
              [["RTL", "src/phy/usb_rx_cdr.v（16 态 DPLL 状态机）"],
               ["Testbench", "sim/cdr/tb_cdr.v：实例化 DUT + 自检逻辑 + +case= 分发"],
               ["Case 文件", "sim/cdr/case_*.v（8 个），通过 +case=<name> 独立运行"],
               ["激励任务", "sim/common/usb_pkt_tasks.vh：bit_task → byte_task → pid_task → packet_task"],
               ["参考模型", "sim/common/crc5_ref.vh、crc16_ref.vh（CRC5/CRC16 黄金向量）"],
               ["时钟", "48MHz #(1000/48/2)；USB bit 时间 = 4 ref_clk ≈ 83.33ns"],
               ["NRZI/位填充", "bit_task 内置 NRZI 编码 + 位填充（连续 6 个 1 后插 0）"],
               ["周期覆盖", "bit_task(d, cyc) 支持 3（短）/4（标称）/5（长）"]],
              widths=[1.4, 4.9])
    add_para(doc, "仿真方式（sim/cdr/ 下）：")
    add_code_block(doc, "make -C sim/cdr run            # 全 8 个 case 逐个运行并汇总\n"
                        "make -C sim/cdr run VCD=1      # 每个 case 保存独立 VCD 波形")

    # ===== 3. 自检机制 =====
    add_heading(doc, "3. 自检机制", 1)
    add_para(doc, "pass/fail 判定基于硬件级别的自动检测（非人工看波形）：")
    add_table(doc,
              ["#", "检测点", "实现", "判据"],
              [["1", "锁存", "state==5 && nxt_state==7 首次成立 → locked=1", "locked"],
               ["2", "F 绕行", "prev_state==3 && state==15", "f_detected"],
               ["3", "B 绕行", "prev_state==7 && state==11", "b_detected"],
               ["4", "恢复时钟", "posedge clk_12m 相邻沿间 ref_clk 计数", "周期 ∈ 3~5 ref_clk"],
               ["5", "d_out 跟踪", "locked 后在 ref_clk 沿比 d_out vs rxdp", "信息性统计（DPLL 有 1~2 拍流水延迟，不强制）"],
               ["6", "端到端回环", "用 clk_12m+d_out 还原数据位 vs 发送位", "逐 bit 一致（见 §5）"]],
              widths=[0.4, 1.2, 3.3, 1.4])
    add_para(doc, "d_out 跟踪（#5）是信息性的：DPLL 内部有流水延迟，每个 case 正常有 ~40~90 "
                  "次沿边沿不匹配，但**连续**不匹配长度（max run）才是数据恢复质量的判据。",
             size=9.5, color="595959")

    # ===== 4. 测试用例与结果 =====
    add_heading(doc, "4. 测试用例与结果", 1)
    add_para(doc, "8 个 case 全部通过：")
    add_table(doc,
              ["Case", "+case=", "测试目的", "关键判据", "结果"],
              [["标称", "cdr_case_nominal", "标称 4-cycle OUT Token 基本锁存", "locked=1", "✅"],
               ["长 bit F", "cdr_case_long_bit_f", "J 电平长 bit（5cyc）→ F 绕行", "f_detected=1", "✅"],
               ["长 bit B", "cdr_case_long_bit_b", "K 电平长 bit（5cyc）→ B 绕行", "b_detected=1", "✅"],
               ["短 bit", "cdr_case_short_bit", "3cyc 短 bit 不失锁", "locked 保持", "✅"],
               ["SE0", "cdr_case_se0", "注入 SE0 后能重新锁存", "第二次 locked=1", "✅"],
               ["随机", "cdr_case_random", "64 bit 随机数据 + 随机宽度(3/4/5cyc)", "locked 全程保持", "✅"],
               ["多包", "cdr_case_multi_pkt", "3 包事务（SETUP+DATA0+ACK）", "时钟/数据持续恢复", "✅"],
               ["回环", "cdr_case_loopback", "端到端逐 bit 对比", "122 数据位 0 差异", "✅"]],
              widths=[0.8, 1.7, 2.2, 1.2, 0.4])
    add_para(doc, "关键实测输出摘录：")
    add_code_block(doc,
        "[长 bit F]  F detour (3→F→6) detected ✓\n"
        "[长 bit B]  B detour (7→B→2) detected ✓\n"
        "[SE0]       CDR re-locked after SE0 ✓\n"
        "[随机]      CDR locked ✓  /  CDR still locked ✓\n"
        "[多包]      clk_12m: 126 rising edges (expect ~124), 0 bad periods\n"
        "            d_out tracking: 200 mismatches, max run 2 ref_clk (≤ 6 ✓)\n"
        "[回环]      ✓ 24 + 90 + 8 = 122 data bits recovered identical")

    add_heading(doc, "4.1 多包事务（case_multi_pkt）", 2)
    add_para(doc, "发送一次 SETUP 控制传输的 3 个包（SETUP token + DATA0(8B, 含 0x7F 触发位填充) + "
                  "ACK），验证 CDR 在包与包之间的 EOP + idle J 间隔后仍持续正确恢复：")
    add_para(doc, "恢复时钟 clk_12m 共 126 个上升沿（预期 ≈124，2 个 stuffed bit 补齐），**0 个坏周期**；", indent=12)
    add_para(doc, "d_out 对 rxdp 的最大连续滞后仅 **2 ref_clk**（远小于 1 bit = 4 ref_clk），"
                  "说明数据电平从未丢失。", indent=12)

    add_heading(doc, "4.2 波形截图（wave_debugger 导出）", 2)
    add_para(doc, "以下波形用本项目的 wave_debugger.py 波形调试器显示，并经 render_waveform.py "
                  "离屏渲染导出。信号名中 dut.state 为 4-bit DPLL 状态（十六进制即状态编码）。")
    add_fig(doc, "cdr_wave_overview.png",
            "图 1 完整 OUT Token（cdr_case_nominal）：rxdp/rxdn（差分线）、clk_12m（恢复时钟）、d_out（NRZI 电平）")
    add_fig(doc, "cdr_lock.png",
            "图 2 锁存放大：clk（48MHz 参考）、rxdp、d_out、dut.state；state 走 C(12)→D(13)→5（锁定进入右环）")
    add_fig(doc, "cdr_f_detour.png",
            "图 3 F 绕行放大（cdr_case_long_bit_f）：state 走 3→F(15)→6→4，恢复时钟高电平加 1 个 48MHz 周期")
    add_fig(doc, "cdr_multi_pkt.png",
            "图 4 3 包事务（cdr_case_multi_pkt）：SETUP + DATA0 + ACK；clk_12m 持续恢复 12MHz，d_out 跟踪 NRZI 电平")

    # ===== 5. 端到端回环验证 =====
    add_heading(doc, "5. 端到端回环验证（case_loopback）—— 核心", 1)
    add_para(doc, "这是对 CDR **最严格**的验证：不再依赖“电平跟踪”等间接判据，而是走完整链路，"
                  "用 CDR 恢复的时钟和数据**还原出原始包数据位**，与发送位逐 bit 对比。")

    add_heading(doc, "5.1 方法", 2)
    add_code_block(doc,
        "发送 bit_task (NRZI + 位填充) ──> 差分线 DP/DN ──> CDR ──> clk_12m + d_out\n"
        "                                                           └─ 采样 d_out @clk_12m 上升沿\n"
        "                                                           └─ NRZI 解码 (变→0, 不变→1)\n"
        "                                                           └─ 恢复数据位 rx_q\n"
        "对比:  rx_q  vs  发送时记录的 exp_tx_q (含 stuffed bit)")
    add_para(doc, "**发送端**：bit_task 把实际线上数据位（含位填充 stuffed bit）按序记入 exp_tx_q；", indent=12)
    add_para(doc, "**接收端**：always @(posedge clk_12m) 采样 d_out，NRZI 解码（相邻采样电平变→0、不变→1）到 rx_q；", indent=12)
    add_para(doc, "**对齐**：用 SYNC 尾巴定位包起点（见 §5.2），从 PID 起逐 bit 比。", indent=12)

    add_heading(doc, "5.2 关键发现：SYNC 相位对齐“吃掉” 1~2 位", 2)
    add_para(doc, "调试中先用 Python 精确比对恢复流与发送流，发现恢复流是发送流的**完美平移拷贝**：")
    add_table(doc,
              ["包", "偏移", "比对结果"],
              [["SETUP（首包，从复位锁存）", "2 bit", "30/30 位 0 差异"],
               ["DATA0（后续包，已锁存）", "1 bit", "97/97 位 0 差异"]],
              widths=[2.4, 0.8, 1.8])
    add_para(doc, "原因：CDR 的时钟相位对齐会“吃掉” SYNC 开头的 1~2 个 bit（首包锁存吃 2 个、"
                  "后续包再对齐吃 1 个）。这正是 USB 设计 SYNC 字段的用途——SIE 只用 SYNC 对齐采样时钟，"
                  "**从不把 SYNC 当数据解码**。因此对齐逻辑不再要求完整 00000001（7 个 0），而是找 SYNC "
                  "尾巴（连续 ≥4 个 0 + 1），把那个 1 对齐到 exp[7]，从 PID 开始逐 bit 比。该方案对 "
                  "0/1/2 位偏移都鲁棒。")

    add_heading(doc, "5.3 结果", 2)
    add_table(doc,
              ["包", "数据位（PID + …）", "结果"],
              [["SETUP token", "24 bit（PID+ADDR+ENDP+CRC5）", "✅ 0 差异（吃掉 2 SYNC 位）"],
               ["DATA0（8B payload + CRC16）", "90 bit", "✅ 0 差异（吃掉 1 SYNC 位）"],
               ["ACK handshake", "8 bit", "✅ 0 差异（吃掉 1 SYNC 位）"]],
              widths=[2.4, 2.4, 2.0])
    add_para(doc, "**共 122 个数据位，0 bit 差异**，直接证明 CDR 恢复的时钟与数据正确配对。")

    # ===== 6. 结论 =====
    add_heading(doc, "6. 结论", 1)
    add_table(doc,
              ["验证点", "结果"],
              [["锁存 C→D→5", "✅ PASS"],
               ["右/左环循环", "✅ PASS"],
               ["d_out 电平跟踪", "✅ PASS（最大滞后 2 ref_clk）"],
               ["clk_12m 恢复时钟", "✅ PASS（12MHz，周期 4 ref_clk，126 沿 0 坏周期）"],
               ["长 bit → F 绕行", "✅ PASS（3→F→6）"],
               ["长 bit → B 绕行", "✅ PASS（7→B→2）"],
               ["短 bit", "✅ PASS（不失锁）"],
               ["SE0/EOP", "✅ PASS（能重新锁存）"],
               ["随机激励", "✅ PASS（64 bit 全程锁存）"],
               ["端到端回环", "✅ PASS（122 数据位逐 bit 一致）"]],
              widths=[2.2, 4.0])
    add_para(doc, "**8 个测试用例全部通过。** 其中端到端回环验证（case_loopback）用“恢复的 "
                  "clk_12m + d_out 还原包数据 → 与发送包逐 bit 对比”的方式，从功能上严格证明了 "
                  "CDR 时钟恢复与数据恢复的正确性。", bold=False)

    doc.save(OUT)
    print(f"OK: {OUT}")


if __name__ == "__main__":
    main()
