# wave_debugger.py — 历史 Bug / 陷阱台账（自查手册）

> 目的：改动本工具前先翻这页，遇到同类症状快速定位，别重复踩坑。
> 只记**真实遇到过、已修复**的问题；每条含 症状 / 根因 / 修法 / 自查。
> 对应源码：`tools/wave_debugger.py`（改动后保持 `python3 -m py_compile` 通过）。
> 参考仿真：`sim/deserial/deserial_out_normal.vcd`（注意其 id 冲突特性，见 B2）。

---

## B1 — QSS `font-size` 覆盖 per-widget `QFont(pt)`，字号怎么调都不生效
- **时间/场景**：2026-09-04 会话；Settings 调字号。
- **症状**：代码窗口设了 15pt 仍渲染成 11px；`QFont.pointSize()` 返回 -1（实际走 pixel）。
- **根因**：全局/局部样式表里写了 `QTreeView{font-size:11px}`、`QPlainTextEdit{font-size:11px}`、信号面板自带 `QTreeView{...font-size:11px}`；祖先/控件局部 QSS 的 px 字号**优先级高于** `widget->setFont(QFont(pt))`。
- **修法**：把可变控件的 **px 字号规则从 QSS 里删掉**（只留背景/border/选中色）；字号统一走每窗口 `QFont`(pt)，`__init__` 建好布局后 `_apply_font_size` 应用 4 默认值（tree14 / signal13 / code15 / wave11）。
- **自查**：要给某个子窗口加字号，永远改 `_apply_font_size` 对应 target，别往该控件样式表写 `font-size`。断言：`code_panel.editor.font().pointSize()==15`；若出现 `==-1` → 说明又有 QSS 覆盖了。

## B2 — VCD 信号 id（vcd_id）会在不同作用域复用 → vcd_id 不能当唯一键
- **时间/场景**：2026-09-04 会话；Trace 追溯时三条同名 `rx_bit` 都解析成同一条。
- **症状**：Icarus 本 VCD 里不同作用域的同名标量可能共用同一 id（实测 `tb_deserial.rx_bit`、`tb_deserial.u_cdr.rx_bit`、`tb_deserial.u_dut.rx_bit` 的 `$var` id **全是 `$`**，405 条 var 里 15 组撞号）。`analyzer.engine.signals` 按 vcd_id 建 dict，撞号时**后写的覆盖先写的** → `cache.get_signal('$')` 永远返回最后一个（u_dut 那条）。
- **修法**：任何"从用户点中的信号反查定义/源码"的路径（Trace Driver/Uses、波形双击定位）一律用**唯一 `full_path`**：右键/双击处发 `sig.full_path`，主窗 `_sig_from_key(key)` 走 `engine.by_path.get(key)` 解析（by_path 键唯一），失败再回落 signals/header。
- **自查**：`full_path` 在 VCD 内应唯一；若想确认某 VCD 是否撞号：数 `$var` 行 vs `$var` 的 id 列去重数，不等即撞号。新加任何按 id 查信号的功能前先想清楚有没有撞号风险。

## B3 — 驱动追溯"上爬"时 `find_instance_connects` 传错模块类型名
- **时间/场景**：2026-09-04 会话；Trace Driver 输入端口用例。
- **症状**：`u_dut.rx_bit`（usb_rx_deserial 的输入端口）报"上层未发现 .rx_bit(…) 连接"，明明 tb 里 `usb_rx_deserial u_dut (.rx_bit(rx_bit))` 就在第 59 行。
- **根因**：`_driver_chain_rows` 里爬层时把**父模块名**（tb_deserial）当实例类型传给了 `find_instance_connects(ptext, parent_mod, inst, …)`；而该函数是在父文本里匹配 `\b<子实例类型> <实例名>\b`，需要的是**子实例的模块类型**（usb_rx_deserial）。
- **修法**：传当前层（被追踪的那层）的模块名 `mod`：`find_instance_connects(ptext, mod, inst, name)`。
- **自查**：Trace 一个 input 端口：日志应出现 1 条 `[使用·实参连线]`（上层实例行）+ 1 条真正驱动；只出现"未发现连接"就是此类问题。对照 tb 文本里 `usb_rx_cdr u_cdr (…` 看实例类型词。

## B4 — `module_port_directions` 非 ANSI 扫描范围错误 → 所有端口被标成 input
- **时间/场景**：2026-09-04 会话；纯函数单测。
- **症状**：解析 `usb_rx_deserial.v`（ANSI 头端口）时把 output 全判成 input。
- **根因**：非 ANSI 体内声明正则 `^\s*(input|output|inout)…([^;]*);` 把 ANSI 头部行 `input wire clk12m,` 也当"体内声明"扫到，group(2) 跨到第一个 `;`（即 `);`），把后面所有端口都覆盖成 input。
- **修法**：非 ANSI 声明只在**头部 `)` 之后**的 `body_tail = clean[close:]` 里扫（先 `_skip_paren_str` 定位头部闭括号）。
- **自查**：`module_port_directions(src/phy/usb_rx_deserial.v)` 应得 clk12m/rx_bit/rxdp…=input、rx_data/rx_valid/rx_active/rx_error/line_state=output。凡是出现"已知输出端口被当输入"即中此招。

## B5 —（历史）Load Session 旧版会强制开会话自带 VCD + 危险"取同名第一个"兜底
- **时间/场景**：跨 case 复用会话功能的前期版本（README 已实现新版）。
- **症状**：当前已开 VCD 时 Load 旧会话会切走当前波形；匹配不上的信号静默 `print` 且用 `endswith('.'+leaf)` 取第一个，可能把同名的另一个作用域信号加错。
- **修法**（现版）：`resolve_session_signals(entries, current_sigs, resolver)` 结构化匹配（精确 → 模块结构适配 → 失败分类），`_load_session` 按"当前 VCD 相同=完整恢复 / 不同=映射到当前 VCD 不切走"，失败一律弹报告对话框，不再静默兜底。
- **自查**：涉及会话匹配改动先跑：同 tb 重跑（完整恢复）/ 不同 tb（映射、不切 VCD）/ 未开 VCD（自动开）。

## B6 —（易踩，非 bug）静态分析返回"模块内相对行号"，写日志/跳转要加 base
- 说明：`module_region_of` 给出 `(region, base)`，`analyze_signal_refs` 的行号相对 region 开头。凡转成文件绝对行号都要 `base + line`（Trace 里每行都这么加）。不加就会出现日志行号偏小、跳到错误的行。
- **自查**：Trace Driver 某 reg，日志里 `usb_rx_deserial.v:442` 应与源码里 `rx_valid <= rx_valid_nxt;` 真实行一致。

## B7 — 代码窗口右键 Trace 在“同名多信号”时整块消失（看着像“没法在代码窗口 trace”）
- **时间/场景**：2026-09-14 会话；用户报"工具无法在代码窗口选中信号直接 trace"。
- **症状**：代码窗口右键 `rx_bit`（`tb_deserial.v:59`）只弹出 `Signals matching 'rx_bit' (3)` 与 `Add ALL`，**没有任何 Trace Driver / Trace Uses 入口**；而 `EOP_SE0_TIME`（全 VCD 唯一）能正常弹出 Trace。
- **根因**：`_show_signal_menu` 旧逻辑 `if len(sigs) == 1:` 才挂 Trace 项。VCD 里同名信号天然分布在多个作用域（撞号 + 层次重名，`rx_bit` 3 条、`pid_type` 10 条、`cyc` 25 条）→ 树里几乎永远 >1 → 追溯入口被整块藏掉（信号面板单选不受影响，故只有代码窗口"不能 trace"）。
- **修法**：Trace 入口**恒显示**。① `_preferred_sig_for_word` 按当前代码作用域（`_scope_context` / `_derive_context_from_file` + `_scope_matches`，与双击加波形同一套规则）过滤，再按"最浅层唯一"定夺 → 唯一时给 `🔍 Trace Driver（追溯驱动源码）→ <full_path>`；② 仍有同深度多条 → 改**子菜单逐条列出 full_path**（发出的键一律 `full_path`，遵守 B2）。
- **配套**：右键目标词从"光标下单词"升级为 `_menu_word_at`，优先级：**选区中的标识符/点分路径**（右键须落在选区内，陈旧选区忽略）→ 光标下的**点分路径**（`u_dut.rx_error`，把同名缩到一条）→ 单词。选区两端允许带 `;`/`,`/`()`（拖选常带上）。
- **自查**：`tb_deserial.v` 右键 `rx_bit` → 菜单出现 `Trace Driver → tb_deserial.rx_bit`（作用域法选中 tb 自己的 wire）；点 `u_dut.st_stat_cur` 的 `st_stat_cur` → 识别词必须是 `u_dut.st_stat_cur` 且候选 1 条；`pid_type` → 必须出现 `Trace Driver ▸` 子菜单且触发后日志有 `🔍 Trace Driver — …` 行。

## B8 — 标签列滚轮只滚左边，右侧波形不跟随（信号多时明显）
- **时间/场景**：2026-09-14 会话；用户报"信号加多了、鼠标上下滚时右侧波形不跟着翻"。
- **症状**：加了 40+ 信号后，鼠标停在**左侧信号名列**上滚动 → 只有标签列在动，右边波形不动（反向：滚在波形区时两列同步）。
- **根因**：① 同步是**单向**的（`wave_view.verticalScrollBar().valueChanged → label_view`），标签列上的 Wheel 没人处理 → 落到 `QGraphicsView` 默认滚动 → 只滚自己；② 两视图视口高度不同（波形列水平滚动条 `AlwaysOn`、标签列 `AlwaysOff`）→ 垂直 range 差一个滚动条高度（实测 834 vs 824），直接搬 scrollbar 数值到两端会错位半行。
- **修法**：① 滚轮统一走 `_handle_wheel(wheel, source_view)`，波形区/标签列共用；**垂直滚动一律驱动 `wave_view`，它是唯一真源**，标签列由 `_sync_v_scroll` 跟随（标签列上 Ctrl+滚仍缩放、Shift+滚仍水平滚）。② 同步改成对齐**"视口左上角对应的场景 Y"**（`mapToScene(0,0)`）而不是搬数值 → 两端也不漂。③ `SignalLabelScene.extra_height` = 两视口高度差，场景高改为 `max(h,200) + extra_height`，使两列 range 相等、**场景小于视口时的居中偏移也相等**（少信号时不再错半个行高）。
- **自查**：3 / 40 / 120 信号三档下，`wave_view.mapToScene(0,0).y() - label_view.mapToScene(0,0).y()` 在顶部、底部、连续滚轮后都必须恒为 `0`，且两列 `verticalScrollBar().maximum()` 相等。

