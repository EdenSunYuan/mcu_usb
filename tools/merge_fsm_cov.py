#!/usr/bin/env python3
#============================================================================
# merge_fsm_cov.py — 合并 19 个 TX 用例日志里的 FSM 状态/弧覆盖
#
# 为什么需要它: Verilator 的 --coverage-fsm 认不出 usb_tx_serial 的两段式 FSM
# (组合算 stat_nxt + 时序搬 stat_cur, 且 case 外套了 if (!tx_active)), 所以 FSM
# 这一维的覆盖率由 TB 自己数 (tb_tx_serial.v 的 print_fsm_coverage), 每个用例
# 在日志末尾打一份 N×N 迁移矩阵。本脚本把这些矩阵**逐元素相加** —— 与
# verilator_coverage 对本模块其它维度做的事完全同构: 单用例只走自己那条路径,
# 合并后才是"这套激励整体覆盖了哪些状态与弧"。
#
#   用法: python3 tools/merge_fsm_cov.py sim/tx/sim_tx_*.log
#         (或 sim/tx: make fsmcov)
#
# 退出码: 0 = 全部状态 + 全部合法弧均已覆盖; 1 = 有未覆盖项 (打印清单)。
#============================================================================

import re
import sys
import glob

# 每个 DUT 一个 profile: 状态名 + 设计意图内的合法弧 (照 RTL 的次态逻辑抄)。
#   ★ 加新模块时: 抄 RTL 的次态 case, 把每个"可达的 from→to"写进来。漏写会让
#     真实弧被误报成"意图外", 多写会让缺口被漏报 —— 两边都要照 RTL 核。
#   ★ 状态数由 states 字典的长度决定, 矩阵按同一维度解析 (4 态 / 6 态都适用)。
PROFILES = {
    "tx": {
        "title": "TX (usb_tx_serial)",
        # ★ 顺序注意: `DATA_LAST=` 不含子串 `DATA=`, 不会串位; 非贪婪 `.*?` 逐段对齐。
        "visit": (r"停留拍数:.*?IDLE=(\d+).*?SYNC=(\d+).*?DATA=(\d+)"
                  r".*?DATA_LAST=(\d+).*?EOP1=(\d+).*?EOP2=(\d+)"),
        "states": {0: "IDLE", 1: "SYNC", 2: "DATA", 3: "DATA_LAST", 4: "EOP1", 5: "EOP2"},
        # 照 `_sy` 设计的次态 case (2026-09-20 起 6 态) 逐条抄:
        #   IDLE→IDLE / IDLE→SYNC (tx_active↑)
        #   SYNC→SYNC / SYNC→DATA (8 拍移完且非末字节) / SYNC→DATA_LAST (末字节)
        #   DATA→DATA / DATA→DATA_LAST (末字节移完且不在填充拍)
        #   DATA_LAST→DATA_LAST / DATA_LAST→EOP1 (末字节移完; 尾填充那拍自环)
        #   EOP1→EOP1 (尾填充 0 那拍) / EOP1→EOP2 (SE0 第 1 拍 → 第 2 拍)
        #   EOP2→IDLE (发完)
        #   另: 各态因 tx_active↓ 强退回 IDLE (from 1~4 → 0)
        "legal": {(0, 0), (0, 1),
                  (1, 0), (1, 1), (1, 2), (1, 3),
                  (2, 0), (2, 2), (2, 3),
                  (3, 0), (3, 3), (3, 4),
                  (4, 0), (4, 4), (4, 5),
                  (5, 0)},
    },
    "clkmux": {
        "title": "clk mux (usb_clk_mux)",
        "visit": (r"停留拍数:.*?RCV=(\d+).*?HOLD1=(\d+).*?HOLD2=(\d+).*?TX=(\d+)"),
        "states": {0: "RCV", 1: "HOLD1", 2: "HOLD2", 3: "TX"},
        # 照 stat_nxt 的 case 逐条抄（每态只有"自环 + 一条出边"）:
        #   RCV→RCV / RCV→HOLD1 (rcv↓ 且 dclk 低)   —— RX→TX 的断离腿
        #   HOLD1→HOLD1 / HOLD1→TX (clk12s 低)      —— 等本地时钟低点后接入
        #   TX→TX / TX→HOLD2 (rcv↑ 且 clk12s 高)    —— TX→RX 的断离腿
        #   HOLD2→HOLD2 / HOLD2→RCV (dclk 低)       —— 等恢复时钟低点后接入
        #   default→TX: 兜底分支, 2 位状态无不可达码, 结构上不可达 (不计入)
        "legal": {(0, 0), (0, 1), (1, 1), (1, 3), (3, 3), (3, 2), (2, 2), (2, 0)},
    },
    "busstate": {
        "title": "bus state (usb_bus_state)",
        # 本模块没有状态机, 状态位由 (connected, suspended) 两个标志位拼出来:
        # 0=OFF(未附着) 1=ATT(已附着) 2=SUSP(挂起)。组合 (0,1) 结构不可达,
        # TB 单独数 n_impl, 不计入矩阵。
        "visit": r"停留拍数:.*?OFF=(\d+).*?ATT=(\d+).*?SUSP=(\d+)",
        "states": {0: "OFF", 1: "ATT", 2: "SUSP"},
        # 照两个标志位的次态逻辑逐条抄:
        #   connected_nxt = usb_rst ? 0 : con_cond ? 1 : connected
        #   suspended_nxt = usb_rst ? 0 : sus_cond ? 1 : (rsm_cond|rst_cond) ? 0 : suspended
        #   OFF→OFF (空闲) / OFF→ATT (con_cond)
        #   ATT→OFF (usb_rst) / ATT→ATT (空闲, 含 rst_cond 只清 suspended 那一拍) / ATT→SUSP (sus_cond)
        #   SUSP→OFF (usb_rst) / SUSP→ATT (rsm_cond 或 rst_cond) / SUSP→SUSP (空闲)
        "legal": {(0, 0), (0, 1), (1, 0), (1, 1), (1, 2),
                  (2, 0), (2, 1), (2, 2)},
    },
    "deserial": {
        "title": "RX deserial (usb_rx_deserial)",
        "visit": r"停留拍数:.*?IDLE=(\d+).*?SEEK=(\d+).*?DATA=(\d+).*?ERROR=(\d+)",
        "states": {0: "IDLE", 1: "SEEK", 2: "DATA", 3: "ERROR"},
        # IDLE→IDLE / IDLE→SEEK (首个 0) / SEEK→SEEK / SEEK→DATA (SYNC 命中)
        # SEEK→IDLE (0 太多 或 假触发) / DATA→DATA / DATA→IDLE (EOP 正常关包)
        # DATA→ERROR (EOP 错 或 7 连 1) / ERROR→ERROR / ERROR→IDLE (SE0→J 或 7 连 1 再现)
        # 另: 各态因 tx_active/rx_abort 强退回 IDLE —— 目标仍是 IDLE, 不新增弧。
        "legal": {(0, 0), (0, 1), (1, 1), (1, 2), (1, 0), (2, 2),
                  (2, 0), (2, 3), (3, 3), (3, 0)},
    },
    "sie": {
        "title": "SIE 事务层 (usb_sie)",
        "visit": r"停留拍数:.*?IDLE=(\d+).*?DWAIT=(\d+).*?TX=(\d+).*?HSW=(\d+)",
        "states": {0: "IDLE", 1: "DATA_WAIT", 2: "TX", 3: "HS_WAIT"},
        # 照次态 case 逐条抄:
        #   IDLE→IDLE (非 OUT/SETUP token) / IDLE→DATA_WAIT (token 派发)
        #   DATA_WAIT→DATA_WAIT (收尾未完 / 新 token 重新武装)
        #   DATA_WAIT→IDLE (数据包结论 或 周转超时)
        #   另: usb_rst 把任意态清回 IDLE —— 各态→IDLE 不新增弧。
        # ★ T_TX / T_HS_WAIT 次态恒为 IDLE, 但本轮只做接收, 没有任何弧进得来,
        #   所以它俩的行列全 0 是结构性的 (等发包轮落地再补入口弧)。
        #   default 分支同理不可达 (2 bit 状态码已全枚举), 不计入。
        "legal": {(0, 0), (0, 1), (1, 0), (1, 1)},
        "unreachable": [2, 3],
    },
}

