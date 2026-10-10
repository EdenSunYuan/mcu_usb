#============================================================================
# sim/deserial Makefile — usb_rx_deserial 单元测试
#
# MODE 选择 DUT 来源:
#   base     默认: src/phy/usb_rx_deserial.v (定稿, 无门控)  → 基线
#   fixed    src/phy/usb_rx_deserial.v + -DTAIL_EXP_CLEAN -DCONFORM_EXP_CLEAN
#            → 定稿模块做严格断言 (tail R5/R6 与 conformant 必须清 0, 否则 FAIL)
#   gate     sim 本地: usb_rx_deserial_gate.v (EOP SE0 区门控, 组合读 eop_state) → 门控
#   gatesync sim 本地 + -DGATE_SYNC (门控打一拍跨域) → 观察漏拦首个 SE0 解码
#   linese0  sim 本地 + -DGATE_LINESE0 (门控源=ref 域 line_se0 组合读)
#   rawse0   sim 本地 + -DGATE_RAWSE0 (门控源=原始 !rxdp&&!rxdn 引脚组合读)
#   nrzi2    sim 本地 + -DNRZI2 (2拍寄存+同或 NRZI 解码, 门控恒0) → 测解码改法本身
#
# VCD=1 存波形 (每 case 单独 <case>.vcd)
# tail_scan 用 +rmin/+rmax 控扫描范围
#
# ★ MODE 产物改名 (2026-09-07): VVP_OUT 与日志均按 MODE 命名 —
#     deserial_$(MODE).vvp, sim_$(MODE)_<case>.log, 汇总 sim_$(MODE).log。
#   MODE 全由编译期宏决定、RTL 源文件路径不变 → make 不会因 MODE 变化自动重编;
#   旧版切 MODE 必须手 `rm -f deserial.vvp` 才安全 (否则串用上一个 MODE 的二进制)。
#   改名后各 MODE 独立产物, 切 MODE 自动重编新文件, base/fixed 日志证据并存,
#   不再有"以为已最新、实际是旧 MODE"的隐患。clean 请见下方 (清 deserial_*.vvp sim_*.log)。
#============================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
VFLAGS   := -g2012 -Wall -I../../src/inc -I../common

VCD ?= 0
ifeq ($(VCD),1)
VFLAGS += -DVCD_SAVE
endif

MODE ?= base
ifeq ($(MODE),base)
RTL_SRC := ../../src/phy/usb_rx_deserial.v
else ifeq ($(MODE),fixed)
RTL_SRC := ../../src/phy/usb_rx_deserial.v
VFLAGS  += -DTAIL_EXP_CLEAN -DCONFORM_EXP_CLEAN
else ifeq ($(MODE),gate)
RTL_SRC := usb_rx_deserial_gate.v
VFLAGS  += -DGATE_VARIANT -DTAIL_EXP_CLEAN -DCONFORM_EXP_CLEAN
else ifeq ($(MODE),gatesync)
RTL_SRC := usb_rx_deserial_gate.v
VFLAGS  += -DGATE_VARIANT -DGATE_SYNC -DTAIL_EXP_CLEAN -DCONFORM_EXP_CLEAN
else ifeq ($(MODE),linese0)
RTL_SRC := usb_rx_deserial_gate.v
VFLAGS  += -DGATE_VARIANT -DGATE_LINESE0 -DTAIL_EXP_CLEAN -DCONFORM_EXP_CLEAN
else ifeq ($(MODE),rawse0)
RTL_SRC := usb_rx_deserial_gate.v
VFLAGS  += -DGATE_VARIANT -DGATE_RAWSE0 -DTAIL_EXP_CLEAN -DCONFORM_EXP_CLEAN
else ifeq ($(MODE),nrzi2)
RTL_SRC := usb_rx_deserial_gate.v
VFLAGS  += -DGATE_VARIANT -DNRZI2 -DTAIL_EXP_CLEAN -DCONFORM_EXP_CLEAN
else
$(error unknown MODE '$(MODE)' — use base|fixed|gate|gatesync|linese0|rawse0|nrzi2)
endif

TB_TOP   := tb_deserial.v
VVP_OUT  := deserial_$(MODE).vvp
LOG_OUT  := sim_$(MODE).log
CDR_SRC  := ../../src/phy/usb_rx_cdr.v

RMIN ?= 3
RMAX ?= 6

CASES := deserial_out_normal \
         deserial_tail_scan \
         deserial_stuff_viol \
         deserial_se0_stuck \
         deserial_conformant_scan \
         deserial_byte_exact \
         deserial_tail7 \
         deserial_pkt_all \
         deserial_err_eop \
         deserial_sync_scan \
         deserial_eop_glitch

build: $(VVP_OUT)

