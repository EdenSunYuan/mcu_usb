"""波形信号分组：布局代数 + .wvs 序列化（纯函数，不依赖 Qt）。

数据结构（踩坑与不变量见 `bug.md` B11）：

- ``order: list[str | SignalGroup]`` 是**顶层序列**，按显示顺序排列。
  顶层信号的 vcd_id 直接放在这里；一个组在 `order` 里只占**一个元素**，成员存在
  ``group.members`` 里。即：**每个信号恰好存在于一处**（要么顶层、要么某个组的 members），
  组与成员天然连续。
- **为什么不用"连续即成员"**：那样组一旦出现，它**后面**的所有信号都算它的成员 ——
  ① 非连续多选建组会把夹在中间没选中的信号一起吞进组；② "移出分组"插到哪儿都仍在某组名下，
  动作等于没做。显式成员表没有这两个坑，代价是成员与顺序两处状态，靠下面的函数统一维护。
- `rows(order)` / `visible_rows(order)` 把 `order` **展开**成逐行序列（行号 == 索引，
  元素是 vcd_id 或组头对象），这就是 `WaveformScene._displayed` 的内容。
- 组头行也只占一个 ROW_HEIGHT，所以行高统一，既有几何 / 命中测试 / 滚动同步都不用动。

本模块不做任何 Qt 依赖，便于在 `bug.md` 的自查块里直接单测。
约定：结构性函数**就地修改**传入的 order（与 `_displayed` 原地改的理由相同：保住引用），
同时把它返回以便链式调用；字符串本身不可变，共享无副作用。
"""

import itertools

__all__ = [
    "SignalGroup", "is_group", "rows", "all_rows", "visible_rows", "row_owners",
    "rows_of_group",
    "groups_in_order", "find_group", "group_at_row", "counts",
    "group_from_rows", "add_to_group", "remove_from_group", "remove_group",
    "move_rows", "move_group_to_row", "insert_rows", "anchor_at",
    "rename_group", "remove_signal",
    "order_to_records", "records_to_order",
]


class SignalGroup:
    """波形区的一个分组：既是那一行组头，也是成员信号的容器。

    `members` 是成员 vcd_id 列表（按显示序，允许重复 —— 同一个信号可以加两次）。
    """

    __slots__ = ("name", "collapsed", "hidden", "gid", "members")
    _seq = itertools.count(1)

    def __init__(self, name: str, collapsed: bool = False, hidden: bool = False,
                 gid: int | None = None, members=None):
        self.name = name
        self.collapsed = bool(collapsed)
        self.hidden = bool(hidden)
        self.gid = next(SignalGroup._seq) if gid is None else gid
        self.members = list(members) if members else []

    def __repr__(self) -> str:
        return (f"SignalGroup({self.name!r}, {len(self.members)} members, "
                f"collapsed={self.collapsed}, hidden={self.hidden}, gid={self.gid})")


def is_group(item) -> bool:
    """该行是不是组头行。"""
    return isinstance(item, SignalGroup)


# ── 展开成行序列 ───────────────────────────────────────────────────────────

def _expand(order: list, include_hidden: bool) -> tuple[list, list]:
    """展开成 (行序列, 逐行归属)。

    行序列元素 = vcd_id 或组头对象；逐行归属 = 该行所属的组（组头行归它自己，顶层信号为 None）。
    include_hidden=True 时忽略折叠 / 隐藏，展开成"完整逻辑序列"（存盘与定位用）。
    """
    row_list, owners = [], []
    for item in order:
        if is_group(item):
            if item.hidden and not include_hidden:
                continue
            row_list.append(item)
            owners.append(item)
            if include_hidden or not item.collapsed:
                for m in item.members:
                    row_list.append(m)
                    owners.append(item)
        else:
            row_list.append(item)
            owners.append(None)
    return row_list, owners


def rows(order: list) -> tuple[list, list]:
    """渲染用的 (行序列, 逐行归属)：隐藏组整块去掉，折叠组只留组头。"""
    return _expand(order, False)


def all_rows(order: list) -> tuple[list, list]:
    """完整逻辑序列（忽略折叠 / 隐藏）：`.wvs` 存盘与"行号→位置"换算用。"""
    return _expand(order, True)


def visible_rows(order: list) -> list:
    """只要渲染行序列。"""
    return _expand(order, False)[0]


def row_owners(order: list) -> list:
    """只要逐行归属（长度 == 渲染行数）。"""
    return _expand(order, False)[1]


def groups_in_order(order: list) -> list[SignalGroup]:
    """按显示顺序列出所有组（含隐藏的）。"""
    return [it for it in order if is_group(it)]


