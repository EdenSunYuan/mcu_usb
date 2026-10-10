#============================================================================
# Makefile — USB 1.1 Device Controller
# iverilog 编译 + 仿真回归
#
# 常用命令:
#   make            # 全部测试
#   make crc5       # 单个测试
#   make cdr        # CDR 测试
#   make cov        # 覆盖率 (Verilator; MOD=tx|deserial|clkmux|busstate|sie|phy)
#   make clean      # 清仿真产物
#
# 每个模块在 sim/<module>/ 下有独立:
#   - Makefile (子模块编译规则)
#   - tb_*.v (顶层 testbench)
#   - case_*.v (独立 test case)
#   - README.md (测试说明)
# 共享参考模型 + USB 包激励在 sim/common/:
#   - *_ref.vh (CRC/NRZI/位填充参考模型)
#   - usb_pkt_tasks.vh (USB 包分层发送任务)
#============================================================================

MODULES := crc5 crc16 nrzi bitstuff cdr tx clkmux busstate sie phy

# 已带 debugwave 目标的模块 (选仿真→出 VCD→直接开 wave_debugger)。
# 新模块 sim Makefile 加了 debugwave 后, 把它追加进来即可 (>1 个时根入口自动弹模块菜单)。
WAVE_MODULES := cdr deserial tx clkmux busstate sie phy

# 已带 cov/fsmcov 目标的模块 (Verilator 覆盖率流程)。
# iverilog 无覆盖率能力, 要上覆盖率得先按 sim/tx/Makefile 的 cov 目标把 TB 过一遍
# Verilator 的可移植性 (见 doc/design_rpt/tx_serial_verification.md §8)。
#   tx       — 单份 DUT, 20 用例合并 (报告 §8)
#   deserial — 两份断言宏 (base/fixed) 合并, 11 用例 (报告 §8)
#   clkmux   — 单份 DUT, 7 用例合并 (报告 clk_mux_verification.md)
#   busstate — 单份 DUT, 14 用例合并 (报告 bus_state_verification.md)
#   sie      — 单份 DUT (SIE + pkt_rx + 两个字节 CRC), 12 用例合并 (报告 usb_sie_verification.md)
#   phy      — 顶层纯连线, 六个 .v 一起编, 18 用例合并 (报告 phy_verification.md);
#              无状态机, fsmcov 是留空目标
COV_MODULES := tx deserial clkmux busstate sie phy

# deserial 不在 MODULES (make run 聚合) 内: 它需 MODE=base+fixed 双跑,
# 单跑只覆盖一半断言; 顶层用下方显式目标 `make deserial` 跑双模回归。
# 根入口 make debugwave 选模块: MOD=cdr | MOD=deserial | MOD=tx (或省 MOD 弹菜单)。

# ---- 目标 ----
.DEFAULT_GOAL := run

build:
	@for m in $(MODULES); do \
		$(MAKE) -C sim/$$m build || exit 1; \
	done

run: build
	@fail=0; \
	for m in $(MODULES); do \
		printf '%-12s ' "$$m"; \
		if $(MAKE) -C sim/$$m run > sim/$$m/sim.log 2>&1; then \
			echo "PASS"; \
		else \
			echo "FAIL"; \
			echo "--- last 20 lines of sim/$$m/sim.log ---"; \
			tail -20 sim/$$m/sim.log; \
			fail=1; \
		fi; \
	done; \
	if [ $$fail -eq 0 ]; then echo "==== ALL TESTS PASSED ===="; \
	else echo "==== SOME TESTS FAILED ===="; exit 1; fi

$(MODULES): %:
	$(MAKE) -C sim/$@ run

# deserial 双模回归 (MODE=base + fixed; 产物按 MODE 命名, 第二条自动重编, 无陈旧)
deserial:
	$(MAKE) -C sim/deserial run MODE=base
	$(MAKE) -C sim/deserial run MODE=fixed

clean:
	@for m in $(MODULES); do \
		$(MAKE) -C sim/$$m clean; \
	done

