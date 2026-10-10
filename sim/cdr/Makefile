IVERILOG ?= iverilog
VVP      ?= vvp
VFLAGS   := -g2012 -Wall -I../../src/inc -I../common

# VCD=1 保存波形文件 (默认不保存, 节省磁盘和仿真时间)
#   每个 case 单独保存为 <case_name>.vcd
VCD ?= 0
ifeq ($(VCD),1)
VCD_DEFINE := -DVCD_SAVE
endif

TB_TOP   := tb_cdr.v
RTL      := ../../src/phy/usb_rx_cdr.v
VVP_OUT  := cdr.vvp
LOG_OUT  := sim.log

# 所有 test case (与 tb_cdr.v 中的 case 分发表一致)
CASES := cdr_case_nominal \
         cdr_case_long_bit_f \
         cdr_case_long_bit_b \
         cdr_case_short_bit_j \
         cdr_case_short_bit_k \
         cdr_case_se0 \
         cdr_case_random \
         cdr_case_multi_pkt \
         cdr_case_loopback \
         cdr_case_pkt_all

build: $(VVP_OUT)

$(VVP_OUT): $(TB_TOP) $(RTL) ../common/*.vh case_*.v
	$(IVERILOG) $(VFLAGS) $(VCD_DEFINE) -o $@ $(TB_TOP) $(RTL)

run: $(VVP_OUT)
	@pass=0; fail=0; \
	for c in $(CASES); do \
		printf '  %-24s ' "$$c"; \
		if $(VVP) $(VVP_OUT) +case=$$c +vcd=$$c.vcd > sim_$$c.log 2>&1; then \
			echo "PASS"; \
			pass=$$((pass+1)); \
		else \
			echo "FAIL"; \
			fail=$$((fail+1)); \
		fi; \
	done; \
	cat sim_*.log > $(LOG_OUT); \
	echo "==== $$pass passed, $$fail failed ===="; \
	if [ $$fail -ne 0 ]; then \
		echo "==== SOME TESTS FAILED ===="; \
		exit 1; \
	fi

# clean: 只清可再生的仿真产物 (.vvp/.log)。
# 注意: *.wvs (波形会话: 信号列表+进制/颜色, 用户手动配置) 与 *.vcd (波形文件,
#       用户查看用, 切换 VCD 模式仅需删 .vvp 重编译) 均【保留不删】。
clean:
	rm -f $(VVP_OUT) $(LOG_OUT) sim_*.log

#============================================================================
# debugwave — 跑所选仿真并直接打开波形软件 (wave_debugger)
#
#   用法:
#     make debugwave                          # 交互菜单: 列全部 case (名) 供选
#     make debugwave                          # (从仓库根目录 make debugwave 亦可, 见根 Makefile)
#     make debugwave CASE=cdr_case_nominal    # 直接指定 (可脚本化)
#
#   行为: ① 强制以 VCD=1 重编译 (-DVCD_SAVE 是编译期宏, 只跑不重编译不写 .vcd)
#         ② 只跑所选 case 存 <case>.vcd
#         ③ 打开 ../../tools/wave_debugger.py <case>.vcd (本项目波形软件)
#
#   ★ 复制到其它模块的模板: 改 "debugwave 里直接引用的变量" 即可 ——
#       CASES (可选仿真清单), VVP_OUT, VVP, 以及 tb 接收的 +case=/+vcd= 名字约定。
#============================================================================
WAVE_OPEN := python3 ../../tools/wave_debugger.py

debugwave:
	@rm -f $(VVP_OUT); \
	$(MAKE) build VCD=1; \
	sel="$(CASE)"; \
	if [ -z "$$sel" ]; then \
		echo "选择要查看波形的 cdr 仿真:"; \
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

.PHONY: build run clean debugwave
