#============================================================================
# sim/tx Makefile — usb_tx_serial 单元测试 (PHY 模型 + 已验收发链回环)
#
# DUT: src/phy/usb_tx_serial.v (1× clk12m 域位执行器)
# 回环: phy_model → usb_rx_cdr → usb_rx_deserial (两个都已单独验证)
# 判据: A 端到端回环 (主) / B TB 自写逐位 oracle / C gen_tx_timing.py 跨语言旁证
#       详见 doc/design_rpt/tx_serial_design.md §4.8
#
# 本模块无 MODE 派生需求 (报告 §4.8.6): 只有一份 RTL, 直接跑 20 个用例。
# VCD=1 存波形 (每 case 单独 <case>.vcd)。
#============================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
VFLAGS   := -g2012 -Wall -I../../src/inc -I../common

VCD ?= 0
ifeq ($(VCD),1)
VFLAGS += -DVCD_SAVE
endif

TB_TOP   := tb_tx_serial.v
VVP_OUT  := tx.vvp
LOG_OUT  := sim.log

TX_SRC   := ../../src/phy/usb_tx_serial.v
CDR_SRC  := ../../src/phy/usb_rx_cdr.v
RX_SRC   := ../../src/phy/usb_rx_deserial.v
PHY_SRC  := ../common/phy_model.v

CASES := tx_pid_only \
         tx_pkt_all \
         tx_len_scan \
         tx_stuff_dense \
         tx_tail_stuff \
         tx_sync_pid_nostuff \
         tx_pid_carry \
         tx_eop_timing \
         tx_back2back \
         tx_abort \
         tx_handshake \
         tx_long_loopback \
         tx_byte_sweep \
         tx_all_pid \
         tx_carry_sweep \
         tx_stuff_pos_scan \
         tx_abort_phases \
         tx_idle_between \
         tx_susp_wkup \
         tx_random_stress

build: $(VVP_OUT)

$(VVP_OUT): $(TB_TOP) $(TX_SRC) $(CDR_SRC) $(RX_SRC) $(PHY_SRC) case_*.v ../../src/inc/usb_const.vh
	$(IVERILOG) $(VFLAGS) -o $@ $(TB_TOP) $(TX_SRC) $(CDR_SRC) $(RX_SRC) $(PHY_SRC)

run: $(VVP_OUT)
	@pass=0; fail=0; \
	for c in $(CASES); do \
		printf '  %-24s ' "$$c"; \
		if $(VVP) $(VVP_OUT) +case=$$c +vcd=$$c.vcd > sim_$$c.log 2>&1 \
		   && grep -q 'TEST PASSED' sim_$$c.log; then \
			echo "PASS"; pass=$$((pass+1)); \
		else \
			echo "FAIL"; fail=$$((fail+1)); \
		fi; \
	done; \
	cat sim_tx_*.log > $(LOG_OUT); \
	echo "==== tx: $$pass passed, $$fail failed ===="; \
	if [ $$fail -ne 0 ]; then exit 1; fi

# 单跑一个 case: make one CASE=tx_pid_only
one: $(VVP_OUT)
	$(VVP) $(VVP_OUT) +case=$(CASE) +vcd=$(CASE).vcd | tee sim_$(CASE).log

# clean 保留 *.vcd (波形) 与 *.wvs (波形会话), 只清可再生的 .vvp/.log。
# ★ 不动 cov/ —— 覆盖率数据与构建目录另用 covclean, 免得 `make clean` 顺手毁掉
#   几分钟才跑出来的合并结果 (与 .vcd 同一条理由)。
clean:
	rm -f *.vvp sim_*.log

#============================================================================
# cov — Verilator 覆盖率 (行 / 分支 / 翻转 / 表达式 / FSM)
#
#   用法: make cov            # 跑全 20 用例 → 合并 → 打印 summary + 层级表
#         make covclean       # 删 cov/ (数据 + 构建目录)
#
#   为什么另起 Verilator: iverilog 没有覆盖率能力。两个仿真器跑同一份 TB
#   (VCD 路径已做逐字节等价性双证), 功能判据仍以 iverilog 回归为准, Verilator
#   只负责出覆盖率数字。
#
#   ★ 覆盖率必须**跨用例合并**再判读: 单个用例只走自己那条路径 (例如
#     tx_pid_only 走不到位填充), 合并后才是"这套激励整体覆盖了多少 DUT"。
#     合并用 verilator_coverage --write, 它按 `\x01<label>\x02<value>` 键归并。
#============================================================================
VERILATOR ?= verilator
VCOV      ?= verilator_coverage