## B9 — `wire X = expr;`（网络声明即赋值）被当成"纯声明" → Trace Driver 误报"未见明确驱动"、Trace Uses 整片漏行
- **时间/场景**：2026-09-15 会话；用户报"trace 显示的不全"。
- **症状**：`sim/deserial/usb_rx_deserial_gate.v` 的 `byte_rdy`（写法是 `wire byte_rdy = …`）Trace Driver 输出
  `⚠ 模块 … 内未见明确驱动，下列为相关引用（候选）`；同文件的 `in_frame`/`seven_ones_data`、`src/common/*.v` 的
  组合线同样。Trace Uses 则整片漏行（每一条 `wire X = (…var…)` 都不见了）。
  > 报错现场最初是 `usb_rx_deserial.v`；该文件 2026-09-20 按规则 7 重写后**已改成 `assign`**
  > （20 处 `assign` / 0 处 `wire X = expr;`），故本条的复现样本转到**冻结的 sim 变体**
  > `usb_rx_deserial_gate.v`（16 处）与 `src/common/*.v`（crc5/crc16/bit_stuff/bit_unstuff）。
  > **修法本身不能撤**：宽限名单里的模块仍全是这种写法。
- **根因**：`analyze_signal_refs` 只把 `assign X = …` / 过程赋值当驱动；行首是 `wire` 的行一律 `role="decl"`。
  本项目**宽限名单里的 RTL 主要就写 `wire X = expr;`**（`usb_rx_deserial_gate.v` 16 处 vs 2 处）→ 这些行对 Trace 完全不可见
  （Trace Uses 明确过滤掉 `decl`；Trace Driver 的 `drivers` 过滤 `role.startswith("driver")` 也收不到）。
- **修法**：新增纯函数 `_decl_is_netinit(line, name)`：声明行里按**顶层逗号**逐条 declarator 判，若 `name` 是该 declarator
  `=` 左边的**被声明名**且类型是**网络**（无 `reg/integer/real/time/parameter/localparam/genvar`）→ 判为
  `driver:netinit`（隐式连续驱动），否则仍 `decl`。要点：必须取"`=` 左边最后一个标识符 == name"，否则
  `wire in_frame = (st_state == …)` 会被误判成 st_state 的驱动（RHS 引用不是驱动）。`_ROLE_META` 增标签
  `驱动 · 声明赋值`。行首关键词正则提为模块级 `_DECL_LINE_RE`（`analyze_signal_refs` 与 `_decl_is_netinit` 共用一份）。
- **自查**：纯函数用例见下方自检脚本（含 `wire X = expr;` 的 9 条）；真 RTL 上拿 `src/common/usb_bit_stuff.v`
  或 `sim/deserial/usb_rx_deserial_gate.v` 的任一 `wire X = …` 验证 `[驱动 · 声明赋值]`。
  注意 `usb_rx_deserial.v:188` 的 `assign in_frame = (st_stat_cur[1:0] == USB_DATA) || …` 是 `assign` 写法，
  走的是普通 driver 路径，与 B9 无关。

## B10 — 状态名识别只认 `localparam NAME = …`，带位宽范围的 `localparam [1:0] NAME = …` 一条都匹配不上 → "未识别"
- **时间/场景**：2026-09-17 会话；用户报"换一个 rtl 代码和仿真以后，波形信号显示状态机名称时未识别，明明 rtl 中是有的"。
- **症状**：`usb_tx_serial.v` 的 `st_state`（该文件写 `localparam [1:0] S_IDLE = 2'd0;`）右键 → Radix → Show State Names
  弹出"未从模块源码识别到与 st_state 一起使用的状态常量"；当时 `usb_rx_deserial.v` 的 `st_state`（写 `localparam ST_… = …`，无范围）却正常。
  > 两侧现在**都**带位宽范围了（`localparam [1:0] USB_IDLE = 2'd0;`），这条对照已不存在；
  > 另有一个**同症状但不同根因**的坑见 **B14**（`case (var[1:0])` 位选），改状态名识别前两条都要看。
- **根因**：`detect_fsm_state_map` 收集常量的正则写死为 `(?:localparam|parameter)\s+(\w+)\s*=\s*…`，**要求关键字后紧跟名字**。
  `localparam [1:0] S_IDLE = 2'd0;` 中间夹着 `[1:0]` → 一条都匹配不到 → `pval` 为空 → 函数开头 `if not pval: return {}` 直接返回空表。
  即"换一份 RTL 就不认识"，与 VCD / 仿真无关，纯源码风格差异。
- **修法**：常量收集重写为 `_collect_param_values(text)`（纯函数），覆盖四种玩法：
  ① 关键字与名字之间可夹**范围/类型**限定词（`[1:0]`、`signed`、`integer`、`logic`…），逐条剥掉；
  ② **一行多声明**（`localparam [1:0] A = 2'd0, B = 2'd1;` 按顶层逗号切开，每段都取 `=` 左边最后一个标识符当名字）；
  ③ **跨行声明**（从关键字起找顶层 `;`，不按行切）；
  ④ 值支持**字面量** / **引用其它常量** / **纯算术式**（`localparam S_B = S_A + 1;`）——`_eval_param_expr` 先把已知常量名替换成数值，
  再用 `^[0-9+\-*/() \t]+$` 卡死字符集 + 清空 builtins 的 `eval`，所以执行不到任何标识符或函数（还挡掉 `**`）；
  另加 SystemVerilog `enum {A, B, C}`（隐式 0,1,2…）识别。
  同时把"这个变量用到哪些常量"的扫描提为 `_params_used_with()`，并补一跳 **`_state_var_aliases()`**：两段式 FSM 常把比较/`case`
  写在次态变量上（`st_state <= st_nxt;` 而 `case (st_nxt)`），只看 `st_state` 会漏掉大半常量；只跳一跳且排除常量名，所以不会串别的状态机。
- **自查**：见下方 B10 自检脚本（13 条纯函数用例 + 真 RTL 三条）；GUI 实链：`sim/tx/tx_abort.vcd` 的
  `tb_tx_serial.u_tx.tx_stat_cur` → `{0:'S_IDLE',1:'S_SYNC',2:'S_DATA',3:'S_DATA_LAST',4:'S_EOP1',5:'S_EOP2'}`。
  > 两侧**不再同名**（tx 是 `tx_stat_cur`、rx 是 `st_stat_cur`），原"同 VCD 两个 `st_state` 各认各的"用例
  > 已随规则 7 改名失效；"不串扰"这条性质改由自检脚本里**同模块两套 FSM** 的用例守着（更强）。
- **易踩**：`0 <= val < (1 << width)` 的位宽过滤仍保留——8 位信号配 16 位常量会被丢掉，那是**正确行为**（用例里踩过一次，别误判成 bug）。

## B11 — 波形信号分组：`_order` 是主序、`_displayed` 是派生视图，别名 / 行高 / 槽位三条不变量
- **时间/场景**：2026-09-17 会话；用户要求"波形窗口信号支持分组，分组后可折叠 / 隐藏"。
- **背景（不是 bug，是必须先立的三条不变量）**：
  1. **`_displayed` 必须原地改，`_order` 必须原地改**。`SignalLabelScene.sync_from()` 做的是
     `self._displayed = waveform_scene._displayed`（**同一个 list 对象**），两列的行几何、命中测试、滚动同步全靠它。
     所以过滤只能写 `self._displayed[:] = wave_groups.visible_rows(self._order)` / `self._order[:] = order`，
     **一旦整体重新赋值（`self._displayed = ...`）标签列的别名立刻断掉** → 左右行数不一致、滚动错位。
  2. **组头行恰好占一个 `ROW_HEIGHT`**，所以 `_row_y` / `signal_at_y` / `_drop_index` / 滚动同步**一律不用改**；
     组名画在标签列（波形侧只画底色带 + 虚线中线）。
  3. **被折叠 / 隐藏的组成员仍留在 `_order` 里**。折叠只是不展开、隐藏只是整块不展开；因此 `.wvs` 存盘
     （`order_to_records` 走"完整逻辑序列"）能存到收起的分组，"加入折叠组"的插入位置也仍有定义。
- **踩过的三个真坑（都已修）**：
  - **① 位置成员模型（"成员 = 紧邻其前的组头"）是错的**：那样组一旦出现，它**后面**的信号全算它的成员 →
    ⓐ 非连续多选建组会把夹在中间没选中的信号一起吞进组；ⓑ "移出分组"插到哪儿都仍在某组名下，动作等于没做。
    改成**显式成员表**（`order: list[str | SignalGroup]` + `group.members: list[str]`，每个信号恰好存在于一处）；
    用户可见的拖拽行为不变（落点决定归属仍是 Verdi 风格）。
  - **② `move_signals_by_visible_indices` 改名后漏改调用点**：`eventFilter` 拖拽释放分支还在调旧名，
    纯函数级自测全过、一拖就 `AttributeError`。→ **必须用真实鼠标事件走一遍 `eventFilter`**（见下方 B11-GUI 自检）。
  - **③ 两个会拿到组头对象的入口**：`toggle_group_collapsed` 里 `group in self._order` 对**字符串**也成立
    （`in` 走 `==`），于是往 `str` 上挂 `.collapsed` 直接抛异常 → 先 `is_group()` 再判；
    `eventFilter` 点折叠三角曾写成 `self.label_scene.item_at_row(...)`（该方法在 `WaveformScene` 上）。
- **易踩（踩过 / 特意保留的语义）**：
  - **落点 y 用 `row_y(0)` 的下半行 = "插在第 0 行之后"**，不是"插到最前"。要拖到最前面得把插入线拉到标尺下沿
    （`_drop_index` 的 `_target_index_at_y` 在 y 位于某行中线上方时给的是"该行之前"）。
  - **拖到序列最末尾会并入末尾那个组**（末尾是组成员时，落点归该组）。这是"落点决定归属"的直接推论，**不是 bug**。
  - `QMenu` 一律 `menu.exec(global_pos)`，**不要用 `QToolButton.setMenu()`** —— 本文件的自查块把 `QMenu` 换成合成菜单
    `FM`，`setMenu` 拿到非 QMenu 会 `TypeError`（工具栏 📁 分组 因此改成 `clicked → _popup_group_menu`）。
  - `SignalGroup` **故意不实现 `__eq__`**：要的就是身份语义（`group in order`、当 dict 键、`_cache` 里按下标取）。
  - 序列化时 `groups[].members` 存的是 **`signals[]` 的下标**，不是 `full_path`：同一 full_path 允许出现多次，
    下标才唯一；`resolve_session_signals` 的返回与入参**同序**，所以槽位下标能一一对上。
- **自查**：见下方 **B11-纯函数** 与 **B11-GUI** 两个自检块（前者是布局代数，后者走真实鼠标事件 + 存盘往返）。

## B12 — 新增波形"插在选中行下面"：锚点是**渲染行号**，不是 `_order` 下标
- **时间/场景**：2026-09-18 会话；用户要求"添加新波形的时候，在选中的波形下面添加"（此前恒为追加到末尾）。
- **规则（`wave_groups.insert_rows` / `anchor_at`）**：`dest_row` 与标签列的**渲染行号同坐标**
  （0..行数，0 = 最前，N = 第 N-1 行之后；没选中时传 `None` = 追加到末尾）。归属走
  `_anchor_at`，**与拖拽 `move_rows` 共用同一条"落点决定归属"**：上一行是组头 → 进该组首位；
  是成员 → 接在它后面（仍在组内）；是顶层信号 / 没有上一行 → 顶层信号。
  于是"选中组内某条成员再添加"→ 新信号自动成为该组成员，这是特性不是 bug。
