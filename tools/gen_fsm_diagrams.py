#!/usr/bin/env python3
#============================================================================
# gen_fsm_diagrams.py — 生成各模块的状态机图
# Generate FSM diagrams for design reports.
#
# 每个 FSM 用 tools/state_machine_gen.py 的 FSM 类描述，渲染到 doc/fig/。
# 后续模块的状态机图都加在这里。
#
# 用法 / Usage:
#   python3 tools/gen_fsm_diagrams.py             # 生成全部图
#   python3 tools/gen_fsm_diagrams.py tx_serial   # 只生成指定图（dpll / tx_serial / block / common）
#============================================================================

import os
import sys

from state_machine_gen import FSM  # 同目录 / same directory

# 配色 / palette
CLK_HIGH = "#C6EFCE"   # 恢复时钟高电平态（内两态）/ recovered-clock high states
CLK_LOW  = "#DDEBF7"   # 恢复时钟低电平态（外两态）/ recovered-clock low states
LOCK     = "#FFF2CC"   # 锁存态 C/D / lock states
DETOUR   = "#FCE4D6"   # 长bit绕行态 F/B / long-bit detour states
TX_IDLE  = "#ECEFF1"   # TX 位 FSM：空闲态 / TX idle state
TX_WORK  = "#DDEBF7"   # TX 位 FSM：移位发送态 / TX shifting states
TX_END   = "#FFE0B2"   # TX 位 FSM：包尾 EOP 态 / TX EOP state


def dpll_diagram():
    """模块② usb_dpll_phy — DPLL 时钟恢复状态机（Intel SIE 结构）。

    布局思路：左环(数据0) 与右环(数据1) 两条竖列并排，C/D 锁存态在顶，
    F/B 长bit绕行态在中间 2/6 行（对应论文 Fig.2 的 "2 B F 6"）。
    跨环/自环边用 constraint=false，避免拉扯布局；环内边撑出竖列。
    """
    fsm = FSM(title="DPLL 时钟恢复状态机（USB 1.1, 48MHz, Intel SIE 结构）",
              init="C")
    # ---- 状态 / states ----
    # 锁存态 / lock acquisition
    fsm.state("C", fillcolor=LOCK, label="C")
    fsm.state("D", fillcolor=LOCK, label="D")
    # 左环（数据0）/ left loop (data 0)
    fsm.state("1", fillcolor=CLK_LOW, label="1")
    fsm.state("0", fillcolor=CLK_LOW, label="0")
    fsm.state("3", fillcolor=CLK_HIGH, label="3")
    fsm.state("2", fillcolor=CLK_HIGH, label="2")
    # 右环（数据1）/ right loop (data 1)
    fsm.state("5", fillcolor=CLK_LOW, label="5")
    fsm.state("4", fillcolor=CLK_LOW, label="4")
    fsm.state("7", fillcolor=CLK_HIGH, label="7")
    fsm.state("6", fillcolor=CLK_HIGH, label="6")
    # 长bit绕行 / long-bit detour
    fsm.state("F", fillcolor=DETOUR, label="F")
    fsm.state("B", fillcolor=DETOUR, label="B")

    # ---- 跳转 / transitions ----
    # 锁存 / lock acquisition（自环不参与布局）
    fsm.edge("C", "C", "b≠0", constraint="false")
    fsm.edge("C", "D", "b=0")
    fsm.edge("D", "D", "b=0", constraint="false")
    fsm.edge("D", "5", "b=1")
    # 左环纵向 / left loop vertical chain
    fsm.edge("1", "3")
    fsm.edge("3", "2", "a=0")
    fsm.edge("2", "0", "b=0")
    # 右环纵向 / right loop vertical chain
    fsm.edge("5", "7")
    fsm.edge("7", "6", "a=1")
    fsm.edge("6", "4", "b=1")
    # F/B 锚定到中间行 / anchor F/B to middle rank
    fsm.edge("3", "F", "a=1", constraint="false")
    fsm.edge("F", "6", constraint="true")
    fsm.edge("7", "B", "a=0", constraint="true")
    fsm.edge("B", "2", constraint="false")
    # 跨环切换（不影响布局）/ cross-loop switches
    fsm.edge("2", "5", "b=1", constraint="false")
    fsm.edge("0", "5", "b=1", constraint="false")
    fsm.edge("6", "1", "b=0", constraint="false")
    fsm.edge("4", "1", "b=0", constraint="false")
    fsm.edge("0", "1", "b=0", constraint="false")
    fsm.edge("4", "5", "b=1", constraint="false")

    # ---- 同行约束：两竖列并排 + F/B 在 2/6 行 / ranks ----
    fsm.rank("C", "D")
    fsm.rank("1", "5")
    fsm.rank("3", "7")
    fsm.rank("2", "6", "F", "B")   # 对应论文 "2 B F 6" 一行
    fsm.rank("0", "4")

    fsm.render("dpll_state_machine")


