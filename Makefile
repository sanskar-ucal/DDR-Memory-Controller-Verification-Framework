# ============================================================================
# DDR Memory Controller Verification Framework
#
#   make uvm                      fetch Accellera UVM (IEEE 1800.2-2020, pinned)
#   make build [BUG=BUG_x]        compile the testbench (clean or bug variant)
#   make run TEST=... SEED=... [NUM_TXN=n] [WAVES=1] [TRACE=1] [BUG=BUG_x]
#   make lint                     Verilator -Wall lint of the RTL
#   make regress                  full regression + coverage merge + reports
#   make bugs                     bug-injection campaign + waveform traces
#   make clean
# ============================================================================

VERILATOR ?= verilator
PYTHON    ?= python3

UVM_REPO  := https://github.com/accellera-official/uvm-core.git
UVM_TAG   := 2020.3.1
UVM_DIR   := third_party/uvm-core
UVM_SRC   := $(UVM_DIR)/src

BUG       ?=
VARIANT   := $(if $(BUG),$(BUG),clean)
BUILD_DIR := build/$(VARIANT)
SIM       := $(BUILD_DIR)/Vtb_top

TEST      ?= ddr_smoke_test
SEED      ?= 1
NUM_TXN   ?=
OUT_DIR   ?= out/$(VARIANT)/$(TEST)_s$(SEED)

RTL_SRCS  := rtl/ddr_pkg.sv rtl/ddr_ctrl.sv
TB_SRCS   := tb/dram/ddr_dram_model.sv \
             tb/sva/ddr_protocol_sva.sv tb/sva/ddr_host_sva.sv \
             tb/sva/ddr_ctrl_internal_sva.sv tb/sva/ddr_binds.sv \
             tb/uvm/ddr_if.sv tb/uvm/ddr_tb_pkg.sv tb/tb_top.sv
TB_DEPS   := $(wildcard tb/uvm/*.svh)

VFLAGS := --binary --timing --assert --trace --trace-structs --timescale 1ns/1ps \
          -j 0 --build-jobs 0 \
          -Wno-fatal -Wno-lint -Wno-style \
          +define+UVM_NO_DPI +define+UVM_REPORT_DISABLE_FILE_LINE \
          +incdir+$(UVM_SRC) +incdir+tb/uvm \
          --top-module tb_top \
          $(if $(BUG),+define+$(BUG))

RUN_ARGS := +UVM_TESTNAME=$(TEST) +verilator+seed+$(SEED) +verilator+error+limit+1000 \
            $(if $(NUM_TXN),+NUM_TXN=$(NUM_TXN)) \
            $(if $(WAVES),+WAVES=$(OUT_DIR)/waves.vcd) \
            $(if $(TRACE),+TRACE) \
            +COV_FILE=$(OUT_DIR)/cov.json

.PHONY: all uvm build run lint regress bugs clean distclean

all: build

$(UVM_SRC)/uvm_pkg.sv:
	mkdir -p third_party
	git clone --depth 1 --branch $(UVM_TAG) $(UVM_REPO) $(UVM_DIR)

uvm: $(UVM_SRC)/uvm_pkg.sv

$(SIM): $(UVM_SRC)/uvm_pkg.sv $(RTL_SRCS) $(TB_SRCS) $(TB_DEPS)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD_DIR) -o Vtb_top \
	  $(UVM_SRC)/uvm_pkg.sv $(RTL_SRCS) $(TB_SRCS) > $(BUILD_DIR).log 2>&1 \
	  || (tail -40 $(BUILD_DIR).log; exit 1)
	@grep -E "^- Verilator: (Walltime|Built)" $(BUILD_DIR).log || true

build:
	@mkdir -p build
	@$(MAKE) --no-print-directory $(SIM)

run: build
	@mkdir -p $(OUT_DIR)
	$(SIM) $(RUN_ARGS) 2>&1 | tee $(OUT_DIR)/sim.log

lint:
	$(VERILATOR) --lint-only -Wall rtl/lint.vlt $(RTL_SRCS) --top-module ddr_ctrl

regress:
	$(PYTHON) scripts/regress.py

bugs:
	$(PYTHON) scripts/bug_hunt.py

clean:
	rm -rf build out

distclean: clean
	rm -rf third_party