- **坑（写之前最容易踩的一条）**：`dest_row` **绝不能直接 `order.insert(dest_row, v)`**。
  `_order` 里还躺着**被隐藏组的组头与成员**（B11 不变量 3），两个下标空间差了"隐藏组头数 + 隐藏成员数"，
  隐藏的组一多插入点就整体前移、插到别的组头前面去。唯一正确的换算入口是
  `wave_groups._locs(order)`（隐藏组不展开）→ `_anchor_at`；`insert_rows` 与 `move_rows` 都走它，
  规则不会两边漂移。
- **配套行为（都在 `WaveformPanel.add_signals` 里，两条都是被实际需要逼出来的）**：
  - **加完把新行设为选中**（`_reselect_rows`）。否则每条新信号都插回同一个锚点，
    连续添加的顺序会**倒过来**；设成选中后锚点跟着往下走，越加越往下排。
  - **落点会进一个折叠的组时先 `set_group_collapsed(False)` 展开**。成员行收着，加完看不见，
    用户会以为"点了没反应"（`insert_rows` 本身不管折叠标志，是纯布局函数）。
  - 没选中任何行 → `at_row=None` → 保持原语义"追加为**顶层**信号"（不会落进末尾那个组里）。
- **自查**：见下方 **B12-纯函数** 与 **B12-GUI** 两块。

---

## B13 — 显示变量的某一位 / 位段（派生信号）：合成 key + 物化跳变表；顺带修"会话载回全行 no data"
- **时间/场景**：2026-09-20 会话；用户要求"能否支持显示变量其中一个 bit，例如 `rx_data[7:0]` 里只看 `rx_data[1]`"。
- **功能规则**：单个 bit 画成 1-bit 折线（高低电平），位段画成多 bit 总线（Hex/Bin/Dec/Oct 随便切）。
  入口两个：**波形标签列右键** → `➕ 显示位 ▸`（≤32 位逐位列出 + `指定位 / 位段…`；>32 位只留手输）、
  **RTL 代码窗口右键** → 同名候选**唯一**（按当前模块作用域消歧后）才给同一套子菜单。派生行右键则给 `↩ 显示完整信号`。
- **设计（关键：读路径零改动）**：派生行 = **合成字符串 key**（`<父vcd_id>[1]` / `<父vcd_id>[7:4]`，撞号追加 `#2`），
  `WaveformDataCache` 里两张注册表 `_slices` / `_slice_sigs` + 一张**物化**的跳变表
  （`add_slice`/`preload` 时把父表逐条切好存进 `_transitions[key]`）。
  于是 `get_visible` 的 bisect、`get_transitions`、`find_nearest_edge`、`_draw_scalar_trace`/`_draw_bus_trace` **一行都不用改**
  —— 切片在缓存里就是一条普通信号。父数据变了由 `_rematerialize_slices_of(父)` 重切。
- **顺带修掉的既有缺陷（实测确认，不是推测）**：`Ctrl+L` 载会话与 `Ctrl+R` 重载 VCD 之后**所有行都画成红框 "no data"**。
  根因：全文件只有 `WaveformPanel.add_signals` 一处调 `preload`，`_load_session` / `_on_reload_vcd` 只 `ws.set_order(order)` 就完事，
  缓存里一条跳变都没有（实测：手工加信号 `get_transitions=8`，会话载回后同一条 `=0`）。
  修法：抽出 `WaveformPanel.preload_ids(ids)`，两条路径在 `set_order` 之后各补一次（一次逗号 glob 拿全部 path，与手工逐条加等价）。
- **三条不变量（改这块前先看这三条）**：
  1. **派生 key 绝不能进 `engine` / glob**：`vcd_analyzer.match_signals` 把路径里的 `[` 当 fnmatch **字符类**，
     `rx_data[7:4]` 会变成"匹配 rx_data、7 或 4"的怪 pattern。所以 `preload` 先把 key 展开回**父 id** 再取数，
     `get_signal` 先查 `_slice_sigs` 再回落 engine，`_on_add_signals` 的状态机扫描要 `continue` 掉派生 id。
  2. **`add_slice` 必须"先注册、后 `add_signals`"**：`set_order` 期间就要能 `get_signal` 到它，否则行被当幽灵键丢掉。
     便利做法是面板 `add_bit_slice` 在 `add_signals` 之前把颜色/进制按父信号写好（同一套记账，且**不推进** `_color_index`）。
  3. **物化必须去重、但必须保住首条**：32 位计数器取 bit31，不去重就是 670 条全是同值（重绘 1.6ms → 11ms）；
     去重是"相邻同值跳过 `continue`"（保留第一条），**不能**写成"值没变就整表清空"——空表 = `if not trans` → 红框 no data。
- **值形状的坑（本次最容易写错的地方）**：
  - 缓存里的值串是 `format_value(raw, width)` 的输出，实测三种形状：1-bit 是裸 `'0'/'1'/'x'/'z'`；
    多 bit 干净值是 `8'hC3`；含 x/z 的多 bit 是**原始串且带尾空格**（`'bx '`，`int()` 失败时原样返回）。
  - `slice_bits` 返回值形状是给渲染层用的：**单 bit 一律裸字符**（`_draw_scalar_trace` 比的是 `ev_raw == '1'`），
    整段全 x/z 也返回裸 `'x'/'z'`，其余 `'b'+位串`（`_format_value_radix` 认 `b` 前缀，进制切换白拿）。
  - 短值（位宽不够）**补 0**，不是按最左字符扩展 —— 必须与 `format_value` 的 `int(bits, 2)`（天然零扩展）一致，
    否则"父信号显示 8'h0A、切片却当 1111_1010"。**只有最左字符是 x/z 时才按 x/z 扩展**。
- **其余守卫点（都踩过）**：
  - 标签列宽度后缀：派生行 `full_path` 自带 `[7:4]`，再拼 `[3:0]` 就成 `rx_data[7:4][3:0]` → 派生行**抑制**后缀。
  - 状态名整块对派生行隐藏（下标变了，沿用父的映射会张冠李戴），但 **Radix 要留着**；父信号的状态名入口不能被误伤。
  - `_fp_of_vcd`（双击跳代码 / Trace 都走它）必须解析回**父**的 full_path。
  - `.wvs` 升到 **version 5**：派生行存**父的身份**（full_path/leaf/width/scope 全是父的）+ 新增 `"bits": [msb, lsb]`，
    这样 `resolve_session_signals` 一行都不用改（跨 case 改名适配照旧）；载回时槽位重建为**重新派生** key。
    `bits` 越界（新 VCD 位宽不够）→ 槽位置空 + status 改判 **`FAIL_BITS`**（"✗ 位段超出范围"）+ 计数从 exact/adapt 挪到 fail；
    `bits` 形状被手改坏（`"7:4"`、`[7]` 之类）→ 同样 FAIL_BITS，**绝不能让整场载入抛异常**。
  - 掉行不静默：报告里逐条列出原因（与 B11 的分组掉信号同一条原则）。
- **无头自查的两个坑（写测试时必踩）**：
  - **`QMenu.exec` 是纯 C++（非虚）函数，Python 侧 patch 不掉**，无头环境弹了就永久阻塞（现象：进程 0% CPU 卡死）。
    所以菜单拆成"构造器 + 弹出"两半：`WaveformPanel._build_color_menu` / `CodeViewerPanel._build_signal_menu`，
    自查块拿**构造器**的返回值查 `actions()`，再 `trigger()` 真入口。
  - **`action.menu()` 返回的 `QMenu` 包装器被 GC 会连带删掉 C++ 子菜单**
    （`RuntimeError: Internal C++ object already deleted`）。取子菜单用 `menu.findChildren(QMenu)` 按标题找，
    并只保留 `QAction`（由菜单持有，生命周期稳定）。
  - 模态输入框也做了同样的 seam：`_ask_bit_text`（面板）+ `_ask_bit_text`（代码窗口），自查里替换掉即可。
- **自查**：见下方 **B13-纯函数** 与 **B13-GUI** 两块。

---

## B14 — `case (var[N:0])` 的**位选**写法让整个 case 体不进扫描 → 状态名"未识别/缺项"
- **时间/场景**：2026-09-20 会话；给 PHY 三模块按 `code_rtl.md` 规则 7 重写后，回头核对状态名识别。
- **症状**：**与 B10 同症状、不同根因**。`detect_fsm_state_map` 返回的表**残缺甚至为空**：
  `usb_rx_cdr.v` 16 态只剩 `{12:'ST_C'}`、`usb_clk_mux.v` 4 态只剩 `{0,3}`、
  `usb_rx_deserial.v` 帧机丢 `USB_SYNC_SEEK`、EOP 机丢 `ST_EOP_SE0_1/2`。
  在 GUI 里的表现是 Radix → Show State Names 缺项/整片认不出。
- **最小复现**（纯函数，与本仓库无关）：
  ```
  case (st)       -> {0: 'S_A', 1: 'S_B'}    ✅
  case (st[1:0])  -> {}                      ❌
  ```
- **根因**：`_params_used_with` 靠这行进入"case 体"扫描模式：
  `re.search(r"\bcase(?:z|x)?\s*\(\s*VAR\s*\)", ln)` —— **要求括号里只有变量名**。
  规则 7 强制显式位宽（`case (st_stat_cur[1:0])`），于是**永远进不去 case 体**，
  只能靠"同行同现"捞到零星几个常量（残表就是这么来的）。
  第二条同源缺陷：`_ASSIGN_PAIR_RE` 同样不认位选，`st_stat_cur[1:0] <= st_stat_nxt[1:0];`
  匹配不上 → `_state_var_aliases` 恒返回空集 → 两段式 FSM 的"次态变量补一跳"整条失效。
- **修法**（两处正则各加"可选的单层 `[..]`"）：
  - case：`VAR\s*(?:\[[^\]]*\])?\s*\)`；
  - 赋值对：两侧名字后各加 `(?:\[[^\]]*\])?`。
  刻意**不**放开"括号里任意内容"（如 `case (sel + st[1:0])`），否则别的表达式的 case 会被误算进来；
  该反例已进自检用例。
- **为什么必须记**：只要 RTL 继续按规则 7 写（新模块一律如此），**每个**新模块都会中招；
  这条不是历史包袱，是活的陷阱。
- **自查**：下方 **B10 单元自检**里的三条 ★ 回归用例（位选 case / 位选赋值对 / 位选反例）+ 真 RTL 五条断言
  （tx 6 态、rx 帧机 4 态、rx EOP 机 5 态、clkmux 4 态、cdr 4 态）。

---

## B15 — 时间刻度固定一位小数 → 亚微秒窗口里所有刻度印成同一个标签
- **时间/场景**：2026-09-28 会话；给 `usb_bus_state` 出波形截图，要看清判据→翻转→脉冲这条链，
  窗口只有 200ns。
- **症状**：刻度标签连印 `3.7us 3.7us 3.7us …`，看不出间隔；导出 PNG 后整条时间轴失去读数能力。
  窗口越短越糟（刻度间隔 0.02us，而标签只有 0.1us 的分辨率）。
- **根因**：`_format_time` 里每个单位都写死 `.1f` —— 小数位数与"看得多细"无关，
  只看单位量级。µs 窗口无论多窄都只有一位小数。
