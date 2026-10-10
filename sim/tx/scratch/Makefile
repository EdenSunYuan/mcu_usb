#============================================================================
# sim/tx/scratch/Makefile — 用项目现有 19 个用例审查 usb_tx_serial_sy.v
#
# ★ 本目录**不改动** src/phy/usb_tx_serial_sy.v (用户自有 RTL)。
#   做法: 把 sim/tx/tb_tx_serial.v 复制成 tb_sy.v, 只改 TB 侧的白盒引用
#   (st_state→tx_stat_cur, stuff_pend→bit_stuff, clk12m→clk_12m) 与 FSM
#   数组位宽, 然后照原样例化用户的 RTL。
#
# ★ 波形一定是"当前设计"出的 (2026-09-20 加, 踩过的坑):
#   VCD 是**编译期**宏 -DVCD_SAVE。二进制没编进它时, `vvp ... +vcd=x.vcd`
#   是**静默空操作** —— 不报错、不写文件、也不覆盖磁盘上的旧 VCD, 于是
#   "看着像刚跑的波形, 其实是几天前那次仿真的"。四条对策:
#     ① run / one / debugwave **每次都先重编** → 永远用磁盘上当前的 RTL;
#     ② 每次编译打印 DUT 路径 + md5 + mtime + VCD 支持开关;
#     ③ debugwave 跑前先删目标 .vcd, 跑完校验它确实被重新生成且比 RTL 新,
#        否则直接报错退出 (不再静默);
#     ④ debugwave 打印 VCD 头里的生成时刻 ($date), 跟 ② 的 RTL 时间对得上。
#   自查: make stale
#
#   用法:
#     make run                                  # 跑全部 19 用例 → sy_<case>.log
#     make one CASE=tx_pkt_all                  # 跑单个用例
#     make debugwave CASE=tx_abort              # 出 VCD 并用 wave_debugger.py 打开
#     make debugwave CASE=tx_abort NOWAVE=1     # 只出 VCD, 不开窗口
#     make stale                                # 现有 .vcd 是"最新"还是"过期"
#     make clean                                # 只删可再生文件 (保留 .vcd)
#============================================================================

IVERILOG := iverilog
VVP      := vvp
TOP      := tb_sy.v
VVP_OUT  := tb_sy.vvp

# 用户的 RTL (只读)
DUT_SRC  := ../../../src/phy/usb_tx_serial_sy.v
CDR_SRC  := ../../../src/phy/usb_rx_cdr.v
RX_SRC   := ../../../src/phy/usb_rx_deserial.v
PHY_SRC  := ../../common/phy_model.v
INC      := -I. -I.. -I../../../src/inc

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
         tx_random_stress

# VCD_SAVE 是**编译期**宏 (TB 里编进去就无条件 dump, 默认写 tx.vcd) → 只有
# 出波形那条路 (debugwave) 才带它, 免得 make run 白写 19 份波形。
VCD_DEF  := $(if $(VCD),-DVCD_SAVE,)

# 打印 DUT 标识 (路径 + md5 + mtime), 供每处编译/波形核对
DUT_INFO  = printf "  DUT: %s\n       md5=%s  mtime=%s\n" "$(DUT_SRC)" \
              "$$(md5 -q $(DUT_SRC))" \
              "$$(stat -f '%Sm' -t '%m-%d %H:%M:%S' $(DUT_SRC))"

.PHONY: build run one clean debugwave list srcmap stale wavecheck

# ---- build: 无前置依赖 → 每次调用都重编, 永远拿当前磁盘上的 RTL ----
build:
	@$(DUT_INFO)
	@printf "       VCD 支持: %s\n" "$(if $(VCD),开 (-DVCD_SAVE),关 (要看波形请用 make debugwave))"
	@$(IVERILOG) -g2012 $(VCD_DEF) $(INC) -o $(VVP_OUT) $(TOP) \
	    $(DUT_SRC) $(CDR_SRC) $(RX_SRC) $(PHY_SRC)

list:
	@i=1; for c in $(CASES); do echo "  $$i) $$c"; i=$$((i+1)); done

# 逐用例跑; 每个用例单独的 log, 失败不影响后续
run:
	@$(MAKE) --no-print-directory build
	@for c in $(CASES); do \
	    echo "== $$c"; \
	    $(VVP) $(VVP_OUT) +case=$$c > sy_$$c.log 2>&1; \
	    grep -m1 -E 'TEST (PASSED|FAILED)' sy_$$c.log | sed 's/^ */   /'; \
	done

