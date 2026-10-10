IVERILOG ?= iverilog
VVP      ?= vvp
VFLAGS   := -g2012 -Wall -I../../src/inc -I../common

TB_TOP   := tb_nrzi.v
RTL      := ../../src/common/usb_nrzi_enc.v ../../src/common/usb_nrzi_dec.v
VVP_OUT  := nrzi.vvp
LOG_OUT  := sim.log

build: $(VVP_OUT)

$(VVP_OUT): $(TB_TOP) $(RTL) ../common/*.vh case_*.v
	$(IVERILOG) $(VFLAGS) -o $@ $(TB_TOP) $(RTL)

run: $(VVP_OUT)
	$(VVP) $(VVP_OUT) > $(LOG_OUT) 2>&1

clean:
	rm -f $(VVP_OUT) $(LOG_OUT)

.PHONY: build run clean
