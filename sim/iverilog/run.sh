#!/usr/bin/env bash
# Icarus Verilog simulations for the Verilog RTL (MCU, VIA, DAFB).
set -e
cd "$(dirname "$0")"

run() {   # <name> <sources...>
	local name="$1"; shift
	echo "=== $name ==="
	iverilog -g2012 -o "$name.vvp" "$@"
	vvp "$name.vvp"
	rm -f "$name.vvp"
}

run tb_mcu  ../../rtl/chipset/mcu.sv  ddr3_model.v tb_mcu.v
run tb_via  ../../rtl/chipset/via.sv  tb_via.v
run tb_dafb ../../rtl/video/dafb.sv   tb_dafb.v