$(VVP_OUT): $(TB_TOP) $(RTL_SRC) $(CDR_SRC) ../common/*.vh case_*.v
	$(IVERILOG) $(VFLAGS) -o $@ $(TB_TOP) $(RTL_SRC) $(CDR_SRC)

run: $(VVP_OUT)
	@echo "== MODE=$(MODE) =="; \
	pass=0; fail=0; \
	for c in $(CASES); do \
		printf '  %-26s ' "$$c"; \
		if $(VVP) $(VVP_OUT) +case=$$c +vcd=$$c.vcd > sim_$(MODE)_$$c.log 2>&1 \
		   && grep -q 'TEST PASSED' sim_$(MODE)_$$c.log; then \
			echo "PASS"; pass=$$((pass+1)); \
		else \
			echo "FAIL"; fail=$$((fail+1)); \
		fi; \
	done; \
	cat sim_$(MODE)_*.log > $(LOG_OUT); \
	echo "==== MODE=$(MODE): $$pass passed, $$fail failed ===="; \
	if [ $$fail -ne 0 ]; then exit 1; fi

# tail_scan 单独跑 (带 R 范围), VCD=1 时存波形便于看解码 vs eop_state 相位
scan: $(VVP_OUT)
	$(VVP) $(VVP_OUT) +case=deserial_tail_scan +rmin=$(RMIN) +rmax=$(RMAX) +vcd=tail_scan.vcd | tee $(LOG_OUT)

# clean 保留 *.vcd (波形, 用户查看用) 与 *.wvs (波形会话, 用户配置);
# 只清可再生的 .vvp/.log (覆盖改名后的 deserial_<MODE>.vvp 与 sim_<MODE>_*.log, 兼容旧名)。
# 切换 VCD 模式只需 rm 对应 .vvp 重编译, .vcd 由下次 VCD=1 运行按 case 名覆盖刷新。
# ★ 不动 cov/ —— 覆盖率数据另用 covclean (与 .vcd 同一条理由)。
clean:
	rm -f deserial_*.vvp sim_*.log

#============================================================================
# cov — Verilator 覆盖率 (行 / 分支 / 翻转 / 表达式), MODE=base + fixed **合并**
#
#   用法: make cov         # 两个 MODE 各跑全 11 用例 → 合并 → 打印 summary
#         make fsmcov      # 合并 FSM 状态迁移矩阵 (TB 侧自建)
#         make covclean    # 删 cov/
#
#   ★ 为什么 base + fixed 一起合并: 两个 MODE 跑的是**同一份 DUT**
#     (src/phy/usb_rx_deserial.v), 区别只是编译期断言宏 (-DTAIL_EXP_CLEAN
#     -DCONFORM_EXP_CLEAN) 会不会把"应当清 0"的偏差判成 FAIL。base 走的是
#     "宽进"路径, fixed 走的是严格断言路径 —— 两者激励相同, 合并后才是
#     "这套激励整体覆盖了多少 DUT"。gate/gatesync/linese0/rawse0/nrzi2 这几个
#     MODE 用的是 **sim 本地变体** usb_rx_deserial_gate.v, 不是交付 RTL, 不计入。
#
#   规范见 sim/common/README.md「cov / fsmcov Makefile 目标」。
#============================================================================
VERILATOR ?= verilator
VCOV      ?= verilator_coverage

COV_DAT   := cov/dat
COV_MERGE := cov/merged.dat
# ★ -o 是相对 -Mdir 的: -Mdir cov/obj_base + -o ../deserial_cov_base → cov/deserial_cov_base
COV_BIN   := cov/deserial_cov_

VCOVFLAGS := --binary --timing --coverage --coverage-fsm -Wno-fatal \
             -I../../src/inc -I../common
DUT_SRC   := ../../src/phy/usb_rx_deserial.v

# ★ 父目录必须自己建: Verilator 的 -Mdir 只建**最后一级**, 不会连父目录一起建
#   (现象: %Error: Can't write file: cov/obj_base/...__Slow.cpp)。
covdir:
	@mkdir -p cov

cov/deserial_cov_base: $(TB_TOP) $(DUT_SRC) $(CDR_SRC) ../common/*.vh case_*.v | covdir
	$(VERILATOR) $(VCOVFLAGS) --top-module tb_deserial -Mdir cov/obj_base \
		-o ../deserial_cov_base $(TB_TOP) $(DUT_SRC) $(CDR_SRC)

cov/deserial_cov_fixed: $(TB_TOP) $(DUT_SRC) $(CDR_SRC) ../common/*.vh case_*.v | covdir
	$(VERILATOR) $(VCOVFLAGS) -DTAIL_EXP_CLEAN -DCONFORM_EXP_CLEAN \
		--top-module tb_deserial -Mdir cov/obj_fixed \
		-o ../deserial_cov_fixed $(TB_TOP) $(DUT_SRC) $(CDR_SRC)

cov: cov/deserial_cov_base cov/deserial_cov_fixed
	@rm -rf $(COV_DAT); mkdir -p $(COV_DAT)
	@for m in base fixed; do \
		for c in $(CASES); do \
			( cd $(COV_DAT) && ../deserial_cov_$$m +case=$$c +rmin=$(RMIN) +rmax=$(RMAX) \
			  > $$m_$$c.log 2>&1 && mv coverage.dat $$m_$$c.dat ) \
			  || { echo "覆盖率运行失败: MODE=$$m $$c" >&2; exit 1; }; \
			grep -q 'TEST PASSED' $(COV_DAT)/$$m_$$c.log \
			  || { echo "覆盖率运行中有用例未通过: MODE=$$m $$c (见 $(COV_DAT)/$$m_$$c.log)" >&2; exit 1; }; \
		done; \
	done
	@$(VCOV) --write $(COV_MERGE) $(COV_DAT)/*.dat > /dev/null
	@echo "==== deserial 覆盖率 (MODE=base+fixed, 11 用例 × 2 = 22 次运行合并) ===="
	@$(VCOV) --report summary $(COV_MERGE)

# FSM 状态/弧覆盖率 (Verilator 的 --coverage-fsm 认不出本 DUT 的两段式 FSM,
# 改由 TB 侧统计; 见 tools/README_merge_fsm_cov.md)
fsmcov:
	@rm -f $(COV_DAT)/../fsm_*.log 2>/dev/null; \
	for m in base fixed; do \
		for c in $(CASES); do \
			./cov/deserial_cov_$$m +case=$$c +rmin=$(RMIN) +rmax=$(RMAX) \
			  > cov/fsm_$${m}_$$c.log 2>&1; \
		done; \
	done
	@python3 ../../tools/merge_fsm_cov.py --profile deserial cov/fsm_*.log

covclean:
	rm -rf cov

.PHONY: build run scan clean debugwave cov covdir fsmcov covclean

#============================================================================
# debugwave — 跑所选仿真并直接打开波形软件 (wave_debugger)
#
#   用法:
#     make debugwave                                # 交互菜单: 列 11 case (名) 供选
#     make debugwave CASE=deserial_out_normal       # 直接指定 (可脚本化)
#     make debugwave MODE=fixed CASE=deserial_tail_scan  # 指定 MODE 的严格断言版
#     make debugwave CASE=deserial_out_normal       # (根入口: make debugwave MOD=deserial ...)
#
#   行为: ① 强制以 VCD=1 重编当前 MODE (-DVCD_SAVE 是编译期宏, 只跑不重编译不写 .vcd)
#         ② 只跑所选 case 存 <case>.vcd ③ 打开 ../../tools/wave_debugger.py <case>.vcd
#   MODE: 默认 base; 产物已按 MODE 命名 → 重编即当前 MODE, 无需手 rm 其它 MODE。
#   deserial_tail_scan 需 +rmin/+rmax → 恒带 (对其它 case 无害), 可 RMIN=/RMAX= 覆盖。
#
#   ★ 样板: sim/cdr/Makefile (各模块 debugwave 必配, 见 sim/common/README.md)。
#============================================================================
WAVE_OPEN := python3 ../../tools/wave_debugger.py

debugwave:
	@rm -f $(VVP_OUT); \
	$(MAKE) build VCD=1; \
	sel="$(CASE)"; \
	if [ -z "$$sel" ]; then \
		echo "选择要查看波形的 deserial 仿真:"; \
		i=1; for c in $(CASES); do echo "  $$i) $$c"; i=$$((i+1)); done; \
		printf "输入编号或 case 名 [默认 1]: "; read inp; \
		if [ -z "$$inp" ]; then inp=1; fi; \
		case "$$inp" in \
			*[!0-9]*) sel=$$inp ;; \
			*) sel=$$(echo "$(CASES)" | tr ' ' '\n' | sed -n "$${inp}p") ;; \
		esac; \
	fi; \
	ok=0; for c in $(CASES); do if [ "$$c" = "$$sel" ]; then ok=1; fi; done; \
	if [ $$ok -eq 0 ]; then echo "错误: 未知 case '$$sel'. 可选: $(CASES)" >&2; exit 1; fi; \
	echo "== debugwave (MODE=$(MODE)): $$sel =="; \
	$(VVP) $(VVP_OUT) +case=$$sel +rmin=$(RMIN) +rmax=$(RMAX) +vcd=$$sel.vcd > sim_$(MODE)_$$sel.log 2>&1; \
	if [ $$? -ne 0 ]; then echo "警告: 仿真非 0 退出, 见 sim_$(MODE)_$$sel.log (仍尝试打开波形)"; fi; \
	tail -n 2 sim_$(MODE)_$$sel.log; \
	if [ -f $$sel.vcd ]; then \
		echo "打开波形: $$sel.vcd ($(WAVE_OPEN))"; \
		$(WAVE_OPEN) $$sel.vcd; \
	else \
		echo "错误: 未生成 $$sel.vcd (确认 VCD=1 编译且 case 名正确)" >&2; exit 1; \
	fi

.PHONY: build run scan clean debugwave