def tx_serial_diagram():
    """模块② usb_tx_serial — TX 位 FSM（6 态两段式，2026-09-20 换 `_sy` 设计）。

    对应 doc/design_rpt/tx_serial_design.md §2.6：
    S_IDLE → S_SYNC → {S_DATA, S_DATA_LAST} → S_EOP1 → S_EOP2 → S_IDLE。
    横向线性排布（rankdir=LR），自环不参与布局；另用灰虚线画出"任意发态 tx_active↓ → S_IDLE"。

    ★ 末字节为什么要独立态: 设计里没有 `last_q` 锁存，`tx_last` 在字节边界直接从端口采
      —— 采到的"这是最后一字节"由**状态**记住 (S_DATA_LAST)，而不是由寄存器记住。
    ★ S_EOP1 为什么自环: 它兼作**尾填充拍** —— 进入时若 `bit_ones_cnt` 恰好是 6
      (末字节 b7 正好凑满 6 连 1)，它就多停一拍把那个 0 插掉再进 SE0。
    """
    fsm = FSM(title="usb_tx_serial TX 位状态机（1× clk12m 域，6 态两段式）",
              init="S_IDLE", rankdir="LR")
    # ---- 状态 / states ----
    fsm.state("S_IDLE", fillcolor=TX_IDLE, label="S_IDLE\ntx_en=0 · 线保持 J")
    fsm.state("S_SYNC", fillcolor=TX_WORK, label="S_SYNC\n载 0x80 移 8 拍\n（不跑填充，恒 8 拍）")
    fsm.state("S_DATA", fillcolor=TX_WORK, label="S_DATA\n载 tx_data 移 8 拍")
    fsm.state("S_DATA_LAST", fillcolor=TX_WORK, label="S_DATA_LAST\n末字节：8 拍完即转 EOP")
    fsm.state("S_EOP1", fillcolor=TX_END, label="S_EOP1\nSE0 第 1 拍\n（兼尾填充拍）")
    fsm.state("S_EOP2", fillcolor=TX_END, label="S_EOP2\nSE0 第 2 拍")

    # ---- 跳转 / transitions ----
    # 主干边参与布局（rankdir=LR → 横向一排），自环/中止回边不参与
    fsm.edge("S_IDLE", "S_SYNC", "tx_active↑")
    fsm.edge("S_SYNC", "S_SYNC", "未满 8 位", constraint="false")
    fsm.edge("S_SYNC", "S_DATA", "8 位完 · 非末字节")
    fsm.edge("S_SYNC", "S_DATA_LAST", "8 位完 · 末字节", constraint="false")
    fsm.edge("S_DATA", "S_DATA", "未满 8 位 / 非末字节", constraint="false")
    fsm.edge("S_DATA", "S_DATA_LAST", "8 位完 · 末字节")
    fsm.edge("S_DATA_LAST", "S_DATA_LAST", "未满 8 位 / 正插尾填充 0", constraint="false")
    fsm.edge("S_DATA_LAST", "S_EOP1", "末字节 8 位完且不在填充拍")
    fsm.edge("S_EOP1", "S_EOP1", "进态时 ones_cnt=6 → 插尾填充 0", constraint="false")
    fsm.edge("S_EOP1", "S_EOP2", "SE0 第 1 拍完")
    fsm.edge("S_EOP2", "S_IDLE", "SE0 第 2 拍完", constraint="false")
    # 中止：任意发态 tx_active↓ 强退回 IDLE（次态逻辑的最外层 if，优先级最高）
    fsm.edge("S_SYNC", "S_IDLE", "tx_active↓", constraint="false", style="dashed", color="#9E9E9E")
    fsm.edge("S_DATA", "S_IDLE", "tx_active↓", constraint="false", style="dashed", color="#9E9E9E")
    fsm.edge("S_DATA_LAST", "S_IDLE", "tx_active↓", constraint="false", style="dashed", color="#9E9E9E")
    fsm.edge("S_EOP1", "S_IDLE", "tx_active↓", constraint="false", style="dashed", color="#9E9E9E")
    fsm.edge("S_EOP2", "S_IDLE", "tx_active↓", constraint="false", style="dashed", color="#9E9E9E")

    fsm.render("tx_serial_state_machine")