- **修法**：改成最多 6 位小数再去尾零（`_trim_time`）：`3.7us` / `3.72us` / `20.833ns`。
  单位选择不变，仍取 ≥ 绝对值的最大单位。上限取 6 而不是 3：ms 量级的时刻（本项目 3ms 挂起事件）
  要看清 20ns 级的刻度，3 位小数会重新撞车（`3.01208ms` 与 `3.01228ms` 都印成 `3.012ms`）。
  调用方只显示标签、不解析，改字符串无连带。
- **自查**：下方 **B15 时间标签自检**（含 3ms 时刻 + 20ns 刻度这组实际用例）。

---

## 快速自查清单（改完随手跑）

```bash
# 一次跑完本文件【下方】所有自查块（在 tools/ 下执行）
# ⚠ 本块必须独立成一个围栏，且靠标记把自己排除掉 ——
#   否则它会把自身再跑一遍 → 无限递归（踩过一次，进程要手动 kill）；
#   而若与别的块共用围栏，那一段会被一起跳过（也踩过：trace 自检曾静默没跑）。
# selfcheck-runner
python3 - <<'EOF'
import re, subprocess
blocks = [b for b in re.findall(r"^```bash\n(.*?)^```", open("bug.md").read(), re.S | re.M)
          if "selfcheck-runner" not in b]
print(f"共 {len(blocks)} 个自查块")
for i, b in enumerate(blocks, 1):
    r = subprocess.run(["bash", "-c", b], capture_output=True, text=True, timeout=180)
    print(f"  block {i}: {'OK' if r.returncode == 0 else 'FAIL'}")
    if r.returncode:
        print(r.stdout[-500:] or r.stderr[-500:])
EOF
```

```bash
python3 -m py_compile wave_debugger.py                      # 语法
python3 -c "import wave_debugger"                           # 导入(需 PySide6)

# 无头跑三条 trace 路径（见 B2/B3/B4 的复现），QT_QPA_PLATFORM=offscreen
python3 - <<'EOF'
import os; os.environ["QT_QPA_PLATFORM"]="offscreen"
import wave_debugger as wd
from PySide6.QtWidgets import QApplication
app=QApplication([]); w=wd.WaveDebuggerMain()
w._open_vcd("/Users/sunyuan/Desktop/apb_usb/sim/deserial/deserial_out_normal.vcd")
sigs=w._analyzer.header.get("signals",[])
rx=sorted({s.full_path for s in sigs if s.name=="rx_bit"})
assert rx==['tb_deserial.rx_bit','tb_deserial.u_cdr.rx_bit','tb_deserial.u_dut.rx_bit'], rx
for fp in rx:
    w.log_panel.clear_log(); w._on_trace_driver(fp)
    t="\n".join(w.log_panel.list.item(i).text() for i in range(w.log_panel.list.count()))
    assert "u_cdr 的 rx_bit 端口输出" in t or "assign rx_bit" in t, fp
print("trace self-check OK")
EOF
```

# B7/B8 自检：代码窗口 Trace 恒可用 + 左右两列垂直对齐

```bash
python3 - <<'EOF'
import os; os.environ["QT_QPA_PLATFORM"]="offscreen"
import sys; sys.path.insert(0,"/Users/sunyuan/Desktop/apb_usb/tools")
import wave_debugger as wd
from PySide6.QtWidgets import QApplication
class FA:  # 合成菜单：不弹模态框
    def __init__(s,t): s._t=t; s.triggered=type("S",(),{"connect":lambda s2,cb:None})()
    def text(s): return s._t
    def setEnabled(s,v): pass
    def setFont(s,f): pass
class FM:
    def __init__(s,*a,**k): s.items=[]; s.title=""
    def addAction(s,t): a=FA(t); s.items.append(a); return a
    def addMenu(s,t): m=FM(); m.title=t; s.items.append(m); return m
    def addSeparator(s): s.items.append(None)
    def clear(s): s.items=[]
    def exec(s,*a,**k): pass
made=[]
def QF(*a,**k):
    m=FM(*a,**k); made.append(m); return m
wd.QMenu=QF
app=QApplication([]); w=wd.WaveDebuggerMain()
w._open_vcd("/Users/sunyuan/Desktop/apb_usb/sim/deserial/deserial_out_normal.vcd")
cp=w.code_panel; cp.load_file("/Users/sunyuan/Desktop/apb_usb/sim/deserial/tb_deserial.v")

def texts(m, out=None):
    out=out if out is not None else []
    for it in m.items:
        if isinstance(it, FM): out.append("▸"+it.title); texts(it,out)
        elif it is not None: out.append(it.text())
    return out

cp._show_signal_menu(None, "rx_bit")
assert any("Trace Driver" in t for t in texts(made[-1])), texts(made[-1])   # 同名 3 条也必须能 trace
cp._show_signal_menu(None, "pid_type")
assert any(t.startswith("▸🔍 Trace Driver") for t in texts(made[-1])), texts(made[-1])

wp=w.wave_panel
ids=[s.vcd_id for s in w._analyzer.header.get("signals",[])]
for n in (3, 40, 120):
    wp.wave_scene.clear_signals(); wp.label_scene.sync_from(wp.wave_scene)
    wp.add_signals(ids[:n]); app.processEvents()
    vw=wp.wave_view.verticalScrollBar(); vl=wp.label_view.verticalScrollBar()
    assert vw.maximum()==vl.maximum(), (n, vw.maximum(), vl.maximum())
    for val in (0, vw.maximum()//2, vw.maximum()):
        vw.setValue(val); app.processEvents()
        dy=wp.wave_view.mapToScene(0,0).y()-wp.label_view.mapToScene(0,0).y()
        assert abs(dy) < 1, (n, val, dy)
print("B7/B8 self-check OK")
EOF
```

# B9 自检：`wire X = expr;` 必须算驱动；RHS 引用不得误判成驱动
```bash
python3 - <<'EOF'
import sys; sys.path.insert(0, "/Users/sunyuan/Desktop/apb_usb/tools")
import wave_debugger as wd
CASES = [   # (源码行, 信号名, 期望是否"声明即驱动")
    ("wire byte_rdy = enable_shift && (bit_cnt == 3'd7);", "byte_rdy", True),
    ("wire in_frame = (st_state == USB_DATA) || (st_state == USB_ERROR);", "st_state", False),   # 只在 RHS
    ("wire in_frame = (st_state == USB_DATA) || (st_state == USB_ERROR);", "in_frame", True),
    ("wire a = 1'b0, b = 1'b1;", "b", True),          # 多 declarator
    ("wire a, b = 1'b1;", "a", False),                # 无初值那条不算
    ("output reg [7:0] rx_data = 8'h00;", "rx_data", False),   # reg 初值不是连续驱动
    ("localparam USB_DATA = 2'd2;", "USB_DATA", False),
    ("reg [7:0] mem [0:15];", "mem", False),
    ("wire [7:0] fb_q;", "fb_q", False),
]
for line, name, exp in CASES:
    assert wd._decl_is_netinit(line, name) == exp, (line, name, exp)
print("B9 unit self-check OK")
EOF
```

# B10 状态名识别：各种常量写法 + 不串扰（纯函数，无需 VCD）
```bash
python3 - <<'EOF'
import wave_debugger as wd
def fsm(decls, var="st", body=None):
    names = [d[2] for d in decls]
    if body is None:
        items = "\n".join(f"      {n}: nxt = {names[(i+1)%len(names)]};" for i, n in enumerate(names))
        body = f"case ({var})\n{items}\n    endcase"
    d = "\n".join(f"  {kw} {rng}{n} = {v};" for kw, rng, n, v in decls)
    return f"module m;\n{d}\n  reg [1:0] st, nxt;\n  always @(*) begin {body} end\nendmodule"
cases = [
  # 本次报错：带位宽范围
  (fsm([("localparam","[1:0] ","S_IDLE","2'd0"),("localparam","[1:0] ","S_RUN","2'd1")]), "st", 2, {0:"S_IDLE",1:"S_RUN"}),
  # 老写法不得回归
  (fsm([("localparam","","ST_A","2'd0"),("localparam","","ST_B","2'd1")]), "st", 2, {0:"ST_A",1:"ST_B"}),
  # 一行多声明
  ("module m;\n  localparam [1:0] S_A = 2'd0, S_B = 2'd1, S_C = 2'd2;\n  reg [1:0] st, nxt;\n"
   "  always @(*) case (st)\n    S_A: nxt = S_B;\n    S_B: nxt = S_C;\n    S_C: nxt = S_A;\n  endcase\nendmodule",
   "st", 2, {0:"S_A",1:"S_B",2:"S_C"}),
  # 常量表达式 / 引用其它常量
  ("module m;\n  localparam [1:0] S_A = 2'd0;\n  localparam [1:0] S_B = S_A + 1;\n"
   "  localparam [1:0] S_C = S_B + 1;\n  reg [1:0] st, nxt;\n  always @(*) case (st)\n"
   "    S_A: nxt = S_B;\n    S_B: nxt = S_C;\n    S_C: nxt = S_A;\n  endcase\nendmodule",
   "st", 2, {0:"S_A",1:"S_B",2:"S_C"}),
  # 跨行声明
  ("module m;\n  localparam [1:0]\n    S_X = 2'd0;\n  localparam [1:0] S_Y = 2'd1;\n  reg [1:0] st, nxt;\n"
   "  always @(*) case (st)\n    S_X: nxt = S_Y;\n    S_Y: nxt = S_X;\n  endcase\nendmodule",
   "st", 2, {0:"S_X",1:"S_Y"}),
  # SystemVerilog enum 隐式值
  ("module m;\n  typedef enum logic [1:0] {E_IDLE, E_RUN, E_DONE} e_t;\n  reg [1:0] st, nxt;\n"
   "  always @(*) case (st)\n    E_IDLE: nxt = E_RUN;\n    E_RUN: nxt = E_DONE;\n    E_DONE: nxt = E_IDLE;\n  endcase\nendmodule",
   "st", 2, {0:"E_IDLE",1:"E_RUN",2:"E_DONE"}),
  # 两段式：case 挂在次态变量上（补一跳）
  ("module m;\n  localparam [1:0] S_IDLE = 2'd0;\n  localparam [1:0] S_RUN = 2'd1;\n"
   "  reg [1:0] st_state, st_nxt;\n  always @(posedge clk) st_state <= st_nxt;\n"
   "  always @(*) begin st_nxt = st_state;\n    case (st_nxt)\n      S_IDLE: st_nxt = S_RUN;\n      S_RUN: st_nxt = S_IDLE;\n    endcase\n  end\nendmodule",
   "st_state", 2, {0:"S_IDLE",1:"S_RUN"}),
  # 同模块两套 FSM 位宽相同 → 不得串扰
  ("module m;\n  localparam [1:0] A_IDLE = 2'd0;\n  localparam [1:0] A_RUN = 2'd1;\n"
   "  localparam [1:0] B_IDLE = 2'd0;\n  localparam [1:0] B_RUN = 2'd1;\n"
   "  reg [1:0] a_st; reg [1:0] b_st;\n  always @(*) case (a_st)\n    A_IDLE: a_nxt = A_RUN;\n    A_RUN: a_nxt = A_IDLE;\n  endcase\n"
   "  always @(*) case (b_st)\n    B_IDLE: b_nxt = B_RUN;\n    B_RUN: b_nxt = B_IDLE;\n  endcase\nendmodule",
   "a_st", 2, {0:"A_IDLE",1:"A_RUN"}),
  # 与常量无关的信号 → 空表
  ("module m;\n  localparam [1:0] S_A = 2'd0;\n  reg [7:0] cnt;\n  always @(*) cnt = cnt + 1;\nendmodule",
   "cnt", 8, {}),
  # ★ B14 回归：case 表达式带**位选**（规则 7 强制写法）—— 曾整表返回空
  ("module m;\n  localparam [1:0] S_A = 2'd0;\n  localparam [1:0] S_B = 2'd1;\n"
   "  reg [1:0] st, nxt;\n  always @(*) begin\n    case (st[1:0])\n      S_A: nxt = S_B;\n      S_B: nxt = S_A;\n    endcase\n  end\nendmodule",
   "st", 2, {0:"S_A",1:"S_B"}),
  # ★ B14 回归：两段式 + 位选赋值对（`st[1:0] <= nxt[1:0];` 的别名跳转曾失效）
  ("module m;\n  localparam [1:0] S_A = 2'd0;\n  localparam [1:0] S_B = 2'd1;\n"
   "  reg [1:0] st, nxt;\n  always @(posedge clk) st[1:0] <= nxt[1:0];\n"
   "  always @(*) begin\n    nxt[1:0] = st[1:0];\n    case (nxt[1:0])\n      S_A: nxt[1:0] = S_B;\n      S_B: nxt[1:0] = S_A;\n    endcase\n  end\nendmodule",
   "st", 2, {0:"S_A",1:"S_B"}),
  # ★ B14 反例：位选只认"名字 + 一层 [..]"，别的表达式不得被当成 case(本变量)
  ("module m;\n  localparam [1:0] S_A = 2'd0;\n  localparam [1:0] S_B = 2'd1;\n"
   "  reg [1:0] st, sel;\n  always @(*) begin\n    case (sel + st[1:0])\n      S_A: st = S_B;\n      S_B: st = S_A;\n    endcase\n  end\nendmodule",
   "sel", 2, {}),
]
for text, var, w, want in cases:
    got = wd.detect_fsm_state_map(var, text, w)
    assert got == want, (var, want, got)
# 真实 RTL：本次报错的写法（带范围）+ 老写法（不得回归）
import os
base = "/Users/sunyuan/Desktop/apb_usb"
tx = open(f"{base}/src/phy/usb_tx_serial.v").read()
assert wd.detect_fsm_state_map("tx_stat_cur", tx, 3) == {
    0:"S_IDLE",1:"S_SYNC",2:"S_DATA",3:"S_DATA_LAST",4:"S_EOP1",5:"S_EOP2"}
rx = open(f"{base}/src/phy/usb_rx_deserial.v").read()
assert wd.detect_fsm_state_map("st_stat_cur", rx, 2) == {
    0:"USB_IDLE",1:"USB_SYNC_SEEK",2:"USB_DATA",3:"USB_ERROR"}
# B14：规则 7 的 `case (var[N:0])` 必须认得出全部状态（曾只剩 default 那一条）
assert wd.detect_fsm_state_map("eop_stat_cur", rx, 3) == {
    0:"ST_EOP_IDLE",1:"ST_EOP_SE0_1",2:"ST_EOP_SE0_2",3:"ST_EOP_SE0_3",4:"ST_EOP_DEAD"}
assert len(wd.detect_fsm_state_map("stat_cur", open(f"{base}/src/phy/usb_clk_mux.v").read(), 2)) == 4
assert len(wd.detect_fsm_state_map("stat_cur", open(f"{base}/src/phy/usb_rx_cdr.v").read(), 4)) == 4
print("B10 unit self-check OK")
EOF
```