def find_group(order: list, gid: int) -> SignalGroup | None:
    """按 gid 找组 —— 菜单回调里存 gid 而不存对象引用，避免结构变更后指向旧对象。"""
    for it in order:
        if is_group(it) and it.gid == gid:
            return it
    return None


def group_at_row(order: list, row_index: int) -> SignalGroup | None:
    """渲染行 row_index 所属的组；顶层信号行返回 None；组头行返回它自己。

    注意必须正序推导，不能往回扫最近的组头 —— 组块之后可以再跟顶层信号。
    """
    rl, owners = rows(order)
    if 0 <= row_index < len(rl):
        return owners[row_index]
    return None


def rows_of_group(order: list, group: SignalGroup, include_hidden: bool = False) -> list[int]:
    """该组在（渲染）序列里占用的行号：组头那一行 + 展开时的各成员行。

    拖动整组时用它算出"这一块到底占几行" —— 少算成员行会让落点换算整体偏移。"""
    return [i for i, (c, _o) in enumerate(_locs(order, include_hidden)) if c is group]


def counts(order: list) -> tuple[int, int]:
    """(信号总数, 组数) —— 信号数含被折叠 / 隐藏组里的成员。"""
    n = sum(len(it.members) if is_group(it) else 1 for it in order)
    m = sum(1 for it in order if is_group(it))
    return n, m


# ── 内部：按下标取行 ───────────────────────────────────────────────────────

def _locs(order: list, include_hidden: bool = False) -> list:
    """逐行的位置描述 = (container, offset)。

    container=None → 顶层，offset 是它在 `order` 里的下标；
    container=组   → 组内成员，offset 是它在 group.members 里的下标；
    offset=-1      → 组头行本身。
    """
    out = []
    for oi, item in enumerate(order):
        if is_group(item):
            if item.hidden and not include_hidden:
                continue
            out.append((item, -1))
            if include_hidden or not item.collapsed:
                for mi in range(len(item.members)):
                    out.append((item, mi))
        else:
            out.append((None, oi))
    return out


def _take_rows(order: list, locs: list, row_indices) -> tuple[list, list]:
    """把 row_indices 这几**行信号**就地摘出来（组头行忽略）。

    返回 (取出的 vcd_id 列表, 删除记录)；删除记录 [(container, offset)] 与取出的一一对应，
    调用方用它把"锚点在新结构里的位置"换算回去。
    """
    picks = []
    for ri in sorted(set(row_indices)):
        if not (0 <= ri < len(locs)):
            continue
        container, offset = locs[ri]
        if offset < 0:                      # 组头行不参与"取出一批信号"
            continue
        value = order[offset] if container is None else container.members[offset]
        picks.append((container, offset, value))
    for container, offset, _ in reversed(picks):        # 同一容器内 offset 递增，倒序删不漂移
        if container is None:
            del order[offset]
        else:
            del container.members[offset]
    return [v for _, _, v in picks], [(c, o) for c, o, _ in picks]


def _shifted(offset: int, container, deleted: list) -> int:
    """把锚点 offset 换算到删除之后的值：减去同一容器里、排在它前面的被删项。"""
    return offset - sum(1 for c, o in deleted if c is container and o < offset)


def _anchor_at(locs: list, dest_row: int) -> tuple:
    """把「展开序列里的插入位 dest_row」换算成 (container, offset)。

    dest_row = 0..len(locs)：0 = 最前，N = 第 N-1 行之后（N == 行数即"最后一行之后"）。
    **落点决定归属**（Verdi 风格，与拖拽同一条规则）：上一行是组头 → 进该组首位；
    上一行是成员 → 接在它后面（仍在组内）；上一行是顶层信号（或没有上一行）→ 顶层。
    组块不允许嵌套，所以组头行只能引出"进组首"，不会引出"再套一层组"。
    """
    dest = max(0, min(dest_row, len(locs)))
    if dest == 0:
        return (None, 0)
    container, offset = locs[dest - 1]
    return (container, 0) if offset < 0 else (container, offset + 1)


# ── 结构性操作（就地修改 order 并返回它） ───────────────────────────────────

def group_from_rows(order: list, name: str, row_indices, collapsed: bool = False,
                    hidden: bool = False, gid: int | None = None) -> SignalGroup:
    """用选中的渲染行建一个新组，返回新组（没选中任何信号则不建组、不插进 order）。

    新组插在**第一个被选中信号原来的位置** —— 夹在中间没选中的信号留在原地，不会被吞进组。
    """
    locs = _locs(order)
    idxs = [r for r in sorted(set(row_indices))
            if 0 <= r < len(locs) and locs[r][1] >= 0]
    group = SignalGroup(name, collapsed=collapsed, hidden=hidden, gid=gid)
    if not idxs:
        return group
    container, offset = locs[idxs[0]]
    anchor = (order.index(container) + 1) if container is not None else offset
    members, _ = _take_rows(order, locs, idxs)
    group.members = members
    order.insert(anchor, group)
    return group