def phy_block_diagram():
    """模块② usb_dpll_phy 内部模块框图（五个子模块 + 外部边界）

    2026-09-28 重画：接口按 RTL 口径 —— 五个子模块全在 `src/phy/`；
    线电平由 `usb_rx_deserial` 采样后以 `line_s` 送 `usb_bus_state`（两者在 PHY 顶层挨着实例化）；
    `rcv` 由 SIE 产生后只驱动 `usb_clk_mux`；`usb_rst` 是 core 复位（总线复位 ∪ 软复位）。
    """
    import subprocess
    dot = r'''
digraph G {
    rankdir=TB;
    graph [labelloc="t", labeljust="c", fontname="Helvetica", fontsize=14,
           label="usb_dpll_phy 内部模块框图\n(ref_clk 48MHz 4x / clk12m 12MHz 1x)\nref_clk 与 ref_rstn 进全部五个子模块（图中省略）", pad=0.5];
    node [fontname="Helvetica", fontsize=10, penwidth=1.2];
    edge [fontname="Helvetica", fontsize=9, color="#555555", arrowsize=0.8];

    // ---- 外部边界 / external boundary ----
    dp [label="usb_rxdp\nusb_rxdn", shape=oval, fillcolor="#E8F5E9", style=filled, color="#388E3C"];
    tx_out [label="tx_bit tx_se0 tx_en\n-&gt; 模拟驱动", shape=oval, fillcolor="#FCE4EC", style=filled, color="#C62828"];
    rst_in [label="usb_rst\n(core 复位：总线复位 ∪ 软复位,\n同步高有效、宽 1 个 clk12m 周期)",
            shape=oval, fillcolor="#ECEFF1", style=filled, color="#546E7A"];
    to_sie [label="→ SIE：rx_data[7:0] rx_valid\nrx_active rx_error\nline_state[1:0]\ntx_ready tx_done\nconnect/rst/suspend/resume",
            shape=oval, fillcolor="#E3F2FD", style=filled, color="#1565C0"];
    from_sie [label="← SIE：rcv tx_active\ntx_data[7:0] tx_last\nsie_wkup",
              shape=oval, fillcolor="#FFF3E0", style=filled, color="#E65100"];

    // ---- ① CDR ----
    subgraph cluster_cdr {
        label="usb_rx_cdr  时钟数据恢复 (ref_clk 4x)";
        fontsize=10;
        style="rounded,dashed"; color="#1565C0"; bgcolor="#E3F2FD44";
        cdr_box [label="DPLL 16 态\na/b 双沿采样\ndclk 去毛刺打拍\nrx_bit 组合输出", shape=box, fillcolor="#E3F2FD", style="filled,rounded"];
    }

    // ---- ② 时钟切换 ----
    subgraph cluster_mux {
        label="usb_clk_mux  时钟切换 (ref_clk 4x)";
        fontsize=10;
        style="rounded,dashed"; color="#6A1B9A"; bgcolor="#F3E5F544";
        mux_box [label="dclk / clk12s\n4 态无毛刺切换\n-&gt; clk12m", shape=box, fillcolor="#F3E5F5", style="filled,rounded"];
    }

    // ---- ③ RX 反序列化 ----
    subgraph cluster_rx {
        label="usb_rx_deserial  RX 反序列化 (clk12m 1x)";
        fontsize=10;
        style="rounded,dashed"; color="#2E7D32"; bgcolor="#E8F5E944";
        rx_box [label="SYNC 检测 / NRZI 解码\n位解填充 / 字节对齐\nEOP·SE0 定界 (ref_clk 4x)\nline_s 采样 (ref_clk 4x)\nframe_clr 复位 (usb_rst ∪ tx_active ∪ rx_abort)",
                shape=box, fillcolor="#E8F5E9", style="filled,rounded"];
    }

    // ---- ④ TX 串行器 ----
    subgraph cluster_tx {
        label="usb_tx_serial  TX 串行器 (clk12m 1x)";
        fontsize=10;
        style="rounded,dashed"; color="#C62828"; bgcolor="#FCE4EC44";
        tx_box [label="SYNC 生成 / 位填充\nNRZI 编码 / EOP 生成\n挂起·远程唤醒 K 旁路\n(bus_suspended &amp; sie_wkup)", shape=box, fillcolor="#FCE4EC", style="filled,rounded"];
    }

    // ---- ⑤ 总线状态检测 ----
    subgraph cluster_bus {
        label="usb_bus_state  总线状态检测 (ref_clk 判据 -&gt; clk12m 脉冲)";
        fontsize=10;
        style="rounded,dashed"; color="#EF6C00"; bgcolor="#FFF3E044";
        bus_box [label="一条计数器 + connected/suspended\nJ &gt;= 2.5us -&gt; connect_evt\nSE0 &gt;= 2.5us -&gt; usb_bus_rst\nidle &gt; 3ms -&gt; suspend_evt\n挂起中 K &gt;= 2.5us -&gt; resume_evt",
                 shape=box, fillcolor="#FFF3E0", style="filled,rounded"];
    }

    // ---- Edges: RX 通路 ----
    dp -> cdr_box [label=" rxdp / rxdn", color="#1565C0"];
    dp -> rx_box  [label=" 单端直采", style=dashed, color="#2E7D32", constraint=false];
    cdr_box -> mux_box [label=" dclk", color="#6A1B9A"];
    cdr_box -> rx_box  [label=" rx_bit", color="#1565C0", constraint=false];
    mux_box -> rx_box  [label=" clk12m", color="#2E7D32"];
    mux_box -> tx_box  [label=" clk12m", color="#2E7D32", style=dashed, constraint=false];
    rx_box -> to_sie  [label=" 字节流 + 包边界", color="#1565C0"];

    // ---- Edges: TX 通路 ----
    from_sie -> tx_box [label=" 字节 + tx_active", color="#E65100"];
    tx_box -> tx_out [label=" 线电平 + 驱动使能", color="#C62828"];

    // ---- Edges: 方向与互斥 ----
    from_sie -> mux_box [label=" rcv", color="#6A1B9A", constraint=false];
    from_sie -> rx_box  [label=" tx_active / rx_abort", style=dashed, color="#9E9E9E", constraint=false];

    // ---- Edges: 线状态交给总线状态检测 ----
    rx_box -> bus_box [label=" line_s", style=dashed, color="#EF6C00"];
    bus_box -> to_sie [label=" 四个事件", style=dashed, color="#EF6C00", constraint=false];
    bus_box -> tx_box [label=" bus_suspended", style=dashed, color="#C62828", constraint=false];

    // ---- Edges: core 复位 ----
    rst_in -> rx_box  [style=dotted, color="#546E7A", constraint=false];
    rst_in -> bus_box [style=dotted, color="#546E7A", constraint=false];

    // ---- 行约束 / ranks：左列 RX 链，右列 TX 链 ----
    // ★ 不能把 cluster 内的节点放进 cluster 外的 rank 组（graphviz 会把该节点
    //   从 cluster 里摘掉、"removing empty cluster"），行对齐只靠约束边给。
    { rank=same; dp; from_sie; rst_in; }
}
'''
    dotpath = "doc/fig/phy_block.dot"
    imgpath = "doc/fig/phy_block.png"
    with open(dotpath, 'w') as f: f.write(dot)
    r = subprocess.run(['dot', '-Tpng', dotpath, '-o', imgpath], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"dot error: {r.stderr}")
    else:
        print(f"  -> {imgpath}")


