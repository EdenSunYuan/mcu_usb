#=============================================================================
# sim/phy/Makefile — usb_dpll_phy 顶层集成测试
#
#   make build        编译 (两个 vvp: base / fixed)
#   make run          跑全部用例
#   make clean        清 .vvp/.log (保留 .vcd/.wvs)
#   make debugwave    出 VCD 并开 tools/wave_debugger.py
#   make cov          全用例 Verilator 覆盖率
#   make covclean     删 cov/
#
# 被测是**顶层一个文件**: src/phy/usb_dpll_phy.v 例化五个子模块,
# 五个子模块(.v)必须一起编译, 但 TB 只 instance 顶层。
#=============================================================================

IVERILOG  ?= iverilog
VFLAGS    := -g2012 -Wall -I../../src/inc -I../common

VVP        = phy.vvp

# 编译期开关: VCD=1 → 存波形
VCD       ?= 0
ifeq ($(VCD),1)
  VFLAGS += -DVCD_SAVE
endif

DUT_SRC := ../../src/phy/usb_dpll_phy.v \
           ../../src/phy/usb_rx_cdr.v \
           ../../src/phy/usb_clk_mux.v \
           ../../src/phy/usb_rx_deserial.v \
           ../../src/phy/usb_tx_serial.v \
           ../../src/phy/usb_bus_state.v

CASES := phy_reset_default \
         phy_connect \
         phy_suspend \
         phy_resume \
         phy_bus_rst \
         phy_rx_token \
         phy_rx_data \
         phy_rx_bad \
         phy_rx_abort \
         phy_rx_usb_rst \
         phy_rx_hshake \
         phy_rx_maxlen \
         phy_tx_line \
         phy_tx_driving \
         phy_tx_rx_turn \
         phy_susp_wkup \
         phy_unplug_susp \
         phy_clk_switch

.PHONY: all build run clean cov fsmcov covclean debugwave help

all: run

build: $(VVP)

$(VVP): tb_phy.v phy_tasks.vh $(wildcard case_*.v) $(DUT_SRC)
	$(IVERILOG) $(VFLAGS) -o $(VVP) tb_phy.v $(DUT_SRC)

run: build
	@pass=0; fail=0; \
	for c in $(CASES); do \
	  if vvp $(VVP) +case=$$c +vcd=phy_$$c.vcd > sim_base_$$c.log 2>&1; then \
	    printf "  %-20s PASS\n" $$c; pass=$$((pass+1)); \
	  else \
	    printf "  %-20s FAIL  (see sim_base_$$c.log)\n" $$c; fail=$$((fail+1)); \
	  fi; \
	done; \
	echo "==== phy: $$pass passed, $$fail failed ===="; \
	test $$fail -eq 0

clean:
	rm -f *.vvp *.log
	@echo "kept: .vcd / .wvs"

#------------------------------------------------------------------------------
# 覆盖率: Verilator --coverage, 18 用例跨用例合并后判读
#
#   报数口径 = **Design Unit Coverage Summary 里的 usb_dpll_phy**
#     —— 本层是纯连线, 行/分支都只有例化与端口连接, 数字本来就该是满的;
#        真正有逻辑的是五个子模块, 各自的单元测试才是它们的判据。
#        这一层的覆盖率只用来证明"五个子模块都被例化到了、没有悬空端口"。
#
#   本层没有状态机: fsmcov 是留空目标, 只为凑齐根入口 `make cov MOD=phy` 的两步。
#------------------------------------------------------------------------------
VERILATOR ?= verilator
VCOV      ?= verilator_coverage

COV_DAT   := cov/dat
COV_MERGE := cov/merged.dat
COV_BIN   := cov/phy_cov

VCOVFLAGS := --binary --timing --coverage -Wno-fatal \
             -I../../src/inc -I../common

# ★ 父目录必须自己建: Verilator 的 -Mdir 只建最后一级, 不会连父目录一起建。
covdir:
	@mkdir -p cov

$(COV_BIN): tb_phy.v phy_tasks.vh $(wildcard case_*.v) $(DUT_SRC) | covdir
	$(VERILATOR) $(VCOVFLAGS) --top-module tb_phy -Mdir cov/obj \
	    -o ../phy_cov tb_phy.v $(DUT_SRC)

cov: $(COV_BIN)
	@rm -rf $(COV_DAT); mkdir -p $(COV_DAT)
	@for c in $(CASES); do \
		( cd $(COV_DAT) && ../phy_cov +case=$$c > $$c.log 2>&1 \
		  && mv coverage.dat $$c.dat ) \
		  || { echo "覆盖率运行失败: $$c" >&2; exit 1; }; \
		grep -q 'TEST PASSED' $(COV_DAT)/$$c.log \
		  || { echo "覆盖率运行中有用例未通过: $$c (见 $(COV_DAT)/$$c.log)" >&2; exit 1; }; \
	done
	@$(VCOV) --write $(COV_MERGE) $(COV_DAT)/*.dat > /dev/null
	@echo "==== phy 覆盖率 (18 用例合并) ===="
	@$(VCOV) --report summary $(COV_MERGE)

# 本层没有状态机: 五个子模块的 FSM(帧机/发送机/时钟 MUX 方向)都在各自的 sim/ 下验过,
# 顶层只剩端口连接, 工具也认不出任何 FSM。这一维留空跑, 只为让根入口
# `make cov MOD=phy` 的 cov + fsmcov 两步都成立。
fsmcov:
	@echo "== phy: 顶层无状态机, fsmcov 留空 (子模块 FSM 见各自 sim/ 的 fsmcov) =="

covclean:
	rm -rf cov

#------------------------------------------------------------------------------
# debugwave: 强制带 VCD 重建, 交互选用例, 存波形并用 wave_debugger 打开
#------------------------------------------------------------------------------
debugwave:
	@$(MAKE) clean >/dev/null
	@$(MAKE) VCD=1 build
	@echo "选择用例:"
	@i=1; for c in $(CASES); do echo "  $$i) $$c"; i=$$((i+1)); done; \
	read n; \
	c=$$(echo $(CASES) | tr ' ' '\n' | sed -n "$${n}p"); \
	echo "run $$c"; \
	vvp $(VVP) +case=$$c +vcd=$$c.vcd; \
	python3 ../../tools/wave_debugger.py $$c.vcd

help:
	@echo "make build | run | clean | cov | fsmcov | covclean | debugwave"
	@echo "make debugwave VCD 重建后交互选用例"