#============================================================================
# debugwave — 顶层入口: 选模块 → 该模块弹出现有 case 名供选 → 出 VCD → 开波形软件
#
#   转发到 <模块>/Makefile 的 debugwave (交互菜单 + CASE= 直选在那里实现,
#   见 sim/common/README.md「debugwave Makefile 目标」)。
#
#   用法:
#     make debugwave                          # 选模块 → 该模块弹全部 case 名供选
#     make debugwave MOD=cdr CASE=cdr_case_nominal   # 直选模块 + case (CASE= 可省)
#     make debugwave MOD=deserial CASE=deserial_out_normal  # deserial (默认 MODE=base)
#     make debugwave MOD=deserial MODE=fixed CASE=deserial_tail_scan  # deserial 指定 MODE
#     make debugwave CASE=cdr_case_nominal    # 单模块时省 MOD (cdr/deserial 均可经 MOD 选)
#============================================================================
debugwave:
	@mod="$(MOD)"; \
	if [ -z "$$mod" ]; then \
		n=0; for m in $(WAVE_MODULES); do n=$$((n+1)); done; \
		if [ $$n -gt 1 ]; then \
			echo "选择要查看波形的模块 (make debugwave MOD=<模块> 直选):"; \
			i=1; for m in $(WAVE_MODULES); do echo "  $$i) $$m"; i=$$((i+1)); done; \
			printf "输入编号或模块名 [默认 1]: "; read inp; \
			if [ -z "$$inp" ]; then inp=1; fi; \
			case "$$inp" in \
				*[!0-9]*) mod=$$inp ;; \
				*) mod=$$(echo "$(WAVE_MODULES)" | tr ' ' '\n' | sed -n "$${inp}p") ;; \
			esac; \
		else \
			mod=$$(echo "$(WAVE_MODULES)"); \
		fi; \
	fi; \
	ok=0; for m in $(WAVE_MODULES); do if [ "$$m" = "$$mod" ]; then ok=1; fi; done; \
	if [ $$ok -eq 0 ]; then echo "错误: 未知模块 '$$mod'. 可选: $(WAVE_MODULES)" >&2; exit 1; fi; \
	echo "== debugwave: 模块 $$mod (进入其 case 菜单) =="; \
	$(MAKE) -C sim/$$mod debugwave CASE="$(CASE)"

#============================================================================
# cov — 覆盖率入口 (转发到模块 Makefile 的 cov + fsmcov)
#
#   make cov              # 默认取 COV_MODULES 第一个 (tx)
#   make cov MOD=tx       # 显式指定 (可选 tx | deserial)
#   make covclean         # 删各模块的覆盖率构建目录
#============================================================================
cov:
	@mod="$(MOD)"; \
	if [ -z "$$mod" ]; then mod=$$(echo "$(COV_MODULES)" | awk '{print $$1}'); fi; \
	ok=0; for m in $(COV_MODULES); do if [ "$$m" = "$$mod" ]; then ok=1; fi; done; \
	if [ $$ok -eq 0 ]; then echo "错误: '$$mod' 没有覆盖率流程. 可选: $(COV_MODULES)" >&2; exit 1; fi; \
	echo "== 覆盖率: 模块 $$mod =="; \
	$(MAKE) -C sim/$$mod cov && $(MAKE) -C sim/$$mod fsmcov

covclean:
	@for m in $(COV_MODULES); do $(MAKE) -C sim/$$m covclean; done

help:
	@echo "make            run all tests (crc5 crc16 nrzi bitstuff cdr tx clkmux busstate sie phy)"
	@echo "make crc5       run single test (also: crc16 nrzi bitstuff cdr tx clkmux busstate sie phy)"
	@echo "make deserial   run deserial dual-mode regression (MODE=base + fixed)"
	@echo "make build      compile only"
	@echo "make debugwave  select module(cdr/deserial/tx)+case, dump VCD, open wave_debugger"
	@echo "make cov        coverage (Verilator, MOD=tx|deserial|clkmux|busstate|sie|phy) + make covclean to drop build dirs"
	@echo "make clean      remove simulation artifacts"

.PHONY: run build clean debugwave deserial cov covclean help
