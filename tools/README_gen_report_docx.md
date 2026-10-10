# gen_report_docx.py — Markdown 报告导出 Word（.docx）

## 功能描述

解析仓库里的 Markdown 报告，生成排版一致的 Word 版本：宋体正文 / Consolas 代码、
四级蓝色标题、Table Grid 表格（表头带底色）、灰底代码块、图居中内嵌并在下方给图注。

它取代了原先一份报告一个的 `gen_cdr_design_docx.py` / `gen_cdr_report_docx.py`：那两个脚本
把内容写死在 Python 里，Markdown 一改就与 docx 对不上（CDR 那份早已过时）。现在内容源只有
Markdown 一份，docx 随时重出。

## 使用方法

```bash
# 输出同名 .docx，落在 Markdown 同目录
python3 tools/gen_report_docx.py doc/design_rpt/bus_state_design.md

# 指定 Word 版文件名（按 §0 命名约定放在 doc/ 下）
python3 tools/gen_report_docx.py doc/design_rpt/bus_state_design.md \
    -o doc/总线状态检测设计报告.docx

# 只解析不写文件：打印块统计与缺图，用来核对转换覆盖
python3 tools/gen_report_docx.py doc/design_rpt/bus_state_verification.md --dry-run
```

| 参数 | 说明 |
|------|------|
| `md` | 输入的 Markdown 文件（位置参数） |
| `-o` / `--out` | 输出的 docx 路径；省略时与 Markdown 同名同目录 |
| `--dry-run` | 不写文件，打印各类块数量与未找到的图 |

## 支持的 Markdown 子集

| 源 | 转成 |
|------|------|
| `# 标题` | 封面标题（居中、20pt、深蓝） |
| `## N. x` / `### N.N x` / `#### x` | 三级蓝色标题 |
| `> 行` | 灰小字（报告头部的模块 / 日期 / 结论块） |
| ` ``` ` 代码块 | 灰底等宽（9.5pt），保留换行 |
| `\| 表格 \|` + 分隔行 | Table Grid，表头加粗带底色 |
| `- 项` / `1. 项` | 圆点缩进 / 保留原编号 |
| `**粗体**`、`` `代码` ``、`[文字](链接)` | 行内样式；链接转 Word 真超链接（外部关系） |
| `📎 [图：说明（x.png）](path/x.png)` | 内嵌 PNG + 图注（图注里去掉文件名后缀） |
| `![alt](x.png)` | 同上 |
| 整行 `*斜体*` | 斜体灰字（报告末尾的注） |

图片路径相对 Markdown 所在目录解析（报告里的 `../fig/x.png` 直接可用）；找不到时在 docx 里
留一行红字 `[缺图：路径]`，并在 stdout 报出来，不会静默丢图。

## 依赖

`python-docx`（已验证 1.2.0）：

```bash
python3 -c "import docx" || pip3 install python-docx
```

## 验收方式

转换后用任意独立阅读器读一遍，确认不是只有 python-docx 自己能读：

```bash
textutil -convert txt -stdout doc/总线状态检测设计报告.docx | head -20   # macOS
```

再核对两项：`--dry-run` 的 `fig` 计数等于 Markdown 里的图链接数、docx 里没有残留的
`**` / `](` / `📎` 这些 Markdown 标记。