one:
	@if [ -z "$(CASE)" ]; then echo "用法: make one CASE=tx_pkt_all" >&2; exit 1; fi
	@$(MAKE) --no-print-directory build
	@$(VVP) $(VVP_OUT) +case=$(CASE) > sy_$(CASE).log 2>&1; \
	    grep -m1 -E 'TEST (PASSED|FAILED)' sy_$(CASE).log | sed 's/^ */   /'

# ---- srcmap: 写 <case>.vcd.src.json 源码配对旁文件 ----
# 必需: 本目录跑的是 **usb_tx_serial_sy.v**, 但该文件里的 module 名也叫
# `usb_tx_serial` —— 与项目 src/phy/usb_tx_serial.v 同名。wave_debugger 的
# ModuleResolver 按"目录扫描先到先得"解析, src/ 先扫, 于是代码面板会显示
# **项目那份**源码 (波形是对的, 代码是错的)。旁文件把映射钉死到 _sy.v。
PY_DIR  := /Users/sunyuan/Desktop/apb_usb
SRCMAP_JSON = {"module_files": {\
  "usb_tx_serial": "$(PY_DIR)/src/phy/usb_tx_serial_sy.v", \
  "tb_tx_serial":  "$(PY_DIR)/sim/tx/scratch/tb_sy.v", \
  "usb_rx_cdr":    "$(PY_DIR)/src/phy/usb_rx_cdr.v", \
  "usb_rx_deserial": "$(PY_DIR)/src/phy/usb_rx_deserial.v", \
  "phy_model":     "$(PY_DIR)/sim/common/phy_model.v"}}

srcmap:
	@for c in $(CASES); do printf '%s\n' '$(SRCMAP_JSON)' > $$c.vcd.src.json; done
	@echo "已写 $(words $(CASES)) 个 <case>.vcd.src.json"

# ---- debugwave: 强制带 VCD 重编 → 跑所选 case → 校验波形新鲜 → 开波形软件 ----
WAVE_OPEN := python3 ../../../tools/wave_debugger.py

debugwave:
	@sel="$(CASE)"; \
	if [ -z "$$sel" ]; then \
	    echo "选择要查看波形的 case:"; \
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
	rm -f $(VVP_OUT) $$sel.vcd; \
	$(MAKE) --no-print-directory build VCD=1; \
	$(VVP) $(VVP_OUT) +case=$$sel +vcd=$$sel.vcd > sy_$$sel.log 2>&1; \
	if [ $$? -ne 0 ]; then echo "警告: 仿真非 0 退出, 见 sy_$$sel.log"; fi; \
	grep -m1 -E 'TEST (PASSED|FAILED)' sy_$$sel.log | sed 's/^ */   /'; \
	if [ ! -f $$sel.vcd ]; then \
	    echo "错误: 未生成 $$sel.vcd —— VCD 宏没编进去 (本次二进制不带 -DVCD_SAVE)" >&2; \
	    echo "      波形软件不会打开, 免得你又看到磁盘上的旧波形" >&2; exit 1; \
	fi; \
	if [ ! $$sel.vcd -nt $(DUT_SRC) ]; then \
	    echo "错误: $$sel.vcd 比 $(DUT_SRC) 旧 —— 这不是当前设计出的波形" >&2; exit 1; \
	fi; \
	printf '%s\n' '$(SRCMAP_JSON)' > $$sel.vcd.src.json; \
	echo "  波形: $$sel.vcd (生成于 $$(sed -n '2p' $$sel.vcd))"; \
	echo "  源码配对: $$sel.vcd.src.json → usb_tx_serial_sy.v"; \
	if [ -n "$(NOWAVE)" ]; then \
	    echo "  (NOWAVE=1: 跳过打开波形)"; \
	else \
	    $(WAVE_OPEN) $$sel.vcd; \
	fi

# ---- stale: 现有 .vcd 相对当前 RTL 是"最新"还是"过期" ----
# 只有 debugwave 会更新 .vcd; run / one 不写波形, 跑完不会让波形变新。
stale:
	@$(DUT_INFO)
	@for c in $(CASES); do \
	    if [ -f $$c.vcd ]; then \
	        if [ $$c.vcd -nt $(DUT_SRC) ]; then s="最新"; else s="过期"; fi; \
	        printf "  %-22s %s  %s\n" "$$c.vcd" "$$s" \
	            "$$(stat -f '%Sm' -t '%m-%d %H:%M:%S' $$c.vcd)"; \
	    fi; \
	done
	@echo "  (判据: .vcd 的 mtime 比 DUT 新 = 最新; 波形生成时刻见其头 2 行)"