- 核心可复用入口（新功能照抄，别另造一套解析）：`analyze_signal_refs` / `module_port_directions` / `module_region_of` / `find_instance_connects` / `iter_instance_blocks`（纯函数，文件顶部）；主窗 `_sig_from_key`（full_path→SignalDef）、`_driver_chain_rows`（驱动链）、`_read_text`（缓存读文件）。

```bash
# B11-纯函数：布局代数 + 序列化（无 Qt，见 bug.md B11 / tools/wave_groups.py）
python3 - <<'EOF'
import sys; sys.path.insert(0, "/Users/sunyuan/Desktop/apb_usb/tools")
import wave_groups as G

def vis(o):   # 渲染行序列（组头写成 "G:名字"）
    return [("G:"+i.name) if G.is_group(i) else i for i in G.visible_rows(o)]
def top(o):   # 顶层序列
    return [("G:"+i.name) if G.is_group(i) else i for i in o]

# 1 展开 / 可见性：隐藏组整块去掉，折叠组只留组头
g1 = G.SignalGroup("组1", members=["m1","m2"])
g2 = G.SignalGroup("组2", hidden=True, members=["m3"])
g3 = G.SignalGroup("组3", collapsed=True, members=["m4","m5"])
order = [g1, "T1", g2, g3]
assert vis(order) == ["G:组1","m1","m2","T1","G:组3"], vis(order)
assert G.all_rows(order)[0] == [g1,"m1","m2","T1",g2,"m3",g3,"m4","m5"]
assert G.row_owners(order) == [g1,g1,g1,None,g3]
assert G.counts(order) == (6, 3)                      # 含被隐藏组的成员
assert G.group_at_row(order,1) is g1 and G.group_at_row(order,3) is None
assert G.group_at_row(order,4) is g3                  # 组块之后还能跟顶层信号，不能往回扫
assert G.find_group(order, g2.gid) is g2 and G.find_group(order, 999) is None

# 2 非连续多选建组：夹在中间没选中的不被吞（位置成员模型的核心 bug）
o = ["A","B","C","D","E"]
g = G.group_from_rows(o, "新组", [1,3])
assert vis(o) == ["A","G:新组","B","D","C","E"], vis(o)
assert g.members == ["B","D"] and G.group_at_row(o,5) is None

# 3 加入 / 移出（移出后成为顶层信号，不再挂名）
o2 = ["A","B","C","D"]
g = G.group_from_rows(o2, "组A", [0,1])
G.add_to_group(o2, [3], g);  assert g.members == ["A","B","C"]
G.remove_from_group(o2, [1])
assert g.members == ["B","C"] and vis(o2) == ["G:组A","B","C","A","D"], vis(o2)
assert G.group_at_row(o2,3) is None

# 4 删组：保留信号 / 连信号一起删
o3 = list(o2); G.remove_group(o3, g, keep_signals=True)
assert vis(o3) == ["B","C","A","D"], vis(o3)
g4 = G.SignalGroup("x", members=["m"]); o5 = [g4,"T"]
G.remove_group(o5, g4, keep_signals=False)
assert vis(o5) == ["T"]

# 5 拖动 move_rows：dest 以"摘除被拖行之后"的序列为准；落点决定归属
g1 = G.SignalGroup("g1", members=["m1","m2"]); g2 = G.SignalGroup("g2", members=["m3"])
o = [g1,"T1",g2]                                      # 行: g1 m1 m2 T1 g2 m3
G.move_rows(o, [3], 4)                                # T1 → g2 组头正下方 → 并入
assert g2.members == ["T1","m3"] and "T1" not in o, g2.members
ga = G.SignalGroup("g1", members=["m1","m2"]); gb = G.SignalGroup("g2", members=["m3"])
o = [ga, "T1", gb]
G.move_rows(o, [1], 3)                                # m1 → T1 之后 → 顶层
assert ga.members == ["m2"] and vis(o) == ["G:g1","m2","T1","m1","G:g2","m3"], vis(o)
ga = G.SignalGroup("g1", members=["m1","m2"]); gb = G.SignalGroup("g2", members=["m3"])
o = [ga, "T1", gb]
G.move_rows(o, [1], 5)                                # 陷阱：拖到最末尾 → 并入末尾那个组
assert gb.members == ["m3","m1"] and ga.members == ["m2"], gb.members
ga = G.SignalGroup("g1", members=["m1","m2"]); o = [ga, "T1", "T2"]   # 行: g1 m1 m2 T1 T2
G.move_rows(o, [3,4], 0); assert vis(o) == ["T1","T2","G:g1","m1","m2"], vis(o)
G.move_rows(o, [3], 2)                                # 行 3 = m1 → T2 之后
assert ga.members == ["m2"] and vis(o) == ["T1","T2","m1","G:g1","m2"], vis(o)
o = ["A","B","C","D"]; G.move_rows(o, [2,3], 0)
assert o == ["C","D","A","B"], o

# 6 拖整组 / 折叠组也是"一块"
g1 = G.SignalGroup("g1", members=["m1"]); g2 = G.SignalGroup("g2", members=["m2"])
o = [g1,"T",g2]
G.move_group_to_row(o, g1, 3); assert vis(o) == ["T","G:g2","m2","G:g1","m1"], vis(o)
G.move_group_to_row(o, g1, 0); assert vis(o) == ["G:g1","m1","T","G:g2","m2"], vis(o)
assert g1.members == ["m1"] and g2.members == ["m2"]
g1 = G.SignalGroup("g1", collapsed=True, members=["m1","m2"]); o = [g1,"T"]
G.move_group_to_row(o, g1, 2)
assert vis(o) == ["T","G:g1"] and g1.members == ["m1","m2"]

# 7 序列化往返（含重复项 / 隐藏 / 折叠）
g1 = G.SignalGroup("组1", members=["s1","s2","s1"])
g2 = G.SignalGroup("组2", hidden=True, members=["s3"])
g3 = G.SignalGroup("组3", collapsed=True, members=["s4"])
order = [g1,"T",g2,g3]
sig_rows, recs = G.order_to_records(order)
assert sig_rows == [1,2,3,4,6,8], sig_rows                 # 完整逻辑序列里的信号行号
assert [r["members"] for r in recs] == [[0,1,2],[4],[5]], recs   # members = signals[] 下标
assert recs[1]["hidden"] is True and recs[2]["collapsed"] is True
slots = ["s1","s2","s1","T","s3","s4"]
o2, groups, dropped = G.records_to_order(slots, recs)
assert not dropped and top(o2) == ["G:组1","T","G:组2","G:组3"], top(o2)
assert groups[0].members == ["s1","s2","s1"] and groups[2].members == ["s4"]
assert vis(o2) == ["G:组1","s1","s2","s1","T","G:组3"], vis(o2)

# 8 掉信号：成员少一个组不散架；整组掉光 → 丢弃并报告；锚点成员掉了也能重新锚定
slots = ["s1",None,"s1","T",None,"s4"]
o3, groups, dropped = G.records_to_order(slots, recs)
assert [x.name for x in groups] == ["组1","组3"] and [r["name"] for r in dropped] == ["组2"]
assert groups[0].members == ["s1","s1"] and vis(o3) == ["G:组1","s1","s1","T","G:组3"]
o4, groups, dropped = G.records_to_order([None,"s2","s1","T","s3","s4"], recs)
assert [x.name for x in groups] == ["组1","组2","组3"] and vis(o4)[0] == "G:组1"
assert groups[0].members == ["s2","s1"]

# 9 旧文件（无 groups 键）/ 脏数据 / 空容器边界
o5, groups, dropped = G.records_to_order(["A","B"], None)
assert top(o5) == ["A","B"] and groups == [] and dropped == []
o6, groups, dropped = G.records_to_order(["A"], [{"name":"x","members":[99,-1]}, "垃圾"])
assert top(o6) == ["A"] and groups == [] and len(dropped) == 1
assert G.visible_rows([]) == [] and G.counts([]) == (0,0)
assert G.group_from_rows([], "空", [0]).members == []
o7 = ["A"]; G.group_from_rows(o7, "空", []); assert top(o7) == ["A"]
assert G.move_rows(["A"], [0], 0) == ["A"]
assert G.add_to_group(["A"], [], G.SignalGroup("x")) == ["A"]
assert G.remove_from_group(["A"], [0]) == ["A"]
assert G.move_group_to_row(["A"], G.SignalGroup("z"), 0) == ["A"]
assert isinstance(hash(G.SignalGroup("g")), int)        # 能当 dict 键
assert G.SignalGroup("g") != G.SignalGroup("g")         # 身份语义（故意无 __eq__）
print("B11 纯函数 self-check OK")
EOF
```

