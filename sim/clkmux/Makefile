#============================================================================
# sim/clkmux Makefile — usb_clk_mux 无毛刺时钟切换单元测试
#
# 被测: src/phy/usb_clk_mux.v（ref_clk 域 4 态切换 FSM + ÷4 分频 + 组合 MUX）
# 只有一份 DUT（不像 deserial 那样有 sim 本地变体），故无 MODE 开关。
#
# VCD=1 存波形（每 case 单独 <case>.vcd）
#
# 规范见 sim/common/README.md: debugwave / cov / fsmcov / covclean 四目标必配。
#============================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
VFLAGS   := -g2012 -Wall -I../../src/inc -I../common

VCD ?= 0
ifeq ($(VCD),1)
VFLAGS += -DVCD_SAVE
endif

RTL_SRC  := ../../src/phy/usb_clk_mux.v
TB_TOP   := tb_clk_mux.v
VVP_OUT  := clkmux.vvp
LOG_OUT  := sim_clkmux.log

CASES := mux_reset_default \
         mux_tx2rx_glitchfree \
         mux_rx2tx_glitchfree \
         mux_hold_deadtime \
         mux_rcv_midswitch \
         mux_toggle_stress \
         mux_noclk_at_reset

build: $(VVP_OUT)

$(VVP_OUT): $(TB_TOP) $(RTL_SRC) ../common/*.vh case_*.v
	$(IVERILOG) $(VFLAGS) -o $@ $(TB_TOP) $(RTL_SRC)

run: $(VVP_OUT)
	@pass=0; fail=0; \
	for c in $(CASES); do \
		printf '  %-26s ' "$$c"; \
		if $(VVP) $(VVP_OUT) +case=$$c +vcd=$$c.vcd > sim_clkmux_$$c.log 2>&1 \
		   && grep -q 'TEST PASSED' sim_clkmux_$$c.log; then \
			echo "PASS"; pass=$$((pass+1)); \
		else \
			echo "FAIL"; fail=$$((fail+1)); \
		fi; \
	done; \
	cat sim_clkmux_*.log > $(LOG_OUT); \
	echo "==== clkmux: $$pass passed, $$fail failed ===="; \
	if [ $$fail -ne 0 ]; then exit 1; fi

# clean 保留 *.vcd（波形，用户查看用）与 *.wvs（波形会话，用户配置）；
# 只清可再生的 .vvp/.log。★ 不动 cov/ —— 覆盖率数据另用 covclean。
clean:
	rm -f clkmux.vvp sim_clkmux*.log

#============================================================================
# cov — Verilator 覆盖率（行 / 分支 / 翻转 / 表达式），7 用例跨用例合并
#
#   用法: make cov         # 跑全 7 用例 → 合并 → 打印 summary
#         make fsmcov      # 合并 FSM 状态迁移矩阵（TB 侧自建）
#         make covclean    # 删 cov/
#
#   ★ 报数口径: 判读时看 **DUT 模块**（usb_clk_mux）那一行，不是全层级 summary
#     —— tb 自己的 dclk 发生器/统计逻辑会把 summary 拉低，与 DUT 质量无关。
#   ★ FSM 维度由 Verilator 的 --coverage-fsm 试跑，认不出就退回 TB 自数
#     （本 DUT 与 tx/deserial 同为两段式：组合算 stat_nxt + 时序搬 stat_cur）。
#============================================================================
VERILATOR ?= verilator
VCOV      ?= verilator_coverage

COV_DAT   := cov/dat
COV_MERGE := cov/merged.dat
COV_BIN   := cov/clkmux_cov

VCOVFLAGS := --binary --timing --coverage --coverage-fsm -Wno-fatal \
             -I../../src/inc -I../common

# ★ 父目录必须自己建: Verilator 的 -Mdir 只建最后一级，不会连父目录一起建。
covdir:
	@mkdir -p cov

$(COV_BIN): $(TB_TOP) $(RTL_SRC) ../common/*.vh case_*.v | covdir
	$(VERILATOR) $(VCOVFLAGS) --top-module tb_clk_mux -Mdir cov/obj \
		-o ../clkmux_cov $(TB_TOP) $(RTL_SRC)

cov: $(COV_BIN)
	@rm -rf $(COV_DAT); mkdir -p $(COV_DAT)
	@for c in $(CASES); do \
		( cd $(COV_DAT) && ../clkmux_cov +case=$$c > $$c.log 2>&1 \
		  && mv coverage.dat $$c.dat ) \
		  || { echo "覆盖率运行失败: $$c" >&2; exit 1; }; \
		grep -q 'TEST PASSED' $(COV_DAT)/$$c.log \
		  || { echo "覆盖率运行中有用例未通过: $$c (见 $(COV_DAT)/$$c.log)" >&2; exit 1; }; \
	done
	@$(VCOV) --write $(COV_MERGE) $(COV_DAT)/*.dat > /dev/null
	@echo "==== clkmux 覆盖率 (7 用例合并) ===="
	@$(VCOV) --report summary $(COV_MERGE)

# FSM 状态/弧覆盖率（TB 侧统计；见 tools/README_merge_fsm_cov.md）
fsmcov:
	@for c in $(CASES); do \
		./$(COV_BIN) +case=$$c > cov/fsm_$$c.log 2>&1; \
	done
	@python3 ../../tools/merge_fsm_cov.py --profile clkmux cov/fsm_*.log

covclean:
	rm -rf cov

.PHONY: build run clean debugwave cov covdir fsmcov covclean

#============================================================================
# debugwave — 跑所选仿真并直接打开波形软件 (wave_debugger)
#
#   用法:
#     make debugwave                            # 交互菜单: 列 7 个 case 供选
#     make debugwave CASE=mux_tx2rx_glitchfree  # 直接指定
#     (根入口: make debugwave MOD=clkmux CASE=...)
#
#   行为: ① 强制以 VCD=1 重编 (-DVCD_SAVE 是编译期宏，只跑不重编译不写 .vcd)
#         ② 只跑所选 case 存 <case>.vcd ③ 打开 ../../tools/wave_debugger.py
#   看波形重点: clk12m 与 dclk/clk12s 的**相位关系**，过渡态是否为恒 0 的整段。
#============================================================================
WAVE_OPEN := python3 ../../tools/wave_debugger.py

debugwave:
	@rm -f $(VVP_OUT); \
	$(MAKE) build VCD=1; \
	sel="$(CASE)"; \
	if [ -z "$$sel" ]; then \
		echo "选择要查看波形的 clkmux 仿真:"; \
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
	echo "== debugwave: $$sel =="; \
	$(VVP) $(VVP_OUT) +case=$$sel +vcd=$$sel.vcd > sim_clkmux_$$sel.log 2>&1; \
	if [ $$? -ne 0 ]; then echo "警告: 仿真非 0 退出, 见 sim_clkmux_$$sel.log (仍尝试打开波形)"; fi; \
	tail -n 2 sim_clkmux_$$sel.log; \
	if [ -f $$sel.vcd ]; then \
		echo "打开波形: $$sel.vcd ($(WAVE_OPEN))"; \
		$(WAVE_OPEN) $$sel.vcd; \
	else \
		echo "错误: 未生成 $$sel.vcd (确认 VCD=1 编译且 case 名正确)" >&2; exit 1; \
	fi
