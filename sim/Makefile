#==============================================================================
# HBM Memory Subsystem - Simulation Makefile
#
# Supports multiple simulators:
#   - Icarus Verilog (iverilog)
#   - Verilator
#   - Synopsys VCS
#   - Cadence Xcelium
#   - Mentor ModelSim/QuestaSim
#==============================================================================

# Project directories
TOP_DIR     := ..
RTL_DIR     := $(TOP_DIR)/rtl
TB_DIR      := $(TOP_DIR)/tb
PKG_DIR     := $(RTL_DIR)/pkg
SIM_DIR     := .
WORK_DIR    := work
LOG_DIR     := logs
WAVE_DIR    := waves

# Top-level module
TOP_MODULE  := hbm_tb

# Source files
PKG_FILES   := $(PKG_DIR)/hbm_params_pkg.sv

RTL_FILES   := $(RTL_DIR)/memory_bank.sv \
               $(RTL_DIR)/dram_controller.sv \
               $(RTL_DIR)/bank_interleaver.sv \
               $(RTL_DIR)/ecc_module.sv \
               $(RTL_DIR)/power_manager.sv \
               $(RTL_DIR)/wide_bus_interface.sv \
               $(RTL_DIR)/hbm_subsystem_top.sv

TB_FILES    := $(TB_DIR)/traffic_generator.sv \
               $(TB_DIR)/performance_monitor.sv \
               $(TB_DIR)/hbm_tb.sv

ALL_FILES   := $(PKG_FILES) $(RTL_FILES) $(TB_FILES)

# Simulator selection (default: iverilog)
SIM         ?= iverilog

# Simulation options
SIM_OPTS    := +define+SIMULATION
WAVE_OPTS   := +define+VCD_DUMP

#==============================================================================
# Icarus Verilog Configuration
#==============================================================================
IVERILOG    := iverilog
VVP         := vvp
IVERILOG_FLAGS := -g2012 -Wall -Wno-timescale

#==============================================================================
# Verilator Configuration
#==============================================================================
VERILATOR   := verilator
VERILATOR_FLAGS := --sv --timing --trace --trace-fst \
                   -Wno-WIDTH -Wno-UNUSED -Wno-UNOPTFLAT \
                   --top-module $(TOP_MODULE) \
                   -DSIMULATION

#==============================================================================
# VCS Configuration
#==============================================================================
VCS         := vcs
VCS_FLAGS   := -full64 -sverilog +v2k \
               -timescale=1ns/1ps \
               +define+SIMULATION \
               -debug_access+all

#==============================================================================
# Xcelium Configuration
#==============================================================================
XRUN        := xrun
XRUN_FLAGS  := -sv -64bit \
               -timescale 1ns/1ps \
               +define+SIMULATION \
               -access +rwc

#==============================================================================
# ModelSim/QuestaSim Configuration
#==============================================================================
VLIB        := vlib
VLOG        := vlog
VSIM        := vsim
QUESTA_FLAGS := -sv -timescale "1ns/1ps" +define+SIMULATION

#==============================================================================
# Phony Targets
#==============================================================================
.PHONY: all compile sim clean help \
        iverilog verilator vcs xcelium questa \
        wave lint

#==============================================================================
# Default Target
#==============================================================================
all: sim

#==============================================================================
# Directory Creation
#==============================================================================
$(WORK_DIR) $(LOG_DIR) $(WAVE_DIR):
	@mkdir -p $@

#==============================================================================
# Icarus Verilog Targets
#==============================================================================
iverilog: $(WORK_DIR) $(LOG_DIR) $(WAVE_DIR)
	@echo "========================================"
	@echo "Compiling with Icarus Verilog..."
	@echo "========================================"
	$(IVERILOG) $(IVERILOG_FLAGS) $(SIM_OPTS) $(WAVE_OPTS) \
		-s $(TOP_MODULE) \
		-o $(WORK_DIR)/$(TOP_MODULE).vvp \
		$(ALL_FILES) 2>&1 | tee $(LOG_DIR)/compile.log
	@echo "========================================"
	@echo "Running simulation..."
	@echo "========================================"
	cd $(WAVE_DIR) && $(VVP) ../$(WORK_DIR)/$(TOP_MODULE).vvp \
		2>&1 | tee ../$(LOG_DIR)/sim.log
	@echo "========================================"
	@echo "Simulation complete!"
	@echo "========================================"

#==============================================================================
# Verilator Targets
#==============================================================================
verilator: $(WORK_DIR) $(LOG_DIR) $(WAVE_DIR)
	@echo "========================================"
	@echo "Compiling with Verilator..."
	@echo "========================================"
	$(VERILATOR) $(VERILATOR_FLAGS) \
		--Mdir $(WORK_DIR)/verilator \
		--exe --build \
		-CFLAGS "-DVL_TIME_CONTEXT" \
		$(ALL_FILES) \
		verilator_main.cpp \
		2>&1 | tee $(LOG_DIR)/verilator.log
	@echo "========================================"
	@echo "Running Verilator simulation..."
	@echo "========================================"
	./$(WORK_DIR)/verilator/V$(TOP_MODULE) \
		2>&1 | tee $(LOG_DIR)/sim_verilator.log