```bash
# B11-GUI：无头端到端（真实鼠标事件走 eventFilter + 存盘往返 + 旧会话兼容）
python3 - <<'EOF'
import os; os.environ["QT_QPA_PLATFORM"]="offscreen"
import sys, json; sys.path.insert(0, "/Users/sunyuan/Desktop/apb_usb/tools")
import wave_debugger as wd, wave_groups as G
from PySide6.QtCore import QEvent, QPointF, Qt
from PySide6.QtGui import QMouseEvent
from PySide6.QtWidgets import QApplication
# 无头环境下模态框会永久阻塞：报告弹窗换成记录，QMessageBox 降级
REPORTS=[]
wd.WaveDebuggerMain._show_load_report = lambda self,summary,results,dropped_groups=(): \
    REPORTS.append((summary, tuple(dropped_groups)))
for _m in ("warning","critical","information"):
    setattr(wd.QMessageBox, _m, staticmethod(lambda *a, **k: None))
app = QApplication([])
B = "/Users/sunyuan/Desktop/apb_usb"
w = wd.WaveDebuggerMain(); w._open_vcd(f"{B}/sim/tx/tx_abort.vcd")
ws, ls, wp = w.wave_panel.wave_scene, w.wave_panel.label_scene, w.wave_panel

def vis():
    return ["G:"+i.name if G.is_group(i) else i for i in ws._displayed]
def row_y(r):
    return wd.RULER_HEIGHT + r*wd.ROW_HEIGHT + wd.ROW_HEIGHT/2
def send(t, x, y, btn=Qt.LeftButton):
    vp = wp.label_view.mapFromScene(QPointF(x,y))
    return wp.eventFilter(wp.label_view.viewport(),
        QMouseEvent(t, QPointF(vp), QPointF(wp.label_view.viewport().mapToGlobal(vp)), btn, btn, Qt.NoModifier))
def wiring():   # 别名 + 两列几何一致（B8/B11 的核心不变量）
    assert ls._displayed is ws._displayed, "标签列 _displayed 别名断了"
    assert ls._order is ws._order, "标签列 _order 别名断了"
    assert abs(ws.sceneRect().height()-ls.sceneRect().height()) < 1
    if ws._displayed:
        assert ws._row_y(len(ws._displayed)-1) + wd.ROW_HEIGHT <= ws.sceneRect().height()

sigs = w._analyzer.header.get("signals", [])
# 本 VCD 内确有跨作用域同名信号（B2/B7 的撞号场景要用到；规则 7 改名后不再用 st_state 举例）
assert len([s for s in sigs if s.name=="rx_bit"]) >= 2
pick, seen = [], set()
for s in sigs:
    if s.vcd_id not in seen:
        seen.add(s.vcd_id); pick.append(s.vcd_id)
        if len(pick) == 6: break
wp.add_signals(pick)
assert wp.signal_count_label.text() == "6 signals" and len(ws._displayed) == 6
wiring()

g = ws.create_group_from_rows([2,3], "通路")      # 非连续多选
assert wp.signal_count_label.text() == "6 signals · 1 groups"
assert g.members == [pick[2], pick[3]] and len(ws._displayed) == 7, vis()
wiring()

# 折叠三角只认组头行最左 FOLD_ZONE_W 像素，且点击不得留下拖动状态
HDR = ws._displayed.index(g)
assert ls.fold_hit_at(6, row_y(HDR)) == HDR
assert ls.fold_hit_at(6, row_y(HDR+1)) is None and ls.fold_hit_at(999, row_y(HDR)) is None
send(QEvent.MouseButtonPress, 6, row_y(HDR))
assert g.collapsed and not ls._drag_indices and len(ws._displayed) == 5, vis()
send(QEvent.MouseButtonPress, 6, row_y(HDR))
assert not g.collapsed and len(ws._displayed) == 7, vis()

# 隐藏 / 恢复 + 计数
ws.set_group_hidden(g, True)
assert len(ws._displayed) == 4 and "G:通路" not in vis()      # 组头 + 2 个成员一起消失
assert ws.count_text() == "6 signals · 1 groups"              # 计数含隐藏
ws.set_all_groups_hidden(False); assert len(ws._displayed) == 7
wiring()

# 拖动（真鼠标事件）：顶层信号 → 拖进组（自动加入）；再拖到最前（插入线拉到标尺下沿）
ls.clear_selection()
send(QEvent.MouseButtonPress, 30, row_y(5)); send(QEvent.MouseMove, 30, row_y(3))
send(QEvent.MouseButtonRelease, 30, row_y(3))
assert pick[4] in g.members, g.members
out = ws._displayed.index(pick[4])
send(QEvent.MouseButtonPress, 30, row_y(out)); send(QEvent.MouseMove, 30, wd.RULER_HEIGHT)
send(QEvent.MouseButtonRelease, 30, wd.RULER_HEIGHT)
assert pick[4] not in g.members and ws._displayed[0] == pick[4], vis()
# 拖组头 = 整块搬，成员不变
HDR = ws._displayed.index(g); snap = list(g.members)
send(QEvent.MouseButtonPress, 30, row_y(HDR))
assert ls.drag_block_has_group() and sorted(ls._drag_indices) == ws.rows_of_group(g)
send(QEvent.MouseMove, 30, wd.RULER_HEIGHT); send(QEvent.MouseButtonRelease, 30, wd.RULER_HEIGHT)
assert ws._displayed[0] is g and g.members == snap, vis()
wiring()

# 工具栏菜单：隐藏组也必须列出来（唯一恢复入口）
wp._refresh_group_menu()
assert "通路" in " ".join(a.text() for a in wp._group_menu.actions())
ws.set_group_hidden(g, True); assert "隐藏" in wp.btn_groups.text()
assert "通路" in " ".join(a.text() for a in wp._group_menu.actions()), "隐藏组没列进菜单"
ws.set_all_groups_hidden(False)

# 存盘往返：隐藏 + 折叠一起存（版本 4），载回逐项一致
ws.set_group_hidden(g, True)
g2 = ws.create_group_from_rows([len(ws._displayed)-1], "末尾组"); ws.toggle_group_collapsed(g2)
order_before = ["G:"+i.name if G.is_group(i) else i for i in ws._order]
meta_before  = [(x.name,x.collapsed,x.hidden,list(x.members)) for x in ws.groups()]
n_vis        = len(ws._displayed)
SS = "/tmp/b11_selfcheck.wvs"; w._save_session(SS)
d = json.load(open(SS))
assert d["version"] == 5 and len(d["groups"]) == 2 and len(d["signals"]) == 6   # 隐藏组成员也存（v5 起派生行多带 bits 键）
w._load_session(SS); ws, ls = w.wave_panel.wave_scene, w.wave_panel.label_scene
assert ["G:"+i.name if G.is_group(i) else i for i in ws._order] == order_before
assert [(x.name,x.collapsed,x.hidden,list(x.members)) for x in ws.groups()] == meta_before
assert len(ws._displayed) == n_vis and wp.signal_count_label.text() == "6 signals · 2 groups"
wiring()

# 换 VCD 载同一会话：组不散架、掉光的分组进加载报告（不静默消失）
w2 = wd.WaveDebuggerMain(); REPORTS.clear()
w2._open_vcd(f"{B}/sim/deserial/deserial_out_normal.vcd"); w2._load_session(SS)
ws2, ls2 = w2.wave_panel.wave_scene, w2.wave_panel.label_scene
assert all(isinstance(r,str) or G.is_group(r) for r in ws2._order)
kept = [x.name for x in ws2.groups()]
dropped = [x["name"] for _s,_d in REPORTS for x in _d]
assert sorted(kept + dropped) == sorted(["通路","末尾组"]), (kept, dropped)   # 保留+丢弃守恒
for grp in ws2.groups(): assert grp.members
assert abs(ws2.sceneRect().height()-ls2.sceneRect().height()) < 1

# 向后兼容：旧 .wvs（v2/v3，无 groups 键）行为与加分组之前完全一致
old = f"{B}/sim/deserial/fixed_r6.wvs"; raw = json.load(open(old))
assert "groups" not in raw
w3 = wd.WaveDebuggerMain()
w3._open_vcd(raw["vcd_file"] if os.path.exists(raw.get("vcd_file") or "") else f"{B}/sim/deserial/fixed_r6.vcd")
w3._load_session(old); ws3 = w3.wave_panel.wave_scene
assert ws3.group_count == 0 and all(isinstance(r,str) for r in ws3._displayed) and ws3._displayed
assert w3.wave_panel.signal_count_label.text() == f"{len(ws3._displayed)} signals"

# 重载 VCD：分组结构原样保留
before = ["G:"+i.name if G.is_group(i) else i for i in w.wave_panel.wave_scene._order]
w._on_reload_vcd(); ws = w.wave_panel.wave_scene
assert ["G:"+i.name if G.is_group(i) else i for i in ws._order] == before
assert ws.group_count == 2 and w.wave_panel.label_scene._order is ws._order
print("B11 GUI self-check OK")
EOF
```

