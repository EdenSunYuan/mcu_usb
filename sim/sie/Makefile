#============================================================================
# sim/sie Makefile — usb_sie (SIE 事务层, 只做接收) 单元测试
#
# DUT: src/sie/usb_sie.v
#        ├─ src/sie/usb_sie_pkt_rx.v   (包级解析)
#        ├─ src/common/usb_crc5_byte.v  (字节并行 CRC5)
#        └─ src/common/usb_crc16_byte.v (字节并行 CRC16)
#
# 输入契约是 **字节级** (rx_data/rx_valid/rx_active/rx_error) = usb_rx_deserial
# 的输出, 本仿真不接 CDR/deserial (位级链路已在 sim/cdr、sim/deserial 验过)。
#
# VCD=1 存波形 (每 case 单独 <case>.vcd)
#
# 仿真规范见 sim/common/README.md (确认规范 / debugwave / 覆盖率 / 因果截图)。
#============================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
VFLAGS   := -g2012 -Wall -I../../src/inc -I../common

VCD ?= 0
ifeq ($(VCD),1)
VFLAGS += -DVCD_SAVE
endif

TB_TOP  := tb_sie.v
RTL_SRC := ../../src/sie/usb_sie.v ../../src/sie/usb_sie_pkt_rx.v \
           ../../src/common/usb_crc5_byte.v ../../src/common/usb_crc16_byte.v
VVP_OUT := sie.vvp
LOG_OUT := sim.log

CASES := sie_token \
         sie_data_len \
         sie_bad_pkt \
         sie_resp_prio \
         sie_setup \
         sie_toggle \
         sie_datawait \
         sie_oversize \
         sie_addr_stray \
         sie_buf_isolate \
         sie_ctl_rst \
         sie_tail_tight

build: $(VVP_OUT)

$(VVP_OUT): $(TB_TOP) $(RTL_SRC) ../common/*.vh case_*.v
	$(IVERILOG) $(VFLAGS) -o $@ $(TB_TOP) $(RTL_SRC)

run: $(VVP_OUT)
	@pass=0; fail=0; \
	for c in $(CASES); do \
		printf '  %-18s ' "$$c"; \
		if $(VVP) $(VVP_OUT) +case=$$c +vcd=$$c.vcd > sim_$$c.log 2>&1 \
		   && grep -q 'TEST PASSED' sim_$$c.log; then \
			echo "PASS"; pass=$$((pass+1)); \
		else \
			echo "FAIL"; fail=$$((fail+1)); \
		fi; \
	done; \
	cat sim_sie_*.log > $(LOG_OUT); \
	echo "==== sie: $$pass passed, $$fail failed ===="; \
	if [ $$fail -ne 0 ]; then exit 1; fi

# clean 保留 *.vcd (波形) 与 *.wvs (波形会话); 只清可再生的 .vvp/.log
# ★ 不动 cov/ —— 覆盖率数据另用 covclean
clean:
	rm -f sie.vvp sim*.log

#============================================================================
# cov — Verilator 覆盖率 (行 / 分支 / 翻转 / 表达式)
#   用法: make cov       # 12 用例跑全 → 跨用例合并 → 打印 summary
#         make fsmcov    # 合并 FSM 状态迁移矩阵 (TB 侧自建)
#         make covclean  # 删 cov/
#   报数口径 = DUT 模块 (usb_sie / usb_sie_pkt_rx), 不是全层级 summary。
#============================================================================
VERILATOR ?= verilator
VCOV      ?= verilator_coverage

COV_DAT   := cov/dat
COV_MERGE := cov/merged.dat
COV_BIN   := cov/sie_cov

VCOVFLAGS := --binary --timing --coverage --coverage-fsm -Wno-fatal \
             -I../../src/inc -I../common

# ★ 父目录必须自己建 (Verilator 的 -Mdir 只建最后一级)
covdir:
	@mkdir -p cov

$(COV_BIN): $(TB_TOP) $(RTL_SRC) ../common/*.vh case_*.v | covdir
	$(VERILATOR) $(VCOVFLAGS) --top-module tb_sie -Mdir cov/obj -o ../sie_cov \
		$(TB_TOP) $(RTL_SRC)

cov: $(COV_BIN)
	@rm -rf $(COV_DAT); mkdir -p $(COV_DAT)
	@for c in $(CASES); do \
		( cd $(COV_DAT) && ../sie_cov +case=$$c > $$c.log 2>&1 && mv coverage.dat $$c.dat ) \
		  || { echo "覆盖率运行失败: $$c" >&2; exit 1; }; \
		grep -q 'TEST PASSED' $(COV_DAT)/$$c.log \
		  || { echo "覆盖率运行中有用例未通过: $$c (见 $(COV_DAT)/$$c.log)" >&2; exit 1; }; \
	done
	@$(VCOV) --write $(COV_MERGE) $(COV_DAT)/*.dat > /dev/null
	@echo "==== usb_sie 覆盖率 (12 用例合并) ===="
	@$(VCOV) --report summary $(COV_MERGE)

# FSM 状态/弧覆盖率 (Verilator 的 --coverage-fsm 认不出规则 5 的两段式 FSM,
# 改由 TB 侧统计; 见 tools/README_merge_fsm_cov.md)
fsmcov: $(COV_BIN)
	@for c in $(CASES); do \
		./$(COV_BIN) +case=$$c > cov/fsm_$$c.log 2>&1; \
	done
	@python3 ../../tools/merge_fsm_cov.py --profile sie cov/fsm_*.log

covclean:
	rm -rf cov

.PHONY: build run clean cov covdir fsmcov covclean debugwave

#============================================================================
# debugwave — 跑所选仿真并直接打开波形软件 (wave_debugger)
#   用法:
#     make debugwave                       # 交互菜单: 列 12 case (名) 供选
#     make debugwave CASE=sie_datawait      # 直接指定
#   行为: ① 强制 VCD=1 重编 (-DVCD_SAVE 是编译期宏) ② 只跑所选 case 存 .vcd
#         ③ 打开 ../../tools/wave_debugger.py <case>.vcd
#   样板: sim/cdr/Makefile (各模块 debugwave 必配, 见 sim/common/README.md)
#============================================================================
WAVE_OPEN := python3 ../../tools/wave_debugger.py

debugwave:
	@rm -f $(VVP_OUT); \
	$(MAKE) build VCD=1; \
	sel="$(CASE)"; \
	if [ -z "$$sel" ]; then \
		echo "选择要查看波形的 sie 仿真:"; \
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