#==============================================================================
# VCS Targets
#==============================================================================
vcs: $(WORK_DIR) $(LOG_DIR) $(WAVE_DIR)
	@echo "========================================"
	@echo "Compiling with VCS..."
	@echo "========================================"
	$(VCS) $(VCS_FLAGS) \
		-o $(WORK_DIR)/simv \
		-l $(LOG_DIR)/vcs_compile.log \
		$(ALL_FILES)
	@echo "========================================"
	@echo "Running VCS simulation..."
	@echo "========================================"
	./$(WORK_DIR)/simv \
		+vcs+flush+all \
		-l $(LOG_DIR)/vcs_sim.log

#==============================================================================
# Xcelium Targets
#==============================================================================
xcelium: $(WORK_DIR) $(LOG_DIR) $(WAVE_DIR)
	@echo "========================================"
	@echo "Running with Xcelium..."
	@echo "========================================"
	$(XRUN) $(XRUN_FLAGS) \
		-xmlibdirpath $(WORK_DIR) \
		-l $(LOG_DIR)/xrun.log \
		$(ALL_FILES)

#==============================================================================
# ModelSim/QuestaSim Targets
#==============================================================================
questa: $(WORK_DIR) $(LOG_DIR) $(WAVE_DIR)
	@echo "========================================"
	@echo "Compiling with QuestaSim..."
	@echo "========================================"
	$(VLIB) $(WORK_DIR)/questa_work
	$(VLOG) $(QUESTA_FLAGS) \
		-work $(WORK_DIR)/questa_work \
		-l $(LOG_DIR)/questa_compile.log \
		$(ALL_FILES)
	@echo "========================================"
	@echo "Running QuestaSim simulation..."
	@echo "========================================"
	$(VSIM) -c -do "run -all; quit" \
		-work $(WORK_DIR)/questa_work \
		-l $(LOG_DIR)/questa_sim.log \
		$(TOP_MODULE)

#==============================================================================
# Simulation Target (uses selected simulator)
#==============================================================================
sim:
ifeq ($(SIM),iverilog)
	$(MAKE) iverilog
else ifeq ($(SIM),verilator)
	$(MAKE) verilator
else ifeq ($(SIM),vcs)
	$(MAKE) vcs
else ifeq ($(SIM),xcelium)
	$(MAKE) xcelium
else ifeq ($(SIM),questa)
	$(MAKE) questa
else
	@echo "Unknown simulator: $(SIM)"
	@echo "Supported: iverilog, verilator, vcs, xcelium, questa"
	@exit 1
endif

#==============================================================================
# Waveform Viewing
#==============================================================================
wave:
	@if [ -f $(WAVE_DIR)/hbm_tb.vcd ]; then \
		gtkwave $(WAVE_DIR)/hbm_tb.vcd &; \
	elif [ -f $(WAVE_DIR)/hbm_tb.fst ]; then \
		gtkwave $(WAVE_DIR)/hbm_tb.fst &; \
	else \
		echo "No waveform file found!"; \
	fi

#==============================================================================
# Linting
#==============================================================================
lint: $(LOG_DIR)
	@echo "========================================"
	@echo "Running lint checks..."
	@echo "========================================"
	$(VERILATOR) --lint-only -Wall \
		-Wno-WIDTH -Wno-UNUSED \
		$(ALL_FILES) 2>&1 | tee $(LOG_DIR)/lint.log

#==============================================================================
# Clean
#==============================================================================
clean:
	@echo "Cleaning simulation artifacts..."
	rm -rf $(WORK_DIR)
	rm -rf $(LOG_DIR)
	rm -rf $(WAVE_DIR)
	rm -rf csrc DVEfiles simv.daidir
	rm -f *.vcd *.fst *.fsdb
	rm -f transcript vsim.wlf
	rm -f ucli.key vc_hdrs.h
	rm -rf xcelium.d .simvision
	@echo "Clean complete!"

#==============================================================================
# Help
#==============================================================================
help:
	@echo "HBM Memory Subsystem - Simulation Makefile"
	@echo ""
	@echo "Usage: make [target] [SIM=simulator]"
	@echo ""
	@echo "Targets:"
	@echo "  all        - Run simulation (default)"
	@echo "  sim        - Run simulation with selected simulator"
	@echo "  iverilog   - Compile and run with Icarus Verilog"
	@echo "  verilator  - Compile and run with Verilator"
	@echo "  vcs        - Compile and run with VCS"
	@echo "  xcelium    - Compile and run with Xcelium"
	@echo "  questa     - Compile and run with QuestaSim"
	@echo "  lint       - Run lint checks with Verilator"
	@echo "  wave       - Open waveform viewer"
	@echo "  clean      - Remove all generated files"
	@echo "  help       - Show this help message"
	@echo ""
	@echo "Simulators:"
	@echo "  SIM=iverilog   - Icarus Verilog (default)"
	@echo "  SIM=verilator  - Verilator"
	@echo "  SIM=vcs        - Synopsys VCS"
	@echo "  SIM=xcelium    - Cadence Xcelium"
	@echo "  SIM=questa     - Mentor QuestaSim"
	@echo ""
	@echo "Examples:"
	@echo "  make                    # Run with default simulator"
	@echo "  make SIM=vcs            # Run with VCS"
	@echo "  make lint               # Check for lint errors"
	@echo "  make wave               # View waveforms"
