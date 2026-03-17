REGTOOL ?= vendor/pulp_platform/register_interface/vendor/lowrisc_opentitan/util/regtool.py
PERIPH_STRUCTS_GEN ?= util/periph_structs_gen/periph_structs_gen.py
TEMPLATE_FILE ?= util/periph_structs_gen/periph_structs.tpl

RTL_DIR ?= rtl
SW_DIR ?= sw

FUSESOC   := fusesoc
CORE_NAME := x-heep:ip:spi

TB_ARGS ?= --gen_waves true --num_beats 10 --size_beat 2 --addr 0x00111000 --random_data true
# TB_ARGS ?= --random_data false
# make clean-sim TB_ARGS="--random_data false"

# w25q128jw_controller
W25Q_NAME := w25q128jw_controller
W25Q_CFG := $(RTL_DIR)/$(W25Q_NAME)/data/$(W25Q_NAME).hjson
W25Q_RTL_OUT := $(RTL_DIR)/$(W25Q_NAME)/rtl
W25Q_SW_OUT := $(SW_DIR)/$(W25Q_NAME)

# Generated outputs
W25Q_RTL_FILES := $(W25Q_RTL_OUT)/$(W25Q_NAME)_reg_pkg.sv $(W25Q_RTL_OUT)/$(W25Q_NAME)_reg_top.sv
W25Q_SW_FILES := $(W25Q_SW_OUT)/$(W25Q_NAME)_regs.h
W25Q_STRUCTS_FILE := $(W25Q_SW_OUT)/$(W25Q_NAME)_structs.h
W25Q_DOC_FILE := $(W25Q_SW_OUT)/$(W25Q_NAME)_regs.md

.PHONY: reg
reg: $(W25Q_RTL_FILES) $(W25Q_SW_FILES) $(W25Q_STRUCTS_FILE) $(W25Q_DOC_FILE)
	@printf -- 'Generating $(W25Q_NAME) registers...\n'

$(W25Q_RTL_FILES): $(W25Q_CFG)
	$(REGTOOL) -r -t $(W25Q_RTL_OUT) $<

$(W25Q_SW_FILES): $(W25Q_CFG)
	mkdir -p $(W25Q_SW_OUT)
	$(REGTOOL) --cdefines -o $@ $<

$(W25Q_STRUCTS_FILE): $(W25Q_CFG)
	mkdir -p $(W25Q_SW_OUT)
	python3 $(PERIPH_STRUCTS_GEN) --template_filename $(TEMPLATE_FILE) \
	                              --hjson_filename $< \
	                              --output_filename $@

$(W25Q_DOC_FILE): $(W25Q_CFG)
	mkdir -p $(W25Q_SW_OUT)
	$(REGTOOL) -d $< > $@

.PHONY: vendor
vendor:
	python3 util/vendor.py -Uv vendor/lowrisc_opentitan_spi_host.vendor.hjson
	python3 util/vendor.py -Uv vendor/yosyshq_picorv32.vendor.hjson
	python3 util/vendor.py -Uv vendor/pulp_platform.vendor.hjson
	python3 util/vendor.py -Uv vendor/pulp_platform_register_interface.vendor.hjson
	python3 util/vendor.py -Uv vendor/pulp_platform_axi.vendor.hjson
	python3 util/vendor.py -Uv vendor/lowrisc_opentitan.vendor.hjson
	python3 util/vendor.py -Uv vendor/pulp_platform_common_cells.vendor.hjson

.PHONY: clean-sim
clean-sim: clear-prompt clean sim

## Build project for simulation
.PHONY: build
build: lib
	@echo "## Building Simulation Model..."
	$(FUSESOC) run --target=sim --setup --build $(CORE_NAME)

## Run simulation
.PHONY: sim
sim: build
	@echo "## Running Simulation..."
	$(FUSESOC) run --target=sim --run $(CORE_NAME) --run_options="$(TB_ARGS)"

## Search for core file dependencies
.PHONY: lib
lib:
	@echo "## Creating Libraries..."
	$(FUSESOC) library add xspi . || true
	$(FUSESOC) library add vendors vendor || true

## Generate spi_subsystem_top_reg.sv
.PHONY: gen-reg
gen-reg:
	@$(RTL_DIR)/spi_subsystem.sh

## Generate spi_subsystem.sv
.PHONY: gen-spi
gen-spi: gen-reg
	python3 $(RTL_DIR)/spi_subsystem_gen.py $(RTL_DIR)/spi_subsystem.sv.tpl $(RTL_DIR)/spi_subsystem.sv

## Clean files
.PHONY: clean
clean:
	@echo "## Cleaning..."
	rm -rf build
	rm -f fusesoc.conf

## Clear prompt
.PHONY: clear-prompt
clear-prompt:
	@clear