def add_to_group(order: list, row_indices, group: SignalGroup) -> list:
    """把选中的渲染行并入 group（追加到组内末尾）。"""
    if group not in order:
        return order
    locs = _locs(order)
    members, _ = _take_rows(order, locs, row_indices)
    if members:
        group.members.extend(members)
    return order


def remove_from_group(order: list, row_indices) -> list:
    """把选中的渲染行移出所在的组，放到**该组之后**成为顶层信号。

    本来就在顶层的行不受影响；不属于任何组的选中集是空操作。
    """
    locs = _locs(order)
    idxs = [r for r in sorted(set(row_indices))
            if 0 <= r < len(locs) and locs[r][1] >= 0]
    src = [locs[r][0] for r in idxs if locs[r][0] is not None]
    if not src:
        return order
    members, _ = _take_rows(order, locs, idxs)
    if not members:
        return order
    ends = [order.index(c) + 1 for c in dict.fromkeys(src) if c in order]
    at = max(ends) if ends else len(order)
    order[at:at] = members
    return order


def remove_group(order: list, group: SignalGroup, keep_signals: bool = True) -> list:
    """删掉组头。keep_signals=True → 成员升为顶层、留在原位置（取消分组）；False → 连成员一起删。"""
    if group not in order:
        return order
    i = order.index(group)
    if keep_signals:
        order[i:i + 1] = list(group.members)
    else:
        del order[i]
    return order


def move_rows(order: list, row_indices, dest_row: int) -> list:
    """把选中的行整块拖到 dest_row 处 —— **dest_row 以"摘除被拖行之后"的序列为准**
    （0..剩余行数），与 `SignalLabelScene.end_drag` 的 target 语义一致。

    **落点决定归属**（Verdi 风格）：落在某组成员之间 → 并入该组；落在组头正下方 → 并入组首；
    落在顶层信号之后或序列最前 → 成为顶层信号。组块不允许嵌套。
    """
    locs = _locs(order)
    idxs = [r for r in sorted(set(row_indices))
            if 0 <= r < len(locs) and locs[r][1] >= 0]
    if not idxs:
        return order
    moved_set = set(idxs)
    survivors = [i for i in range(len(locs)) if i not in moved_set]
    # 锚点在"摘除被拖行之后"的序列里算，规则与 insert_rows 共用 _anchor_at
    target = _anchor_at([locs[i] for i in survivors], dest_row)
    moved, deleted = _take_rows(order, locs, idxs)
    if not moved:
        return order
    container, at = target
    if container is None:
        pos = _shifted(at, None, deleted)
        order[pos:pos] = moved
    else:
        if container not in order:
            return order
        pos = _shifted(at, container, deleted)
        container.members[pos:pos] = moved
    return order


def move_group_to_row(order: list, group: SignalGroup, dest_row: int) -> list:
    """把 group 整块拖到 dest_row 处（同样以"摘除本组各行之后"的序列为准）。

    只改它在顶层序列里的位置，成员不动；落进别的组内部会被钳到那个组之后（组块不嵌套）。
    """
    if group not in order:
        return order
    locs = _locs(order)
    block = {i for i, (c, _o) in enumerate(locs) if c is group}
    survivors = [i for i in range(len(locs)) if i not in block]
    dest = max(0, min(dest_row, len(survivors)))
    if dest == 0:
        at = 0
    else:
        container, offset = locs[survivors[dest - 1]]
        at = (order.index(container) + 1) if container is not None else offset + 1
    gi = order.index(group)
    del order[gi]
    if at > gi:
        at -= 1
    order.insert(min(at, len(order)), group)
    return order


def anchor_at(order: list, dest_row: int) -> tuple:
    """`_anchor_at` 的公开版：给定展开序列的插入位，问"会落到哪个容器里"。

    返回 (container, offset)，container=None 表示顶层、是 SignalGroup 表示会进这个组。
    调用方靠它判断"新行会不会进一个折叠的组"之类的落点后果，不用自己再算一遍布局。
    """
    return _anchor_at(_locs(order), dest_row)


