# rtl_autogen.py — Verilog RTL 自动化工具箱

## 功能描述

单文件 Python 脚本（仅标准库，无第三方依赖），针对 Verilog-2001 风格 RTL 提供
五个子命令。lint 规则对标 Verilator/verible，实例化生成对标 Emacs
verilog-mode 的 AUTOINST 幂等展开，文件流程支持工业界 .f filelist：

| 子命令 | 功能 |
|--------|------|
| `ports` | 解析 module 端口列表（ANSI / 非 ANSI 自适应），文本 / `--json` / `--md` 三种输出 |
| `lint` | 信号级检查：未驱动 / 未使用 / **未声明** / **多驱动** / **锁存器？**；`--style` 附加风格检查 |
| `tree` | 模块层次树 + 实例端口连接核对（连错端口、漏连、未定义模块、循环实例化） |
| `tb` | 按 DUT 端口一键生成测试台骨架（时钟/复位/实例化/波形转储），生成即可编译 |
| `gen` | `// INST:` 注释驱动实例化生成；`--inplace` 原地回写并标记包裹，**可反复再生成** |

**文件参数可以是文件或目录**（递归收集 `*.v`/`*.sv`，批内目录自动作为
include 搜索目录），也可以用 `-f design.f` 读工业界 filelist
（支持 `#` 注释、`+incdir+`、嵌套 `-f`；路径相对 .f 文件所在目录）。

## lint 检查项（对标 Verilator 规则名）

| 标记 | 对标 | 含义 |
|------|------|------|
| `[未驱动]` | UNDRIVEN | 有引用但无任何驱动源 |
| `[未使用]` | UNUSEDSIGNAL | 有驱动但从未被读取（或 input 端口从未被读） |
| `[未驱动且未使用]` | — | 完全无引用，可直接删除 |
| `[未声明]` | 隐式网线 / `default_nettype none` | 未声明标识符 — 隐式 1bit 网线或拼写错误 |
| `[多驱动]` | MULTIDRIVEN | 同一信号被 ≥2 个 always 块 / assign+always / 多实例输出驱动 |
| `[锁存器?]` | LATCH | 组合 always 有 if 无 else / 有 case 无 default |
| `[风格]` | DECLFILENAME / verible | `--style` 时：模块名与文件名不一致、超 100 列、Tab 缩进（不计退出码） |

抗误报设计（TB 常见写法不报）：

- `if (cnt <= 9)` 的比较 `<=`、字符串内 `x = y`、参数/函数/块标签不算信号；
- `initial clk = 0;` + `always #5 clk = ~clk;`（TB 时钟标准写法）不算多驱动；
- task/function 体内的写入是调用时序执行，归初始化语义，不与 always 冲突；
- `\`ifdef` 宏名（可能由命令行 `-D` 提供）、`` `include `` 链上的任务/宏/
  参数名自动识别为已知；include 任务内的信号使用计入读取分析；
- 未知子模块的实例连接保守处理（宁漏报不误报）。

```bash
python3 rtl_autogen.py lint src/ --all     # 全工程 + 列出信号定义
python3 rtl_autogen.py lint src/ --style   # 附加风格检查
python3 rtl_autogen.py lint -f sim/filelist.f
python3 rtl_autogen.py lint src/ --json    # JSON (接工具链)
# 退出码: 0=干净  2=有问题  1=错误 (风格提示不计入)
```

## tree — 层次树 + 端口连接核对

```bash
python3 rtl_autogen.py tree src/
```

```
顶层候选 1 个:
└─ top_usb3 (顶层)  [test/top_inplace.v:1]
   ├─ u_stuff: usb_bit_stuff  [../src/common/usb_bit_stuff.v:15]
   └─ u_crc16: usb_crc16  [../src/common/usb_crc16.v:23]
```

核对：连了不存在的端口 / 输入输出漏连 / 未定义模块 / 循环实例化，
问题以 `⚠` 标出并计入退出码 2。

## tb — 测试台骨架生成

```bash
python3 rtl_autogen.py tb src/common/usb_crc5.v -o sim/crc5/tb_auto.v
python3 rtl_autogen.py tb src/sie/usb_sie_cdc.v --period 83.3 -n tb_cdc
```

- `clk`/`*clk` → 带初值的时钟发生器（`parameter CLK_PERIOD` 可调）
- `rstn`/`rst_n`/`rst` → 按高/低有效生成复位流程
- input → `reg` 激励区、output/inout → `wire`/`tri` 观测区（带回端口注释）
- 命名端口实例化 + `$dumpfile/$dumpvars` + 激励自检 TODO 区

生成结果经 iverilog `-g2001` 编译运行验证（6 端口与 22 端口双时钟域模块）。

## gen — INST 注释驱动的实例化生成

在顶层模块体内、希望实例化的位置写 INST 注释：

```verilog
    // INST: ../../src/common/usb_bit_stuff.v  u_stuff
    // INST: ../../src/common/usb_crc16.v  u_crc16  .d_in=d_out .crc_en=d_out_valid .crc_clr=1'b0
