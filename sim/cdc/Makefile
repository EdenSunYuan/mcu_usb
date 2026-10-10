IVERILOG ?= iverilog
VVP      ?= vvp
VFLAGS   := -g2012 -Wall -I../../src/inc

TB_TOP   := tb_cdc.v
RTL      := ../../src/sie/usb_sie_cdc.v
VVP_OUT  := cdc.vvp

# pclk 相对 clk12m 的相位扫描 (ps)，覆盖一个 clk12m 周期内的竞态窗口
PHASES   := 0 5000 10000 15000 20000 25000 30000 35000 40000 45000 50000 55000 60000

.PHONY: all build run vcd clean

all: run

build: $(VVP_OUT)

$(VVP_OUT): $(TB_TOP) $(RTL)
	$(IVERILOG) $(VFLAGS) -o $@ $(TB_TOP) $(RTL)

run: $(VVP_OUT)
	@pass=0; fail=0; \
	for p in $(PHASES); do \
	  printf '  phase=%-6s ' "$$p"; \
	  if $(VVP) $(VVP_OUT) +phase=$$p > sim_phase_$$p.log 2>&1; then \
	    echo "PASS"; pass=$$((pass+1)); \
	  else \
	    echo "FAIL"; tail -6 sim_phase_$$p.log; fail=$$((fail+1)); \
	  fi; \
	done; \
	echo "==== $$pass passed, $$fail failed ===="; \
	if [ $$fail -ne 0 ]; then exit 1; fi

vcd: $(VVP_OUT)
	$(VVP) $(VVP_OUT) +phase=20000 +vcd > sim.log 2>&1; cat sim.log
	@echo "waveform -> cdc.vcd"

# clean 保留 *.vcd (波形, 用户查看用); 只清可再生的 .vvp/.log
clean:
	rm -f $(VVP_OUT) sim.log sim_phase_*.log