def insert_rows(order: list, values, dest_row: int) -> list:
    """在展开序列的 dest_row 处插入若干**新信号**（"添加新波形时插在选中行下面"）。

    dest_row 与 `SignalLabelScene` 的渲染行号同坐标（0..行数，**不含被隐藏组的行**），
    所以调用方直接把选中行号 +1 传进来即可。**落点决定归属**：插在组头正下方 → 成为该组
    首位成员；插在某成员之后 → 接在它后面（仍在组内）；插在顶层信号之后或序列最前 → 顶层。
    新增的行恒为**顶层或某组成员**，不会新建组。

    坑：dest_row 是**展开序列**的行号，绝不能拿它去 `order.insert()` —— `_order` 里隐藏组的
    成员也在，两个下标空间差了"隐藏组成员数 + 隐藏组头数"（见 bug.md B12）。
    """
    vals = [v for v in values if not is_group(v)]     # 新行只能是信号，组对象一律忽略
    if not vals:
        return order
    container, at = _anchor_at(_locs(order), dest_row)
    if container is None:
        order[at:at] = vals
    elif container in order:
        container.members[at:at] = vals
    return order


def rename_group(order: list, group: SignalGroup, new_name: str) -> list:
    """改组名（名字存在组对象上，order 本身不变）。"""
    if group in order and new_name:
        group.name = new_name
    return order


def remove_signal(order: list, vcd_id: str, count: int = 1) -> int:
    """按显示序删除前 `count` 个等于 vcd_id 的信号行（顶层或组内），返回实际删除数。

    走完整逻辑序列（含折叠 / 隐藏组的成员），所以收起的分组里也能删干净。
    """
    removed = 0
    while removed < count:
        hit = None
        locs = _locs(order, include_hidden=True)
        for container, offset in locs:
            if offset < 0:
                continue
            value = order[offset] if container is None else container.members[offset]
            if value == vcd_id:
                hit = (container, offset)
                break
        if hit is None:
            break
        container, offset = hit
        if container is None:
            del order[offset]
        else:
            del container.members[offset]
        removed += 1
    return removed


# ── .wvs 序列化 ────────────────────────────────────────────────────────────

def order_to_records(order: list) -> tuple[list[int], list[dict]]:
    """保存用：返回 (信号在完整逻辑序列里的行号, 组记录)。

    调用方按返回的行号顺序写 `signals[]`；组记录的 `members` 是**在 signals[] 里的下标**
    （不是 full_path —— 同一 full_path 可以出现多次，下标才唯一且精确）。
    走"完整逻辑序列"（含折叠 / 隐藏组成员），所以收起的分组也照样存下来。
    """
    rl, _ = all_rows(order)
    seq_of = {}
    n = 0
    for i, item in enumerate(rl):
        if not is_group(item):
            seq_of[i] = n
            n += 1
    sig_rows = [i for i in sorted(seq_of)]
    records = []
    for item in order:
        if not is_group(item):
            continue
        base = rl.index(item)               # 组头行号（SignalGroup 无 __eq__ → 按身份匹配）
        records.append({
            "name": item.name,
            "collapsed": item.collapsed,
            "hidden": item.hidden,
            "members": [seq_of[base + 1 + k] for k in range(len(item.members))
                        if base + 1 + k in seq_of],
        })
    return sig_rows, records


def records_to_order(slots: list, groups_json: list | None
                     ) -> tuple[list, list[SignalGroup], list[dict]]:
    """加载用：从 `.wvs` 重建 order，返回 (order, 组列表, 被丢弃的组记录)。

    slots: 第 i 项 = 第 i 条 `signals[]` 解析出来的 vcd_id（没能解析出来的槽位为 None）。
    用**槽位下标**认领成员，所以掉信号时：成员少一个、组不散架、重复项也不会串；
    一个成员都没解析出来的组整组丢弃并计入 dropped（调用方好写进加载报告）。
    """
    n = len(slots)
    owner: dict[int, int] = {}              # signals 下标 → groups 里的序号
    groups: list[SignalGroup] = []
    dropped: list[dict] = []
    for rec in (groups_json or []):
        if not isinstance(rec, dict):
            continue
        kept = [m for m in (rec.get("members") or [])
                if isinstance(m, int) and 0 <= m < n and slots[m]]
        if not kept:
            dropped.append(rec)
            continue
        group = SignalGroup(rec.get("name") or "Group",
                            collapsed=rec.get("collapsed"),
                            hidden=rec.get("hidden"))
        gi = len(groups)
        groups.append(group)
        for m in kept:
            owner[m] = gi

    order: list = []
    emitted: set[int] = set()
    for i, vid in enumerate(slots):
        if vid is None:
            continue
        gi = owner.get(i)
        if gi is None:
            order.append(vid)
            continue
        if gi in emitted:                   # 该组已在第一个存活成员处整块吐出
            continue
        emitted.add(gi)
        group = groups[gi]
        group.members = [slots[m] for m in range(n) if owner.get(m) == gi]
        order.append(group)
    return order, groups, dropped