```

- 实例名省略默认 `u_<模块名>`；行内 `.端口=连线` 显式重连（也接受常量
  `.crc_clr=1'b0`），重连过的端口不再参与来源检查
- 输入自动连同名网络（顶层端口/手写信号/前面实例生成的连线），无来源记
  `[未驱动]`；输出对接顶层同名端口或自动生成 `wire`（被占则
  `<实例名>_<端口名>`）；`#(参数)` 按默认值展开

```bash
# 方式一: 生成代码片段 (手工粘贴)
python3 rtl_autogen.py gen top_usb.v -o gen_snippet.v

# 方式二: 原地回写 (推荐) — INST 注释替换为标记包裹的生成块, 备份 .bak
python3 rtl_autogen.py gen top_usb.v --inplace
```

**标记幂等再生成**（verilog-mode AUTOINST 式）：`--inplace` 展开的块由

```verilog
    //<<< rtl_autogen:begin <文件引用> <实例名> [.端口=连线 ...]
    ...生成代码...
    //>>> rtl_autogen:end
```

包裹。修改子模块端口、改名连线后**重跑同一条命令**即可整段再生成，
顶层文件长期演进无需手工同步；多次运行结果幂等（已验证）。
生成后自动输出连通性检查（`--no-check` 关闭）。

## 命令行速查

```
rtl_autogen.py [--version]
  ports  <file|dir>... [-f filelist]... [--json] [--md]
  lint   <file|dir>... [-f filelist]... [--all] [--json] [--style]
  tree   <file|dir>... [-f filelist]... [--no-check]
  tb     <dut.v> [-m module] [-o out.v] [-n tb_name] [--period ns]
  gen    <top.v> [-o out.v | --inplace] [-I dir]... [--no-comments] [--no-check]
```

## 自检 / 测试

```bash
cd rtl_auto_tools
python3 rtl_autogen.py lint test/tb_edge.v        # 边界用例 (6 雷)
python3 rtl_autogen.py lint test/lint_new.v       # 新检查项用例 (多驱动/未声明/锁存器)
python3 rtl_autogen.py lint ../src/               # 真实工程 (usb_rx_cdr 2 个真问题)
python3 rtl_autogen.py lint ../sim/               # TB 压测 (1 个真死信号, 零误报)
python3 rtl_autogen.py tree test/hier_bad.v       # 端口连错抓取
python3 rtl_autogen.py tb ../src/common/usb_crc5.v -o /tmp/tb.v
iverilog -g2001 -o /tmp/tb.vvp /tmp/tb.v ../src/common/usb_crc5.v && vvp /tmp/tb.vvp
python3 rtl_autogen.py gen test/top_usb.v         # 片段模式
python3 rtl_autogen.py gen test/top_usb3.v --inplace -I ../src/common   # 标记展开
```

测试文件：`test/tb_edge.v`（lint 边界 6 雷）、`test/lint_new.v`（多驱动/
未声明/锁存器/风格）、`test/hier_bad.v`（tree 端口核对）、
`test/top_usb*.v`（INST 骨架）、`test/design.f`（filelist）。

## 已知边界（按需再扩展）

- 面向 Verilog-2001 常用子集；SystemVerilog 的 interface/struct/modport、
  `always_ff` 等未专门处理（`logic` 声明可识别）。
- lint/tree 的跨模块识别要求相关模块在同一批文件参数里（给目录或 -f 最省心）。
- include 解析按 文件同目录 → 批内目录 → `-I` 顺序；批外 include 需
  filelist `+incdir+` 指路。
- `defparam`、`generate` 块内条件实例、`configure` 等罕见语法未覆盖。
- 参数化位宽 `[W-1:0]` 按参数默认值求值，求不出时按原文显示。
- tb 生成假设单一时钟/复位取第一个匹配端口；多时钟域需手动补齐。
- 位宽不匹配检查（Verilator WIDTH）未实现 — 建议与 `verilator --lint-only`
  组合使用作为 CI 二道防线。