```bash
# B12-纯函数：新增信号的锚点 = 渲染行号（隐藏组不占行号），归属与 move_rows 同一条规则
python3 - <<'EOF'
import sys; sys.path.insert(0, "/Users/sunyuan/Desktop/apb_usb/tools")
import wave_groups as G
R = lambda o: ["G:"+i.name if G.is_group(i) else i for i in G.visible_rows(o)]

# 隐藏组 + 普通组各一个：隐藏组不占渲染行号，也不该被当锚点
gx = G.SignalGroup("x", hidden=True, members=["m1", "m2"])
gy = G.SignalGroup("y", members=["c", "d"])
o = ["a", gx, "b", gy]
assert R(o) == ["a", "b", "G:y", "c", "d"], R(o)

# 1 插在渲染行 2 之前（= "b" 与组头之间）。按 _order 下标硬插会插到隐藏组后面去：
#   naive `o.insert(2, "n")` → ["a", gx, "n", "b", gy] → 渲染落在 "b" **上面**（错）
G.insert_rows(o, ["n"], 2)
assert o == ["a", gx, "b", "n", gy], o
assert R(o) == ["a", "b", "n", "G:y", "c", "d"], R(o)

# 2 落点在组头正下方 → 进该组首位；落在某成员后面 → 接在它后面（仍在组内）
#   注意 dest 语义是"插到渲染行 dest-1 的后面"：此时渲染行 = [a, b, n, 组头, c, d]
G.insert_rows(o, ["p"], 4)              # 渲染行 3 == 组头行 "G:y"，dest=4 即紧贴它下面
assert gy.members == ["p", "c", "d"], gy.members
a2 = G.anchor_at(o, 4); assert a2 == (gy, 0), a2
G.insert_rows(o, ["q"], 7)              # 渲染行 6 == 成员 "d"，dest=7 即接在它后面
assert gy.members == ["p", "c", "d", "q"], gy.members
assert R(o) == ["a", "b", "n", "G:y", "p", "c", "d", "q"], R(o)

# 3 最前 / 越界钳到末尾
o2 = ["a", "b"]
G.insert_rows(o2, ["z"], 0); assert o2 == ["z", "a", "b"], o2
G.insert_rows(o2, ["w"], 99); assert o2 == ["z", "a", "b", "w"], o2
assert G.anchor_at(o2, 0) == (None, 0) and G.anchor_at(o2, 99) == (None, 4), G.anchor_at(o2, 99)

# 4 选中的是折叠组头 → 插进组首（折叠组的组头就是它的最后一个渲染行，所以 dest = 行数）；
#   insert_rows 只管布局，折叠标志必须原样留着（展开是 GUI 那边的事）
gy2 = G.SignalGroup("y2", collapsed=True, members=["c"])
o3 = ["a", gy2]
assert R(o3) == ["a", "G:y2"] and G.anchor_at(o3, 2) == (gy2, 0), G.anchor_at(o3, 2)
G.insert_rows(o3, ["n"], 2)
assert gy2.members == ["n", "c"] and gy2.collapsed is True, gy2

# 5 批量插入保持给定顺序；组对象一律不当作新信号塞进去（gy 是已有组，不参与本次插入）
o4 = ["a"]
G.insert_rows(o4, ["x", "y", "z", gy], 1)
assert o4 == ["a", "x", "y", "z"] and gy not in o4, o4

# 6 与 move_rows 同一条锚点规则：同一个落点，拖入与插入落到同一个容器同一个位置
gy4 = G.SignalGroup("y4", members=["c"]); o5 = ["a", gy4]
G.move_rows(o5, [0], 2)                 # 把 "a" 拖到组内 "c" 之后（dest 不含被拖行）
assert gy4.members == ["c", "a"], gy4.members
gy5 = G.SignalGroup("y5", members=["c"]); o6 = ["b", gy5]
G.insert_rows(o6, ["a2"], 3)            # 插到成员 "c" 之后（锚点行号含全部现存行）
assert gy5.members == ["c", "a2"], gy5.members
print("B12 纯函数 self-check OK")
EOF
```

```bash
# B12-GUI：无头端到端（含真实入口 _on_add_signals / _paste_signals）
python3 - <<'EOF'
import os; os.environ["QT_QPA_PLATFORM"]="offscreen"
import sys; sys.path.insert(0, "/Users/sunyuan/Desktop/apb_usb/tools")
import wave_debugger as wd, wave_groups as G
from PySide6.QtWidgets import QApplication
for _m in ("warning","critical","information"):
    setattr(wd.QMessageBox, _m, staticmethod(lambda *a, **k: None))
app = QApplication([]); B = "/Users/sunyuan/Desktop/apb_usb"
w = wd.WaveDebuggerMain(); w._open_vcd(f"{B}/sim/tx/tx_abort.vcd")
ws, ls, wp = w.wave_panel.wave_scene, w.wave_panel.label_scene, w.wave_panel

vis = lambda: ["G" if G.is_group(i) else i for i in ws._displayed]
def wiring():
    assert ls._displayed is ws._displayed and ls._order is ws._order, "标签列别名断了"
    assert abs(ws.sceneRect().height()-ls.sceneRect().height()) < 1
    if ws._displayed:
        assert ws._row_y(len(ws._displayed)-1) + wd.ROW_HEIGHT <= ws.sceneRect().height()

sigs = w._analyzer.header.get("signals", [])
pick, seen = [], set()
for s in sigs:
    if s.vcd_id not in seen:
        seen.add(s.vcd_id); pick.append(s.vcd_id)
        if len(pick) == 14: break
A,B,C,D,E,F,H,I,J,X,Y,Z,K,L = pick

ls.clear_selection(); wp.add_signals([A,B,C])          # 没选中 → 原语义：追加到末尾
assert vis() == [A,B,C] and ls.selected_rows() == [0,1,2], vis()   # 新行自动成为选中行

ls.select_at_index(0); wp.add_signals([D])             # 选中一条 → 插在它下面
assert vis() == [A,D,B,C] and ls.selected_rows() == [1], vis()

ls._selected_indices = {2,3}; wp.add_signals([E])      # 多选 → 插在选中块**最下面**一行之后
assert vis() == [A,D,B,C,E] and ls.selected_rows() == [4], vis()

g = ws.create_group_from_rows([2,3], "通路")           # B、C 建组
assert vis() == [A,D,"G",B,C,E] and g.members == [B,C], vis()
ls.select_at_index(3); wp.add_signals([F])             # 选中组内成员 → 插在它后面、仍是组成员
assert g.members == [B,F,C] and ls.selected_rows() == [4], g.members

ws.set_group_collapsed(g, True)
assert vis() == [A,D,"G",E], vis()
ls.select_at_index(2); wp.add_signals([H])             # 选中折叠组头 → 组首 + 自动展开
assert not g.collapsed, "插进折叠组必须自动展开，否则新行看不见"
assert g.members == [H,B,F,C] and vis() == [A,D,"G",H,B,F,C,E], g.members

ls.clear_selection(); wp.add_signals([I])              # 没选中且末尾是组 → 仍是**顶层**信号
assert vis() == [A,D,"G",H,B,F,C,E,I] and I not in g.members, vis()
wiring()

ws.set_group_hidden(g, True)
assert vis() == [A,D,E,I], vis()
ls.select_at_index(1); wp.add_signals([J])             # 隐藏组不占行号：锚点不能按 _order 下标算
assert vis() == [A,D,J,E,I] and list(ws._order) == [A,D,J,g,E,I], vis()

ws.set_group_hidden(g, False)
ls.select_at_index(0); wp.add_signals([X,Y,Z])         # 一次多条 → 按给定顺序排在锚点下面
assert vis()[:4] == [A,X,Y,Z] and ls.selected_rows() == [1,2,3], vis()
wiring()

ls.select_at_index(0)
w._on_add_signals([K])                                 # 真实入口：信号树双击 / 代码窗口 Ctrl+Click
assert vis()[1] == K, vis()
wp._clipboard = [L]; wp._paste_signals()               # 粘贴 = 另一个 add_signals 调用方
assert vis()[2] == L and ls.selected_rows() == [2], vis()
wiring()
print("B12 GUI self-check OK")
EOF
```

```bash
# B13-纯函数：值串 → 位串 → 切片；去重；非法输入
python3 - <<'EOF'
import sys; sys.path.insert(0, "/Users/sunyuan/Desktop/apb_usb/tools")
from wave_debugger import parse_bit_spec as p, value_to_bits as vb, slice_bits as sb, slice_transitions as st

# 1 位段写法：裸数字 / 带方括号 / 带空格 / 写反了自动交换 / 非法一律 None
assert p("1") == (1,1) and p("[1]") == (1,1)
assert p("7:4") == (7,4) and p("[7:4]") == (7,4) and p(" 3 : 0 ") == (3,0)
assert p("4:7") == (7,4), "写反了也应认"
for bad in ("", "x", "-1", "[]", "1:", None): assert p(bad) is None, bad

# 2 三种真实值形状（format_value 的输出）：'8'hC3' / 裸字符 / 带尾空格的 'bx '
assert vb("8'hC3", 8) == "11000011"
assert vb("1", 4) == "1111" and vb("0", 4) == "0000" and vb("x", 4) == "xxxx" and vb("z", 3) == "zzz"
assert vb("bx ", 7) == "xxxxxxx", "含 x/z 的多 bit 是**带尾空格**的原始串（int() 失败时原样返回）"

# 3 短值补 0（与 format_value 的 int(bits,2) 一致）；只有最左字符是 x/z 才按它扩展；超宽右锚定裁高位
assert vb("b1010", 8) == "00001010" and vb("'b1010", 8) == "00001010"
assert vb("bx1", 8) == "xxxxxxx1" and vb("b1x0 ", 8) == "000001x0"
assert vb("8'b11110000", 4) == "0000", "比位宽长就砍掉高位"
assert vb("8'hC3", 8) == "11000011" and vb("hC3", 8) == "11000011" and vb("d5", 4) == "0101"
assert vb("3.14", 8) is None and vb("", 8) is None and vb("8'hGG", 8) is None
assert vb("8'hZZ", 8) == "zzzzzzzz", "hex 里的 z 是合法高阻位（整段展开）"

# 4 切片：单 bit 裸字符 / 整段全 x 缩成一个 x z / 其余 'b'+位串（_draw_scalar_trace 只认第一种形状）
b = vb("8'hC3", 8)                                  # 1100_0011
assert sb(b, 7, 7) == "1" and sb(b, 1, 1) == "1" and sb(b, 3, 3) == "0"
assert sb(b, 7, 4) == "b1100" and sb(b, 3, 0) == "b0011" and sb(b, 0, 0) == "1"
assert sb(vb("bx ", 7), 6, 0) == "x" and sb(vb("bx ", 7), 2, 2) == "x"
# 传进来的是**纯位串**（不是 'b' 前缀的那种）：段里夹 x/z 就原样保留，渲染层会原样显示 'b1x'
assert sb("01x0", 3, 3) == "0" and sb("01x0", 2, 1) == "b1x" and sb("01x0", 2, 2) == "1"

# 5 物化：逐条切 + 相邻同值去重（父表 4 条，bit0 只变一次 → 只剩 2 条），但**首条必须留着**
ptr = [(0, "8'h00", ""), (10, "8'hFF", ""), (20, "8'hFD", ""), (30, "8'h01", "")]
assert st(ptr, 8, 0, 0) == [(0, "0", "0"), (10, "1", "1")], st(ptr, 8, 0, 0)
assert st(ptr, 8, 7, 4) == [(0, "b0000", "b0000"), (10, "b1111", "b1111"), (30, "b0000", "b0000")], \
    st(ptr, 8, 7, 4)
assert st(ptr, 8, 1, 0) == [(0, "b00", "b00"), (10, "b11", "b11"), (20, "b01", "b01")], st(ptr, 8, 1, 0)
assert st([(0, "32'hFFFFFFFF", "")], 32, 0, 0) == [(0, "1", "1")], "恒定不变的位去重后仍有 1 条"
assert st([], 8, 0, 0) == []
# 32 位计数器只翻低位的场景：bit31 只该剩真正变化的那几条
cnt = [(i, f"32'h{i:X}", "") for i in range(0, 64, 4)]
assert len(st(cnt, 32, 31, 31)) <= 2, st(cnt, 32, 31, 31)
print("B13 纯函数 self-check OK")
EOF
```