COV_OBJ   := cov/obj
# ★ COV_BIN 必须与 -o 的落点严格一致: -o 是相对 -Mdir 的, 故 `-o ../tx_cov` 落在
#   cov/tx_cov 而**不是** cov/obj/tx_cov。写错会让"跑用例"用到上一次的旧二进制,
#   覆盖率数字看着有模有样却全是陈的 (踩过: 改完 TB 数字一个不动)。
COV_BIN   := cov/tx_cov
COV_DAT   := cov/dat
COV_MERGE := cov/merged.dat

VCOVFLAGS := --binary --timing --coverage --coverage-fsm -Wno-fatal \
             -I../../src/inc -I../common

# ★ 父目录必须自己建: Verilator 的 -Mdir 只建**最后一级**, 不连父目录一起建
#   (现象: %Error: Can't write file: cov/obj/...__Slow.cpp)。
covdir:
	@mkdir -p cov

$(COV_BIN): $(TB_TOP) $(TX_SRC) $(CDR_SRC) $(RX_SRC) $(PHY_SRC) ../../src/inc/usb_const.vh | covdir
	$(VERILATOR) $(VCOVFLAGS) --top-module tb_tx_serial -Mdir $(COV_OBJ) \
		-o ../tx_cov $(TB_TOP) $(TX_SRC) $(CDR_SRC) $(RX_SRC) $(PHY_SRC)

cov: $(COV_BIN)
	@rm -rf $(COV_DAT); mkdir -p $(COV_DAT)
	@for c in $(CASES); do \
		( cd $(COV_DAT) && ../tx_cov +case=$$c > $$c.log 2>&1 \
		  && mv coverage.dat $$c.dat ) \
		  || { echo "覆盖率运行失败: $$c" >&2; exit 1; }; \
		grep -q 'TEST PASSED' $(COV_DAT)/$$c.log \
		  || { echo "覆盖率运行中有用例未通过: $$c (见 $(COV_DAT)/$$c.log)" >&2; exit 1; }; \
	done
	@$(VCOV) --write $(COV_MERGE) $(COV_DAT)/*.dat > /dev/null
	@echo "==== tx 覆盖率 (20 用例合并) ===="
	@$(VCOV) --report summary $(COV_MERGE)

# FSM 状态/弧覆盖率: Verilator 认不出本 DUT 的两段式 FSM, 改由 TB 侧统计
# (tb_tx_serial.v 的 print_fsm_coverage), 本目标把 20 个用例的矩阵合并。
# 依赖 run 产生的 sim_tx_*.log, 故先跑 run。
fsmcov:
	@$(MAKE) --no-print-directory run > /dev/null
	@python3 ../../tools/merge_fsm_cov.py --profile tx sim_tx_*.log

covclean:
	rm -rf cov

.PHONY: build run one clean debugwave cov covdir fsmcov covclean


#============================================================================
# debugwave — 跑所选仿真并直接打开波形软件 (wave_debugger)
#
#   用法:
#     make debugwave                                # 交互菜单: 列 20 case 供选
#     make debugwave CASE=tx_tail_stuff             # 直接指定 (可脚本化)
#     (根入口: make debugwave MOD=tx CASE=tx_tail_stuff)
#
#   行为: ① 强制以 VCD=1 重编 (-DVCD_SAVE 是编译期宏, 只跑不重编译不写 .vcd)
#         ② 只跑所选 case 存 <case>.vcd ③ 打开 ../../tools/wave_debugger.py <case>.vcd
#
#   ★ 样板: sim/cdr/Makefile (各模块 debugwave 必配, 见 sim/common/README.md)。
#============================================================================
WAVE_OPEN := python3 ../../tools/wave_debugger.py

debugwave:
	@rm -f $(VVP_OUT); \
	$(MAKE) build VCD=1; \
	sel="$(CASE)"; \
	if [ -z "$$sel" ]; then \
		echo "选择要查看波形的 tx 仿真:"; \
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
	$(VVP) $(VVP_OUT) +case=$$sel +vcd=$$sel.vcd > sim_$$sel.log 2>&1; \
	if [ $$? -ne 0 ]; then echo "警告: 仿真非 0 退出, 见 sim_$$sel.log (仍尝试打开波形)"; fi; \
	tail -n 2 sim_$$sel.log; \
	if [ -f $$sel.vcd ]; then \
		echo "打开波形: $$sel.vcd ($(WAVE_OPEN))"; \
		$(WAVE_OPEN) $$sel.vcd; \
	else \
		echo "错误: 未生成 $$sel.vcd (确认 VCD=1 编译且 case 名正确)" >&2; exit 1; \
	fi

.PHONY: build run one clean debugwave
