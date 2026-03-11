REGTOOL ?= vendor/pulp_platform/register_interface/vendor/lowrisc_opentitan/util/regtool.py

RTL_DIR ?= rtl
SW_DIR ?= sw

# w25q128jw_controller
W25Q_NAME := w25q128jw_controller
W25Q_CFG := $(RTL_DIR)/$(W25Q_NAME)/data/$(W25Q_NAME).hjson
W25Q_RTL_OUT := $(RTL_DIR)/$(W25Q_NAME)/rtl
W25Q_SW_OUT := $(SW_DIR)/$(W25Q_NAME)

# Generated outputs
W25Q_RTL_FILES := $(W25Q_RTL_OUT)/$(W25Q_NAME)_reg_pkg.sv $(W25Q_RTL_OUT)/$(W25Q_NAME)_reg_top.sv
W25Q_SW_FILES := $(W25Q_SW_OUT)/$(W25Q_NAME)_regs.h

.PHONY: reg
reg: $(W25Q_RTL_FILES) $(W25Q_SW_FILES)

$(W25Q_RTL_FILES): $(W25Q_CFG)
	$(REGTOOL) -r -t $(W25Q_RTL_OUT) $<

$(W25Q_SW_FILES): $(W25Q_CFG)
	mkdir -p $(W25Q_SW_OUT)
	$(REGTOOL) --cdefines -o $@ $<

.PHONY: vendor
vendor:
	python3 util/vendor.py -Uv rtl/vendor/lowrisc_opentitan_spi_host.vendor.hjson
	python3 util/vendor.py -Uv rtl/vendor/yosyshq_picorv32.vendor.hjson
	python3 util/vendor.py -Uv rtl/vendor/pulp_platform.vendor.hjson