```bash
# B13-GUI：无头端到端（加切片 / 菜单真入口 / 会话 v5 往返 / Ctrl+R 重载）
python3 - <<'EOF'
import os, json; os.environ["QT_QPA_PLATFORM"]="offscreen"
import sys; sys.path.insert(0, "/Users/sunyuan/Desktop/apb_usb/tools")
import wave_debugger as wd, wave_groups as G
from PySide6.QtWidgets import QApplication, QMenu
for _m in ("warning","critical","information"):
    setattr(wd.QMessageBox, _m, staticmethod(lambda *a, **k: None))
app = QApplication([]); B = "/Users/sunyuan/Desktop/apb_usb"
VCD = f"{B}/sim/tx/tx_abort.vcd"
w = wd.WaveDebuggerMain(); w._show_load_report = lambda *s, **k: None   # 报告框无头下会阻塞
w._open_vcd(VCD)
wp, ws, ls = w.wave_panel, w.wave_panel.wave_scene, w.wave_panel.label_scene
cache = w._cache
vb, sb = wd.value_to_bits, wd.slice_bits
sub = lambda m, t: next((list(x.actions()) for x in m.findChildren(QMenu) if t in x.title()), None)
def wiring():
    assert ls._displayed is ws._displayed and ls._order is ws._order, "标签列别名断了"
    assert abs(ws.sceneRect().height()-ls.sceneRect().height()) < 1

parent = [s for s in w._analyzer.header["signals"] if s.width == 8][0]
wp.add_signals([parent.vcd_id])
assert wp.add_bit_slice(parent.vcd_id, 1, 1) is True
k1 = cache._make_slice_key(parent.vcd_id, 1, 1)
assert cache.is_derived(k1) and cache.get_signal(k1).width == 1 and k1 in ws._displayed
assert wp.add_bit_slice(parent.vcd_id, 7, 4) is True
k4 = cache._make_slice_key(parent.vcd_id, 7, 4)
assert cache.get_signal(k4).width == 4 and cache.get_signal(k4).full_path.endswith("[7:4]")

# 交叉验：切片值 == 父信号值切出来的位（真实 VCD 数据，不是自证）；并断言已去重
ptr = cache.get_transitions(parent.vcd_id)
def v_at(t, time):
    v = None
    for et, x, _f in t:
        if et <= time: v = x
        else: break
    return v
for t, pv, _f in ptr:
    assert v_at(cache.get_transitions(k1), t) == sb(vb(pv, 8), 1, 1), (t, pv)
    assert v_at(cache.get_transitions(k4), t) == sb(vb(pv, 8), 7, 4), (t, pv)
for k in (k1, k4):
    tr = cache.get_transitions(k)
    assert tr and all(x[1] != y[1] for x, y in zip(tr, tr[1:])), (k, tr[:4])
assert all(x[1] in ("0","1","x","z") for x in cache.get_transitions(k1)), "单 bit 必须是裸字符"

# 越界 / 非法：不加行、返回 False
n = len(ws._displayed)
for msb, lsb in ((0,8), (3,9), (8,8), (-1,0), (2,3)):
    assert wp.add_bit_slice(parent.vcd_id, msb, lsb) is False, (msb, lsb)
assert wp.add_bit_slice("不存在的id", 1, 1) is False and len(ws._displayed) == n

# B12 语义照旧：插在选中行下面 + 新行成为选中行
ls.select_at_index(0); assert wp.add_bit_slice(parent.vcd_id, 0, 0) is True
k0 = cache._make_slice_key(parent.vcd_id, 0, 0)
assert ws._displayed[1] == k0 and ls.selected_rows() == [1]
texts = [i.toPlainText() for i in ls.items() if hasattr(i, "toPlainText")]
assert not any("[7:4][3:0]" in t for t in texts), "派生行不该再拼一次宽度后缀"
assert wp._fp_of_vcd(k4) == parent.full_path, "派生行的 full_path 必须解析回父"
assert ws._signal_color[k4] == ws._signal_color[parent.vcd_id], "颜色要继承父信号"
wiring()

# 菜单真入口：用**构造器**拿菜单（QMenu.exec 是纯 C++ 函数，patch 不掉，弹了就永久阻塞）
acts = sub(wp._build_color_menu(parent.vcd_id, 0), "显示位")
assert acts and f"{parent.name}[7]" in [a.text() for a in acts] and "指定位 / 位段…" in [a.text() for a in acts]
acts4 = sub(wp._build_color_menu(k4, ws._displayed.index(k4)), "显示位")
assert "显示完整信号" in " ".join(a.text() for a in acts4)
assert "State Names" not in " ".join(a.text() for a in sub(wp._build_color_menu(k4, None), "Radix") or []), \
    "切片不给状态名（下标变了会张冠李戴）"
assert "State Names" in " ".join(a.text() for a in sub(wp._build_color_menu(parent.vcd_id, 0), "Radix") or [])
n = len(ws._displayed)
[a for a in acts if a.text() == f"{parent.name}[2]"][0].trigger()          # 点菜单 == 真入口
assert len(ws._displayed) == n + 1 and cache._make_slice_key(parent.vcd_id, 2, 2) in ws._displayed

# 代码窗口入口：候选唯一 → 发信号 → 主窗口连到面板；手输位段走 _ask_bit_text seam
cp = w.code_panel; cp._sig_candidates_for_word = lambda word: [parent]
cacts = sub(cp._build_signal_menu(parent.name), "显示位")
assert cacts and f"{parent.name}[7]" in [a.text() for a in cacts]
n = len(ws._displayed)
[a for a in cacts if a.text() == f"{parent.name}[5]"][0].trigger()
assert len(ws._displayed) == n + 1 and cache._make_slice_key(parent.vcd_id, 5, 5) in ws._displayed
cp._ask_bit_text = lambda t, p: ("3:1", True); cp._prompt_bit_spec_by_sig(parent)
assert cache._make_slice_key(parent.vcd_id, 3, 1) in ws._displayed
cp._ask_bit_text = lambda t, p: ("9:8", True)                        # 越界：只警告，不加行
n = len(ws._displayed); cp._prompt_bit_spec_by_sig(parent); assert len(ws._displayed) == n

# 会话 v5：派生行存父身份 + bits；载回后**必须还有跳变数据**（B13 的原始症状：全行 no data）
ws.create_group_from_rows([0, 1], "通路")
SS = "/tmp/b13_selfcheck.wvs"; w._save_session(SS)
d = json.load(open(SS))
assert d["version"] == 5 and "groups" in d
sl = [e for e in d["signals"] if e.get("bits") == [7, 4]]
assert len(sl) == 1 and sl[0]["full_path"] == parent.full_path and sl[0]["width"] == 8
assert sl[0]["leaf"] == parent.name and sl[0]["scope_modules"], "派生行要存父的身份，否则跨 case 适配失效"
w2 = wd.WaveDebuggerMain(); w2._show_load_report = lambda *s, **k: None
w2._open_vcd(VCD); w2._load_session(SS)
c2 = w2._cache
assert [("G:"+i.name if G.is_group(i) else i) for i in w2.wave_panel.wave_scene._displayed] == \
       [("G:"+i.name if G.is_group(i) else i) for i in ws._displayed], "行结构不一致"
for k in (k0, k1, k4):
    assert c2.get_transitions(k), f"{k} 载回后没有跳变数据（= 会话加载没 preload → 全行红框 no data）"
assert c2.get_transitions(parent.vcd_id), "普通信号载回后也要有数据（B13 的原始症状）"
assert c2.get_signal(k4).width == 4 and w2.wave_panel.wave_scene._order is w2.wave_panel.label_scene._order

# 坏 bits（越界 / 形状不对）→ 判 FAIL_BITS、不静默、也不许把整场载入打断
for patch, tag in (([15, 8], "越界"), ("7:4", "形状不对")):
    bad = json.load(open(SS))
    for e in bad["signals"]:
        if e.get("bits") == [7, 4]: e["bits"] = patch; break
    p = f"/tmp/b13_selfcheck_{tag}.wvs"; json.dump(bad, open(p, "w"))
    R = {}; w3 = wd.WaveDebuggerMain()
    w3._show_load_report = lambda s, r, dg=(): R.update(res=list(r), fail=s.get("fail"))
    w3._open_vcd(VCD); w3._load_session(p)
    assert "FAIL_BITS" in [x["status"] for x in R["res"]], (tag, [x["status"] for x in R["res"]])
    assert R["fail"] >= 1 and not w3._cache.is_derived(k4), tag
    assert w3._cache.get_transitions(parent.vcd_id), f"{tag} 的坏行不该拖垮其它行"

# Ctrl+R 重载：行结构 + 数据都在
w2._on_reload_vcd()
assert w2._cache.get_transitions(k4) and w2._cache.get_transitions(parent.vcd_id), "重载后没数据（B13）"
assert w2._cache.get_signal(k4).width == 4
print("B13 GUI self-check OK")
EOF
```

# B15 自检：时间标签的小数位随量级走，且相邻刻度必须能区分

```bash
python3 - <<'EOF'
import os; os.environ.setdefault("QT_QPA_PLATFORM","offscreen")
import sys; sys.path.insert(0,"/Users/sunyuan/Desktop/apb_usb/tools")
import wave_debugger as wd
from PySide6.QtWidgets import QApplication
app=QApplication([]); w=wd.WaveDebuggerMain()
f=w.wave_panel.wave_scene._format_time

for ps, exp in [(0,"0ps"), (120,"120ps"), (1500,"1.5ns"), (200000,"200ns"),
                (20833,"20.833ns"), (20834,"20.834ns"), (83300,"83.3ns"),
                (1000000,"1us"), (1234567,"1.234567us"), (3700000,"3.7us"),
                (3720000,"3.72us"), (3750000,"3.75us"),
                (2000000000,"2ms"), (9900000000,"9.9ms")]:
    assert f(ps) == exp, (ps, f(ps), exp)

# 不长出无谓的精度：整数毫秒 / 3 位就够的纳秒值不补零
assert f(3000000000) == "3ms" and f(3012106801) == "3.012107ms"
assert f(20833333) == "20.833333us", f(20833333)

# 刻度标签两两不同（B15 的原始症状：全是 '3.7us'）。
# 两组都是本项目的真实窗口：connect 的 200ns 亚微秒窗、挂起/唤醒的 3ms 窗。
sc = w.wave_panel.wave_scene
for t0, span in ((3700000, 200000), (3012080000, 180000)):
    iv = sc._nice_tick_interval(span)
    assert iv < span, (t0, span, iv)
    labels = [f(t) for t in range(t0, t0 + span + 1, iv)]
    assert len(set(labels)) == len(labels), (t0, span, labels)
    print(f"B15 self-check: {span}ps 窗 {len(labels)} 个刻度: {' '.join(labels)}")
print("B15 self-check OK")
EOF
```
