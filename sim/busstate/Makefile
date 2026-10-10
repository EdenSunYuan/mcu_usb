#============================================================================
# sim/busstate Makefile — usb_bus_state 总线状态检测单元测试
#
# 被测: src/phy/usb_bus_state.v（一条计数器 + 两个标志位 + 两个翻转位，无状态机；
#       判据跑 ref_clk，四个事件脉冲在 clk12m 组合直出）
# 只有一份 DUT，无 MODE 开关。14 个用例；其中 bs_clk_jitter 需 +jit=1
# （clk12m 走 3/4/5 拍抖动），本 Makefile 对该用例自动加，其余不加。
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

RTL_SRC  := ../../src/phy/usb_bus_state.v
TB_TOP   := tb_bus_state.v
VVP_OUT  := busstate.vvp
LOG_OUT  := sim_busstate.log

CASES := bs_reset_default \
         bs_connect \
         bs_suspend \
         bs_resume \
         bs_short_k \
         bs_threshold_scan \
         bs_self_drive \
         bs_bus_rst \
         bs_two_resets \
         bs_usb_rst \
         bs_k_when_awake \
         bs_se1_stuck \
         bs_clk_jitter \
         bs_latency_phase

build: $(VVP_OUT)

$(VVP_OUT): $(TB_TOP) $(RTL_SRC) ../common/*.vh case_*.v
	$(IVERILOG) $(VFLAGS) -o $@ $(TB_TOP) $(RTL_SRC)

# 每个用例的额外 plusarg: bs_clk_jitter 需要抖动时钟
JIT_EXTRA = extra=""; if [ "$$c" = "bs_clk_jitter" ]; then extra="+jit=1"; fi;

run: $(VVP_OUT)
	@pass=0; fail=0; \
	for c in $(CASES); do \
		$(JIT_EXTRA) \
		printf '  %-22s ' "$$c"; \
		if $(VVP) $(VVP_OUT) +case=$$c $$extra +vcd=$$c.vcd > sim_busstate_$$c.log 2>&1 \
		   && grep -q 'TEST PASSED' sim_busstate_$$c.log; then \
			echo "PASS"; pass=$$((pass+1)); \
		else \
			echo "FAIL"; fail=$$((fail+1)); \
		fi; \
	done; \
	cat sim_busstate_*.log > $(LOG_OUT); \
	echo "==== busstate: $$pass passed, $$fail failed ===="; \
	if [ $$fail -ne 0 ]; then exit 1; fi

# clean 保留 *.vcd（波形，用户查看用）与 *.wvs（波形会话，用户配置）；
# 只清可再生的 .vvp/.log。★ 不动 cov/ —— 覆盖率数据另用 covclean。
clean:
	rm -f busstate.vvp sim_busstate*.log

#============================================================================
# cov — Verilator 覆盖率（行 / 分支 / 翻转 / 表达式），14 用例跨用例合并
#
#   用法: make cov         # 跑全 14 用例 → 合并 → 打印 summary
#         make fsmcov      # 合并标志位状态/迁移矩阵（TB 侧自建）
#         make covclean    # 删 cov/
#
#   ★ 报数口径: 判读时看 **DUT 模块**（usb_bus_state）那一行，不是全层级 summary
#     —— TB 自己的时钟发生器/统计逻辑会把 summary 拉低，与 DUT 质量无关。
#   ★ FSM 维度: 本模块没有状态机，工具认不出任何 FSM（也没得认）。这一维改数
#     {connected, suspended} 两个标志位的组合与迁移 —— 它就是本模块的状态。
#============================================================================
VERILATOR ?= verilator
VCOV      ?= verilator_coverage

COV_DAT   := cov/dat
COV_MERGE := cov/merged.dat
COV_BIN   := cov/busstate_cov

VCOVFLAGS := --binary --timing --coverage --coverage-fsm -Wno-fatal \
             -I../../src/inc -I../common

# ★ 父目录必须自己建: Verilator 的 -Mdir 只建最后一级，不会连父目录一起建。
covdir:
	@mkdir -p cov

$(COV_BIN): $(TB_TOP) $(RTL_SRC) ../common/*.vh case_*.v | covdir
	$(VERILATOR) $(VCOVFLAGS) --top-module tb_bus_state -Mdir cov/obj \
		-o ../busstate_cov $(TB_TOP) $(RTL_SRC)

cov: $(COV_BIN)
	@rm -rf $(COV_DAT); mkdir -p $(COV_DAT)
	@for c in $(CASES); do \
		$(JIT_EXTRA) \
		( cd $(COV_DAT) && ../busstate_cov +case=$$c $$extra > $$c.log 2>&1 \
		  && mv coverage.dat $$c.dat ) \
		  || { echo "覆盖率运行失败: $$c" >&2; exit 1; }; \
		grep -q 'TEST PASSED' $(COV_DAT)/$$c.log \
		  || { echo "覆盖率运行中有用例未通过: $$c (见 $(COV_DAT)/$$c.log)" >&2; exit 1; }; \
	done
	@$(VCOV) --write $(COV_MERGE) $(COV_DAT)/*.dat > /dev/null
	@echo "==== busstate 覆盖率 (14 用例合并) ===="
	@$(VCOV) --report summary $(COV_MERGE)

# 标志位状态/迁移覆盖（TB 侧统计；见 tools/merge_fsm_cov.py 的 busstate profile）
fsmcov:
	@for c in $(CASES); do \
		$(JIT_EXTRA) \
		./$(COV_BIN) +case=$$c $$extra > cov/fsm_$$c.log 2>&1; \
	done
	@python3 ../../tools/merge_fsm_cov.py --profile busstate cov/fsm_*.log

covclean:
	rm -rf cov

.PHONY: build run clean debugwave cov covdir fsmcov covclean

#============================================================================
# debugwave — 跑所选仿真并直接打开波形软件 (wave_debugger)
#
#   用法:
#     make debugwave                        # 交互菜单: 列 14 个 case 供选
#     make debugwave CASE=bs_threshold_scan # 直接指定
#     (根入口: make debugwave MOD=busstate CASE=...)
#
#   行为: ① 强制以 VCD=1 重编（-DVCD_SAVE 是编译期宏，只跑不重编译不写 .vcd）
#         ② 只跑所选 case 存 <case>.vcd ③ 打开 ../../tools/wave_debugger.py
#   看波形重点: ref_clk 域的 cnt / 两个判据（单拍）与 clk12m 域的四个输出脉冲，
#     一次事件应当是「判据 1 拍 → 翻转 1 次 → 脉冲 1 拍」。
#============================================================================
WAVE_OPEN := python3 ../../tools/wave_debugger.py

debugwave:
	@rm -f $(VVP_OUT); \
	$(MAKE) build VCD=1; \
	sel="$(CASE)"; \
	if [ -z "$$sel" ]; then \
		echo "选择要查看波形的 busstate 仿真:"; \
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
	extra=""; if [ "$$sel" = "bs_clk_jitter" ]; then extra="+jit=1"; fi; \
	echo "== debugwave: $$sel =="; \
	$(VVP) $(VVP_OUT) +case=$$sel $$extra +vcd=$$sel.vcd > sim_busstate_$$sel.log 2>&1; \
	if [ $$? -ne 0 ]; then echo "警告: 仿真非 0 退出, 见 sim_busstate_$$sel.log (仍尝试打开波形)"; fi; \
	tail -n 2 sim_busstate_$$sel.log; \
	if [ -f $$sel.vcd ]; then \
		echo "打开波形: $$sel.vcd ($(WAVE_OPEN))"; \
		$(WAVE_OPEN) $$sel.vcd; \
	else \
		echo "错误: 未生成 $$sel.vcd (确认 VCD=1 编译且 case 名正确)" >&2; exit 1; \
	fi
