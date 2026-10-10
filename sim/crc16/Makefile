IVERILOG ?= iverilog
VVP      ?= vvp
VFLAGS   := -g2012 -Wall -I../../src/inc -I../common

TB_TOP   := tb_crc16.v
RTL      := ../../src/common/usb_crc16.v
VVP_OUT  := crc16.vvp
LOG_OUT  := sim.log

build: $(VVP_OUT)

$(VVP_OUT): $(TB_TOP) $(RTL) ../common/*.vh case_data.v case_boundary.v
	$(IVERILOG) $(VFLAGS) -o $@ $(TB_TOP) $(RTL)

run: $(VVP_OUT)
	$(VVP) $(VVP_OUT) > $(LOG_OUT) 2>&1

clean:
	rm -f $(VVP_OUT) $(LOG_OUT)

.PHONY: build run clean
