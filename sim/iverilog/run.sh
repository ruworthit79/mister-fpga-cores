#!/usr/bin/env bash
# Icarus Verilog simulation of the MCU <-> DDR3 controller.
set -e
cd "$(dirname "$0")"
iverilog -g2012 -o tb_mcu.vvp \
	../../rtl/chipset/mcu.sv \
	ddr3_model.v \
	tb_mcu.v
vvp tb_mcu.vvp