def common_block_diagram():
    """模块① 公共原语 模块框图"""
    import subprocess
    dot = r'''
digraph G {
    rankdir=LR;
    graph [labelloc="t", labeljust="c", fontname="Helvetica", fontsize=14,
           label="公共原语（Common Primitives）", pad=0.5];
    node [fontname="Helvetica", fontsize=10, penwidth=1.2, shape=box,
          style="rounded,filled", margin="0.15,0.1"];

    // CRC 组
    subgraph cluster_crc {
        label="CRC 校验\n（包级，SIE 使用）";
        style="rounded,dashed"; color="#1565C0";
        node [fillcolor="#BBDEFB", color="#1565C0"];
        crc5 [label="usb_crc5\n(x⁵+x²+1)\n种子 0x1F\n残余 0x0C", width=1.8];
        crc16 [label="usb_crc16\n(x¹⁶+x¹⁵+x²+1)\n种子 0xFFFF\n残余 0x800D", width=1.8];
    }

    // NRZI 组
    subgraph cluster_nrzi {
        label="NRZI 编解码\n（位级，PHY 使用）";
        style="rounded,dashed"; color="#E65100";
        node [fillcolor="#FFE0B2", color="#E65100"];
        nrzi_enc [label="usb_nrzi_enc\n0=翻转 1=保持\n初始=J(idle)", width=1.8];
        nrzi_dec [label="usb_nrzi_dec\n同=1 异=0\nref=上一电平", width=1.8];
    }

    // 位填充组
    subgraph cluster_stuff {
        label="位填充\n（位级，PHY 使用）";
        style="rounded,dashed"; color="#2E7D32";
        node [fillcolor="#C8E6C9", color="#2E7D32"];
        stuff [label="usb_bit_stuff\n6个连续1后\n插入0\n(2深FIFO+直通)", width=1.8];
        unstuff [label="usb_bit_unstuff\n6个连续1后\n丢弃stuffed 0", width=1.8];
    }

    // 数据流标注
    edge [fontname="Helvetica", fontsize=9, arrowsize=0.7, color="#555555"];

    // PHY TX 路径
    tx_path [label="PHY TX 路径\nstuff → nrzi_enc", shape=note, fillcolor="#FFF9C4", color="#F9A825"];
    stuff -> tx_path [style=invis];

    // PHY RX 路径
    rx_path [label="PHY RX 路径\nnrzi_dec → unstuff", shape=note, fillcolor="#F3E5F5", color="#7B1FA2"];
    unstuff -> rx_path [style=invis];

    // 逻辑关系
    nrzi_enc -> stuff [label=" 数据位", dir=back, color="#E65100", style=dashed];
    nrzi_dec -> unstuff [dir=none, color="#7B1FA2", style=dashed];

    // CRC 说明
    crc_note [label="CRC 采用 bit-serial\n逐位喂入(LSB first)\n适配TOKEN 11bit不对齐", shape=note, fillcolor="#E3F2FD", color="#1565C0"];
    crc5 -> crc_note [style=invis];

    { rank=same; crc5; crc16; tx_path; }
    { rank=same; nrzi_enc; nrzi_dec; rx_path; }
    { rank=same; stuff; unstuff; crc_note; }
}
'''
    dotpath = "doc/fig/common_block.dot"
    imgpath = "doc/fig/common_block.png"
    with open(dotpath, 'w') as f: f.write(dot)
    r = subprocess.run(['dot', '-Tpng', dotpath, '-o', imgpath], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"dot error: {r.stderr}")
    else:
        print(f"  -> {imgpath}")


if __name__ == "__main__":
    only = sys.argv[1] if len(sys.argv) > 1 else None
    jobs = {"dpll": dpll_diagram, "tx_serial": tx_serial_diagram,
            "block": phy_block_diagram, "common": common_block_diagram}
    if only:
        jobs[only]()
    else:
        for fn in jobs.values():
            fn()
    print("全部图已生成 / all diagrams generated")
