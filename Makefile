# Makefile: Complete INT8 Systolic Array Accelerator IP Automation Flow
SHELL := /bin/bash

IVL = /opt/homebrew/bin/iverilog
VVP = /opt/homebrew/bin/vvp
YOSYS = /opt/homebrew/bin/yosys
PYTHON = $(shell pwd)/.venv/bin/python3

BUILD_DIR = build
REPORTS_DIR = reports

.PHONY: all test test_sv test_cocotb synth clean help

all: test synth

help:
	@echo "Available Make targets:"
	@echo "  make test           - Run full test regression (SystemVerilog + Cocotb)"
	@echo "  make test_sv        - Run all SystemVerilog self-checking simulations"
	@echo "  make test_cocotb    - Run Cocotb Python verification (1,000 vectors)"
	@echo "  make synth          - Run Yosys RTL synthesis and generate reports"
	@echo "  make clean          - Remove all build, simulation, and waveform artifacts"

# Master test regression
test: test_sv test_cocotb
	@echo "================================================================"
	@echo ">>> ALL SYSTEMVERILOG & COCOTB REGRESSIONS PASSED (100%) <<<"
	@echo "================================================================"

# SystemVerilog unit, array, top, and randomized regression suites
test_sv: sim_pe sim_array sim_fifo sim_top sim_randomized

sim_pe:
	@mkdir -p $(BUILD_DIR)
	@echo "--- [1/5] Simulating Processing Element (PE) ---"
	$(IVL) -g2012 -o $(BUILD_DIR)/pe_sim rtl/pe.sv tb/tb_pe.sv
	$(VVP) $(BUILD_DIR)/pe_sim

sim_array:
	@mkdir -p $(BUILD_DIR)
	@echo "--- [2/5] Simulating 4x4 Systolic Array Grid ---"
	$(IVL) -g2012 -o $(BUILD_DIR)/systolic_sim rtl/pe.sv rtl/systolic_array.sv tb/tb_systolic_array.sv
	$(VVP) $(BUILD_DIR)/systolic_sim

sim_fifo:
	@mkdir -p $(BUILD_DIR)
	@echo "--- [3/5] Simulating Streaming Input Buffer FIFO ---"
	$(IVL) -g2012 -o $(BUILD_DIR)/fifo_sim rtl/input_buffer.sv tb/tb_input_buffer.sv
	$(VVP) $(BUILD_DIR)/fifo_sim

sim_top:
	@mkdir -p $(BUILD_DIR)
	@echo "--- [4/5] Simulating Top-Level Accelerator Integration ---"
	$(IVL) -g2012 -o $(BUILD_DIR)/top_sim rtl/pe.sv rtl/systolic_array.sv rtl/accelerator_controller.sv rtl/int8_accelerator_top.sv tb/tb_accelerator_top.sv
	$(VVP) $(BUILD_DIR)/top_sim

sim_randomized:
	@mkdir -p $(BUILD_DIR)
	@echo "--- [5/5] Running 100-Matrix Randomized Regression ---"
	$(IVL) -g2012 -o $(BUILD_DIR)/randomized_sim rtl/pe.sv rtl/systolic_array.sv rtl/accelerator_controller.sv rtl/int8_accelerator_top.sv tb/tb_accelerator_randomized.sv
	$(VVP) $(BUILD_DIR)/randomized_sim

# Cocotb Python Verification
test_cocotb:
	@echo "--- Running Cocotb Python Verification ---"
	@export PATH="/opt/homebrew/bin:$$PATH" && source .venv/bin/activate && make -f tb/Makefile.pe

# Yosys Synthesis
synth:
	@mkdir -p $(REPORTS_DIR) $(BUILD_DIR)
	@echo "--- Running Yosys Logic Synthesis ---"
	$(YOSYS) -s scripts/synth_accelerator.ys > $(REPORTS_DIR)/synthesis_stats.txt
	@echo "Synthesis complete. Report generated at: $(REPORTS_DIR)/synthesis_stats.txt"

clean:
	@rm -rf $(BUILD_DIR) sim_build *.vcd *.vvp *.sim results.xml
	@echo "Cleaned all temporary build artifacts."