DEFAULT_PROFILE = "tx"

# 一行迁移矩阵: `    from 3:       0      0      0     35      5      0 `
# ★ 列数不写死 —— 由 profile 的 states 长度定, 免得像之前那样 4 态改成 6 态时,
#   正则只吃前 4 列 (余下列被静默丢掉, 缺口查不出来)。
RE_ROW = re.compile(r"from\s+(\d):\s+((?:\d+\s*)+)")


def parse_log(path, re_visit, n):
    """从一个用例日志里取出 (停留拍数[n], 迁移矩阵[n][n]); 没找到返回 None。"""
    txt = open(path, encoding="utf-8", errors="replace").read()
    m = re_visit.search(txt)
    if not m:
        return None
    visit = [int(x) for x in m.groups()]
    arc = [[0] * n for _ in range(n)]
    for fm in RE_ROW.finditer(txt):
        r = int(fm.group(1))
        if 0 <= r < n:
            arc[r] = [int(x) for x in fm.group(2).split()][:n]
    return visit, arc


def main(argv):
    # ---- 参数解析: [--profile <PROFILES 里的键>] <日志 glob>... ----
    profile = DEFAULT_PROFILE
    paths = []
    i = 0
    while i < len(argv):
        if argv[i] == "--profile":
            i += 1
            if i >= len(argv) or argv[i] not in PROFILES:
                print("错误: --profile 需要 %s 之一" % "|".join(PROFILES), file=sys.stderr)
                return 2
            profile = argv[i]
        else:
            paths.append(argv[i])
        i += 1
    prof = PROFILES[profile]
    state = prof["states"]
    legal = prof["legal"]
    n = len(state)                                  # 状态数 = 矩阵维度 (由 profile 决定)

    if not paths:
        paths = ["cov/fsm_*.log", "cov/dat/*.log", "sim_tx_*.log"]
    logs = []
    for p in paths:
        logs.extend(sorted(glob.glob(p)))
    if not logs:
        print("错误: 没有匹配到日志文件 (提示: 日志须含 TB 的 print_fsm_coverage 输出)",
              file=sys.stderr)
        return 1

    visit = [0] * n
    arc = [[0] * n for _ in range(n)]
    used = 0
    for path in logs:
        got = parse_log(path, re.compile(prof["visit"]), n)
        if got is None:
            continue
        used += 1
        v, a = got
        for r in range(n):
            visit[r] += v[r]
            for c in range(n):
                arc[r][c] += a[r][c]

    print("==== %s FSM 覆盖率 (合并 %d 个用例日志) ====" % (prof["title"], used))
    print()
    print("  状态停留拍数 (合并):")
    for r in range(n):
        print("    %-10s %8d" % (state[r], visit[r]))
    unvisited = [state[r] for r in range(n) if visit[r] == 0]

    print()
    print("  迁移矩阵 (行=from, 列=to, 合并拍数):")
    print("               to: " + "".join("%10s" % state[c] for c in range(n)))
    for r in range(n):
        print("      from %-10s " % state[r] + "".join("%10d" % arc[r][c] for c in range(n)))

    # ---- 逐弧判定: 只对"设计意图内"的弧要求覆盖 ----
    missing = [(state[r], state[c]) for (r, c) in sorted(legal) if arc[r][c] == 0]
    hit_illegal = [(state[r], state[c], arc[r][c]) for r in range(n) for c in range(n)
                   if arc[r][c] > 0 and (r, c) not in legal]

    print()
    print("  合法弧覆盖: %d/%d" % (len(legal) - len(missing), len(legal)))
    # profile 可声明"本轮结构上到不了"的状态 (如发包轮的编码预留态):
    # 它们不进缺口, 单独列出来, 免得把"本轮不做"当成"没测到"。
    locked = set(state[r] for r in prof.get("unreachable", []))
    if locked:
        print("  ○ 本轮结构不可达 (不发缺口): %s" % ", ".join(sorted(locked)))
    unvisited = [s for s in unvisited if s not in locked]
    if unvisited:
        print("  ✗ 未停留过的状态: %s" % ", ".join(unvisited))
    if missing:
        print("  ✗ 未覆盖的合法弧:")
        for a, b in missing:
            print("      %s → %s" % (a, b))
    if hit_illegal:
        print("  ⚠ 出现了设计意图外的迁移 (需人工确认; 若属正常路径, 应把它加进 PROFILE):")
        for a, b, n in hit_illegal:
            print("      %s → %s (%d 次)" % (a, b, n))

    ok = not unvisited and not missing
    print()
    print("==== FSM: %s ====" % ("全状态 + 全合法弧已覆盖" if ok else "存在缺口"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
